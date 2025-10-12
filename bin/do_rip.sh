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

  if [[ "${KEEP_MENU_VOBS}" = "1" ]]; then
    log_info "Sauvegarde des menus .VOB activée (KEEP_MENU_VOBS=1)"
    mkdir -p "$dest_dir/raw"
    mkdir -p "$MOUNT_TMP_DIR" 2>/dev/null || true

    local mountpoint_in_use=0
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_TMP_DIR"; then
      mountpoint_in_use=1
      log_warn "Point de montage $MOUNT_TMP_DIR déjà utilisé, tentative de libération"
      safe_umount "$MOUNT_TMP_DIR"
    fi

    local mount_types="${MOUNT_FS_TYPES:-}"
    local mount_options="$MOUNT_OPTS"
    if [[ -z "$mount_types" ]]; then
      local _mount_parts=()
      IFS=',' read -r -a _mount_parts <<<"$MOUNT_OPTS"
      if ((${#_mount_parts[@]} > 0)); then
        local _types=()
        local _opts=()
        local _part
        for _part in "${_mount_parts[@]}"; do
          _part="${_part//[[:space:]]/}"
          [[ -z "$_part" ]] && continue
          case "$_part" in
            udf|iso9660)
              _types+=("$_part")
              ;;
            *)
              _opts+=("$_part")
              ;;
          esac
        done
        if ((${#_types[@]} > 0)); then
          mount_types=""
          local _type
          for _type in "${_types[@]}"; do
            if [[ -n "$mount_types" ]]; then
              mount_types+=",$_type"
            else
              mount_types="$_type"
            fi
          done
        fi
        if ((${#_opts[@]} > 0)); then
          mount_options=""
          local _opt
          for _opt in "${_opts[@]}"; do
            if [[ -n "$mount_options" ]]; then
              mount_options+=",$_opt"
            else
              mount_options="$_opt"
            fi
          done
        else
          mount_options=""
        fi
      fi
    fi
    mount_types="${mount_types:-udf,iso9660}"
    mount_options="${mount_options:-ro}"

    if mount -t "$mount_types" "$DEVICE" "$MOUNT_TMP_DIR" -o "$mount_options" 2>/dev/null; then
      local src_dir="$MOUNT_TMP_DIR/VIDEO_TS"
      if [[ -d "$src_dir" ]]; then
        local found_menu=0
        for pat in ${MENU_VOB_GLOB}; do
          for src in "$src_dir"/$pat; do
            [[ -e "$src" ]] || continue
            found_menu=1
            local base
            base="$(basename "$src")"
            local dst="$dest_dir/raw/$base"
            if [[ -e "$dst" ]]; then
              log_info "Menu déjà présent, conservation inchangée : $dst"
            else
              log_info "Copie du menu DVD : $src → $dst"
              if cp -a "$src" "$dst"; then
                :
              else
                log_warn "Échec de copie du menu DVD : $src"
              fi
            fi
          done
        done
        if [[ "$found_menu" -eq 0 ]]; then
          log_warn "Aucun menu .VOB trouvé dans $src_dir (motifs : ${MENU_VOB_GLOB})"
        fi
      else
        log_warn "Répertoire VIDEO_TS absent sur le disque monté : $src_dir"
      fi
      safe_umount "$MOUNT_TMP_DIR"
    else
      if [[ "$mountpoint_in_use" -eq 1 ]]; then
        log_warn "Montage RO du DVD impossible après libération du point $MOUNT_TMP_DIR"
      else
        log_warn "Montage RO du DVD impossible (DEVICE=$DEVICE)"
      fi
    fi
    rmdir "$MOUNT_TMP_DIR" 2>/dev/null || true
  else
    log_info "Sauvegarde des menus .VOB désactivée (KEEP_MENU_VOBS=0)"
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
