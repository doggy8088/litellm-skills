#!/usr/bin/env bash
set -euo pipefail
umask 077

# Create a logical PostgreSQL backup. Secrets and deployment configuration are
# deliberately excluded from the archive.
#
# Usage:
#   LITELLM_AGE_RECIPIENT='age1...' \
#     LITELLM_PROJECT_DIR=/path/to/deployment ./daily-backup.sh
#   LITELLM_AGE_RECIPIENT='age1...' \
#     AZURE_BACKUP_SAS_URL='https://...?...' ./daily-backup.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE=""
BACKUPS_DIR=""
AZURE_BACKUP_RETENTION_DAYS="${AZURE_BACKUP_RETENTION_DAYS:-7}"
AGE_RECIPIENT="${LITELLM_AGE_RECIPIENT:-}"

WORK_DIR=""
PUBLISH_DIR=""
PLAINTEXT_ZIP=""
BACKUP_ARCHIVE=""
ARCHIVE_TEMP_PATH=""
ARCHIVE_SUM_FILE=""
ARCHIVE_SUM_TEMP=""
BACKUP_READY=false
ARCHIVE_PUBLISHED=false
SUM_PUBLISHED=false

cleanup() {
  if [[ "$BACKUP_READY" != true ]]; then
    [[ "$ARCHIVE_PUBLISHED" == true && -n "$BACKUP_ARCHIVE" ]] && rm -f -- "$BACKUP_ARCHIVE"
    [[ "$SUM_PUBLISHED" == true && -n "$ARCHIVE_SUM_FILE" ]] && rm -f -- "$ARCHIVE_SUM_FILE"
  fi
  [[ -n "$ARCHIVE_TEMP_PATH" ]] && rm -f -- "$ARCHIVE_TEMP_PATH"
  [[ -n "$ARCHIVE_SUM_TEMP" ]] && rm -f -- "$ARCHIVE_SUM_TEMP"
  if [[ -n "$PUBLISH_DIR" && -d "$PUBLISH_DIR" ]]; then
    rm -rf -- "$PUBLISH_DIR"
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

strip_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

dotenv_get() {
  local key="$1" file="$2" line value
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | head -n 1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  strip_quotes "$value"
}

sha256_file() {
  local file="$1"
  if have sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

if have docker-compose; then
  COMPOSE_CMD=(docker-compose)
elif have docker && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
else
  die "docker compose not found"
fi

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

have zip || die "zip is required"
have age || die "age is required"
[[ -n "$AGE_RECIPIENT" ]] || die "set LITELLM_AGE_RECIPIENT to an explicit age recipient"
[[ "$AGE_RECIPIENT" != *$'\n'* && "$AGE_RECIPIENT" != *$'\r'* ]] || \
  die "invalid age recipient"
[[ "$AZURE_BACKUP_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || \
  die "AZURE_BACKUP_RETENTION_DAYS must be a positive integer"

[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd -P)"
ENV_FILE="${PROJECT_DIR}/.env"
if [[ -n "${LITELLM_BACKUPS_DIR:-}" ]]; then
  BACKUPS_DIR="$LITELLM_BACKUPS_DIR"
else
  BACKUPS_DIR="${PROJECT_DIR}/backups"
fi
cd -- "$PROJECT_DIR"
mkdir -p -- "$BACKUPS_DIR"
BACKUPS_DIR="$(cd -- "$BACKUPS_DIR" && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/litellm-backup.XXXXXX")"
chmod 700 -- "$WORK_DIR"
PUBLISH_DIR="$(mktemp -d "${BACKUPS_DIR}/.backup-publish.XXXXXX")"
chmod 700 -- "$PUBLISH_DIR"

PG_USER="$(dotenv_get POSTGRES_USER "$ENV_FILE" || printf '%s' 'litellm')"
PG_DB="$(dotenv_get POSTGRES_DB "$ENV_FILE" || printf '%s' 'litellm')"
[[ "$PG_USER" != *$'\n'* && "$PG_USER" != *$'\r'* ]] || die "invalid POSTGRES_USER"
[[ "$PG_DB" != *$'\n'* && "$PG_DB" != *$'\r'* ]] || die "invalid POSTGRES_DB"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DUMP_NAME="database.dump"
DUMP_FILE="${WORK_DIR}/${DUMP_NAME}"
MANIFEST_FILE="${WORK_DIR}/manifest.txt"
SUMS_FILE="${WORK_DIR}/SHA256SUMS"
PLAINTEXT_ZIP="${WORK_DIR}/backup_${TIMESTAMP}.zip"
BACKUP_ARCHIVE="${BACKUPS_DIR}/backup_${TIMESTAMP}.zip.age"
ARCHIVE_TEMP_PATH="${PUBLISH_DIR}/$(basename "$BACKUP_ARCHIVE")"
ARCHIVE_SUM_FILE="${BACKUP_ARCHIVE}.sha256"
ARCHIVE_SUM_TEMP="${PUBLISH_DIR}/$(basename "$ARCHIVE_SUM_FILE")"
[[ ! -e "$BACKUP_ARCHIVE" && ! -e "$ARCHIVE_TEMP_PATH" && \
   ! -e "$ARCHIVE_SUM_FILE" && ! -e "$ARCHIVE_SUM_TEMP" ]] || \
  die "backup output already exists for timestamp ${TIMESTAMP}"

POSTGRES_CONTAINER_ID="$(compose ps -q postgres 2>/dev/null | head -n 1)"
[[ -n "$POSTGRES_CONTAINER_ID" ]] || die "Postgres container is not running"

log "Creating a logical dump of database ${PG_DB}"
ERROR_FILE="${WORK_DIR}/pg_dump.err"
if ! compose exec -T postgres pg_dump -U "$PG_USER" -d "$PG_DB" -Fc \
  >"$DUMP_FILE" 2>"$ERROR_FILE"; then
  sed -E 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ii][Gg])=[^[:space:]]+/\1=<redacted>/g' "$ERROR_FILE" >&2 || true
  die "database dump failed"
fi
[[ -s "$DUMP_FILE" ]] || die "database dump is empty"
rm -f -- "$ERROR_FILE"

DUMP_SHA256="$(sha256_file "$DUMP_FILE")"
printf '%s  %s\n' "$DUMP_SHA256" "$DUMP_NAME" >"$SUMS_FILE"
cat >"$MANIFEST_FILE" <<EOF
backup_format=litellm-logical-v1
created_utc=${CREATED_UTC}
database=${PG_DB}
dump_format=postgresql-custom
dump_file=${DUMP_NAME}
checksum_file=SHA256SUMS
EOF

log "Creating plaintext archive inside the protected temporary directory"
(
  cd "$WORK_DIR"
  zip -q "$PLAINTEXT_ZIP" "$DUMP_NAME" "$(basename "$MANIFEST_FILE")" "$(basename "$SUMS_FILE")"
)
[[ -s "$PLAINTEXT_ZIP" ]] || die "plaintext backup archive is empty"

log "Encrypting backup with age"
age --encrypt --recipient "$AGE_RECIPIENT" \
  --output "$ARCHIVE_TEMP_PATH" "$PLAINTEXT_ZIP"
[[ -s "$ARCHIVE_TEMP_PATH" ]] || die "encrypted backup archive is empty"
rm -f -- "$PLAINTEXT_ZIP"
PLAINTEXT_ZIP=""

printf '%s  %s\n' \
  "$(sha256_file "$ARCHIVE_TEMP_PATH")" "$(basename "$BACKUP_ARCHIVE")" \
  >"$ARCHIVE_SUM_TEMP"
mv --no-clobber -- "$ARCHIVE_SUM_TEMP" "$ARCHIVE_SUM_FILE"
[[ ! -e "$ARCHIVE_SUM_TEMP" && -s "$ARCHIVE_SUM_FILE" ]] || \
  die "checksum destination appeared during publication"
SUM_PUBLISHED=true
ARCHIVE_SUM_TEMP=""
mv --no-clobber -- "$ARCHIVE_TEMP_PATH" "$BACKUP_ARCHIVE"
[[ ! -e "$ARCHIVE_TEMP_PATH" && -s "$BACKUP_ARCHIVE" ]] || \
  die "archive destination appeared during publication"
ARCHIVE_PUBLISHED=true
ARCHIVE_TEMP_PATH=""
BACKUP_READY=true
log "Encrypted backup created: ${BACKUP_ARCHIVE}"

# Uploading is opt-in. The SAS is accepted only from the process environment;
# it is never read from or written into an archived configuration file.
UPLOAD_SCRIPT="${SCRIPT_DIR}/upload-backup.sh"
if [[ -n "${AZURE_BACKUP_SAS_URL:-}" ]]; then
  [[ -f "$UPLOAD_SCRIPT" ]] || die "upload helper not found: $UPLOAD_SCRIPT"
  have bash || die "bash is required to invoke the upload helper"

  log "Uploading the archive and detached checksum to Azure Blob Storage"
  bash "$UPLOAD_SCRIPT" --file "$ARCHIVE_SUM_FILE" --verbose
  bash "$UPLOAD_SCRIPT" --file "$BACKUP_ARCHIVE" --verbose
  log "Applying ${AZURE_BACKUP_RETENTION_DAYS}-day Azure retention policy"
  bash "$UPLOAD_SCRIPT" \
    --delete-older-than-days "$AZURE_BACKUP_RETENTION_DAYS" \
    --execute-retention \
    --verbose
else
  log "AZURE_BACKUP_SAS_URL is not set; kept the backup locally"
fi

log "Daily backup completed"
