#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
RAW_BACKUP_DIR="${RAW_BACKUP_DIR:-raw/VIDEO_TS_BACKUP}"
TMP_DIR="${TMP_DIR:-/var/tmp/dvdarchiver}"
LOG_DIR="${LOG_DIR:-/var/log/dvdarchiver}"
DEVICE="${DEVICE:-/dev/sr0}"
MAKEMKV_BIN="${MAKEMKV_BIN:-makemkvcon}"
MAKEMKV_BACKUP_ENABLE="${MAKEMKV_BACKUP_ENABLE:-1}"
MAKEMKV_BACKUP_OPTS="${MAKEMKV_BACKUP_OPTS:---decrypt}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"
EJECT_ON_DONE="${EJECT_ON_DONE:-1}"
MAKEMKV_INFO_OPTS="${MAKEMKV_INFO_OPTS:---directio=true --progress=-stdout}"
LSDVD_BIN="${LSDVD_BIN:-lsdvd}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_ENQUEUE="${SCAN_ENQUEUE_BIN:-${SCRIPT_DIR}/scan_enqueue.sh}"

log() { printf '[backup] %s\n' "$*"; }
err() { printf '[backup][ERREUR] %s\n' "$*" >&2; }
require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "Dépendance manquante: $bin"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$DEST" "$TMP_DIR" "$LOG_DIR"
}

check_space() {
  local mount free_bytes free_gb
  mount="$DEST"
  if [[ ! -d "$mount" ]]; then
    err "DEST introuvable: $mount"
    exit 1
  fi
  free_bytes=$(df -PB1 "$mount" | awk 'NR==2 {print $4}')
  free_bytes=${free_bytes:-0}
  free_gb=$((free_bytes / 1024 / 1024 / 1024))
  if (( free_gb < MIN_FREE_GB )); then
    err "Espace libre insuffisant sur $mount (${free_gb}G < ${MIN_FREE_GB}G)"
    exit 1
  fi
}

run_makemkv_info() {
  local info_file
  info_file="$(mktemp "$TMP_DIR/makemkv_info.XXXXXX")"
  local info_cmd
  IFS=' ' read -r -a info_args <<<"$MAKEMKV_INFO_OPTS"
  info_cmd=("$MAKEMKV_BIN" -r "${info_args[@]}" info "disc:0")
  log "Extraction des informations disque (${info_cmd[*]})"
  if ! "${info_cmd[@]}" >"$info_file" 2>"$info_file.err"; then
    err "makemkvcon info a échoué (voir $info_file.err)"
    rm -f "$info_file" "$info_file.err"
    exit 1
  fi
  rm -f "$info_file.err"
  echo "$info_file"
}

extract_disc_title() {
  local info_file="$1" title
  title=$(grep -m1 '^CINFO:' "$info_file" | cut -d',' -f4- | tr -d '"' || true)
  if [[ -z "$title" ]]; then
    title=$(grep -m1 '^TINFO' "$info_file" | cut -d',' -f5- | tr -d '"' || true)
  fi
  title=${title:-UNKNOWN_DISC}
  echo "$title"
}

compute_disc_uid() {
  local info_file="$1" title="$2" hash
  hash=$(sha256sum "$info_file" | awk '{print $1}')
  printf '%s\n%s' "$title" "$hash" | sha256sum | awk '{print substr($1,1,16)}'
}

write_fingerprint() {
  local dest_dir="$1" disc_uid="$2" title="$3" info_file="$4"
  local fingerprint="$dest_dir/tech/fingerprint.json"
  mkdir -p "$dest_dir/tech"
  local info_sha
  info_sha=$(sha256sum "$info_file" | awk '{print $1}')
  cat <<JSON >"$fingerprint"
{
  "disc_uid": "${disc_uid}",
  "disc_title": "${title}",
  "device": "${DEVICE}",
  "info_sha256": "${info_sha}",
  "generated_at": "$(date -Is)",
  "makemkv_binary": "${MAKEMKV_BIN}"
}
JSON
}

run_backup() {
  local dest_dir="$1"
  local backup_target="$dest_dir/${RAW_BACKUP_DIR}"
  mkdir -p "$backup_target"
  if [[ $MAKEMKV_BACKUP_ENABLE -ne 1 ]]; then
    log "MAKEMKV_BACKUP_ENABLE=0, étape backup ignorée"
    return
  fi
  if find "$backup_target/VIDEO_TS" -maxdepth 1 -name '*.VOB' -print -quit >/dev/null 2>&1; then
    log "Backup déjà présent, étape skip"
    return
  fi
  IFS=' ' read -r -a opts <<<"$MAKEMKV_BACKUP_OPTS"
  local cmd=("$MAKEMKV_BIN" -r backup "${opts[@]}" "disc:0" "$backup_target")
  log "Exécution: ${cmd[*]}"
  "${cmd[@]}"
}

capture_structure() {
  local dest_dir="$1" backup_target="$dest_dir/${RAW_BACKUP_DIR}"
  local tech_dir="$dest_dir/tech"
  mkdir -p "$tech_dir"
  if command -v "$LSDVD_BIN" >/dev/null 2>&1; then
    log "Capture de la structure via lsdvd"
    if ! "$LSDVD_BIN" -Oy "$backup_target" >"$tech_dir/structure.lsdvd.yml" 2>"$tech_dir/structure.lsdvd.err"; then
      err "lsdvd a échoué (voir $tech_dir/structure.lsdvd.err)"
    else
      rm -f "$tech_dir/structure.lsdvd.err"
    fi
  else
    err "lsdvd introuvable, structure.lsdvd.yml non générée"
  fi
}

enqueue_scan() {
  local dest_dir="$1"
  if [[ -x "$SCAN_ENQUEUE" ]]; then
    "$SCAN_ENQUEUE" "$dest_dir"
  else
    err "scan_enqueue.sh introuvable ($SCAN_ENQUEUE)"
  fi
}

main() {
  require_bin "$MAKEMKV_BIN"
  require_bin sha256sum
  require_bin df
  require_bin "$LSDVD_BIN"
  ensure_dirs
  check_space
  local info_file
  info_file=$(run_makemkv_info)
  local disc_title
  disc_title=$(extract_disc_title "$info_file")
  local disc_uid
  disc_uid=$(compute_disc_uid "$info_file" "$disc_title")
  local dest_dir="$DEST/$disc_uid"
  mkdir -p "$dest_dir"
  write_fingerprint "$dest_dir" "$disc_uid" "$disc_title" "$info_file"
  run_backup "$dest_dir"
  capture_structure "$dest_dir"
  enqueue_scan "$dest_dir"
  rm -f "$info_file"
  if [[ $EJECT_ON_DONE -eq 1 ]]; then
    if command -v eject >/dev/null 2>&1; then
      eject "$DEVICE" || err "Impossible d'éjecter $DEVICE"
    fi
  fi
  log "Phase 1 terminée pour $disc_uid"
}

main "$@"
