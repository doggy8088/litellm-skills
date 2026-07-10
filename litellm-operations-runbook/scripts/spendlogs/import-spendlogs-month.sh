#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${LITELLM_ENV_FILE:-${PROJECT_DIR}/.env}"

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
Usage: ${SCRIPT_NAME} --file <archive.tar.gz> [options]

Options:
  --file <archive.tar.gz>    LiteLLM_SpendLogs monthly archive to import.
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

manifest_get() {
  local key="$1" manifest_file="$2"
  grep -E "^${key}=" "$manifest_file" | head -n 1 | cut -d= -f2-
}

verify_sha256() {
  local label="$1" file="$2" expected="$3"
  local actual
  [[ -f "$file" ]] || die "Missing ${label}: $file"
  [[ -n "$expected" ]] || die "Missing expected sha256 for ${label}."
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "${label} checksum mismatch. expected=${expected}, actual=${actual}"
}

run_import_sql() {
  local db_user="$1" db_name="$2" container_data_file="$3" expected_count="$4" mode="$5"
  local columns stage_columns output stats

  columns="$(columns_sql)"
  stage_columns="$(columns_sql "s")"

  if [[ "$mode" == "dry-run" ]]; then
    output="$(compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN;
CREATE TEMP TABLE _spendlogs_import_stage (
  LIKE public."LiteLLM_SpendLogs" INCLUDING DEFAULTS INCLUDING GENERATED
) ON COMMIT DROP;
\copy _spendlogs_import_stage(${columns}) FROM '${container_data_file}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  stage_count bigint;
  duplicate_count bigint;
BEGIN
  SELECT COUNT(*) INTO stage_count FROM _spendlogs_import_stage;
  IF stage_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive row count mismatch: expected %, got %', ${expected_count}, stage_count;
  END IF;

  SELECT COUNT(*) - COUNT(DISTINCT request_id) INTO duplicate_count FROM _spendlogs_import_stage;
  IF duplicate_count <> 0 THEN
    RAISE EXCEPTION 'archive contains duplicate request_id rows: %', duplicate_count;
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
CREATE TEMP TABLE _spendlogs_import_stage (
  LIKE public."LiteLLM_SpendLogs" INCLUDING DEFAULTS INCLUDING GENERATED
) ON COMMIT DROP;
\copy _spendlogs_import_stage(${columns}) FROM '${container_data_file}' WITH (FORMAT csv, HEADER true);
DO \$\$
DECLARE
  stage_count bigint;
  duplicate_count bigint;
BEGIN
  SELECT COUNT(*) INTO stage_count FROM _spendlogs_import_stage;
  IF stage_count <> ${expected_count} THEN
    RAISE EXCEPTION 'archive row count mismatch: expected %, got %', ${expected_count}, stage_count;
  END IF;

  SELECT COUNT(*) - COUNT(DISTINCT request_id) INTO duplicate_count FROM _spendlogs_import_stage;
  IF duplicate_count <> 0 THEN
    RAISE EXCEPTION 'archive contains duplicate request_id rows: %', duplicate_count;
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
      ARCHIVE_FILE="${2:-}"
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

init_compose
ensure_prereqs
cd "$PROJECT_DIR"

DB_USER="$(pg_user)"
DB_NAME="$(pg_db)"
PG_CID="$(postgres_container_id)"
[[ -n "$PG_CID" ]] || die "postgres container is not running."

WORK_DIR="$(mktemp -d)"
tar -xzf "$ARCHIVE_FILE" -C "$WORK_DIR"

MANIFEST_FILE="${WORK_DIR}/manifest.env"
[[ -f "$MANIFEST_FILE" ]] || die "manifest.env not found in archive."

ARCHIVE_FORMAT="$(manifest_get archive_format "$MANIFEST_FILE")"
MONTH="$(manifest_get month "$MANIFEST_FILE")"
ROW_COUNT="$(manifest_get row_count "$MANIFEST_FILE")"
DATA_REL="$(manifest_get data_file "$MANIFEST_FILE")"
DATA_SHA256="$(manifest_get data_sha256 "$MANIFEST_FILE")"
REQUEST_IDS_REL="$(manifest_get request_ids_file "$MANIFEST_FILE")"
REQUEST_IDS_SHA256="$(manifest_get request_ids_sha256 "$MANIFEST_FILE")"

[[ "$ARCHIVE_FORMAT" == "litellm_spendlogs_month_v1" ]] || die "Unsupported archive format: ${ARCHIVE_FORMAT:-missing}"
[[ "$ROW_COUNT" =~ ^[0-9]+$ ]] || die "Invalid row_count in manifest: ${ROW_COUNT:-missing}"
[[ -n "$DATA_REL" ]] || die "Missing data_file in manifest."
[[ -n "$REQUEST_IDS_REL" ]] || die "Missing request_ids_file in manifest."

DATA_FILE="${WORK_DIR}/${DATA_REL}"
REQUEST_IDS_FILE="${WORK_DIR}/${REQUEST_IDS_REL}"
verify_sha256 "data CSV" "$DATA_FILE" "$DATA_SHA256"
verify_sha256 "request_ids CSV" "$REQUEST_IDS_FILE" "$REQUEST_IDS_SHA256"

CONTAINER_IMPORT_DIR="$(compose exec -T postgres mktemp -d /tmp/litellm_spendlogs_import_XXXXXX | tr -d '\r')"
[[ -n "$CONTAINER_IMPORT_DIR" ]] || die "Could not create container temp directory."
CONTAINER_DATA_FILE="${CONTAINER_IMPORT_DIR}/LiteLLM_SpendLogs.csv"
docker cp "$DATA_FILE" "${PG_CID}:${CONTAINER_DATA_FILE}"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run only. Archive will be validated but no rows will be imported."
  STATS="$(run_import_sql "$DB_USER" "$DB_NAME" "$CONTAINER_DATA_FILE" "$ROW_COUNT" "dry-run")"
  IFS='|' read -r ARCHIVE_ROWS EXISTING_DUPLICATES WOULD_INSERT WOULD_SKIP <<< "$STATS"
  printf 'month=%s\n' "$MONTH"
  printf 'archive_rows=%s\n' "$ARCHIVE_ROWS"
  printf 'existing_duplicates=%s\n' "$EXISTING_DUPLICATES"
  printf 'would_insert=%s\n' "$WOULD_INSERT"
  printf 'would_skip=%s\n' "$WOULD_SKIP"
  exit 0
fi

log "Importing LiteLLM_SpendLogs archive: $ARCHIVE_FILE"
STATS="$(run_import_sql "$DB_USER" "$DB_NAME" "$CONTAINER_DATA_FILE" "$ROW_COUNT" "import")"
IFS='|' read -r ARCHIVE_ROWS EXISTING_DUPLICATES INSERTED_ROWS SKIPPED_DUPLICATES <<< "$STATS"

printf 'month=%s\n' "$MONTH"
printf 'archive_rows=%s\n' "$ARCHIVE_ROWS"
printf 'existing_duplicates=%s\n' "$EXISTING_DUPLICATES"
printf 'inserted_rows=%s\n' "$INSERTED_ROWS"
printf 'skipped_duplicates=%s\n' "$SKIPPED_DUPLICATES"
