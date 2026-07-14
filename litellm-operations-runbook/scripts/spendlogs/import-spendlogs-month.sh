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

ARCHIVE_FILE=""
DRY_RUN="false"

COMPOSE_CMD=()
CONTAINER_IMPORT_DIR=""
WORK_DIR=""

SPENDLOG_COLUMNS=(
  request_id
  call_type
  api_key
  spend
  total_tokens
  prompt_tokens
  completion_tokens
  startTime
  endTime
  request_duration_ms
  completionStartTime
  model
  model_id
  model_group
  custom_llm_provider
  api_base
  user
  metadata
  cache_hit
  cache_key
  request_tags
  team_id
  end_user
  requester_ip_address
  messages
  response
  proxy_server_request
  session_id
  status
  mcp_namespaced_tool_name
  organization_id
  agent_id
)

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --file <archive.tar.gz.age> [options]

Options:
  --file <archive.tar.gz.age> Encrypted LiteLLM_SpendLogs monthly archive.
  --age-identity <file>      Explicit age identity file (or LITELLM_AGE_IDENTITY_FILE).
  --dry-run                  Validate and report duplicate/insert counts without importing.
  -h, --help                 Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [[ -n "$CONTAINER_IMPORT_DIR" ]]; then
    compose exec -T postgres rm -rf "$CONTAINER_IMPORT_DIR" >/dev/null 2>&1 || true
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
  have age || die "age command not found."
  have sha256sum || die "sha256sum command not found."
  [[ -f "$ARCHIVE_VALIDATOR" ]] || die "archive validator not found: $ARCHIVE_VALIDATOR"
  docker info >/dev/null 2>&1 || die "Docker is not running."
  [[ -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yml" || -f "$PROJECT_DIR/compose.yaml" ]] || die "compose file not found in $PROJECT_DIR."
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

columns_sql() {
  local prefix="${1:-}"
  local joined="" col item
  for col in "${SPENDLOG_COLUMNS[@]}"; do
    if [[ -n "$prefix" ]]; then
      item="${prefix}.\"${col}\""
    else
      item="\"${col}\""
    fi
    joined+="${joined:+, }${item}"
  done
  printf '%s' "$joined"
}

manifest_get() {
  local key="$1" manifest_file="$2"
  local count
  count="$(grep -c -E "^${key}=" "$manifest_file" || true)"
  [[ "$count" == "1" ]] || die "Manifest key ${key} must occur exactly once."
  grep -E "^${key}=" "$manifest_file" | cut -d= -f2-
}

run_import_sql() {
  local db_user="$1" db_name="$2" container_data_file="$3" container_request_ids_file="$4" expected_count="$5" mode="$6"
  local columns stage_columns output stats

  columns="$(columns_sql)"
  stage_columns="$(columns_sql "s")"

  if [[ "$mode" == "dry-run" ]]; then
    output="$(compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN;
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE _spendlogs_import_stage (
  LIKE public."LiteLLM_SpendLogs" INCLUDING DEFAULTS INCLUDING GENERATED
) ON COMMIT DROP;
CREATE TEMP TABLE _spendlogs_archive_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
\copy _spendlogs_import_stage(${columns}) FROM '${container_data_file}' WITH (FORMAT csv, HEADER true);
\copy _spendlogs_archive_ids(request_id) FROM '${container_request_ids_file}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  stage_count bigint;
  id_count bigint;
  duplicate_count bigint;
BEGIN
  SELECT COUNT(*) INTO stage_count FROM _spendlogs_import_stage;
  IF stage_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive row count mismatch: expected %, got %', ${expected_count}, stage_count;
  END IF;

  SELECT COUNT(*) INTO id_count FROM _spendlogs_archive_ids;
  IF id_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive request ID count mismatch: expected %, got %', ${expected_count}, id_count;
  END IF;

  SELECT COUNT(*) - COUNT(DISTINCT request_id) INTO duplicate_count FROM _spendlogs_import_stage;
  IF duplicate_count <> 0 THEN
    RAISE EXCEPTION 'archive contains duplicate request_id rows: %', duplicate_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _spendlogs_import_stage stage
    WHERE NOT EXISTS (
      SELECT 1 FROM _spendlogs_archive_ids ids WHERE ids.request_id = stage.request_id
    )
  ) OR EXISTS (
    SELECT 1
    FROM _spendlogs_archive_ids ids
    WHERE NOT EXISTS (
      SELECT 1 FROM _spendlogs_import_stage stage WHERE stage.request_id = ids.request_id
    )
  ) THEN
    RAISE EXCEPTION 'request_ids.csv does not match the data CSV request_id set';
  END IF;
END
\$\$;
SELECT
  COUNT(*) AS archive_rows,
  COUNT(target.request_id) AS existing_duplicates,
  COUNT(*) - COUNT(target.request_id) AS would_insert,
  COUNT(target.request_id) AS would_skip
FROM _spendlogs_import_stage stage
LEFT JOIN public."LiteLLM_SpendLogs" target
  ON target.request_id = stage.request_id;
ROLLBACK;
SQL
)"
  else
    output="$(compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN;
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE _spendlogs_import_stage (
  LIKE public."LiteLLM_SpendLogs" INCLUDING DEFAULTS INCLUDING GENERATED
) ON COMMIT DROP;
CREATE TEMP TABLE _spendlogs_archive_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
\copy _spendlogs_import_stage(${columns}) FROM '${container_data_file}' WITH (FORMAT csv, HEADER true);
\copy _spendlogs_archive_ids(request_id) FROM '${container_request_ids_file}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  stage_count bigint;
  id_count bigint;
  duplicate_count bigint;
BEGIN
  SELECT COUNT(*) INTO stage_count FROM _spendlogs_import_stage;
  IF stage_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive row count mismatch: expected %, got %', ${expected_count}, stage_count;
  END IF;

  SELECT COUNT(*) INTO id_count FROM _spendlogs_archive_ids;
  IF id_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive request ID count mismatch: expected %, got %', ${expected_count}, id_count;
  END IF;

  SELECT COUNT(*) - COUNT(DISTINCT request_id) INTO duplicate_count FROM _spendlogs_import_stage;
  IF duplicate_count <> 0 THEN
    RAISE EXCEPTION 'archive contains duplicate request_id rows: %', duplicate_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _spendlogs_import_stage stage
    WHERE NOT EXISTS (
      SELECT 1 FROM _spendlogs_archive_ids ids WHERE ids.request_id = stage.request_id
    )
  ) OR EXISTS (
    SELECT 1
    FROM _spendlogs_archive_ids ids
    WHERE NOT EXISTS (
      SELECT 1 FROM _spendlogs_import_stage stage WHERE stage.request_id = ids.request_id
    )
  ) THEN
    RAISE EXCEPTION 'request_ids.csv does not match the data CSV request_id set';
  END IF;
END
\$\$;
WITH stats AS (
  SELECT
    COUNT(*) AS archive_rows,
    COUNT(target.request_id) AS existing_duplicates
  FROM _spendlogs_import_stage stage
  LEFT JOIN public."LiteLLM_SpendLogs" target
    ON target.request_id = stage.request_id
),
inserted AS (
  INSERT INTO public."LiteLLM_SpendLogs"(${columns})
  SELECT ${stage_columns}
  FROM _spendlogs_import_stage s
  ON CONFLICT (request_id) DO NOTHING
  RETURNING 1
)
SELECT
  stats.archive_rows,
  stats.existing_duplicates,
  (SELECT COUNT(*) FROM inserted) AS inserted_rows,
  stats.archive_rows - (SELECT COUNT(*) FROM inserted) AS skipped_duplicates
FROM stats;
COMMIT;
SQL
)"
  fi

  stats="$(printf '%s\n' "$output" | awk -F'|' '/^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$/ { line=$0 } END { print line }')"
  [[ -n "$stats" ]] || die "Could not parse import statistics from psql output."
  printf '%s' "$stats"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || die "--file requires a value."
      ARCHIVE_FILE="$2"
      shift 2
      ;;
    --age-identity)
      [[ $# -ge 2 ]] || die "--age-identity requires a value."
      AGE_IDENTITY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
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

[[ -n "$ARCHIVE_FILE" ]] || die "--file is required."
[[ -f "$ARCHIVE_FILE" ]] || die "Archive file not found: $ARCHIVE_FILE"
[[ "${ARCHIVE_FILE,,}" == *.tar.gz.age ]] || die "Only .tar.gz.age archives are accepted."
[[ -n "$AGE_IDENTITY" ]] || die "set LITELLM_AGE_IDENTITY_FILE or pass --age-identity."
[[ -f "$AGE_IDENTITY" && -r "$AGE_IDENTITY" ]] || die "Age identity file is not readable."
[[ "$MAX_MEMBER_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_ARCHIVE_MAX_MEMBER_BYTES must be positive."
[[ "$MAX_TOTAL_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_ARCHIVE_MAX_TOTAL_BYTES must be positive."
((MAX_TOTAL_BYTES >= MAX_MEMBER_BYTES)) || die "Archive total-size limit must be at least the member-size limit."
ARCHIVE_DIR="$(cd -- "$(dirname -- "$ARCHIVE_FILE")" && pwd -P)"
ARCHIVE_FILE="${ARCHIVE_DIR}/$(basename -- "$ARCHIVE_FILE")"
AGE_IDENTITY_DIR="$(cd -- "$(dirname -- "$AGE_IDENTITY")" && pwd -P)"
AGE_IDENTITY="${AGE_IDENTITY_DIR}/$(basename -- "$AGE_IDENTITY")"

init_compose
ensure_prereqs
cd "$PROJECT_DIR"

DB_USER="$(pg_user)"
DB_NAME="$(pg_db)"
PG_CID="$(postgres_container_id)"
[[ -n "$PG_CID" ]] || die "postgres container is not running."

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
[[ -f "$MANIFEST_FILE" ]] || die "manifest.env not found in archive."

ARCHIVE_FORMAT="$(manifest_get archive_format "$MANIFEST_FILE")"
MONTH="$(manifest_get month "$MANIFEST_FILE")"
ROW_COUNT="$(manifest_get row_count "$MANIFEST_FILE")"
DATA_REL="$(manifest_get data_file "$MANIFEST_FILE")"
REQUEST_IDS_REL="$(manifest_get request_ids_file "$MANIFEST_FILE")"

[[ "$ARCHIVE_FORMAT" == "litellm_spendlogs_month_v3" ]] || die "Unsupported archive format: ${ARCHIVE_FORMAT:-missing}"
[[ "$ROW_COUNT" =~ ^[0-9]+$ ]] || die "Invalid row_count in manifest: ${ROW_COUNT:-missing}"
[[ "$DATA_REL" == "data/LiteLLM_SpendLogs.csv" ]] || die "Invalid data_file in manifest."
[[ "$REQUEST_IDS_REL" == "data/request_ids.csv" ]] || die "Invalid request_ids_file in manifest."

DATA_FILE="${EXTRACT_DIR}/${DATA_REL}"
REQUEST_IDS_FILE="${EXTRACT_DIR}/${REQUEST_IDS_REL}"

CONTAINER_IMPORT_DIR="$(compose exec -T postgres mktemp -d /tmp/litellm_spendlogs_import_XXXXXX | tr -d '\r')"
[[ -n "$CONTAINER_IMPORT_DIR" ]] || die "Could not create container temp directory."
CONTAINER_DATA_FILE="${CONTAINER_IMPORT_DIR}/LiteLLM_SpendLogs.csv"
CONTAINER_REQUEST_IDS_FILE="${CONTAINER_IMPORT_DIR}/request_ids.csv"
docker cp "$DATA_FILE" "${PG_CID}:${CONTAINER_DATA_FILE}"
docker cp "$REQUEST_IDS_FILE" "${PG_CID}:${CONTAINER_REQUEST_IDS_FILE}"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run only. Archive will be validated but no rows will be imported."
  STATS="$(run_import_sql "$DB_USER" "$DB_NAME" "$CONTAINER_DATA_FILE" "$CONTAINER_REQUEST_IDS_FILE" "$ROW_COUNT" "dry-run")"
  IFS='|' read -r ARCHIVE_ROWS EXISTING_DUPLICATES WOULD_INSERT WOULD_SKIP <<< "$STATS"
  printf 'month=%s\n' "$MONTH"
  printf 'archive_rows=%s\n' "$ARCHIVE_ROWS"
  printf 'existing_duplicates=%s\n' "$EXISTING_DUPLICATES"
  printf 'would_insert=%s\n' "$WOULD_INSERT"
  printf 'would_skip=%s\n' "$WOULD_SKIP"
  exit 0
fi

log "Importing LiteLLM_SpendLogs archive: $ARCHIVE_FILE"
STATS="$(run_import_sql "$DB_USER" "$DB_NAME" "$CONTAINER_DATA_FILE" "$CONTAINER_REQUEST_IDS_FILE" "$ROW_COUNT" "import")"
IFS='|' read -r ARCHIVE_ROWS EXISTING_DUPLICATES INSERTED_ROWS SKIPPED_DUPLICATES <<< "$STATS"

printf 'month=%s\n' "$MONTH"
printf 'archive_rows=%s\n' "$ARCHIVE_ROWS"
printf 'existing_duplicates=%s\n' "$EXISTING_DUPLICATES"
printf 'inserted_rows=%s\n' "$INSERTED_ROWS"
printf 'skipped_duplicates=%s\n' "$SKIPPED_DUPLICATES"
