#!/usr/bin/env bash
set -euo pipefail

# Scripts for daily cron job
# Usage: LITELLM_PROJECT_DIR=/path/to/deployment ./daily-backup.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUPS_DIR="${PROJECT_DIR}/backups"
AZURE_BACKUP_RETENTION_DAYS=7

# Ensure we are in the project dir for docker-compose to work correctly
cd "$PROJECT_DIR"

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Determine compose command
if have docker-compose; then
  COMPOSE_CMD=(docker-compose)
elif have docker && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
else
  die "docker compose not found."
fi

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

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

postgres_container_id() {
  compose ps -q postgres 2>/dev/null | head -n 1
}

# Pre-checks
if ! have zip; then
  die "zip command not found."
fi

mkdir -p "$BACKUPS_DIR"

log "Starting daily backup..."

USER="$(pg_user)"
DB="$(pg_db)"
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_ZIP="${BACKUPS_DIR}/backup_${TS}.zip"
DUMP_TMP="$(mktemp "/tmp/pg_${DB}_${TS}_XXXXXX.dump")"

PG_CID="$(postgres_container_id)"
if [[ -z "$PG_CID" ]]; then
  die "Postgres container is not running."
fi

# 1. Dump DB
log "Dumping database $DB..."
set +e
compose exec -T postgres sh -lc "pg_dump -U \"$USER\" -d \"$DB\" -Fc" >"$DUMP_TMP" 2>"${DUMP_TMP}.err"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  cat "${DUMP_TMP}.err" >&2 || true
  rm -f "$DUMP_TMP" "${DUMP_TMP}.err"
  die "Database dump failed with exit code $RC"
fi
rm -f "${DUMP_TMP}.err"

# 2. Gather configs
log "Gathering configuration files..."
CONFIGS=(docker-compose.yml compose.yml compose.yaml config/litellm_config.yaml "$ENV_FILE")
FILES_TO_ZIP=()
for f in "${CONFIGS[@]}"; do
  [[ -f "$f" ]] && FILES_TO_ZIP+=("$f")
done

# 3. Create Zip
log "Creating archive $BACKUP_ZIP..."
if zip -q -j "$BACKUP_ZIP" "$DUMP_TMP" && zip -q "$BACKUP_ZIP" "${FILES_TO_ZIP[@]}"; then
  log "Backup created successfully: $BACKUP_ZIP"
else
  rm -f "$DUMP_TMP"
  die "Zip creation failed."
fi

# Cleanup dump (it's in the zip)
rm -f "$DUMP_TMP"

# 4. Upload
UPLOAD_SCRIPT="${SCRIPT_DIR}/upload-backup.sh"
if [[ -f "$UPLOAD_SCRIPT" && -x "$UPLOAD_SCRIPT" ]]; then
  log "Uploading to Azure Blob Storage..."
  if "$UPLOAD_SCRIPT" -f "$BACKUP_ZIP" -v; then
    log "Upload successful."
    log "Deleting Azure backup blobs older than ${AZURE_BACKUP_RETENTION_DAYS} days..."
    "$UPLOAD_SCRIPT" --delete-older-than-days "$AZURE_BACKUP_RETENTION_DAYS" -v
  else
    log "ERROR: Upload failed."
    # We don't exit here, preserving the local backup is better than failing completely
    exit 1
  fi
else
  log "WARNING: Upload script not found or not executable at $UPLOAD_SCRIPT. Skipping upload."
fi

log "Daily backup completed."
