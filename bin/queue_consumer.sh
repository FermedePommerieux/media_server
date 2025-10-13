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

DO_BACKUP_BIN="${DO_BACKUP_BIN:-}"

find_do_backup() {
  if [[ -n "$DO_BACKUP_BIN" ]]; then
    if command -v "$DO_BACKUP_BIN" >/dev/null 2>&1; then
      DO_BACKUP_BIN="$(command -v "$DO_BACKUP_BIN")"
      return 0
    fi
    if [[ -x "$DO_BACKUP_BIN" ]]; then
      return 0
    fi
  fi

  local candidate
  if command -v do_backup.sh >/dev/null 2>&1; then
    candidate="$(command -v do_backup.sh)"
    if [[ -x "$candidate" ]]; then
      DO_BACKUP_BIN="$candidate"
      return 0
    fi
  fi

  candidate="$SCRIPT_DIR/do_backup.sh"
  if [[ -x "$candidate" ]]; then
    DO_BACKUP_BIN="$candidate"
    return 0
  fi

  candidate="$SCRIPT_DIR/../dvd-archiver/bin/do_backup.sh"
  if [[ -x "$candidate" ]]; then
    DO_BACKUP_BIN="$candidate"
    return 0
  fi

  return 1
}

if ! find_do_backup; then
  log_err "Script do_backup introuvable (utilisez DO_BACKUP_BIN pour préciser le chemin)"
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
  if [[ "${ACTION:-}" != "BACKUP" ]]; then
    log_warn "Action inconnue (${ACTION:-}) pour $job"
    rm -f "${status_file}.skipped"
    mv "$job" "${status_file}.skipped"
    return
  fi
  export DEVICE
  local exit_code=0
  if "$DO_BACKUP_BIN"; then
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
