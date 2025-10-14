#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

DEBUG="${DEBUG:-0}"
if [[ ! "$DEBUG" =~ ^[0-9]+$ ]]; then
  DEBUG=0
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
debug_enabled() { (( DEBUG > 0 )); }
log_debug() { if debug_enabled; then log "[DEBUG] $*"; fi }
require_bin() {
  local bin="$1"
  log_debug "Vérification de la présence de $bin"
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "Dépendance manquante: $bin"
    exit 1
  fi
}

ensure_dirs() {
  log_debug "Création des répertoires DEST=$DEST TMP_DIR=$TMP_DIR LOG_DIR=$LOG_DIR"
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
  log_debug "Espace disponible sur $mount: ${free_gb}G"
}

run_makemkv_info() {
  local info_file
  info_file="$(mktemp "$TMP_DIR/makemkv_info.XXXXXX")"
  local info_cmd
  IFS=' ' read -r -a info_args <<<"$MAKEMKV_INFO_OPTS"
  info_cmd=("$MAKEMKV_BIN" -r "${info_args[@]}" info "disc:0")
  log "Extraction des informations disque (${info_cmd[*]})" >&2
  log_debug "Fichier temporaire info: $info_file"
  if ! "${info_cmd[@]}" >"$info_file" 2>"$info_file.err"; then
    err "makemkvcon info a échoué (voir $info_file.err)"
    if debug_enabled && [[ -s "$info_file.err" ]]; then
      log_debug "Dernières lignes d'erreur makemkvcon info:"
      tail -n 20 "$info_file.err" 2>/dev/null
    fi
    rm -f "$info_file" "$info_file.err"
    exit 1
  fi
  rm -f "$info_file.err"
  log_debug "Extraction info makemkv réussie"
  echo "$info_file"
}

extract_disc_title() {
  local info_file="$1" title
  title=$(grep -m1 '^CINFO:' "$info_file" | cut -d',' -f4- | tr -d '"' || true)
  if [[ -z "$title" ]]; then
    title=$(grep -m1 '^TINFO' "$info_file" | cut -d',' -f5- | tr -d '"' || true)
  fi
  title=${title:-UNKNOWN_DISC}
  log_debug "Titre disque détecté: $title"
  echo "$title"
}

filter_stable_info() {
  local info_file="$1"
  awk '/^(DRV|CINFO|TINFO|SINFO|PINFO|AINFO|DINFO|DISC|CAPP):/ { sub(/\r$/,""); print }' "$info_file"
}

compute_info_sha256() {
  local info_file="$1"
  filter_stable_info "$info_file" | sha256sum | awk '{print $1}'
}

compute_disc_uid() {
  local info_file="$1" title="$2" info_hash
  info_hash=$(compute_info_sha256 "$info_file")
  printf '%s\n%s' "$title" "$info_hash" | sha256sum | awk '{print substr($1,1,16)}'
}

write_fingerprint() {
  local dest_dir="$1" disc_uid="$2" title="$3" info_file="$4"
  local fingerprint="$dest_dir/tech/fingerprint.json"
  mkdir -p "$dest_dir/tech"
  local info_sha
  info_sha=$(compute_info_sha256 "$info_file")
  log_debug "SHA info makemkv: $info_sha"
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
  log_debug "Cible backup: $backup_target"
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
  log_debug "Commande backup en cours (journal standard)"
  "${cmd[@]}"
}

capture_structure() {
  local dest_dir="$1" backup_target="$dest_dir/${RAW_BACKUP_DIR}"
  local tech_dir="$dest_dir/tech"
  mkdir -p "$tech_dir"
  if ! command -v "$LSDVD_BIN" >/dev/null 2>&1; then
    err "lsdvd introuvable, structure.lsdvd.yml non générée"
    return
  fi

  local lsdvd_source="$backup_target"
  local lsdvd_source_desc="backup (${backup_target})"
  if [[ ! -f "$backup_target/VIDEO_TS/VIDEO_TS.IFO" ]]; then
    if [[ -b "$DEVICE" ]]; then
      lsdvd_source="$DEVICE"
      lsdvd_source_desc="périphérique (${DEVICE})"
      log "Aucun backup valide pour lsdvd, utilisation du périphérique ${DEVICE}"
    else
      err "Aucune source valide pour lsdvd (backup manquant et périphérique $DEVICE indisponible)"
      return
    fi
  fi

  local lsdvd_cmd=("$LSDVD_BIN" -Oy "$lsdvd_source")
  log "Capture de la structure via lsdvd depuis ${lsdvd_source_desc} (${lsdvd_cmd[*]})"
  log_debug "Fichiers de sortie lsdvd: $tech_dir/structure.lsdvd.yml"
  if ! "${lsdvd_cmd[@]}" >"$tech_dir/structure.lsdvd.yml" 2>"$tech_dir/structure.lsdvd.err"; then
    err "lsdvd a échoué (voir $tech_dir/structure.lsdvd.err)"
    if [[ -s "$tech_dir/structure.lsdvd.err" ]]; then
      if grep -qi 'Encrypted DVD support unavailable' "$tech_dir/structure.lsdvd.err"; then
        err "Support CSS absent : installez libdvdcss (ou équivalent) pour permettre la lecture chiffrée."
      elif grep -qi 'No medium found' "$tech_dir/structure.lsdvd.err"; then
        err "Aucun média détecté par lsdvd sur ${lsdvd_source}. Vérifiez que le disque est monté et accessible."
      elif grep -qi "Can't open" "$tech_dir/structure.lsdvd.err"; then
        err "lsdvd ne parvient pas à ouvrir ${lsdvd_source}. Vérifiez les permissions et la présence du périphérique."
      fi
      if debug_enabled; then
        log_debug "Dernières lignes lsdvd:"
        tail -n 20 "$tech_dir/structure.lsdvd.err" 2>/dev/null
      fi
    fi
  else
    rm -f "$tech_dir/structure.lsdvd.err"
    log_debug "structure.lsdvd.yml généré avec succès"
  fi
}

enqueue_scan() {
  local dest_dir="$1"
  if [[ -x "$SCAN_ENQUEUE" ]]; then
    log_debug "Enfilement Phase 2 via $SCAN_ENQUEUE pour $dest_dir"
    "$SCAN_ENQUEUE" "$dest_dir"
  else
    err "scan_enqueue.sh introuvable ($SCAN_ENQUEUE)"
  fi
}

main() {
  log_debug "Début Phase 1 avec DEBUG=$DEBUG"
  log_debug "Configuration: DEVICE=$DEVICE DEST=$DEST RAW_BACKUP_DIR=$RAW_BACKUP_DIR"
  require_bin "$MAKEMKV_BIN"
  require_bin sha256sum
  require_bin df
  require_bin "$LSDVD_BIN"
  ensure_dirs
  check_space
  local info_file
  info_file=$(run_makemkv_info)
  log_debug "Fichier info obtenu: $info_file"
  local disc_title
  disc_title=$(extract_disc_title "$info_file")
  local disc_uid
  disc_uid=$(compute_disc_uid "$info_file" "$disc_title")
  log_debug "disc_uid calculé: $disc_uid"
  local dest_dir="$DEST/$disc_uid"
  mkdir -p "$dest_dir"
  log_debug "Répertoire destination phase 1: $dest_dir"
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
