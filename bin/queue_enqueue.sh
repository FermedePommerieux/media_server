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
ACTION=BACKUP
JOB_TS=${ts_now}
JOB_ID=${rand}
JOB
  log_info "Nouveau job en file: $job_file"
}

main "$@"
