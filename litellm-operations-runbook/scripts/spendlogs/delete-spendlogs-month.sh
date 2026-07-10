#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${LITELLM_ENV_FILE:-${PROJECT_DIR}/.env}"

MONTH=""
DRY_RUN="false"
COMPOSE_CMD=()

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --month <YYYY-MM> [options]

Options:
  --month <YYYY-MM>          Month to delete from LiteLLM_SpendLogs.
  --dry-run                  Show range and row count without deleting.
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
  docker info >/dev/null 2>&1 || die "Docker is not running."
  [[ -f "$PROJECT_DIR/docker-compose.yml" || -f "$PROJECT_DIR/compose.yml" || -f "$PROJECT_DIR/compose.yaml" ]] || die "compose file not found in $PROJECT_DIR."
}

validate_month() {
  [[ "$MONTH" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "--month must use YYYY-MM."
}

month_summary() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
SELECT
  COUNT(*) AS rows,
  COALESCE(MIN("startTime")::text, '') AS first_start_time,
  COALESCE(MAX("startTime")::text, '') AS last_start_time
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${start_ts}'::timestamp
  AND "startTime" < '${end_ts}'::timestamp;
SQL
}

delete_month_rows() {
  local db_user="$1" db_name="$2" start_ts="$3" end_ts="$4"
  compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$db_user" -d "$db_name" -At -F '|' <<SQL
BEGIN;
CREATE TEMP TABLE _spendlogs_delete_month_ids (
  request_id text PRIMARY KEY
) ON COMMIT DROP;
INSERT INTO _spendlogs_delete_month_ids(request_id)
SELECT request_id
FROM public."LiteLLM_SpendLogs"
WHERE "startTime" >= '${start_ts}'::timestamp
  AND "startTime" < '${end_ts}'::timestamp;
WITH deleted AS (
  DELETE FROM public."LiteLLM_SpendLogs" target
  USING _spendlogs_delete_month_ids ids
  WHERE target.request_id = ids.request_id
  RETURNING 1
)
SELECT
  (SELECT COUNT(*) FROM _spendlogs_delete_month_ids) AS matched_rows,
  (SELECT COUNT(*) FROM deleted) AS deleted_rows;
COMMIT;
SQL
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --month)
      MONTH="${2:-}"
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

[[ -n "$MONTH" ]] || die "--month is required."
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

if [[ "$DRY_RUN" == "true" ]]; then
  STATS="$(month_summary "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS")"
  IFS='|' read -r ROWS FIRST_START LAST_START <<< "$STATS"
  log "Dry run only. No rows will be deleted."
  printf 'table=public."LiteLLM_SpendLogs"\n'
  printf 'month=%s\n' "$MONTH"
  printf 'range_start=%s\n' "${START_TS/ /T}"
  printf 'range_end=%s\n' "${END_TS/ /T}"
  printf 'row_count=%s\n' "$ROWS"
  printf 'first_start_time=%s\n' "$FIRST_START"
  printf 'last_start_time=%s\n' "$LAST_START"
  exit 0
fi

log "Deleting LiteLLM_SpendLogs rows for ${MONTH} (${START_TS} <= startTime < ${END_TS})..."
RESULT="$(delete_month_rows "$DB_USER" "$DB_NAME" "$START_TS" "$END_TS")"
RESULT="$(printf '%s\n' "$RESULT" | awk -F'|' '/^[0-9]+\|[0-9]+$/ { line=$0 } END { print line }')"
[[ -n "$RESULT" ]] || die "Could not parse delete result from psql output."

IFS='|' read -r MATCHED_ROWS DELETED_ROWS <<< "$RESULT"
printf 'table=public."LiteLLM_SpendLogs"\n'
printf 'month=%s\n' "$MONTH"
printf 'range_start=%s\n' "${START_TS/ /T}"
printf 'range_end=%s\n' "${END_TS/ /T}"
printf 'matched_rows=%s\n' "$MATCHED_ROWS"
printf 'deleted_rows=%s\n' "$DELETED_ROWS"
