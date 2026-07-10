#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${LITELLM_ENV_FILE:-${PROJECT_DIR}/.env}"
DEFAULT_OUTPUT_DIR="${PROJECT_DIR}/backups/spendlogs"

MONTH=""
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
DRY_RUN="false"
DELETE_AFTER_EXPORT="false"

COMPOSE_CMD=()
CONTAINER_EXPORT_DIR=""
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
Usage: ${SCRIPT_NAME} --month <YYYY-MM> [options]

Options:
  --month <YYYY-MM>          Month to export from LiteLLM_SpendLogs.
  --output-dir <dir>         Output directory (default: backups/spendlogs).
  --dry-run                  Show range, row count, and output name only.
  --delete-after-export      Delete only the exported request_id rows after the archive is created.
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
  if [[ -n "$CONTAINER_EXPORT_DIR" ]]; then
    compose exec -T postgres rm -rf "$CONTAINER_EXPORT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

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
  have tar || die "tar command not found."
  have sha256sum || die "sha256sum command not found."
  docker info >/dev/null 2>&1 || die "Docker is not running."
  [[ -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yml" || -f "$PROJECT_DIR/compose.yaml" ]] || die "compose file not found in $PROJECT_DIR."
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

validate_month() {
  [[ "$MONTH" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "--month must use YYYY-MM."
}

count_month_rows() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4"
  compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -Atq <<SQL
SELECT COUNT(*)
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${start_ts}'::timestamp
  AND "startTime" < '${end_ts}'::timestamp;
SQL
}

count_request_ids_file() {
  local request_ids_file="$1"
  local lines
  lines="$(wc -l < "$request_ids_file" | tr -d '[:space:]')"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "Could not count request_ids.csv lines."
  (( lines >= 1 )) || die "request_ids.csv is missing its header."
  printf '%s' "$((lines - 1))"
}

delete_exported_rows() {
  local db_user="$1" db_name="$2" expected_count="$3" request_ids_path="$4"

  log "Deleting ${expected_count} exported rows from LiteLLM_SpendLogs..."
  compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" >/dev/null <<SQL
BEGIN;
CREATE TEMP TABLE _spendlogs_delete_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
\copy _spendlogs_delete_ids(request_id) FROM '${request_ids_path}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  id_count bigint;
  deleted_count bigint;
BEGIN
  SELECT COUNT(*) INTO id_count FROM _spendlogs_delete_ids;
  IF id_count <> ${expected_count} THEN
    RAISE EXCEPTION 'request id count mismatch: expected %, got %', ${expected_count}, id_count;
  END IF;

  WITH deleted AS (
    DELETE FROM public."LiteLLM_SpendLogs" target
    USING _spendlogs_delete_ids ids
    WHERE target.request_id = ids.request_id
    RETURNING 1
  )
  SELECT COUNT(*) INTO deleted_count FROM deleted;

  IF deleted_count <> ${expected_count} THEN
    RAISE EXCEPTION 'deleted row count mismatch: expected %, got %', ${expected_count}, deleted_count;
  END IF;
END
\$\$;
COMMIT;
SQL
  log "Deleted ${expected_count} rows."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --month)
      MONTH="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --delete-after-export)
      DELETE_AFTER_EXPORT="true"
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
[[ -n "$OUTPUT_DIR" ]] || die "--output-dir cannot be empty."
validate_month

init_compose
ensure_prereqs
cd "$PROJECT_DIR"

DB_USER="$(pg_user)"
DB_NAME="$(pg_db)"
PG_CID="$(postgres_container_id)"
[[ -n "$PG_CID" ]] || die "postgres container is not running."

START_DATE="${MONTH}-01"
END_DATE="$(date -u -d "${START_DATE} +1 month" +%Y-%m-%d)"
START_TS="${START_DATE} 00:00:00"
END_TS="${END_DATE} 00:00:00"
ARCHIVE_TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE_NAME="LiteLLM_SpendLogs_${MONTH}_${ARCHIVE_TS}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR%/}/${ARCHIVE_NAME}"

EXPECTED_COUNT="$(count_month_rows "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS" | tr -d '[:space:]')"
[[ "$EXPECTED_COUNT" =~ ^[0-9]+$ ]] || die "Could not read month row count."

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run only. No archive will be created and no rows will be deleted."
  printf 'table=public."LiteLLM_SpendLogs"\n'
  printf 'month=%s\n' "$MONTH"
  printf 'range_start=%s\n' "${START_TS/ /T}"
  printf 'range_end=%s\n' "${END_TS/ /T}"
  printf 'row_count=%s\n' "$EXPECTED_COUNT"
  printf 'output=%s\n' "$ARCHIVE_PATH"
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d)"
PACKAGE_DIR="${WORK_DIR}/package"
DATA_DIR="${PACKAGE_DIR}/data"
SCHEMA_DIR="${PACKAGE_DIR}/schema"
mkdir -p "$DATA_DIR" "$SCHEMA_DIR"

CONTAINER_EXPORT_DIR="$(compose exec -T postgres mktemp -d /tmp/litellm_spendlogs_export_XXXXXX | tr -d '\r')"
[[ -n "$CONTAINER_EXPORT_DIR" ]] || die "Could not create container temp directory."

CONTAINER_DATA_FILE="${CONTAINER_EXPORT_DIR}/LiteLLM_SpendLogs.csv"
CONTAINER_REQUEST_IDS_FILE="${CONTAINER_EXPORT_DIR}/request_ids.csv"
DATA_FILE="${DATA_DIR}/LiteLLM_SpendLogs.csv"
REQUEST_IDS_FILE="${DATA_DIR}/request_ids.csv"
SCHEMA_FILE="${SCHEMA_DIR}/LiteLLM_SpendLogs.schema.sql"
MANIFEST_FILE="${PACKAGE_DIR}/manifest.env"
T_COLUMNS="$(columns_sql "t")"

log "Exporting ${MONTH} from LiteLLM_SpendLogs (${START_TS} <= startTime < ${END_TS})..."
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" >/dev/null <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
CREATE TEMP TABLE _spendlogs_export_ids ON COMMIT DROP AS
SELECT request_id
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${START_TS}'::timestamp
  AND "startTime" < '${END_TS}'::timestamp;
\copy (SELECT ${T_COLUMNS} FROM public."LiteLLM_SpendLogs" t JOIN _spendlogs_export_ids ids ON ids.request_id = t.request_id ORDER BY t."startTime", t.request_id) TO '${CONTAINER_DATA_FILE}' WITH (FORMAT csv, HEADER true, FORCE_QUOTE *);
\copy (SELECT request_id FROM _spendlogs_export_ids ORDER BY request_id) TO '${CONTAINER_REQUEST_IDS_FILE}' WITH (FORMAT csv, HEADER true);
COMMIT;
SQL

docker cp "${PG_CID}:${CONTAINER_DATA_FILE}" "$DATA_FILE"
docker cp "${PG_CID}:${CONTAINER_REQUEST_IDS_FILE}" "$REQUEST_IDS_FILE"

ACTUAL_COUNT="$(count_request_ids_file "$REQUEST_IDS_FILE")"
if [[ "$ACTUAL_COUNT" != "$EXPECTED_COUNT" ]]; then
  log "WARNING: row count changed during export pre-check. precheck=${EXPECTED_COUNT}, exported=${ACTUAL_COUNT}."
fi

log "Dumping LiteLLM_SpendLogs schema..."
compose exec -T postgres pg_dump -U "$DB_USER" -d "$DB_NAME" --schema-only -t 'public."LiteLLM_SpendLogs"' > "$SCHEMA_FILE"

DATA_SHA256="$(sha256sum "$DATA_FILE" | awk '{print $1}')"
REQUEST_IDS_SHA256="$(sha256sum "$REQUEST_IDS_FILE" | awk '{print $1}')"
EXPORTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$MANIFEST_FILE" <<EOF
archive_format=litellm_spendlogs_month_v1
table_schema=public
table_name=LiteLLM_SpendLogs
month=${MONTH}
range_start=${START_TS/ /T}
range_end=${END_TS/ /T}
timezone_basis=DB_UTC
row_count=${ACTUAL_COUNT}
exported_at_utc=${EXPORTED_AT_UTC}
source_database=${DB_NAME}
data_file=data/LiteLLM_SpendLogs.csv
data_sha256=${DATA_SHA256}
request_ids_file=data/request_ids.csv
request_ids_sha256=${REQUEST_IDS_SHA256}
schema_file=schema/LiteLLM_SpendLogs.schema.sql
EOF

tar -czf "$ARCHIVE_PATH" -C "$PACKAGE_DIR" manifest.env data schema
log "Archive created: $ARCHIVE_PATH"
log "Exported rows: $ACTUAL_COUNT"

if [[ "$DELETE_AFTER_EXPORT" == "true" ]]; then
  delete_exported_rows "$DB_USER" "$DB_NAME" "$ACTUAL_COUNT" "$CONTAINER_REQUEST_IDS_FILE"
fi
