#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dvdarchiver.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_FILE"
fi

BUILD_QUEUE_DIR="${BUILD_QUEUE_DIR:-/var/spool/dvdarchiver-build}"
log() { printf '[build_enqueue] %s\n' "$*"; }
usage() { cat <<USAGE >&2
Usage: $0 <DISC_DIR>
USAGE
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

disc_dir="$1"
if [[ ! -d "$disc_dir" ]]; then
  log "Répertoire disque introuvable: $disc_dir"
  exit 1
fi

metadata="$disc_dir/meta/metadata_ia.json"
if [[ ! -f "$metadata" ]]; then
  log "metadata_ia.json absent, gating actif"
  exit 0
fi

mkdir -p "$BUILD_QUEUE_DIR"

disc_dir="$(cd "$disc_dir" && pwd)"

shopt -s nullglob
for job in "$BUILD_QUEUE_DIR"/BUILD_*.job; do
  if grep -q "^DISC_DIR=\"$disc_dir\"" "$job"; then
    log "Job déjà en file: $job"
    shopt -u nullglob
    exit 0
  fi
done
shopt -u nullglob

rand="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 6 || date +%s)"
ts="$(date +%s)"
job_file="$BUILD_QUEUE_DIR/BUILD_${ts}_${rand}.job"

tmp_job="${job_file}.tmp"
cat <<JOB >"$tmp_job"
DISC_DIR="$disc_dir"
ACTION="BUILD"
JOB
mv "$tmp_job" "$job_file"
log "Job créé: $job_file"
