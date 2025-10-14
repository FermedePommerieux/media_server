#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR_DEFAULT="$SCRIPT_DIR/lib"
LIB_DIR_PREFIX="$(cd "$SCRIPT_DIR/.." && pwd)/lib/dvdarchiver"
declare -a LIB_DIR_CANDIDATES=()
if [[ -n "${LIB_DIR:-}" ]]; then
  LIB_DIR_CANDIDATES+=("${LIB_DIR}")
fi
LIB_DIR_CANDIDATES+=("$LIB_DIR_DEFAULT")
if [[ "$LIB_DIR_PREFIX" != "$LIB_DIR_DEFAULT" ]]; then
  LIB_DIR_CANDIDATES+=("$LIB_DIR_PREFIX")
fi
LIB_DIR_CANDIDATES+=("/usr/local/lib/dvdarchiver")
LIB_DIR=""
for candidate in "${LIB_DIR_CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    LIB_DIR="$candidate"
    break
  fi
done
if [[ -z "$LIB_DIR" ]]; then
  printf 'Impossible de localiser la bibliothèque DVD Archiver (candidats: %s)\n' "$(IFS=', '; printf '%s' "${LIB_DIR_CANDIDATES[*]}")" >&2
  exit 2
fi
# shellcheck source=bin/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=bin/lib/hash.sh
source "$LIB_DIR/hash.sh"
# shellcheck source=bin/lib/techdump.sh
source "$LIB_DIR/techdump.sh"

main() {
  log_info "Début de session de rip sur $DEVICE"
  log_debug "Contexte rip: DEST=$DEST, LOG_DIR=$LOG_DIR, TMP_DIR=$TMP_DIR, CONFIG_FILE=${CONFIG_FILE:-/etc/dvdarchiver.conf}"
  ensure_dirs

  require_cmd "$MAKEMKV_BIN"
  require_cmd "$ISOINFO_BIN"
  require_cmd "$LSDVD_BIN"
  require_cmd "$EJECT_BIN"
  require_cmd mount
  require_cmd sha256sum
  require_cmd dd

  if [[ ! -b "$DEVICE" ]]; then
    log_err "Périphérique $DEVICE introuvable"
    printf 'Périphérique %s introuvable\n' "$DEVICE" >&2
    exit 30
  fi

  check_free_space_gb "$DEST" "$MIN_FREE_GB"

  local volume_id
  if ! volume_id=$(dump_volume_id); then
    log_debug "Volume ID indisponible via isoinfo"
    volume_id="DVD_UNTITLED"
  fi
  log_debug "Volume ID détecté: $volume_id"
  local title="$volume_id"
  if [[ -z "$title" ]]; then
    title="DVD_UNTITLED"
  fi

  local sha_full disc_sha_short
  if ! IFS=' ' read -r sha_full disc_sha_short < <(disc_id "$title"); then
    log_err "Impossible de calculer l'empreinte du disque"
    exit 31
  fi
  log_debug "Empreinte calculée: sha_full=$sha_full sha_short=$disc_sha_short"
  DISC_SHA_FULL="$sha_full"
  DISC_SHA_SHORT="$disc_sha_short"
  export DISC_SHA_FULL DISC_SHA_SHORT
  local dest_dir="$DEST/${DISC_SHA_SHORT}"
  mkdir -p "$dest_dir/mkv" "$dest_dir/tech" "$dest_dir/meta" "$dest_dir/raw"
  log_debug "Répertoire de destination: $dest_dir"

  if compgen -G "$dest_dir/mkv/*.mkv" >/dev/null 2>&1; then
    log_info "Rippage déjà présent pour ${DISC_SHA_SHORT}, aucune action"
    exit 0
  fi

  log_info "Empreinte disque: ${DISC_SHA_FULL} (${DISC_SHA_SHORT})"

  local logfile="$LOG_DIR/rip-${DISC_SHA_SHORT}-$(ts).log"
  touch "$logfile"
  log_debug "Journal de rip: $logfile"

  local makemkv_cmd=("$MAKEMKV_BIN" -r mkv disc:0 all "$dest_dir/mkv")
  if [[ -n "${MAKEMKV_OPTS:-}" ]]; then
    local opts_array=()
    # shellcheck disable=SC2086
    eval "opts_array=(${MAKEMKV_OPTS})"
    makemkv_cmd+=("${opts_array[@]}")
  fi

  if command -v ionice >/dev/null 2>&1; then
    makemkv_cmd=(ionice -c3 "${makemkv_cmd[@]}")
  fi
  if command -v nice >/dev/null 2>&1; then
    makemkv_cmd=(nice -n 10 "${makemkv_cmd[@]}")
  fi

  log_info "Commande MakeMKV: ${makemkv_cmd[*]}"
  if ! "${makemkv_cmd[@]}" >>"$logfile" 2>&1; then
    log_err "Échec du rip, voir $logfile"
    exit 40
  fi

  if ! compgen -G "$dest_dir/mkv/*.mkv" >/dev/null 2>&1; then
    log_err "Aucun fichier MKV produit dans $dest_dir/mkv"
    exit 41
  fi

  if [[ "$KEEP_MENU_VOBS" -eq 1 && "$MAKEMKV_BACKUP_ENABLE" -eq 1 ]]; then
    local backup_dir="$dest_dir/raw/VIDEO_TS_BACKUP"
    local have_backup=0
    log_debug "Vérification backup menus dans $backup_dir"
    if [[ -d "$backup_dir/VIDEO_TS" ]]; then
      local pattern
      for pattern in $MENU_VOB_GLOB; do
        if compgen -G "$backup_dir/VIDEO_TS/$pattern" >/dev/null 2>&1; then
          have_backup=1
          break
        fi
      done
    fi
    if (( have_backup )); then
      log_info "Backup menus déjà présent dans $backup_dir"
    else
      log_debug "Aucun backup menus détecté, création du dossier $backup_dir"
      mkdir -p "$backup_dir"
      local backup_cmd=("$MAKEMKV_BIN" backup)
      if [[ -n "${MAKEMKV_BACKUP_OPTS:-}" ]]; then
        local backup_opts=()
        # shellcheck disable=SC2086
        eval "backup_opts=(${MAKEMKV_BACKUP_OPTS})"
        backup_cmd+=("${backup_opts[@]}")
      fi
      backup_cmd+=("disc:0" "$backup_dir")
      log_info "Commande MakeMKV (backup menus): ${backup_cmd[*]}"
      log_debug "Lancement backup menus vers $backup_dir (journal: $logfile)"
      if ! "${backup_cmd[@]}" >>"$logfile" 2>&1; then
        log_warn "Échec du backup menus, voir $logfile"
      else
        log_info "Backup menus généré dans $backup_dir"
      fi
    fi
  else
    log_info "Backup menus désactivé (MAKEMKV_BACKUP_ENABLE=$MAKEMKV_BACKUP_ENABLE, KEEP_MENU_VOBS=$KEEP_MENU_VOBS)"
  fi

  if ! dump_lsdvd_yaml "$dest_dir/tech/structure.lsdvd.yml"; then
    log_warn "Impossible de générer le dump lsdvd"
    log_debug "Vérifier $dest_dir/tech/structure.lsdvd.err pour plus de détails"
  fi

  write_fingerprint_json "$dest_dir" "$DISC_SHA_SHORT" "$volume_id" "$sha_full"
  log_debug "fingerprint.json écrit dans $dest_dir/tech"

  if [[ "${ALLOW_ISO_DUMP}" -eq 1 ]]; then
    log_info "Dump ISO brut activé"
    log_debug "Début du dd if=$DEVICE of=$dest_dir/raw/dvd.iso"
    if dd if="$DEVICE" of="$dest_dir/raw/dvd.iso" bs=1M status=none >>"$logfile" 2>&1; then
      sha256sum "$dest_dir/raw/dvd.iso" >"$dest_dir/raw/dvd.iso.sha256"
      log_debug "Checksum ISO écrit dans $dest_dir/raw/dvd.iso.sha256"
    else
      log_warn "Échec du dump ISO brut"
    fi
  fi

  if [[ "${EJECT_ON_DONE}" -eq 1 ]]; then
    if ! "$EJECT_BIN" "$DEVICE" >>"$logfile" 2>&1; then
      log_warn "Impossible d'éjecter $DEVICE"
      log_debug "Commande d'éjection $EJECT_BIN $DEVICE en échec (voir $logfile)"
    fi
  fi

  log_info "Rip terminé pour ${DISC_SHA_SHORT} → $dest_dir"
}

main "$@"
