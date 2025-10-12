#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"
SCAN_LOG_DIR="${SCAN_LOG_DIR:-/var/log/dvdarchiver-scan}"
SCANNER_BIN="${SCANNER_BIN:-/usr/local/bin/scan/scanner.py}"
SLEEP_SEC="${SCAN_IDLE_SLEEP_SEC:-10}"
SCAN_TRIGGER_GLOB="${SCAN_TRIGGER_GLOB:-}"
SCAN_ENQUEUE_BIN="${SCAN_ENQUEUE_BIN:-/usr/local/bin/scan_enqueue.sh}"

mkdir -p "$SCAN_QUEUE_DIR" "$SCAN_LOG_DIR"

log() {
  printf '[scan_consumer] %s\n' "$*"
}

enqueue_ready_discs() {
  local glob="$SCAN_TRIGGER_GLOB"
  [[ -z "$glob" ]] && return
  while IFS= read -r mkv_path; do
    [[ -z "$mkv_path" ]] && continue
    if [[ ! -e "$mkv_path" ]]; then
      continue
    fi
    local disc_dir
    disc_dir="$(dirname "$(dirname "$mkv_path")")"
    if [[ -f "$disc_dir/meta/metadata_ia.json" ]]; then
      continue
    fi
    if [[ -x "$SCAN_ENQUEUE_BIN" ]]; then
      "$SCAN_ENQUEUE_BIN" "$disc_dir" || log "Échec enqueue $disc_dir"
    else
      log "SCAN_ENQUEUE_BIN inexistant: $SCAN_ENQUEUE_BIN"
    fi
  done < <(compgen -G "$glob" 2>/dev/null || true)
}

process_job() {
  local job_file="$1"
  # shellcheck disable=SC1090
  source "$job_file"
  if [[ -z "${DISC_DIR:-}" ]]; then
    log "DISC_DIR manquant dans $job_file"
    return 1
  fi
  local disc_name
  disc_name="$(basename "$DISC_DIR")"
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  local log_file="$SCAN_LOG_DIR/scan-${disc_name}-${timestamp}.log"
  log "Traitement $job_file pour $DISC_DIR"
  export DISC_DIR
  if python3 "$SCANNER_BIN" >>"$log_file" 2>&1; then
    log "Succès $DISC_DIR"
    mv "$job_file" "${job_file%.job}.done"
  else
    log "Échec $DISC_DIR (voir $log_file)"
    mv "$job_file" "${job_file%.job}.err"
  fi
}

while true; do
  enqueue_ready_discs
  mapfile -t jobs < <(find "$SCAN_QUEUE_DIR" -maxdepth 1 -type f -name 'SCAN_*.job' | sort)
  if [[ ${#jobs[@]} -eq 0 ]]; then
    sleep "$SLEEP_SEC"
    continue
  fi
  for job in "${jobs[@]}"; do
    process_job "$job" || true
  done
done
