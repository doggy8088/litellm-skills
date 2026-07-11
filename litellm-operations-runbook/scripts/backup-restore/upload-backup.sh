#!/usr/bin/env bash
# Disable command tracing before handling a SAS credential.
set +x
set -euo pipefail
umask 077

SAS_URL="${AZURE_BACKUP_SAS_URL:-}"
FILE_PATH=""
BLOB_NAME=""
CONTENT_TYPE=""
DELETE_OLDER_THAN_DAYS=""
EXECUTE_RETENTION=false
FORCE=false
VERBOSE=false
AZCOPY_WORK_DIR=""

cleanup() {
  if [[ -n "$AZCOPY_WORK_DIR" && -d "$AZCOPY_WORK_DIR" ]]; then
    rm -rf -- "$AZCOPY_WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --file <local-path> [options]
  $(basename "$0") --delete-older-than-days <days> --execute-retention [options]

Options:
  -f, --file <path>                 Local file to upload
  -s, --sas <url>                   HTTPS container SAS URL
                                      (prefer AZURE_BACKUP_SAS_URL)
  -n, --name <name>                 Blob name; defaults to local filename
  -t, --type <mime>                 Content-Type override
      --force                       Overwrite an existing blob
      --delete-older-than-days <n>  Select old encrypted backup ZIPs for deletion
      --execute-retention           Required confirmation for retention deletion
  -v, --verbose                     Log non-secret progress
  -h, --help                        Show this help

Only local files are accepted. Retention is restricted to backup_*.zip.age and
backup_*.zip.age.sha256 blobs at the container root.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  if [[ "$VERBOSE" == true ]]; then
    printf '[INFO] %s\n' "$*" >&2
  fi
}

require_value() {
  local option="$1" count="$2"
  ((count >= 2)) || die "${option} requires a value"
}

while (($# > 0)); do
  case "$1" in
    -f|--file)
      require_value "$1" "$#"
      FILE_PATH="$2"
      shift 2
      ;;
    -s|--sas)
      require_value "$1" "$#"
      SAS_URL="$2"
      shift 2
      ;;
    -n|--name)
      require_value "$1" "$#"
      BLOB_NAME="$2"
      shift 2
      ;;
    -t|--type)
      require_value "$1" "$#"
      CONTENT_TYPE="$2"
      shift 2
      ;;
    --delete-older-than-days)
      require_value "$1" "$#"
      DELETE_OLDER_THAN_DAYS="$2"
      shift 2
      ;;
    --execute-retention)
      EXECUTE_RETENTION=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
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

command -v azcopy >/dev/null 2>&1 || die "azcopy is required"
[[ -n "$SAS_URL" ]] || die "set AZURE_BACKUP_SAS_URL or pass --sas"
[[ "$SAS_URL" != *$'\n'* && "$SAS_URL" != *$'\r'* && "$SAS_URL" != *'#'* ]] || \
  die "invalid SAS URL"
[[ "$SAS_URL" == https://* ]] || die "the SAS URL must use HTTPS"
[[ "$SAS_URL" == *\?* ]] || die "the SAS URL must contain a SAS query"

SAS_BASE="${SAS_URL%%\?*}"
SAS_BASE="${SAS_BASE%/}"
SAS_QUERY="${SAS_URL#*\?}"
[[ "$SAS_BASE" =~ ^https://[^/?#]+/[^/?#]+$ ]] || \
  die "use an HTTPS container-level SAS URL"
[[ "&${SAS_QUERY}&" == *'&sig='* ]] || die "the SAS query is missing a signature"

AZCOPY_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/litellm-azcopy.XXXXXX")"
mkdir -p -- "${AZCOPY_WORK_DIR}/logs" "${AZCOPY_WORK_DIR}/plans"

run_azcopy() {
  # AzCopy job data is isolated in a mode-0700 temporary directory. Command
  # output and job logs are disabled so the SAS query cannot reach a console or
  # persistent log. Failures are reported by this wrapper without echoing args.
  AZCOPY_LOG_LOCATION="${AZCOPY_WORK_DIR}/logs" \
  AZCOPY_JOB_PLAN_LOCATION="${AZCOPY_WORK_DIR}/plans" \
    azcopy "$@" --log-level=NONE --output-level=quiet >/dev/null 2>&1
}

sas_has_permission() {
  local permission="$1" pair key value
  local -a pairs=()
  IFS='&' read -r -a pairs <<<"$SAS_QUERY"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ "$key" == sp && "$value" == *"$permission"* ]]; then
      return 0
    fi
  done
  return 1
}

if [[ -n "$DELETE_OLDER_THAN_DAYS" ]]; then
  [[ -z "$FILE_PATH" ]] || die "upload and retention must be separate invocations"
  [[ "$DELETE_OLDER_THAN_DAYS" =~ ^[1-9][0-9]*$ ]] || \
    die "--delete-older-than-days must be a positive integer"
  [[ "$EXECUTE_RETENTION" == true ]] || \
    die "retention deletion requires --execute-retention"
  sas_has_permission d || die "the SAS requires delete permission for retention"
  command -v date >/dev/null 2>&1 || die "date is required"

  CUTOFF_UTC="$(date -u -d "${DELETE_OLDER_THAN_DAYS} days ago" +'%Y-%m-%dT%H:%M:%SZ')" || \
    die "could not calculate the retention cutoff"
  log "Deleting encrypted backup archives older than ${DELETE_OLDER_THAN_DAYS} days"
  if ! run_azcopy remove "$SAS_URL" \
    --recursive=false \
    --include-pattern='backup_*.zip.age;backup_*.zip.age.sha256' \
    --include-before="$CUTOFF_UTC"; then
    die "Azure retention cleanup failed"
  fi
  log "Azure retention cleanup completed"
  exit 0
fi

[[ "$EXECUTE_RETENTION" == false ]] || die "--execute-retention requires a retention request"
[[ -n "$FILE_PATH" ]] || die "--file is required"
[[ ! "$FILE_PATH" =~ ^https?:// ]] || die "remote URL sources are not supported"
[[ -f "$FILE_PATH" ]] || die "local file not found"
[[ -r "$FILE_PATH" ]] || die "local file is not readable"

if [[ -z "$BLOB_NAME" ]]; then
  BLOB_NAME="$(basename -- "$FILE_PATH")"
fi

# A conservative blob-name grammar avoids URL/query confusion. Place backups
# in a subdirectory by using slash-separated safe path segments.
[[ "$BLOB_NAME" =~ ^[A-Za-z0-9._/-]+$ ]] || \
  die "blob names may contain only letters, digits, dot, underscore, dash, and slash"
[[ "$BLOB_NAME" != /* && "$BLOB_NAME" != */ && "$BLOB_NAME" != *//* ]] || \
  die "invalid blob path"
declare -a blob_segments=()
IFS='/' read -r -a blob_segments <<<"$BLOB_NAME"
for segment in "${blob_segments[@]}"; do
  [[ -n "$segment" && "$segment" != . && "$segment" != .. ]] || die "invalid blob path"
done

if [[ -z "$CONTENT_TYPE" ]]; then
  if command -v file >/dev/null 2>&1; then
    CONTENT_TYPE="$(file --brief --mime-type -- "$FILE_PATH")"
  else
    case "${FILE_PATH,,}" in
      *.age) CONTENT_TYPE='application/octet-stream' ;;
      *.zip) CONTENT_TYPE='application/zip' ;;
      *.sha256|*.txt) CONTENT_TYPE='text/plain' ;;
      *) CONTENT_TYPE='application/octet-stream' ;;
    esac
  fi
fi
[[ "$CONTENT_TYPE" != *$'\n'* && "$CONTENT_TYPE" != *$'\r'* ]] || die "invalid content type"

DESTINATION="${SAS_BASE}/${BLOB_NAME}?${SAS_QUERY}"
OVERWRITE=false
[[ "$FORCE" == true ]] && OVERWRITE=true

log "Uploading local file $(basename -- "$FILE_PATH") as ${BLOB_NAME}"
if ! run_azcopy copy "$FILE_PATH" "$DESTINATION" \
  --from-to=LocalBlob \
  --blob-type=BlockBlob \
  --put-md5 \
  --content-type="$CONTENT_TYPE" \
  --overwrite="$OVERWRITE"; then
  die "Azure upload failed"
fi
log "Upload completed (an existing blob is left unchanged unless --force is used)"
