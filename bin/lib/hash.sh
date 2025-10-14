#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/common.sh"

_mount_temp_dir() {
  mkdir -p "$TMP_DIR"
  local temp_dir
  temp_dir="$(mktemp -d "${TMP_DIR%/}/mnt.XXXXXX")"
  log_debug "Point de montage temporaire créé: $temp_dir"
  echo "$temp_dir"
}

disc_struct_hash() {
  local mount_point
  mount_point=$(_mount_temp_dir)
  local hash=""
  if mount -o "$MOUNT_OPTS" "$DEVICE" "$mount_point" >/dev/null 2>&1; then
    log_debug "Montage réussi de $DEVICE sur $mount_point pour hash structurel"
    local video_ts_dir="$mount_point/VIDEO_TS"
    if [[ -d "$video_ts_dir" ]]; then
      log_debug "Collecte des IFO/VOB pour hash structurel dans $video_ts_dir"
      hash=$( {
        if [[ -f "$video_ts_dir/VIDEO_TS.IFO" ]]; then
          cat "$video_ts_dir/VIDEO_TS.IFO"
        fi
        find "$video_ts_dir" -maxdepth 1 -type f -name 'VTS_*_0.IFO' -print | sort | while IFS= read -r file; do
          cat "$file"
        done
        find "$video_ts_dir" -maxdepth 1 -type f -name 'VTS_*_*.VOB' -print | sort | while IFS= read -r file; do
          stat -c '%s' "$file"
        done
      } | sha256sum | awk '{print $1}')
    fi
    safe_umount "$mount_point"
  else
    log_warn "Montage impossible pour calcul de hash structurel"
  fi
  rmdir "$mount_point" 2>/dev/null || true
  log_debug "Hash structurel obtenu: ${hash:-<vide>}"
  printf '%s' "$hash"
}

_read_sectors() {
  local offset="$1"
  log_debug "Lecture de ${DISC_HASH_COUNT_SECT} secteurs à partir de l'offset $offset"
  dd if="$DEVICE" bs=2048 skip="$offset" count="$DISC_HASH_COUNT_SECT" status=none 2>/dev/null || true
}

disc_sector_hash() {
  local title="$1"
  local tmpfile
  mkdir -p "$TMP_DIR"
  tmpfile="$(mktemp "${TMP_DIR%/}/sectors.XXXXXX")"
  local offsets=()
  offsets+=("$DISC_HASH_SKIP_SECT")
  if [[ -n "${DISC_HASH_EXTRA_OFFSETS:-}" ]]; then
    read -r -a extra_array <<<"${DISC_HASH_EXTRA_OFFSETS}"
    offsets+=("${extra_array[@]}")
  fi
  log_debug "Offsets utilisés pour le hash secteurs: ${offsets[*]}"
  for offset in "${offsets[@]}"; do
    _read_sectors "$offset" >>"$tmpfile"
  done
  printf '\n%s' "$title" >>"$tmpfile"
  local sector_hash
  sector_hash=$(sha256sum "$tmpfile" | awk '{print $1}')
  rm -f "$tmpfile"
  log_debug "Hash secteurs obtenu: $sector_hash"
  printf '%s' "$sector_hash"
}

disc_id() {
  local title="$1"
  local struct_hash sector_hash combined
  struct_hash=$(disc_struct_hash)
  sector_hash=$(disc_sector_hash "$title")
  if [[ -n "$struct_hash" ]]; then
    combined="${struct_hash}${sector_hash}"
  else
    combined="$sector_hash"
  fi
  log_debug "Combinaison des hashes (struct=${struct_hash:-<vide>}, sector=$sector_hash)"
  DISC_SHA_FULL=$(printf '%s' "$combined" | sha256sum | awk '{print $1}')
  export DISC_SHA_FULL
  local trim_len="$DISC_HASH_TRIM"
  if (( trim_len > 0 )); then
    DISC_SHA_SHORT="${DISC_SHA_FULL:0:trim_len}"
  else
    DISC_SHA_SHORT="$DISC_SHA_FULL"
  fi
  export DISC_SHA_SHORT
  printf '%s %s\n' "$DISC_SHA_FULL" "$DISC_SHA_SHORT"
}
