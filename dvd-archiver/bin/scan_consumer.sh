#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"
SCAN_LOG_DIR="${SCAN_LOG_DIR:-/var/log/dvdarchiver-scan}"
SCAN_SCANNER_BIN="${SCAN_SCANNER_BIN:-/usr/local/bin/scan/scanner.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log() {
  printf '[scan_consumer] %s\n' "$*"
}

mkdir -p "$SCAN_QUEUE_DIR" "$SCAN_LOG_DIR"

process_job() {
  local job="$1"
  local status suffix disc_dir log_file ts result_file

  # shellcheck disable=SC1090
  source "$job"

  disc_dir="${DISC_DIR:-}"
  if [[ -z "$disc_dir" ]]; then
    log "Job $job invalide: DISC_DIR manquant"
    suffix="err"
    ts="$(date -Is)"
    result_file="${job%.job}.${suffix}"
    {
      cat "$job"
      echo "STATUS=ERREUR"
      echo "TIMESTAMP=$ts"
      echo "MESSAGE=DISC_DIR absent"
    } >"$result_file"
    rm -f "$job"
    return
  fi

  if [[ ! -d "$disc_dir" ]]; then
    log "Répertoire disque introuvable: $disc_dir"
    suffix="err"
    ts="$(date -Is)"
    result_file="${job%.job}.${suffix}"
    {
      cat "$job"
      echo "STATUS=ERREUR"
      echo "TIMESTAMP=$ts"
      echo "MESSAGE=DISC_DIR introuvable"
    } >"$result_file"
    rm -f "$job"
    return
  fi

  if [[ -f "$disc_dir/meta/metadata_ia.json" ]]; then
    log "Déjà traité: $disc_dir"
    suffix="done"
    ts="$(date -Is)"
    result_file="${job%.job}.${suffix}"
    {
      cat "$job"
      echo "STATUS=EXISTANT"
      echo "TIMESTAMP=$ts"
      echo "MESSAGE=metadata déjà présent"
    } >"$result_file"
    rm -f "$job"
    return
  fi

  ts="$(date +%Y%m%dT%H%M%S)"
  log_file_name="scan-$(basename "$disc_dir")-${ts}.log"
  log_file="$SCAN_LOG_DIR/$log_file_name"

  log "Traitement $disc_dir (log: $log_file)"
  export DISC_DIR="$disc_dir"

  set +e
  "$PYTHON_BIN" "$SCAN_SCANNER_BIN" 2>&1 | tee -a "$log_file"
  status=${PIPESTATUS[0]}
  set -e

  if [[ $status -eq 0 ]]; then
    suffix="done"
    log "Job terminé pour $disc_dir"
  else
    suffix="err"
    log "Job en erreur ($status) pour $disc_dir"
  fi

  result_file="${job%.job}.${suffix}"
  {
    cat "$job"
    echo "STATUS=$suffix"
    echo "EXIT_CODE=$status"
    echo "LOG_FILE=$log_file"
    echo "TIMESTAMP=$(date -Is)"
  } >"$result_file"
  rm -f "$job"
}

shopt -s nullglob
jobs=("$SCAN_QUEUE_DIR"/SCAN_*.job)
shopt -u nullglob

if [[ ${#jobs[@]} -eq 0 ]]; then
  log "Aucun job à traiter"
  exit 0
fi

for job in "${jobs[@]}"; do
  process_job "$job"
done
