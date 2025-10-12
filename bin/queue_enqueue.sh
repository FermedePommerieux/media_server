#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR_DEFAULT="$SCRIPT_DIR/lib"
LIB_DIR="${LIB_DIR:-$LIB_DIR_DEFAULT}"
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="/usr/local/lib/dvdarchiver"
fi
# shellcheck source=bin/lib/common.sh
source "$LIB_DIR/common.sh"

main() {
  ensure_dirs
  local ts_now rand job_file
  ts_now=$(ts)
  rand=$(printf '%06d' "$RANDOM")
  local safe_ts
  safe_ts="${ts_now//[^0-9]/}" 
  job_file="$QUEUE_DIR/JOB_${safe_ts}_${rand}.job"
  while [[ -e "$job_file" ]]; do
    rand=$(printf '%06d' "$RANDOM")
    job_file="$QUEUE_DIR/JOB_${safe_ts}_${rand}.job"
  done
  cat >"$job_file" <<JOB
DEVICE=${DEVICE}
ACTION=RIP
JOB_TS=${ts_now}
JOB_ID=${rand}
JOB
  log_info "Nouveau job en file: $job_file"
}

main "$@"
