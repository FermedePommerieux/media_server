#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"

log() {
  printf '[scan_enqueue] %s\n' "$*"
}

usage() {
  echo "Usage: $0 <DISC_DIR>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

disc_dir="$1"
if [[ ! -d "$disc_dir" ]]; then
  echo "Répertoire disque introuvable: $disc_dir" >&2
  exit 1
fi

disc_dir="$(cd "$disc_dir" && pwd)"
meta_json="$disc_dir/meta/metadata_ia.json"
if [[ -f "$meta_json" ]]; then
  log "Déjà traité ($meta_json)"
  exit 0
fi

mkdir -p "$SCAN_QUEUE_DIR"

existing_job=""
shopt -s nullglob
for job in "$SCAN_QUEUE_DIR"/SCAN_*.job; do
  if grep -q "^DISC_DIR=\"$disc_dir\"" "$job"; then
    existing_job="$job"
    break
  fi
done
shopt -u nullglob

if [[ -n "$existing_job" ]]; then
  log "Job déjà en file: $existing_job"
  exit 0
fi

ts="$(date +%s)"
rand="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6 || echo RAND)"
job_file="$SCAN_QUEUE_DIR/SCAN_${ts}_${rand}.job"

tmp_job="${job_file}.tmp"
cat <<EOF >"$tmp_job"
DISC_DIR="$disc_dir"
ACTION="SCAN"
EOF
mv "$tmp_job" "$job_file"
log "Job créé: $job_file"
