#!/usr/bin/env bash
set -euo pipefail

# Default values
SAS_URL="${AZURE_BACKUP_SAS_URL:-}"
FILE_PATH=""
BLOB_NAME=""
CONTENT_TYPE=""
DELETE_OLDER_THAN_DAYS=""
SKIP_URL_VALIDATION=false
OPEN_AFTER=false
FORCE=false
VERBOSE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -f <FilePath> [options]

Options:
  -f, --file <path>       Path to local file or URL to upload (Mandatory)
  -s, --sas <url>         Container SAS URL (or AZURE_BACKUP_SAS_URL)
  -n, --name <name>       Blob name (Defaults to local filename)
  -t, --type <mime>       Content-Type override
  --delete-older-than-days <days>
                          Delete backup_*.zip blobs older than the given days
  --skip-validation       Skip SAS URL validation
  --open                  Open uploaded URL after completion
  --force                 Overwrite existing blob
  -v, --verbose           Enable verbose output
  -h, --help              Show this help

Example:
  AZURE_BACKUP_SAS_URL="https://account.blob.core.windows.net/container?sv=..." $(basename "$0") -f ./report.pdf -v
  $(basename "$0") -f ./photo.jpg -n "images/photo.jpg" --type "image/jpeg"
  $(basename "$0") --delete-older-than-days 7 -v
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  if [ "$VERBOSE" = true ]; then
    echo "[INFO] $*" >&2
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -f|--file)
      FILE_PATH="$2"
      shift 2
      ;;
    -s|--sas)
      SAS_URL="$2"
      shift 2
      ;;
    -n|--name)
      BLOB_NAME="$2"
      shift 2
      ;;
    -t|--type)
      CONTENT_TYPE="$2"
      shift 2
      ;;
    --delete-older-than-days)
      DELETE_OLDER_THAN_DAYS="$2"
      shift 2
      ;;
    --skip-validation)
      SKIP_URL_VALIDATION=true
      shift
      ;;
    --open)
      OPEN_AFTER=true
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
      die "Unknown option: $1"
      ;;
  esac
done

if [ -z "$FILE_PATH" ] && [ -z "$DELETE_OLDER_THAN_DAYS" ]; then
  usage
  die "File path is required (-f), unless --delete-older-than-days is used."
fi

if [ -z "$SAS_URL" ]; then
  usage
  die "SAS URL is required. Pass --sas or set AZURE_BACKUP_SAS_URL."
fi

# Dependency check
command -v azcopy >/dev/null 2>&1 || die "azcopy is required but not installed."
command -v date >/dev/null 2>&1 || die "date is required but not installed."
if [ -z "$DELETE_OLDER_THAN_DAYS" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
fi

# Helper functions
urlencode() {
  # Python is robust for url encoding
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
  else
    # Fallback to simple sed for basic path safety (not full RFC compliance)
    echo "$1" | sed 's/ /%20/g'
  fi
}

validate_sas_url() {
  local url="$1"
  if [[ ! "$url" =~ ^https?:// ]]; then
    die "SAS URL must start with http:// or https://"
  fi
  
  if [ "$SKIP_URL_VALIDATION" = false ]; then
    if [[ ! "$url" == *"?"* ]]; then
      die "SAS URL should include query parameters. Use --skip-validation to bypass."
    fi
    
    # Primitive check for container vs blob SAS (counting slashes/segments logic from PS is tricky in bash without parsing)
    # PS: if ($uri.Segments.Count -gt 2) -> essentially checking if path has more than just container
    # Let's verify it ends with container name or has valid structure
    # For now, we trust the user mostly, but warn if it looks like a file path
    # Removing query part
    local base_url="${url%%\?*}"
    # remove protocol
    local path_part="${base_url#*://}"
    # remove domain
    path_part="${path_part#*/}"
    
    # If path_part contains '/', it might be a blob path (container/blob)
    if [[ "$path_part" == *"/"* ]]; then
       die "SAS URL looks like a Blob-level URL (contains '/'). Please use a Container-level SAS URL or use --skip-validation."
    fi
  fi
}

resolve_content_type() {
  local path="$1"
  local override="$2"
  
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi

  if command -v file >/dev/null 2>&1; then
    file --brief --mime-type "$path"
  else
    # Fallback extension map
    local ext="${path##*.}"
    ext=".${ext,,}" # to lowercase
    case "$ext" in
      .txt|.log) echo "text/plain" ;;
      .md) echo "text/markdown" ;;
      .json) echo "application/json" ;;
      .zip) echo "application/zip" ;;
      .pdf) echo "application/pdf" ;;
      .png) echo "image/png" ;;
      .jpg|.jpeg) echo "image/jpeg" ;;
      *) echo "application/octet-stream" ;;
    esac
  fi
}

check_blob_exists() {
  local uri="$1"
  local http_code
  http_code=$(curl -s -o /dev/null -I -w "%{http_code}" "$uri")
  if [ "$http_code" -eq 200 ]; then
    return 0
  else
    return 1
  fi
}

sas_has_permission() {
  local url="$1" permission="$2"
  local query pair key value
  [[ "$url" == *"?"* ]] || return 1

  query="${url#*\?}"
  IFS='&' read -ra pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if [ "$key" = "sp" ] && [[ "$value" == *"$permission"* ]]; then
      return 0
    fi
  done

  return 1
}

# Main Logic

validate_sas_url "$SAS_URL"

if [ -n "$DELETE_OLDER_THAN_DAYS" ]; then
  if [[ ! "$DELETE_OLDER_THAN_DAYS" =~ ^[0-9]+$ ]] || [ "$DELETE_OLDER_THAN_DAYS" -lt 1 ]; then
    die "--delete-older-than-days must be a positive integer."
  fi
  if ! sas_has_permission "$SAS_URL" "d"; then
    die "SAS URL must include delete permission ('d' in sp=...) to delete old Azure backup blobs."
  fi

  CUTOFF_UTC="$(date -u -d "${DELETE_OLDER_THAN_DAYS} days ago" +'%Y-%m-%dT%H:%M:%SZ')"
  log "Deleting Azure backup blobs older than $DELETE_OLDER_THAN_DAYS days (modified before $CUTOFF_UTC)..."

  if [ "$VERBOSE" = true ]; then
    AZCOPY_LOG_LEVEL=INFO
  else
    AZCOPY_LOG_LEVEL=ERROR
  fi

  azcopy remove "$SAS_URL" \
    --recursive=false \
    --include-pattern='backup_*.zip' \
    --include-before="$CUTOFF_UTC" \
    --log-level "$AZCOPY_LOG_LEVEL"

  log "Azure backup retention cleanup completed."
  exit 0
fi

TEMP_FILE=""
LOCAL_PATH="$FILE_PATH"

# Check if remote URL
if [[ "$FILE_PATH" =~ ^https?:// ]]; then
  log "Detected remote URL. Downloading to temp file..."
  TEMP_FILE=$(mktemp)
  curl -sL -o "$TEMP_FILE" "$FILE_PATH"
  LOCAL_PATH="$TEMP_FILE"
  # Try to guess name from URL for display purposes or Content-Disposition? 
  filename=$(basename "$FILE_PATH")
  if [ -z "$filename" ]; then filename="downloaded.bin"; fi
else
  if [ ! -f "$LOCAL_PATH" ]; then
    die "File not found: $LOCAL_PATH"
  fi
  filename=$(basename "$LOCAL_PATH")
fi

cleanup() {
  if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
    log "Removing temp file $TEMP_FILE"
    rm -f "$TEMP_FILE"
  fi
}
trap cleanup EXIT

# Determine Blob Name
if [ -n "$BLOB_NAME" ]; then
  TARGET_BLOB_NAME="$BLOB_NAME"
  SOURCE_NAME="explicit argument"
else
  TARGET_BLOB_NAME="$filename"
  SOURCE_NAME="filename"
fi

# Build Blob URI
# Remove trailing slash from base
BASE_SAS_URL="${SAS_URL%%\?*}" # URL without query
SAS_QUERY="${SAS_URL#*\?}"      # Query string

# If SAS_URL had no query, handle appropriately
if [ "$BASE_SAS_URL" == "$SAS_URL" ]; then
  SAS_QUERY=""
fi

# Encode blob name (path segments)
ENCODED_BLOB_NAME=$(urlencode "$TARGET_BLOB_NAME")
FULL_BLOB_URI="${BASE_SAS_URL}/${ENCODED_BLOB_NAME}"
if [ -n "$SAS_QUERY" ]; then
  FULL_BLOB_SAS_URI="${FULL_BLOB_URI}?${SAS_QUERY}"
else
  FULL_BLOB_SAS_URI="${FULL_BLOB_URI}"
fi

# Determine Content Type
MIME_TYPE=$(resolve_content_type "$LOCAL_PATH" "$CONTENT_TYPE")

# Content-Disposition logic
AZCOPY_ARGS=()
AZCOPY_ARGS+=(--blob-type BlockBlob)
AZCOPY_ARGS+=(--from-to LocalBlob)
AZCOPY_ARGS+=(--put-md5)
AZCOPY_ARGS+=(--content-type "$MIME_TYPE")

if [ "$VERBOSE" = true ]; then
  AZCOPY_ARGS+=(--log-level INFO)
else
  AZCOPY_ARGS+=(--log-level ERROR)
fi

# List of types requiring content-disposition
case "$MIME_TYPE" in
  application/zip|application/gzip|application/x-tar|application/x-7z-compressed|application/vnd.rar|application/octet-stream)
    ENCODED_FILENAME=$(urlencode "$filename")
    AZCOPY_ARGS+=(--content-disposition "attachment; filename*=UTF-8''$ENCODED_FILENAME")
    log "Added Content-Disposition for $filename"
    ;;
esac

log "File: $LOCAL_PATH"
log "Target Blob: $TARGET_BLOB_NAME ($SOURCE_NAME)"
log "Content-Type: $MIME_TYPE"

# Check Existence
SHOULD_UPLOAD=true
if [ "$FORCE" = false ]; then
  log "Checking if blob exists..."
  if check_blob_exists "$FULL_BLOB_SAS_URI"; then
    log "Blob already exists. Skipping upload."
    echo "$FULL_BLOB_URI"
    SHOULD_UPLOAD=false
  fi
else
  log "Force enabled. Overwriting if exists."
fi

if [ "$SHOULD_UPLOAD" = true ]; then
  log "Uploading..."
  if [ "$FORCE" = true ]; then
    AZCOPY_ARGS+=(--overwrite true)
  else
    AZCOPY_ARGS+=(--overwrite false)
  fi

  if azcopy copy "$LOCAL_PATH" "$FULL_BLOB_SAS_URI" "${AZCOPY_ARGS[@]}"; then
    echo "$FULL_BLOB_URI"
    log "Upload successful via azcopy."
  else
    die "azcopy upload failed."
  fi
else
  # Already existed
  :
fi

if [ "$OPEN_AFTER" = true ]; then
  log "Opening $FULL_BLOB_URI..."
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$FULL_BLOB_URI"
  elif command -v open >/dev/null 2>&1; then
    open "$FULL_BLOB_URI"
  else
    log "WARN: Cannot open URL (xdg-open/open not found)."
  fi
fi
