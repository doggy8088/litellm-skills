#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${LITELLM_ENV_FILE:-${PROJECT_DIR}/.env}"
ARCHIVE_VALIDATOR="${SCRIPT_DIR}/validate-spendlogs-archive.py"
AGE_IDENTITY="${LITELLM_AGE_IDENTITY_FILE:-}"
MAX_MEMBER_BYTES="${LITELLM_ARCHIVE_MAX_MEMBER_BYTES:-8589934592}"
MAX_TOTAL_BYTES="${LITELLM_ARCHIVE_MAX_TOTAL_BYTES:-12884901888}"

MONTH=""
EXECUTE="false"
EXPLICIT_DRY_RUN="false"
EXPECT_COUNT=""
FORCE_CURRENT_MONTH="false"
ARCHIVE_FILE=""
RETENTION_ONLY="false"

COMPOSE_CMD=()
WORK_DIR=""
CONTAINER_ARCHIVE_DIR=""

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --month <YYYY-MM> [options]

Without --execute, this command is a non-destructive preview.

Options:
  --month <YYYY-MM>          UTC month to preview or delete.
  --dry-run                  Explicitly request a non-destructive preview.
  --execute                  Confirm deletion; also requires --expect-count.
  --expect-count <N>         Expected number of matching rows.
  --archive <archive.tar.gz.age> Validate encrypted archive proof and delete its exact request ID set.
  --age-identity <file>      Explicit age identity file (or LITELLM_AGE_IDENTITY_FILE).
  --retention-only           Confirm intentional deletion without archive proof.
  --force-current-month      Permit deletion for the current UTC month.
  -h, --help                 Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s UTC] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [[ -n "$CONTAINER_ARCHIVE_DIR" ]]; then
    compose exec -T postgres rm -rf "$CONTAINER_ARCHIVE_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

strip_quotes() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then
    s="${s:1:${#s}-2}"
  elif [[ "$s" == \'*\' && "$s" == *\' ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

dotenv_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  local line value
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | head -n 1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  strip_quotes "$value"
}

pg_user() { dotenv_get POSTGRES_USER "$ENV_FILE" || printf '%s' "litellm"; }
pg_db() { dotenv_get POSTGRES_DB "$ENV_FILE" || printf '%s' "litellm"; }

init_compose() {
  if have docker-compose; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  if have docker && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  die "docker compose not found."
}

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

postgres_container_id() {
  compose ps -q postgres 2>/dev/null | head -n 1
}

ensure_prereqs() {
  have docker || die "docker command not found."
  have python3 || die "python3 command not found."
  docker info >/dev/null 2>&1 || die "Docker is not running."
  [[ -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yml" || -f "$PROJECT_DIR/compose.yaml" ]] || die "compose file not found in $PROJECT_DIR."
  if [[ -n "$ARCHIVE_FILE" ]]; then
    have age || die "age command not found."
    have sha256sum || die "sha256sum command not found."
    [[ -f "$ARCHIVE_VALIDATOR" ]] || die "archive validator not found: $ARCHIVE_VALIDATOR"
  fi
}

next_month_start() {
  python3 - "$1" <<'PY'
import sys

try:
    year_text, month_text, day_text = sys.argv[1].split("-")
    year, month, day = int(year_text), int(month_text), int(day_text)
    if day != 1 or not 1 <= year <= 9999 or not 1 <= month <= 12:
        raise ValueError
    if month == 12:
        if year == 9999:
            raise ValueError
        year, month = year + 1, 1
    else:
        month += 1
except ValueError:
    raise SystemExit(1)

sys.stdout.write(f"{year:04d}-{month:02d}-01")
PY
}

verify_ciphertext_checksum() {
  local input="$1" sums expected recorded extra actual line_count
  sums="${input}.sha256"
  [[ -f "$sums" && -r "$sums" ]] || die "Required ciphertext checksum is missing: $sums"
  line_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$sums")"
  [[ "$line_count" == "1" ]] || die "Ciphertext checksum must contain exactly one non-empty line."
  IFS=' ' read -r expected recorded extra <"$sums" || die "Could not read ciphertext checksum."
  [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || die "Ciphertext checksum is invalid."
  recorded="${recorded#\*}"
  [[ "$recorded" == "$(basename -- "$input")" && -z "${extra:-}" ]] || die "Ciphertext checksum filename does not match the archive."
  actual="$(sha256sum "$input" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "Ciphertext checksum verification failed."
}

validate_month() {
  [[ "$MONTH" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "--month must use YYYY-MM."
}

manifest_get() {
  local key="$1" manifest_file="$2" count
  count="$(grep -c -E "^${key}=" "$manifest_file" || true)"
  [[ "$count" == "1" ]] || die "Manifest key ${key} must occur exactly once."
  grep -E "^${key}=" "$manifest_file" | cut -d= -f2-
}

month_summary() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
SET TIME ZONE 'UTC';
SELECT
  COUNT(*) AS rows,
  COALESCE(MIN("startTime")::text, '') AS first_start_time,
  COALESCE(MAX("startTime")::text, '') AS last_start_time
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${start_ts}+00'::timestamptz
  AND "startTime" < '${end_ts}+00'::timestamptz;
SQL
}

archive_set_summary() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4" request_ids_path="$5"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN;
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE _spendlogs_archive_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
\copy _spendlogs_archive_ids(request_id) FROM '${request_ids_path}' WITH (FORMAT csv, HEADER true);
SELECT
  (SELECT COUNT(*) FROM _spendlogs_archive_ids) AS archive_ids,
  (SELECT COUNT(*)
   FROM public."LiteLLM_SpendLogs"
   WHERE "startTime" >= '${start_ts}+00'::timestamptz
     AND "startTime" < '${end_ts}+00'::timestamptz) AS database_rows,
  (SELECT COUNT(*)
   FROM _spendlogs_archive_ids ids
   LEFT JOIN public."LiteLLM_SpendLogs" target
     ON target.request_id = ids.request_id
    AND target."startTime" >= '${start_ts}+00'::timestamptz
    AND target."startTime" < '${end_ts}+00'::timestamptz
   WHERE target.request_id IS NULL) AS archive_ids_missing_in_month,
  (SELECT COUNT(*)
   FROM public."LiteLLM_SpendLogs" target
   LEFT JOIN _spendlogs_archive_ids ids ON ids.request_id = target.request_id
   WHERE target."startTime" >= '${start_ts}+00'::timestamptz
     AND target."startTime" < '${end_ts}+00'::timestamptz
     AND ids.request_id IS NULL) AS month_rows_missing_in_archive;
ROLLBACK;
SQL
}

delete_archived_rows() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4" expected_count="$5" request_ids_path="$6"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL TIME ZONE 'UTC';
LOCK TABLE public."LiteLLM_SpendLogs" IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE _spendlogs_archive_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
\copy _spendlogs_archive_ids(request_id) FROM '${request_ids_path}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  id_count bigint;
  month_count bigint;
BEGIN
  SELECT COUNT(*) INTO id_count FROM _spendlogs_archive_ids;
  SELECT COUNT(*) INTO month_count
  FROM public."LiteLLM_SpendLogs"
  WHERE "startTime" >= '${start_ts}+00'::timestamptz
    AND "startTime" < '${end_ts}+00'::timestamptz;

  IF id_count <> ${expected_count} OR month_count <> ${expected_count} THEN
    RAISE EXCEPTION 'count mismatch: expected %, archive IDs %, database month rows %', ${expected_count}, id_count, month_count;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM _spendlogs_archive_ids ids
    LEFT JOIN public."LiteLLM_SpendLogs" target
      ON target.request_id = ids.request_id
     AND target."startTime" >= '${start_ts}+00'::timestamptz
     AND target."startTime" < '${end_ts}+00'::timestamptz
    WHERE target.request_id IS NULL
  ) OR EXISTS (
    SELECT 1
    FROM public."LiteLLM_SpendLogs" target
    LEFT JOIN _spendlogs_archive_ids ids ON ids.request_id = target.request_id
    WHERE target."startTime" >= '${start_ts}+00'::timestamptz
      AND target."startTime" < '${end_ts}+00'::timestamptz
      AND ids.request_id IS NULL
  ) THEN
    RAISE EXCEPTION 'archive request ID set does not exactly match the database UTC month';
  END IF;
END
\$\$;
CREATE TEMP TABLE _spendlogs_delete_result (
  matched_rows bigint NOT NULL,
  deleted_rows bigint NOT NULL
) ON COMMIT DROP;
WITH deleted AS (
  DELETE FROM public."LiteLLM_SpendLogs" target
  USING _spendlogs_archive_ids ids
  WHERE target.request_id = ids.request_id
    AND target."startTime" >= '${start_ts}+00'::timestamptz
    AND target."startTime" < '${end_ts}+00'::timestamptz
  RETURNING 1
)
INSERT INTO _spendlogs_delete_result(matched_rows, deleted_rows)
SELECT ${expected_count}, COUNT(*) FROM deleted;
DO \$\$
DECLARE
  deleted_count bigint;
  remaining_count bigint;
BEGIN
  SELECT deleted_rows INTO deleted_count FROM _spendlogs_delete_result;
  IF deleted_count <> ${expected_count} THEN
    RAISE EXCEPTION 'deleted row count mismatch: expected %, got %', ${expected_count}, deleted_count;
  END IF;
  SELECT COUNT(*) INTO remaining_count
  FROM public."LiteLLM_SpendLogs"
  WHERE "startTime" >= '${start_ts}+00'::timestamptz
    AND "startTime" < '${end_ts}+00'::timestamptz;
  IF remaining_count <> 0 THEN
    RAISE EXCEPTION 'UTC month still contains % rows after guarded deletion', remaining_count;
  END IF;
END
\$\$;
SELECT matched_rows, deleted_rows FROM _spendlogs_delete_result;
COMMIT;
SQL
}

delete_retention_rows() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4" expected_count="$5"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL TIME ZONE 'UTC';
LOCK TABLE public."LiteLLM_SpendLogs" IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE _spendlogs_delete_month_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
INSERT INTO _spendlogs_delete_month_ids(request_id)
SELECT request_id
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${start_ts}+00'::timestamptz
  AND "startTime" < '${end_ts}+00'::timestamptz;
DO \$\$
DECLARE
  matched_count bigint;
BEGIN
  SELECT COUNT(*) INTO matched_count FROM _spendlogs_delete_month_ids;
  IF matched_count <> ${expected_count} THEN
    RAISE EXCEPTION 'matched row count mismatch: expected %, got %', ${expected_count}, matched_count;
  END IF;
END
\$\$;
CREATE TEMP TABLE _spendlogs_delete_result (
  matched_rows bigint NOT NULL,
  deleted_rows bigint NOT NULL
) ON COMMIT DROP;
WITH deleted AS (
  DELETE FROM public."LiteLLM_SpendLogs" target
  USING _spendlogs_delete_month_ids ids
  WHERE target.request_id = ids.request_id
    AND target."startTime" >= '${start_ts}+00'::timestamptz
    AND target."startTime" < '${end_ts}+00'::timestamptz
  RETURNING 1
)
INSERT INTO _spendlogs_delete_result(matched_rows, deleted_rows)
SELECT ${expected_count}, COUNT(*) FROM deleted;
DO \$\$
DECLARE
  deleted_count bigint;
  remaining_count bigint;
BEGIN
  SELECT deleted_rows INTO deleted_count FROM _spendlogs_delete_result;
  IF deleted_count <> ${expected_count} THEN
    RAISE EXCEPTION 'deleted row count mismatch: expected %, got %', ${expected_count}, deleted_count;
  END IF;
  SELECT COUNT(*) INTO remaining_count
  FROM public."LiteLLM_SpendLogs"
  WHERE "startTime" >= '${start_ts}+00'::timestamptz
    AND "startTime" < '${end_ts}+00'::timestamptz;
  IF remaining_count <> 0 THEN
    RAISE EXCEPTION 'UTC month still contains % rows after guarded deletion', remaining_count;
  END IF;
END
\$\$;
SELECT matched_rows, deleted_rows FROM _spendlogs_delete_result;
COMMIT;
SQL
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --month)
      [[ $# -ge 2 ]] || die "--month requires a value."
      MONTH="$2"
      shift 2
      ;;
    --dry-run)
      EXPLICIT_DRY_RUN="true"
      shift
      ;;
    --execute)
      EXECUTE="true"
      shift
      ;;
    --expect-count)
      [[ $# -ge 2 ]] || die "--expect-count requires a value."
      EXPECT_COUNT="$2"
      shift 2
      ;;
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a value."
      ARCHIVE_FILE="$2"
      shift 2
      ;;
    --age-identity)
      [[ $# -ge 2 ]] || die "--age-identity requires a value."
      AGE_IDENTITY="$2"
      shift 2
      ;;
    --retention-only)
      RETENTION_ONLY="true"
      shift
      ;;
    --force-current-month)
      FORCE_CURRENT_MONTH="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$MONTH" ]] || die "--month is required."
validate_month
[[ -z "$EXPECT_COUNT" || "$EXPECT_COUNT" =~ ^[0-9]+$ ]] || die "--expect-count must be a non-negative integer."
[[ "$EXECUTE" != "true" || "$EXPLICIT_DRY_RUN" != "true" ]] || die "--execute and --dry-run cannot be used together."
[[ -z "$ARCHIVE_FILE" || "$RETENTION_ONLY" != "true" ]] || die "--archive and --retention-only are mutually exclusive."
[[ "$MAX_MEMBER_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_ARCHIVE_MAX_MEMBER_BYTES must be positive."
[[ "$MAX_TOTAL_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_ARCHIVE_MAX_TOTAL_BYTES must be positive."
((MAX_TOTAL_BYTES >= MAX_MEMBER_BYTES)) || die "Archive total-size limit must be at least the member-size limit."

if [[ "$EXECUTE" == "true" ]]; then
  [[ -n "$EXPECT_COUNT" ]] || die "--execute requires --expect-count N."
  [[ -n "$ARCHIVE_FILE" || "$RETENTION_ONLY" == "true" ]] || die "--execute requires --archive FILE; use --retention-only only for an intentional unarchived deletion."
else
  [[ "$FORCE_CURRENT_MONTH" != "true" ]] || die "--force-current-month is valid only with --execute."
  [[ "$RETENTION_ONLY" != "true" ]] || die "--retention-only is valid only with --execute."
fi

CURRENT_UTC_MONTH="$(date -u +%Y-%m)"
if [[ "$EXECUTE" == "true" && "$MONTH" == "$CURRENT_UTC_MONTH" && "$FORCE_CURRENT_MONTH" != "true" ]]; then
  die "Refusing to delete the current UTC month; pass --force-current-month only after verifying active writes are stopped."
fi

if [[ -n "$ARCHIVE_FILE" ]]; then
  [[ -f "$ARCHIVE_FILE" ]] || die "Archive file not found: $ARCHIVE_FILE"
  [[ "${ARCHIVE_FILE,,}" == *.tar.gz.age ]] || die "Only .tar.gz.age archive proof is accepted."
  [[ -n "$AGE_IDENTITY" ]] || die "set LITELLM_AGE_IDENTITY_FILE or pass --age-identity."
  [[ -f "$AGE_IDENTITY" && -r "$AGE_IDENTITY" ]] || die "Age identity file is not readable."
  ARCHIVE_DIR="$(cd -- "$(dirname -- "$ARCHIVE_FILE")" && pwd -P)"
  ARCHIVE_FILE="${ARCHIVE_DIR}/$(basename -- "$ARCHIVE_FILE")"
  AGE_IDENTITY_DIR="$(cd -- "$(dirname -- "$AGE_IDENTITY")" && pwd -P)"
  AGE_IDENTITY="${AGE_IDENTITY_DIR}/$(basename -- "$AGE_IDENTITY")"
fi

init_compose
ensure_prereqs
cd "$PROJECT_DIR"

DB_USER="$(pg_user)"
DB_NAME="$(pg_db)"
PG_CID="$(postgres_container_id)"
[[ -n "$PG_CID" ]] || die "postgres container is not running."

START_DATE="${MONTH}-01"
END_DATE="$(next_month_start "$START_DATE")" || die "Could not calculate the next month."
START_TS="${START_DATE} 00:00:00"
END_TS="${END_DATE} 00:00:00"

ARCHIVE_ROW_COUNT=""
CONTAINER_REQUEST_IDS_FILE=""
if [[ -n "$ARCHIVE_FILE" ]]; then
  WORK_DIR="$(mktemp -d)"
  chmod 700 "$WORK_DIR"
  DECRYPTED_ARCHIVE="${WORK_DIR}/archive.tar.gz"
  verify_ciphertext_checksum "$ARCHIVE_FILE"
  age --decrypt --identity "$AGE_IDENTITY" --output "$DECRYPTED_ARCHIVE" "$ARCHIVE_FILE"
  [[ -s "$DECRYPTED_ARCHIVE" ]] || die "age produced an empty plaintext archive."
  chmod 600 "$DECRYPTED_ARCHIVE"
  EXTRACT_DIR="${WORK_DIR}/archive"
  python3 "$ARCHIVE_VALIDATOR" \
    --max-member-bytes "$MAX_MEMBER_BYTES" \
    --max-total-bytes "$MAX_TOTAL_BYTES" \
    "$DECRYPTED_ARCHIVE" "$EXTRACT_DIR" >/dev/null
  rm -f "$DECRYPTED_ARCHIVE"
  DECRYPTED_ARCHIVE=""
  MANIFEST_FILE="${EXTRACT_DIR}/manifest.env"
  ARCHIVE_MONTH="$(manifest_get month "$MANIFEST_FILE")"
  ARCHIVE_ROW_COUNT="$(manifest_get row_count "$MANIFEST_FILE")"
  [[ "$ARCHIVE_MONTH" == "$MONTH" ]] || die "Archive month ${ARCHIVE_MONTH} does not match --month ${MONTH}."
  [[ -z "$EXPECT_COUNT" || "$ARCHIVE_ROW_COUNT" == "$EXPECT_COUNT" ]] || die "Archive row count mismatch: expected=${EXPECT_COUNT}, archive=${ARCHIVE_ROW_COUNT}."

  CONTAINER_ARCHIVE_DIR="$(compose exec -T postgres mktemp -d /tmp/litellm_spendlogs_delete_XXXXXX | tr -d '\r')"
  [[ -n "$CONTAINER_ARCHIVE_DIR" ]] || die "Could not create container temp directory."
  CONTAINER_REQUEST_IDS_FILE="${CONTAINER_ARCHIVE_DIR}/request_ids.csv"
  docker cp "${EXTRACT_DIR}/data/request_ids.csv" "${PG_CID}:${CONTAINER_REQUEST_IDS_FILE}"
fi

STATS="$(month_summary "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS")"
STATS="$(printf '%s\n' "$STATS" | awk -F'|' '/^[0-9]+\|/ { line=$0 } END { print line }')"
[[ -n "$STATS" ]] || die "Could not parse month summary from psql output."
IFS='|' read -r ROWS FIRST_START LAST_START <<< "$STATS"

if [[ "$EXECUTE" != "true" ]]; then
  log "Dry run only. No rows will be deleted."
  printf 'table=public."LiteLLM_SpendLogs"\n'
  printf 'month=%s\n' "$MONTH"
  printf 'range_start=%sZ\n' "${START_TS/ /T}"
  printf 'range_end=%sZ\n' "${END_TS/ /T}"
  printf 'row_count=%s\n' "$ROWS"
  printf 'first_start_time=%s\n' "$FIRST_START"
  printf 'last_start_time=%s\n' "$LAST_START"
  if [[ -n "$ARCHIVE_FILE" ]]; then
    SET_STATS="$(archive_set_summary "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS" "$CONTAINER_REQUEST_IDS_FILE")"
    SET_STATS="$(printf '%s\n' "$SET_STATS" | awk -F'|' '/^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$/ { line=$0 } END { print line }')"
    [[ -n "$SET_STATS" ]] || die "Could not parse archive set comparison from psql output."
    IFS='|' read -r ARCHIVE_IDS DATABASE_ROWS ARCHIVE_IDS_MISSING MONTH_ROWS_MISSING <<< "$SET_STATS"
    printf 'archive_row_count=%s\n' "$ARCHIVE_ROW_COUNT"
    printf 'archive_ids_missing_in_month=%s\n' "$ARCHIVE_IDS_MISSING"
    printf 'month_rows_missing_in_archive=%s\n' "$MONTH_ROWS_MISSING"
    [[ "$ARCHIVE_IDS" == "$ARCHIVE_ROW_COUNT" && "$DATABASE_ROWS" == "$ROWS" && "$ARCHIVE_IDS_MISSING" == "0" && "$MONTH_ROWS_MISSING" == "0" ]] || die "Archive request ID set does not exactly match the database UTC month."
  fi
  [[ -z "$EXPECT_COUNT" || "$ROWS" == "$EXPECT_COUNT" ]] || die "row count mismatch: expected=${EXPECT_COUNT}, actual=${ROWS}"
  exit 0
fi

[[ "$ROWS" == "$EXPECT_COUNT" ]] || die "row count changed or was mis-estimated: expected=${EXPECT_COUNT}, actual=${ROWS}; nothing deleted."
log "Deleting ${EXPECT_COUNT} LiteLLM_SpendLogs rows for UTC month ${MONTH}..."
if [[ -n "$ARCHIVE_FILE" ]]; then
  RESULT="$(delete_archived_rows "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS" "$EXPECT_COUNT" "$CONTAINER_REQUEST_IDS_FILE")"
else
  RESULT="$(delete_retention_rows "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS" "$EXPECT_COUNT")"
fi
RESULT="$(printf '%s\n' "$RESULT" | awk -F'|' '/^[0-9]+\|[0-9]+$/ { line=$0 } END { print line }')"
[[ -n "$RESULT" ]] || die "Could not parse delete result from psql output."

IFS='|' read -r MATCHED_ROWS DELETED_ROWS <<< "$RESULT"
[[ "$MATCHED_ROWS" == "$EXPECT_COUNT" && "$DELETED_ROWS" == "$EXPECT_COUNT" ]] || die "delete result mismatch after transaction."
printf 'table=public."LiteLLM_SpendLogs"\n'
printf 'month=%s\n' "$MONTH"
printf 'range_start=%sZ\n' "${START_TS/ /T}"
printf 'range_end=%sZ\n' "${END_TS/ /T}"
printf 'matched_rows=%s\n' "$MATCHED_ROWS"
printf 'deleted_rows=%s\n' "$DELETED_ROWS"
