#!/usr/bin/env bash
# Disable command tracing before handling an Azure SAS credential.
set +x
set -euo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ZIP_PREPARER="${SCRIPT_DIR}/prepare-logical-backup.py"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
BACKUPS_DIR="${LITELLM_BACKUPS_DIR:-${PROJECT_DIR}/backups}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
RESTORE_PG_USER="${PG_USER:-litellm}"
RESTORE_PG_DB="${PG_DB:-litellm_restore}"
AZURE_SAS_URL="${AZURE_BACKUP_SAS_URL:-}"
AGE_IDENTITY="${LITELLM_AGE_IDENTITY_FILE:-}"
MAX_MEMBER_BYTES="${LITELLM_RESTORE_MAX_MEMBER_BYTES:-8589934592}"
MAX_TOTAL_BYTES="${LITELLM_RESTORE_MAX_TOTAL_BYTES:-9663676416}"

KEEP_DATA=false
RESTORE_SUCCEEDED=false
WORK_DIR=""
RESTORE_CONTAINER=""
RESTORE_CONTAINER_ID=""
RESTORE_CONTAINER_CREATED=false
RESTORE_VOLUME=""
RESTORE_VOLUME_CREATED=false
RUN_ID=""

container_owned_by_run() {
  local actual
  actual="$(docker inspect --format '{{ index .Config.Labels "litellm.restore.run" }}' \
    "$RESTORE_CONTAINER_ID" 2>/dev/null || true)"
  [[ -n "$RUN_ID" && "$actual" == "$RUN_ID" ]]
}

volume_owned_by_run() {
  local actual
  actual="$(docker volume inspect --format '{{ index .Labels "litellm.restore.run" }}' \
    "$RESTORE_VOLUME" 2>/dev/null || true)"
  [[ -n "$RUN_ID" && "$actual" == "$RUN_ID" ]]
}

cleanup() {
  local status=$?

  if [[ "$KEEP_DATA" != true || "$RESTORE_SUCCEEDED" != true ]]; then
    if [[ "$RESTORE_CONTAINER_CREATED" == true && -n "$RESTORE_CONTAINER_ID" ]] && \
      command -v docker >/dev/null 2>&1 && container_owned_by_run; then
      docker rm -f "$RESTORE_CONTAINER_ID" >/dev/null 2>&1 || true
    fi
    if [[ "$RESTORE_VOLUME_CREATED" == true && -n "$RESTORE_VOLUME" ]] && \
      command -v docker >/dev/null 2>&1 && volume_owned_by_run; then
      docker volume rm -f "$RESTORE_VOLUME" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi

  return "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --source local --file <backup.zip.age|backup.dump.age|backup.sql.age> [options]
  ${SCRIPT_NAME} --source local --date <YYYY-MM-DD> [options]
  ${SCRIPT_NAME} --source azure --blob-name <name.zip.age|name.dump.age|name.sql.age> [options]
  ${SCRIPT_NAME} --source azure --date <YYYY-MM-DD> [options]

Options:
  --source <local|azure>  Backup source (inferred from --file/--blob-name;
                           otherwise defaults to azure for compatibility)
  --file <path>           Explicit encrypted local logical backup
  --date <YYYY-MM-DD>     Select the latest standard backup from this UTC date
  --blob-name <name>      Explicit Azure .zip.age/.dump.age/.sql.age blob
  --sas <url>             HTTPS container SAS URL (prefer AZURE_BACKUP_SAS_URL)
  --age-identity <file>   Explicit age identity file (or LITELLM_AGE_IDENTITY_FILE)
  --local-dir <dir>       Local date-search directory (default: ${BACKUPS_DIR})
  --port <n>              Loopback port for the temporary DB (default: 55432)
  --verify-only           Restore, query, and clean up (the default lifecycle)
  --keep-data             Explicitly keep the successful container and Docker volume
  -h, --help              Show this help

Only age-encrypted logical pg_dump inputs with a detached ciphertext checksum
are supported. Physical base backups, incremental archives, WAL replay, and
plaintext backup inputs are intentionally unsupported.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

require_value() {
  local option="$1" count="$2"
  ((count >= 2)) || die "${option} requires a value"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v od >/dev/null 2>&1; then
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  else
    die "openssl or od is required for a random temporary password"
  fi
}

validate_date() {
  local value="$1" normalized
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  normalized="$(date -u -d "$value" +%F 2>/dev/null)" || return 1
  [[ "$normalized" == "$value" ]]
}

supported_path() {
  case "${1,,}" in
    *.zip.age|*.dump.age|*.sql.age) return 0 ;;
    *) return 1 ;;
  esac
}

find_local_for_date() {
  local date_key="$1" directory="$2" path base best="" best_base=""
  [[ -d "$directory" ]] || return 1
  while IFS= read -r -d '' path; do
    base="$(basename -- "$path")"
    if [[ -z "$best" || "$base" > "$best_base" ]]; then
      best="$path"
      best_base="$base"
    fi
  done < <(
    find "$directory" -maxdepth 1 -type f \
      \( -name "backup_${date_key}_*.zip.age" \
      -o -name "backup_${date_key}_*.dump.age" \
      -o -name "backup_${date_key}_*.sql.age" \) -print0 2>/dev/null
  )
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

validate_sas_url() {
  local sas="$1" base query
  [[ "$sas" != *$'\n'* && "$sas" != *$'\r'* && "$sas" != *'#'* ]] || return 1
  [[ "$sas" == https://* && "$sas" == *\?* ]] || return 1
  base="${sas%%\?*}"
  base="${base%/}"
  query="${sas#*\?}"
  [[ "$base" =~ ^https://[^/?#]+/[^/?#]+$ ]] || return 1
  [[ "&${query}&" == *'&sig='* ]]
}

azcopy_env() {
  AZCOPY_LOG_LOCATION="${WORK_DIR}/azcopy-logs" \
  AZCOPY_JOB_PLAN_LOCATION="${WORK_DIR}/azcopy-plans" \
    "$@"
}

list_azure_for_date() {
  local sas="$1" date_key="$2" raw_list="${WORK_DIR}/azure-list.txt"
  local line name best=""

  if ! azcopy_env azcopy list "$sas" \
    --recursive=false --output-level=essential \
    >"$raw_list" 2>/dev/null; then
    die "could not list Azure backups"
  fi

  while IFS= read -r line; do
    line="${line#INFO: }"
    name="${line%%;*}"
    name="${name##*/}"
    case "${name,,}" in
      "backup_${date_key}_"*.zip.age|"backup_${date_key}_"*.dump.age|"backup_${date_key}_"*.sql.age)
        if [[ -z "$best" || "$name" > "$best" ]]; then
          best="$name"
        fi
        ;;
    esac
  done <"$raw_list"

  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

validate_blob_name() {
  local blob="$1" segment
  local -a segments=()
  [[ "$blob" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$blob" != /* && "$blob" != */ && "$blob" != *//* ]] || return 1
  IFS='/' read -r -a segments <<<"$blob"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" && "$segment" != . && "$segment" != .. ]] || return 1
  done
  supported_path "$blob"
}

download_azure_blob() {
  local sas="$1" blob="$2" destination="$3"
  local base="${sas%%\?*}" query="${sas#*\?}" uri
  base="${base%/}"
  uri="${base}/${blob}?${query}"

  if ! azcopy_env azcopy copy "$uri" "$destination" \
    --from-to=BlobLocal --overwrite=true --log-level=NONE --output-level=quiet \
    >/dev/null 2>&1; then
    die "Azure backup download failed"
  fi
  [[ -s "$destination" ]] || die "downloaded backup is empty"
}

verify_detached_checksum() {
  local input="$1" expected recorded extra actual line_count
  local sums="${input}.sha256"
  [[ -f "$sums" && -r "$sums" ]] || die "required detached checksum is missing: $(basename -- "$sums")"
  line_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$sums")"
  [[ "$line_count" == 1 ]] || die "detached checksum must contain exactly one non-empty line"
  IFS=' ' read -r expected recorded extra <"$sums" || die "could not read detached checksum"
  [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || die "invalid detached checksum"
  recorded="${recorded#\*}"
  [[ "$recorded" == "$(basename -- "$input")" && -z "${extra:-}" ]] || \
    die "detached checksum filename does not match the encrypted archive"
  actual="$(sha256_file "$input")"
  [[ "${actual,,}" == "${expected,,}" ]] || die "detached checksum verification failed"
  log "Verified encrypted archive checksum"
}

PREPARED_FILE=""
PREPARED_KIND=""

prepare_logical_input() {
  local input="$1" lower="${1,,}" decrypted helper_output prepared_dir raw_size

  verify_detached_checksum "$input"

  case "$lower" in
    *.dump.age)
      PREPARED_KIND="dump"
      decrypted="${WORK_DIR}/decrypted.dump"
      ;;
    *.sql.age)
      PREPARED_KIND="sql"
      decrypted="${WORK_DIR}/decrypted.sql"
      ;;
    *.zip.age)
      PREPARED_KIND="zip"
      decrypted="${WORK_DIR}/decrypted.zip"
      ;;
    *) die "supported encrypted inputs are .zip.age, .dump.age, and .sql.age" ;;
  esac

  age --decrypt --identity "$AGE_IDENTITY" --output "$decrypted" "$input"
  [[ -s "$decrypted" ]] || die "age produced an empty plaintext backup"
  chmod 600 -- "$decrypted"

  if [[ "$PREPARED_KIND" == zip ]]; then
    prepared_dir="${WORK_DIR}/prepared"
    helper_output="$(python3 "$ZIP_PREPARER" \
      --max-member-bytes "$MAX_MEMBER_BYTES" \
      --max-total-bytes "$MAX_TOTAL_BYTES" \
      "$decrypted" "$prepared_dir")"
    PREPARED_KIND="$(printf '%s\n' "$helper_output" | awk -F= '$1 == "prepared_kind" { print $2 }')"
    [[ "$PREPARED_KIND" == dump || "$PREPARED_KIND" == sql ]] || \
      die "logical ZIP preparer returned an invalid kind"
    PREPARED_FILE="${prepared_dir}/restore.${PREPARED_KIND}"
    [[ -s "$PREPARED_FILE" ]] || die "logical ZIP preparer did not create the expected file"
    rm -f -- "$decrypted"
    log "Verified logical backup member checksum"
  else
    raw_size="$(wc -c <"$decrypted" | tr -d '[:space:]')"
    [[ "$raw_size" =~ ^[0-9]+$ && "$raw_size" -gt 0 ]] || die "invalid raw logical backup size"
    ((raw_size <= MAX_MEMBER_BYTES && raw_size <= MAX_TOTAL_BYTES)) || \
      die "raw logical backup exceeds the configured size limit"
    PREPARED_FILE="$decrypted"
  fi
}

wait_for_postgres() {
  local attempts=0
  while ((attempts < 60)); do
    if docker exec "$RESTORE_CONTAINER" \
      pg_isready -U "$RESTORE_PG_USER" -d "$RESTORE_PG_DB" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempts=$((attempts + 1))
  done
  die "temporary PostgreSQL did not become ready"
}

SOURCE=""
INPUT_FILE=""
TARGET_DATE=""
BLOB_NAME=""
LOCAL_DIR="$BACKUPS_DIR"
PORT="55432"
VERIFY_ONLY=false
SAS_OPTION_SET=false
LOCAL_DIR_OPTION_SET=false

while (($# > 0)); do
  case "$1" in
    --source)
      require_value "$1" "$#"
      SOURCE="$2"
      shift 2
      ;;
    --file)
      require_value "$1" "$#"
      INPUT_FILE="$2"
      shift 2
      ;;
    --date)
      require_value "$1" "$#"
      TARGET_DATE="$2"
      shift 2
      ;;
    --blob-name)
      require_value "$1" "$#"
      BLOB_NAME="$2"
      shift 2
      ;;
    --sas)
      require_value "$1" "$#"
      AZURE_SAS_URL="$2"
      SAS_OPTION_SET=true
      shift 2
      ;;
    --age-identity)
      require_value "$1" "$#"
      AGE_IDENTITY="$2"
      shift 2
      ;;
    --local-dir)
      require_value "$1" "$#"
      LOCAL_DIR="$2"
      LOCAL_DIR_OPTION_SET=true
      shift 2
      ;;
    --port)
      require_value "$1" "$#"
      PORT="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    --keep-data)
      KEEP_DATA=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option"
      ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "invalid port"
[[ "$MAX_MEMBER_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_RESTORE_MAX_MEMBER_BYTES must be positive"
[[ "$MAX_TOTAL_BYTES" =~ ^[1-9][0-9]*$ ]] || die "LITELLM_RESTORE_MAX_TOTAL_BYTES must be positive"
((MAX_TOTAL_BYTES >= MAX_MEMBER_BYTES)) || die "restore total-size limit must be at least the member-size limit"
[[ "$RESTORE_PG_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid PG_USER"
[[ "$RESTORE_PG_DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid PG_DB"

if [[ -z "$SOURCE" ]]; then
  if [[ -n "$INPUT_FILE" ]]; then
    SOURCE="local"
  elif [[ -n "$BLOB_NAME" ]]; then
    SOURCE="azure"
  else
    SOURCE="azure"
  fi
fi
[[ "$SOURCE" == local || "$SOURCE" == azure ]] || die "--source must be local or azure"

if [[ -n "$TARGET_DATE" ]]; then
  validate_date "$TARGET_DATE" || die "invalid --date"
fi
[[ -z "$INPUT_FILE" || -z "$BLOB_NAME" ]] || die "--file and --blob-name are mutually exclusive"
[[ -z "$INPUT_FILE" || -z "$TARGET_DATE" ]] || die "--file and --date are mutually exclusive"
[[ -z "$BLOB_NAME" || -z "$TARGET_DATE" ]] || die "--blob-name and --date are mutually exclusive"
[[ "$SOURCE" != local || "$SAS_OPTION_SET" != true ]] || die "--sas requires --source azure"
[[ "$SOURCE" != azure || "$LOCAL_DIR_OPTION_SET" != true ]] || die "--local-dir requires --source local"
[[ -z "$INPUT_FILE" || "$LOCAL_DIR_OPTION_SET" != true ]] || die "--local-dir is valid only with a local --date search"
[[ "$SOURCE" != local || -z "$BLOB_NAME" ]] || die "--blob-name requires --source azure"
[[ "$SOURCE" != azure || -z "$INPUT_FILE" ]] || die "--file requires --source local"
if [[ "$SOURCE" == local ]]; then
  [[ -n "$INPUT_FILE" || -n "$TARGET_DATE" ]] || die "local restore requires --file or --date"
else
  [[ -n "$BLOB_NAME" || -n "$TARGET_DATE" ]] || die "Azure restore requires --blob-name or --date"
fi

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v date >/dev/null 2>&1 || die "date is required"
command -v age >/dev/null 2>&1 || die "age is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ -f "$ZIP_PREPARER" ]] || die "logical ZIP preparer not found: $ZIP_PREPARER"
[[ -n "$AGE_IDENTITY" ]] || die "set LITELLM_AGE_IDENTITY_FILE or pass --age-identity"
[[ -f "$AGE_IDENTITY" && -r "$AGE_IDENTITY" ]] || die "age identity file is not readable"
AGE_IDENTITY_DIR="$(cd -- "$(dirname -- "$AGE_IDENTITY")" && pwd -P)"
AGE_IDENTITY="${AGE_IDENTITY_DIR}/$(basename -- "$AGE_IDENTITY")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/litellm-restore.XXXXXX")"
chmod 700 -- "$WORK_DIR"
mkdir -p -- "${WORK_DIR}/azcopy-logs" "${WORK_DIR}/azcopy-plans"

if [[ "$SOURCE" == local ]]; then
  if [[ -z "$INPUT_FILE" ]]; then
    DATE_KEY="${TARGET_DATE//-/}"
    INPUT_FILE="$(find_local_for_date "$DATE_KEY" "$LOCAL_DIR")" || \
      die "no local logical backup matched the requested date"
  fi
  [[ -f "$INPUT_FILE" && -r "$INPUT_FILE" ]] || die "local backup is not readable"
  supported_path "$INPUT_FILE" || die "supported inputs are .zip.age, .dump.age, and .sql.age"
else
  command -v azcopy >/dev/null 2>&1 || die "azcopy is required for Azure restores"
  [[ -n "$AZURE_SAS_URL" ]] || die "set AZURE_BACKUP_SAS_URL or pass --sas"
  validate_sas_url "$AZURE_SAS_URL" || die "use a valid HTTPS container SAS URL"

  if [[ -z "$BLOB_NAME" ]]; then
    DATE_KEY="${TARGET_DATE//-/}"
    BLOB_NAME="$(list_azure_for_date "$AZURE_SAS_URL" "$DATE_KEY")" || \
      die "no Azure logical backup matched the requested date"
  fi
  validate_blob_name "$BLOB_NAME" || die "invalid or unsupported Azure blob name"

  BLOB_BASENAME="$(basename -- "$BLOB_NAME")"
  INPUT_FILE="${WORK_DIR}/${BLOB_BASENAME}"
  log "Downloading Azure logical backup ${BLOB_BASENAME}"
  download_azure_blob "$AZURE_SAS_URL" "$BLOB_NAME" "$INPUT_FILE"
  download_azure_blob "$AZURE_SAS_URL" "${BLOB_NAME}.sha256" "${INPUT_FILE}.sha256"
fi

prepare_logical_input "$INPUT_FILE"

RANDOM_PASSWORD="$(random_hex)"
RUN_ID="$(random_hex)"
TOKEN="${RUN_ID:0:24}"
RESTORE_CONTAINER="litellm-restore-${TOKEN}"
RESTORE_VOLUME="litellm-restore-data-${TOKEN}"

if docker container inspect "$RESTORE_CONTAINER" >/dev/null 2>&1; then
  die "refusing to reuse an existing restore container name"
fi
if docker volume inspect "$RESTORE_VOLUME" >/dev/null 2>&1; then
  die "refusing to reuse an existing restore volume name"
fi

docker volume create \
  --label "litellm.restore.owner=${SCRIPT_NAME}" \
  --label "litellm.restore.run=${RUN_ID}" \
  "$RESTORE_VOLUME" >/dev/null
RESTORE_VOLUME_CREATED=true
log "Starting isolated PostgreSQL restore container"
RESTORE_CONTAINER_ID="$(docker create --name "$RESTORE_CONTAINER" \
  --label "litellm.restore.owner=${SCRIPT_NAME}" \
  --label "litellm.restore.run=${RUN_ID}" \
  -e POSTGRES_USER="$RESTORE_PG_USER" \
  -e POSTGRES_PASSWORD="$RANDOM_PASSWORD" \
  -e POSTGRES_DB="$RESTORE_PG_DB" \
  -v "${RESTORE_VOLUME}:/var/lib/postgresql/data" \
  -p "127.0.0.1:${PORT}:5432" \
  "$POSTGRES_IMAGE")"
[[ -n "$RESTORE_CONTAINER_ID" ]] || die "Docker did not return a restore container ID"
RESTORE_CONTAINER_CREATED=true
docker start "$RESTORE_CONTAINER_ID" >/dev/null

wait_for_postgres

if [[ "$PREPARED_KIND" == dump ]]; then
  docker exec -i -e PGPASSWORD="$RANDOM_PASSWORD" "$RESTORE_CONTAINER" \
    pg_restore -U "$RESTORE_PG_USER" -d "$RESTORE_PG_DB" \
      --clean --if-exists --no-owner --no-acl >/dev/null <"$PREPARED_FILE"
else
  docker exec -i -e PGPASSWORD="$RANDOM_PASSWORD" "$RESTORE_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$RESTORE_PG_USER" -d "$RESTORE_PG_DB" \
      >/dev/null <"$PREPARED_FILE"
fi
rm -f -- "$PREPARED_FILE"

VERIFY_RESULT="$(docker exec -e PGPASSWORD="$RANDOM_PASSWORD" "$RESTORE_CONTAINER" \
  psql -At -U "$RESTORE_PG_USER" -d "$RESTORE_PG_DB" \
    -c "SELECT current_database(), count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');")"
[[ -n "$VERIFY_RESULT" ]] || die "restore verification query returned no result"

RESTORE_SUCCEEDED=true
log "Restore verification succeeded (database and user-table count: ${VERIFY_RESULT})"

if [[ "$KEEP_DATA" == true ]]; then
  log "Kept container ${RESTORE_CONTAINER} and volume ${RESTORE_VOLUME} by explicit request"
  log "Inspect with: docker exec -it ${RESTORE_CONTAINER} psql -U ${RESTORE_PG_USER} -d ${RESTORE_PG_DB}"
  log "The published database port is bound only to 127.0.0.1:${PORT}"
elif [[ "$VERIFY_ONLY" == true ]]; then
  log "Verify-only drill completed; temporary container and volume will be removed"
else
  log "Restore drill completed; temporary container and volume will be removed"
fi
