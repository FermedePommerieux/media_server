#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"

log() {
  printf '[scan_enqueue] %s\n' "$*"
}

usage() {
  cat <<USAGE >&2
Usage: $0 <DISC_DIR>
USAGE
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

if ! mkdir -p "$SCAN_QUEUE_DIR"; then
  echo "Impossible de créer $SCAN_QUEUE_DIR" >&2
  exit 1
fi

disc_dir="$(cd "$disc_dir" && pwd)"
meta_json="$disc_dir/meta/metadata_ia.json"
if [[ -f "$meta_json" ]]; then
  log "Déjà traité ($meta_json)"
  exit 0
fi

# Vérifie si un job existe déjà pour ce disque
shopt -s nullglob
for job in "$SCAN_QUEUE_DIR"/SCAN_*.job; do
  if grep -q "^DISC_DIR=\"$disc_dir\"" "$job"; then
    log "Job déjà présent: $job"
    shopt -u nullglob
    exit 0
  fi
done
shopt -u nullglob

# Génère un suffixe aléatoire
rand="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6 || date +%s)"
ts="$(date +%s)"
job_file="$SCAN_QUEUE_DIR/SCAN_${ts}_${rand}.job"

tmp_job="${job_file}.tmp"
cat <<JOB >"$tmp_job"
DISC_DIR="$disc_dir"
ACTION="SCAN"
JOB
mv "$tmp_job" "$job_file"
log "Job créé: $job_file"
