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
    volume_id="DVD_UNTITLED"
  fi
  local title="$volume_id"
  if [[ -z "$title" ]]; then
    title="DVD_UNTITLED"
  fi

  local sha_full
  sha_full=$(disc_id "$title")
  local dest_dir="$DEST/${DISC_SHA_SHORT}"
  mkdir -p "$dest_dir/mkv" "$dest_dir/tech" "$dest_dir/meta" "$dest_dir/raw"

  if compgen -G "$dest_dir/mkv/*.mkv" >/dev/null 2>&1; then
    log_info "Rippage déjà présent pour ${DISC_SHA_SHORT}, aucune action"
    exit 0
  fi

  log_info "Empreinte disque: ${DISC_SHA_FULL} (${DISC_SHA_SHORT})"

  local logfile="$LOG_DIR/rip-${DISC_SHA_SHORT}-$(ts).log"
  touch "$logfile"

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

  if ! dump_lsdvd_yaml "$dest_dir/tech/structure.lsdvd.yml"; then
    log_warn "Impossible de générer le dump lsdvd"
  fi

  write_fingerprint_json "$dest_dir" "$DISC_SHA_SHORT" "$volume_id" "$sha_full"

  if [[ "${ALLOW_ISO_DUMP}" -eq 1 ]]; then
    log_info "Dump ISO brut activé"
    if dd if="$DEVICE" of="$dest_dir/raw/dvd.iso" bs=1M status=none >>"$logfile" 2>&1; then
      sha256sum "$dest_dir/raw/dvd.iso" >"$dest_dir/raw/dvd.iso.sha256"
    else
      log_warn "Échec du dump ISO brut"
    fi
  fi

  if [[ "${EJECT_ON_DONE}" -eq 1 ]]; then
    if ! "$EJECT_BIN" "$DEVICE" >>"$logfile" 2>&1; then
      log_warn "Impossible d'éjecter $DEVICE"
    fi
  fi

  log_info "Rip terminé pour ${DISC_SHA_SHORT} → $dest_dir"
}

main "$@"
