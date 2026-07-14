#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
BACKUP_SCRIPTS="${REPO_ROOT}/litellm-operations-runbook/scripts/backup-restore"
SPENDLOG_SCRIPTS="${REPO_ROOT}/litellm-operations-runbook/scripts/spendlogs"
TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK_DIR="${LITELLM_INTEGRATION_DIR:-${TEMP_ROOT}/litellm-skills-integration}"
PROJECT_DIR="${WORK_DIR}/project"
BACKUPS_DIR="${WORK_DIR}/backups"
SPENDLOGS_DIR="${WORK_DIR}/spendlogs"
AGE_IDENTITY="${WORK_DIR}/age-identity.txt"
TARGET_MONTH="2020-01"

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-skills-integration}"

log() {
  printf '[integration] %s\n' "$*"
}

die() {
  printf '[integration] ERROR: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

compose() {
  docker compose \
    --project-directory "$PROJECT_DIR" \
    --file "${PROJECT_DIR}/compose.yml" \
    "$@"
}

cleanup() {
  local status
  status="${1:-0}"
  trap - EXIT INT TERM
  if [[ -f "${PROJECT_DIR}/compose.yml" ]] && have docker; then
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_DIR"
  return "$status"
}

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

raw = sys.argv[1]
resolved = os.path.realpath(raw)
if "\n" in raw or "\r" in raw or "\n" in resolved or "\r" in resolved:
    raise SystemExit(1)
sys.stdout.write(resolved)
PY
}

have python3 || die "required command not found: python3"
TEMP_ROOT="$(canonical_path "$TEMP_ROOT")" || die "could not canonicalize the temporary root"
WORK_DIR="$(canonical_path "$WORK_DIR")" || die "could not canonicalize the integration work directory"
[[ "$TEMP_ROOT" != "/" ]] || die "temporary root must not be the filesystem root"
case "$WORK_DIR" in
  "$TEMP_ROOT"/*) ;;
  *) die "integration work directory must be below $TEMP_ROOT: $WORK_DIR" ;;
esac
[[ "$WORK_DIR" != "$TEMP_ROOT" ]] || die "integration work directory must not equal the temporary root"
[[ "$(basename -- "$WORK_DIR")" == "litellm-skills-integration" ]] || \
  die "integration work directory must end with litellm-skills-integration: $WORK_DIR"
PROJECT_DIR="${WORK_DIR}/project"
BACKUPS_DIR="${WORK_DIR}/backups"
SPENDLOGS_DIR="${WORK_DIR}/spendlogs"
AGE_IDENTITY="${WORK_DIR}/age-identity.txt"

if [[ "${1:-run}" == "cleanup" ]]; then
  cleanup 0
  exit 0
fi
[[ "${1:-run}" == "run" ]] || die "usage: $0 [run|cleanup]"

trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in age age-keygen docker sha256sum tar zip; do
  have "$command" || die "required command not found: $command"
done
docker compose version >/dev/null
docker info >/dev/null

rm -rf -- "$WORK_DIR"
mkdir -p -- "$PROJECT_DIR" "$BACKUPS_DIR" "$SPENDLOGS_DIR"
cp -- "${SCRIPT_DIR}/compose.yml" "${PROJECT_DIR}/compose.yml"
POSTGRES_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
printf '%s\n' \
  'POSTGRES_USER=litellm' \
  "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  'POSTGRES_DB=litellm' >"${PROJECT_DIR}/.env"
unset POSTGRES_PASSWORD

log "Generating an ephemeral age identity"
age-keygen --output "$AGE_IDENTITY" >/dev/null
chmod 600 "$AGE_IDENTITY"
AGE_RECIPIENT="$(age-keygen -y "$AGE_IDENTITY")"
[[ "$AGE_RECIPIENT" == age1* ]] || die "age-keygen did not produce an X25519 recipient"

log "Starting PostgreSQL 16"
compose up --detach --wait

log "Creating the SpendLogs fixture"
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U litellm -d litellm <<'SQL'
CREATE TABLE public."LiteLLM_SpendLogs" (
  request_id text PRIMARY KEY,
  call_type text,
  api_key text,
  spend double precision,
  total_tokens bigint,
  prompt_tokens bigint,
  completion_tokens bigint,
  "startTime" timestamp with time zone NOT NULL,
  "endTime" timestamp with time zone,
  request_duration_ms integer,
  "completionStartTime" timestamp with time zone,
  model text,
  model_id text,
  model_group text,
  custom_llm_provider text,
  api_base text,
  "user" text,
  metadata jsonb,
  cache_hit boolean,
  cache_key text,
  request_tags jsonb,
  team_id text,
  end_user text,
  requester_ip_address text,
  messages jsonb,
  response jsonb,
  proxy_server_request jsonb,
  session_id text,
  status text,
  mcp_namespaced_tool_name text,
  organization_id text,
  agent_id text
);

INSERT INTO public."LiteLLM_SpendLogs" (
  request_id, call_type, spend, total_tokens, prompt_tokens,
  completion_tokens, "startTime", "endTime", request_duration_ms, model, status
) VALUES
  ('request-january-1', 'acompletion', 0.01, 15, 10, 5,
   '2020-01-05T12:00:00Z', '2020-01-05T12:00:01Z', 1001, 'test-model', 'success'),
  ('request-january-2', 'acompletion', 0.02, 30, 20, 10,
   '2020-01-31T23:59:59Z', '2020-01-31T23:59:59Z', 2022, 'test-model', 'success'),
  ('request-february-boundary', 'acompletion', 0.03, 45, 30, 15,
   '2020-02-01T00:00:00Z', '2020-02-01T00:00:01Z', 3033, 'test-model', 'success');
SQL

month_count() {
  compose exec -T postgres psql -X -Atq -U litellm -d litellm -c \
    "SET TIME ZONE 'UTC'; SELECT COUNT(*) FROM public.\"LiteLLM_SpendLogs\" WHERE \"startTime\" >= '${TARGET_MONTH}-01T00:00:00Z'::timestamptz AND \"startTime\" < '2020-02-01T00:00:00Z'::timestamptz;" \
    | tail -n 1 | tr -d '[:space:]'
}

total_count() {
  compose exec -T postgres psql -X -Atq -U litellm -d litellm -c \
    'SELECT COUNT(*) FROM public."LiteLLM_SpendLogs";' \
    | tail -n 1 | tr -d '[:space:]'
}

duration_rows() {
  compose exec -T postgres psql -X -Atq -U litellm -d litellm -c \
    "SELECT request_id, request_duration_ms FROM public.\"LiteLLM_SpendLogs\" WHERE \"startTime\" >= '${TARGET_MONTH}-01T00:00:00Z'::timestamptz AND \"startTime\" < '2020-02-01T00:00:00Z'::timestamptz ORDER BY request_id;" \
    | tr -d '\r'
}

assert_equal() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || \
    die "${label}: expected ${expected}, got ${actual}"
}

log "Creating and verifying an encrypted logical backup"
LITELLM_PROJECT_DIR="$PROJECT_DIR" \
LITELLM_BACKUPS_DIR="$BACKUPS_DIR" \
LITELLM_AGE_RECIPIENT="$AGE_RECIPIENT" \
  bash "${BACKUP_SCRIPTS}/daily-backup.sh"

mapfile -t backup_archives < <(find "$BACKUPS_DIR" -maxdepth 1 -type f -name 'backup_*.zip.age' -print)
assert_equal 1 "${#backup_archives[@]}" "encrypted backup archive count"
BACKUP_ARCHIVE="${backup_archives[0]}"
[[ -s "$BACKUP_ARCHIVE" && -s "${BACKUP_ARCHIVE}.sha256" ]] || \
  die "encrypted backup or checksum sidecar is missing"

LITELLM_AGE_IDENTITY_FILE="$AGE_IDENTITY" \
  bash "${BACKUP_SCRIPTS}/restore-backup.sh" \
    --source local \
    --file "$BACKUP_ARCHIVE" \
    --verify-only \
    --port 55432

log "Checking the SpendLogs export dry-run"
dry_run_output="$(
  LITELLM_PROJECT_DIR="$PROJECT_DIR" \
  LITELLM_AGE_RECIPIENT="$AGE_RECIPIENT" \
    bash "${SPENDLOG_SCRIPTS}/export-spendlogs-month.sh" \
      --month "$TARGET_MONTH" \
      --output-dir "$SPENDLOGS_DIR" \
      --dry-run
)"
grep -q '^row_count=2$' <<<"$dry_run_output" || \
  die "export dry-run did not report row_count=2"

log "Exporting an encrypted SpendLogs archive and deleting its exact rows"
LITELLM_PROJECT_DIR="$PROJECT_DIR" \
LITELLM_AGE_RECIPIENT="$AGE_RECIPIENT" \
  bash "${SPENDLOG_SCRIPTS}/export-spendlogs-month.sh" \
    --month "$TARGET_MONTH" \
    --output-dir "$SPENDLOGS_DIR" \
    --delete-after-export \
    --execute \
    --expect-count 2

mapfile -t spendlog_archives < <(find "$SPENDLOGS_DIR" -maxdepth 1 -type f -name 'LiteLLM_SpendLogs_*.tar.gz.age' -print)
assert_equal 1 "${#spendlog_archives[@]}" "encrypted SpendLogs archive count"
SPENDLOG_ARCHIVE="${spendlog_archives[0]}"
[[ -s "$SPENDLOG_ARCHIVE" && -s "${SPENDLOG_ARCHIVE}.sha256" ]] || \
  die "encrypted SpendLogs archive or checksum sidecar is missing"
assert_equal 0 "$(month_count)" "target-month count after export-delete"
assert_equal 1 "$(total_count)" "out-of-month row preservation"

log "Importing the archive"
first_import_output="$(
  LITELLM_PROJECT_DIR="$PROJECT_DIR" \
  LITELLM_AGE_IDENTITY_FILE="$AGE_IDENTITY" \
    bash "${SPENDLOG_SCRIPTS}/import-spendlogs-month.sh" \
      --file "$SPENDLOG_ARCHIVE"
)"
grep -q '^inserted_rows=2$' <<<"$first_import_output" || \
  die "first import did not insert two rows"
assert_equal 2 "$(month_count)" "target-month count after import"
assert_equal 3 "$(total_count)" "total count after import"
assert_equal $'request-january-1|1001\nrequest-january-2|2022' \
  "$(duration_rows)" "request duration values after import"

log "Re-importing to verify idempotency"
second_import_output="$(
  LITELLM_PROJECT_DIR="$PROJECT_DIR" \
  LITELLM_AGE_IDENTITY_FILE="$AGE_IDENTITY" \
    bash "${SPENDLOG_SCRIPTS}/import-spendlogs-month.sh" \
      --file "$SPENDLOG_ARCHIVE"
)"
grep -q '^inserted_rows=0$' <<<"$second_import_output" || \
  die "second import was not idempotent"
grep -q '^skipped_duplicates=2$' <<<"$second_import_output" || \
  die "second import did not report two skipped duplicates"
assert_equal 2 "$(month_count)" "target-month count after idempotent import"
assert_equal 3 "$(total_count)" "total count after idempotent import"
assert_equal $'request-january-1|1001\nrequest-january-2|2022' \
  "$(duration_rows)" "request duration values after idempotent import"

log "Deleting the restored month with encrypted archive proof"
LITELLM_PROJECT_DIR="$PROJECT_DIR" \
LITELLM_AGE_IDENTITY_FILE="$AGE_IDENTITY" \
  bash "${SPENDLOG_SCRIPTS}/delete-spendlogs-month.sh" \
    --month "$TARGET_MONTH" \
    --archive "$SPENDLOG_ARCHIVE" \
    --execute \
    --expect-count 2
assert_equal 0 "$(month_count)" "target-month count after archive-proof delete"
assert_equal 1 "$(total_count)" "out-of-month row preservation after archive-proof delete"

log "PostgreSQL round-trip passed"
