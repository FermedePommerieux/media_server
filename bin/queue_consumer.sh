#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_lib_dir_candidates=()
if [[ -n "${LIB_DIR:-}" ]]; then
  _lib_dir_candidates+=("$LIB_DIR")
fi
_lib_dir_candidates+=("$SCRIPT_DIR/lib")
_lib_dir_candidates+=("$(cd "$SCRIPT_DIR/.." && pwd)/lib/dvdarchiver")
_lib_dir_candidates+=("/usr/local/lib/dvdarchiver")

LIB_DIR=""
for candidate in "${_lib_dir_candidates[@]}"; do
  if [[ -d "$candidate" ]]; then
    LIB_DIR="$candidate"
    break
  fi
done

if [[ -z "$LIB_DIR" ]]; then
  printf 'Impossible de localiser les bibliothèques dvdarchiver (essayé: %s)\n' "${_lib_dir_candidates[*]}" >&2
  exit 11
fi
# shellcheck source=bin/lib/common.sh
source "$LIB_DIR/common.sh"

DO_RIP_BIN="${DO_RIP_BIN:-$SCRIPT_DIR/do_rip.sh}"

if [[ ! -x "$DO_RIP_BIN" ]]; then
  log_err "Script do_rip introuvable ou non exécutable: $DO_RIP_BIN"
  exit 51
fi

process_job() {
  local job="$1"
  log_info "Traitement du job $job"
  if [[ ! -f "$job" ]]; then
    log_warn "Job $job introuvable"
    return
  fi
  # shellcheck disable=SC1090
  source "$job"
  local status_file
  status_file="${job%.job}"
  if [[ "${ACTION:-}" != "RIP" ]]; then
    log_warn "Action inconnue (${ACTION:-}) pour $job"
    rm -f "${status_file}.skipped"
    mv "$job" "${status_file}.skipped"
    return
  fi
  export DEVICE
  local exit_code=0
  if "$DO_RIP_BIN"; then
    exit_code=0
  else
    exit_code=$?
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -f "${status_file}.done"
    mv "$job" "${status_file}.done"
    log_info "Job terminé: ${status_file}.done"
  else
    rm -f "${status_file}.err"
    mv "$job" "${status_file}.err"
    log_err "Job en échec (code $exit_code): ${status_file}.err"
  fi
}

main() {
  ensure_dirs
  local jobs=()
  mapfile -t jobs < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name 'JOB_*.job' | sort)
  if [[ ${#jobs[@]} -eq 0 ]]; then
    log_info "Aucun job à consommer"
    return 0
  fi
  for job in "${jobs[@]}"; do
    if [[ -f "$job" ]]; then
      process_job "$job"
    fi
  done
}

main "$@"
