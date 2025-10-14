#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
source "$SCRIPT_DIR/common.sh"

dump_volume_id() {
  if ! command -v "$ISOINFO_BIN" >/dev/null 2>&1; then
    log_warn "isoinfo indisponible pour extraire le volume ID"
    return 1
  fi
  log_debug "Extraction du volume ID avec $ISOINFO_BIN depuis $DEVICE"
  local output
  if ! output="$($ISOINFO_BIN -d -i "$DEVICE" 2>/dev/null)"; then
    log_debug "isoinfo a échoué pour $DEVICE"
    return 1
  fi
  local volume_id
  volume_id=$(printf '%s\n' "$output" | awk -F': ' '/Volume id:/ {print $2; exit}')
  if [[ -z "$volume_id" ]]; then
    log_debug "Volume ID non trouvé dans la sortie isoinfo"
    return 1
  fi
  log_debug "Volume ID trouvé: $volume_id"
  printf '%s' "$volume_id"
}

dump_lsdvd_yaml() {
  local outfile="$1"
  if ! command -v "$LSDVD_BIN" >/dev/null 2>&1; then
    log_warn "lsdvd indisponible pour le dump structurel"
    return 1
  fi
  log_debug "Exécution de $LSDVD_BIN -Oy $DEVICE (sortie: $outfile)"
  if ! $LSDVD_BIN -Oy "$DEVICE" >"$outfile" 2>"$outfile.err"; then
    log_warn "Échec lsdvd, voir $outfile.err"
    if debug_enabled; then
      tail -n 20 "$outfile.err" 2>/dev/null | while IFS= read -r line; do
        log_debug "lsdvd stderr: $line"
      done
    fi
    return 1
  fi
  rm -f "$outfile.err"
  log_debug "Dump lsdvd écrit dans $outfile"
  return 0
}

write_fingerprint_json() {
  local dest_dir="$1"
  local disc_uid="$2"
  local volume_id="$3"
  local sha_full="$4"
  local fingerprint_dir="$dest_dir/tech"
  mkdir -p "$fingerprint_dir"
  local escaped_uid escaped_volume escaped_sha escaped_ts escaped_layout
  escaped_uid="$(json_escape "$disc_uid")"
  escaped_volume="$(json_escape "$volume_id")"
  escaped_sha="$(json_escape "$sha_full")"
  escaped_ts="$(json_escape "$(ts)")"
  escaped_layout="$(json_escape "$ARCHIVE_LAYOUT_VERSION")"
  cat >"$fingerprint_dir/fingerprint.json" <<JSON
{
  "disc_uid": "${escaped_uid}",
  "volume_id": "${escaped_volume}",
  "struct_sha256": "${escaped_sha}",
  "generated_at": "${escaped_ts}",
  "layout_version": "${escaped_layout}"
}
JSON
  log_debug "fingerprint.json mis à jour pour $disc_uid"
}
