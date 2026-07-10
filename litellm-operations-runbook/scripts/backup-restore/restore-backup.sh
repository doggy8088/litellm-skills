#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${LITELLM_PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)}"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUPS_DIR="${PROJECT_DIR}/backups"
POSTGRES_IMAGE="postgres:16-alpine"

AZURE_SAS_URL="${AZURE_BACKUP_SAS_URL:-}"
PG_USER="${PG_USER:-}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_DB="${PG_DB:-}"

SCRIPT_NAME="$(basename "$0")"
RESTORE_KEEP="false"
RESTORE_CONTAINER=""
RESTORE_DATA_DIR=""

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --date <YYYY-MM-DD> [options]

  --date <YYYY-MM-DD>        Restore target date
  --source <local|azure>      Source type (default: azure)
  --file <path>               Restore directly from this local backup file
  --blob-name <name>          Restore a specific Azure blob
  --sas <url>                 Azure container SAS URL (or AZURE_BACKUP_SAS_URL env var)
  --local-dir <dir>           Local backup search dir (default: backups)
  --keep-data                 Keep temp DB + data (default: auto-clean)
  --verify-only               Same as --keep-data
  --port <n>                  Host port for temp restore DB (default: 55432)
  -h, --help                 Show this help
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

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

load_defaults() {
  PG_USER="$(dotenv_get POSTGRES_USER "$ENV_FILE" || printf '%s' "${PG_USER:-litellm}")"
  PG_PASSWORD="$(dotenv_get POSTGRES_PASSWORD "$ENV_FILE" || printf '%s' "${PG_PASSWORD:-litellm_password_change_me}")"
  PG_DB="$(dotenv_get POSTGRES_DB "$ENV_FILE" || printf '%s' "${PG_DB:-litellm}")"
  if [[ -z "$AZURE_SAS_URL" ]]; then
    AZURE_SAS_URL="$(dotenv_get AZURE_BACKUP_SAS_URL "$ENV_FILE" || printf '%s' "")"
  fi
}

date_key() { date -u -d "$1" +'%Y%m%d'; }

extract_date_from_name() {
  local name="$1"
  if [[ "$name" =~ backup_(full|incr)_([0-9]{8}) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  elif [[ "$name" =~ backup_([0-9]{8}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '\n'
  fi
}

set_cleanup() {
  RESTORE_KEEP="$1"
  RESTORE_CONTAINER="$2"
  RESTORE_DATA_DIR="$3"
}

cleanup() {
  if [[ "$RESTORE_KEEP" == "false" ]]; then
    [[ -n "${RESTORE_CONTAINER}" ]] && docker rm -f "${RESTORE_CONTAINER}" >/dev/null 2>&1 || true
    [[ -n "${RESTORE_DATA_DIR}" ]] && rm -rf "${RESTORE_DATA_DIR}"
  fi
}

trap cleanup EXIT

wait_for_db() {
  local container="$1" user="$2" db="$3" pass="$4"
  local i=0
  while ((i < 90)); do
    if docker exec -e PGPASSWORD="$pass" "$container" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    i=$((i+1))
  done
  docker logs "$container" >&2 || true
  die "PostgreSQL did not become ready."
}

download_blob() {
  local sas="$1" blob="$2" out_file="$3"
  local base="${sas%%\?*}"
  local query=""
  if [[ "$sas" == *\?* ]]; then
    query="${sas#*\?}"
  fi
  local uri="${base}/${blob}"
  [[ -n "$query" ]] && uri="${uri}?${query}"
  azcopy copy "$uri" "$out_file"
}

list_azure_blobs() {
  local sas="$1"
  azcopy list "$sas" --recursive --output-level=quiet | grep 'backup_' || true
}

collect_candidates() {
  local sas="$1" out_file="$2"
  local line name key typ
  : > "$out_file"
  while IFS= read -r line; do
    name="${line##*/}"
    name="${name%%\?*}"
    [[ "$name" == backup_* ]] || continue
    key="$(extract_date_from_name "$name")"
    [[ -z "$key" ]] && continue
    if [[ "$name" == backup_full_* ]]; then
      typ="full"
    elif [[ "$name" == backup_incr_* ]]; then
      typ="incr"
    else
      typ="legacy"
    fi
    printf '%s|%s|%s\n' "$typ" "$key" "$name" >> "$out_file"
  done < <(list_azure_blobs "$sas")
}

select_chain_for_date() {
  local target_key="$1" candidates_file="$2"
  local full_list="$(mktemp)" incr_list="$(mktemp)"
  local typ key name selected_full="" selected_base="" selected_incr="" line
  : > "$full_list" ; : > "$incr_list"

  while IFS='|' read -r typ key name; do
    [[ -z "$key" ]] && continue
    if ((10#${key} > 10#${target_key})); then
      continue
    fi
    if [[ "$typ" == "full" ]]; then
      printf '%s|%s\n' "$key" "$name" >> "$full_list"
    elif [[ "$typ" == "incr" ]]; then
      printf '%s|%s\n' "$key" "$name" >> "$incr_list"
    else
      selected_full="$name"
      selected_base="$key"
    fi
  done < "$candidates_file"

  if [[ -s "$full_list" ]]; then
    selected_full="$(sort -n -t'|' -k1,1 "$full_list" | tail -n 1 | cut -d'|' -f2)"
    selected_base="$(sort -n -t'|' -k1,1 "$full_list" | tail -n 1 | cut -d'|' -f1)"
    while IFS='|' read -r key name; do
      if ((10#${key} >= 10#${selected_base} && 10#${key} <= 10#${target_key})); then
        selected_incr+="${selected_incr:+\n}${name}"
      fi
    done < <(sort -n -t'|' -k1,1 "$incr_list")
  fi

  printf '%s|%s\n' "${selected_full:-__NONE__}" "${selected_incr:-__NONE__}"
  rm -f "$full_list" "$incr_list"
}

find_local_for_date() {
  local target_key="$1" dir="$2"
  local f key best="" best_key=""
  while IFS= read -r -d '' p; do
    key="$(extract_date_from_name "$(basename "$p")")"
    [[ -z "$key" ]] && continue
    if [[ -z "$best" || ( "$key" -le "$target_key" && "$key" -gt "$best_key" ) ]]; then
      best="$p"
      best_key="$key"
    fi
  done < <(
    find "$dir" -maxdepth 6 -type f -name 'backup_*.zip' -o -name 'backup_*.dump' -o -name 'backup_*.sql' -o -name 'backup_*.tar' -o -name 'backup_*.tar.gz' 2>/dev/null | sort | tr '\n' '\0'
  )
  printf '%s' "$best"
}

restore_legacy() {
  local input_file="$1" port="$2" data_dir="$3" keep="$4"
  local container="litellm-restore-$(date +%s)"
  local resolved="$input_file"
  local work
  work="$(mktemp -d)"

  if [[ "$resolved" == *.zip ]]; then
    local member
    member="$(unzip -l "$resolved" | awk '{print $4}' | grep -E '\.dump$|\.sql$' | tail -n 1)"
    [[ -n "$member" ]] || die "No dump/sql member in $resolved"
    resolved="$work/restore.dump"
    unzip -p "$input_file" "$member" > "$resolved"
  fi

  mkdir -p "$data_dir"
  docker run -d --name "$container" \
    -e POSTGRES_DB="$PG_DB" -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -v "${data_dir}:/var/lib/postgresql/data" \
    -p "${port}:5432" \
    "$POSTGRES_IMAGE" >/dev/null

  wait_for_db "$container" "$PG_USER" "$PG_DB" "$PG_PASSWORD"

  if [[ "$resolved" == *.dump ]]; then
    docker cp "$resolved" "$container:/tmp/restore.dump"
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$container" pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists --no-owner --no-acl /tmp/restore.dump >/dev/null
  else
    docker cp "$resolved" "$container:/tmp/restore.sql"
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$container" psql -U "$PG_USER" -d "$PG_DB" -f /tmp/restore.sql >/dev/null
  fi

  docker exec -e PGPASSWORD="$PG_PASSWORD" "$container" psql -U "$PG_USER" -d "$PG_DB" -c "select current_database();" >/dev/null
  log "Restore preview: postgresql://$PG_USER:<password>@localhost:$port/$PG_DB"
  log "Container: $container"
  set_cleanup "$keep" "$container" "$data_dir"
  rm -rf "$work"
}

restore_chain() {
  local base_file="$1" incr_dir="$2" date_target="$3" port="$4" data_dir="$5" keep="$6"
  local container="litellm-restore-chain-$(date +%s)"
  local wal_dir="${data_dir}/wal"

  mkdir -p "$data_dir" "$wal_dir"
  case "$base_file" in
    *.tar.gz|*.tgz) tar -xzf "$base_file" -C "$data_dir" ;;
    *.tar) tar -xf "$base_file" -C "$data_dir" ;;
    *.zip) unzip -q "$base_file" -d "$data_dir" ;;
    *) die "Unsupported base archive: $base_file" ;;
  esac

  while IFS= read -r -d '' f; do
    if [[ "$f" == *.tar || "$f" == *.tar.gz || "$f" == *.tgz ]]; then
      if [[ "$f" == *.tar.gz || "$f" == *.tgz ]]; then
        tar -xzf "$f" -C "$wal_dir"
      else
        tar -xf "$f" -C "$wal_dir"
      fi
    else
      cp "$f" "$wal_dir/"
    fi
  done < <(find "$incr_dir" -maxdepth 1 -type f -print0 2>/dev/null || true)

  cat > "${data_dir}/recovery.signal"
  cat >> "${data_dir}/postgresql.auto.conf" <<EOF
restore_command = 'cp /wal_archive/%f %p'
recovery_target_time = '${date_target} 23:59:59'
recovery_target_inclusive = on
recovery_target_action = promote
EOF

  docker run -d --name "$container" \
    -v "${data_dir}:/var/lib/postgresql/data" \
    -v "${wal_dir}:/wal_archive:ro" \
    -p "${port}:5432" \
    "$POSTGRES_IMAGE" \
    postgres -D /var/lib/postgresql/data >/dev/null

  wait_for_db "$container" "$PG_USER" "$PG_DB" "$PG_PASSWORD"
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$container" psql -U "$PG_USER" -d "$PG_DB" -c "select current_database();" >/dev/null
  log "Restore preview: postgresql://$PG_USER:<password>@localhost:$port/$PG_DB"
  log "Container: $container"
  set_cleanup "$keep" "$container" "$data_dir"
}

main() {
  local target_date="" source="azure" file="" blob_name="" sas_url="" local_dir="$BACKUPS_DIR" port="55432"
  local keep_data=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) target_date="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      --blob-name) blob_name="$2"; shift 2 ;;
      --sas) sas_url="$2"; shift 2 ;;
      --local-dir) local_dir="$2"; shift 2 ;;
      --keep-data|--verify-only) keep_data=true; shift ;;
      --port) port="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$target_date" ]] || die "Missing --date"
  date -u -d "$target_date" >/dev/null 2>&1 || die "Invalid date: $target_date"
  have docker || die "docker is required"
  have azcopy || die "azcopy is required"
  load_defaults
  [[ "$source" == "local" || "$source" == "azure" ]] || die "source must be local|azure"
  sas_url="${sas_url:-$AZURE_SAS_URL}"
  RESTORE_KEEP=$([[ "$keep_data" == true ]] && echo true || echo false)
  log "Starting restore for date ${target_date} (source: ${source})"

  local target_key
  target_key="$(date_key "$target_date")"

  if [[ "$source" == "local" ]]; then
    if [[ -z "$file" ]]; then
      file="$(find_local_for_date "$target_key" "$local_dir")"
      [[ -n "$file" ]] || die "No local backup matched date $target_date under $local_dir"
    fi
    [[ -f "$file" ]] || die "File not found: $file"
    restore_dir="$(mktemp -d)"
    restore_legacy "$file" "$port" "$restore_dir" "$RESTORE_KEEP"
    return 0
  fi

  [[ -n "$sas_url" ]] || die "No Azure SAS URL (use --sas or AZURE_BACKUP_SAS_URL)"
  tmp_dir="$(mktemp -d)"
  candidate_file="${tmp_dir}/candidates.txt"
  collect_candidates "$sas_url" "$candidate_file"

  if [[ -n "$blob_name" ]]; then
    file="${tmp_dir}/explicit.backup"
    download_blob "$sas_url" "$blob_name" "$file"
    restore_dir="$(mktemp -d)"
    restore_legacy "$file" "$port" "$restore_dir" "$RESTORE_KEEP"
    return 0
  fi

  chain="$(select_chain_for_date "$target_key" "$candidate_file")"
  selected_full="${chain%%|*}"
  selected_incr="${chain#*|}"
  [[ "$selected_full" != "__NONE__" ]] || die "No matching backup for $target_date"
  if [[ "$selected_incr" == "__NONE__" ]]; then
    file="${tmp_dir}/selected.zip"
    download_blob "$sas_url" "$selected_full" "$file"
    restore_dir="$(mktemp -d)"
    restore_legacy "$file" "$port" "$restore_dir" "$RESTORE_KEEP"
    return 0
  fi

  base_file="${tmp_dir}/base.tar"
  incr_dir="${tmp_dir}/incr"
  mkdir -p "$incr_dir"
  download_blob "$sas_url" "$selected_full" "$base_file"
  while IFS= read -r blob; do
    [[ -z "$blob" ]] && continue
    download_blob "$sas_url" "$blob" "$incr_dir/$(basename "$blob")"
  done <<< "$selected_incr"

  restore_dir="$(mktemp -d)"
  restore_chain "$base_file" "$incr_dir" "$target_date" "$port" "$restore_dir" "$RESTORE_KEEP"
}

main "$@"
