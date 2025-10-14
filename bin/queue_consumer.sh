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
log_debug "Bibliothèque partagée chargée depuis $LIB_DIR"

resolve_bin() {
  local __target="$1"; shift || true
  local resolved=""
  local candidate
  for candidate in "$@"; do
    [[ -z "$candidate" ]] && continue
    if [[ -x "$candidate" ]]; then
      resolved="$candidate"
      break
    fi
  done
  printf -v "${__target}" '%s' "$resolved"
  if [[ -n "$resolved" ]]; then
    log_debug "Binaire résolu pour $__target: $resolved"
  else
    log_debug "Aucun binaire trouvé pour $__target parmi: $*"
  fi
}

declare -a DO_BACKUP_CANDIDATES=()
if [[ -n "${DO_BACKUP_BIN:-}" ]]; then
  DO_BACKUP_CANDIDATES+=("${DO_BACKUP_BIN}")
fi
DO_BACKUP_CANDIDATES+=("$SCRIPT_DIR/do_backup.sh")
DO_BACKUP_CANDIDATES+=("$(cd "$SCRIPT_DIR/.." && pwd)/dvd-archiver/bin/do_backup.sh")
DO_BACKUP_CANDIDATES+=("/usr/local/bin/do_backup.sh")

resolve_bin DO_BACKUP_BIN_RESOLVED "${DO_BACKUP_CANDIDATES[@]}"

if [[ -z "$DO_BACKUP_BIN_RESOLVED" ]]; then
  backup_candidates_str=$(IFS=', '; printf '%s' "${DO_BACKUP_CANDIDATES[*]}")
  log_err "Script do_backup introuvable (candidats: ${backup_candidates_str})"
  exit 51
fi
log_debug "do_backup résolu vers $DO_BACKUP_BIN_RESOLVED"

declare -a LEGACY_RIP_CANDIDATES=()
LEGACY_RIP_BIN="${LEGACY_RIP_BIN:-${DO_RIP_BIN:-}}"
if [[ -n "$LEGACY_RIP_BIN" ]]; then
  LEGACY_RIP_CANDIDATES+=("$LEGACY_RIP_BIN")
fi
if [[ -n "${LEGACY_RIP_CANDIDATES[*]:-}" ]]; then
  resolve_bin LEGACY_RIP_BIN_RESOLVED "${LEGACY_RIP_CANDIDATES[@]}"
  if [[ -z "$LEGACY_RIP_BIN_RESOLVED" ]]; then
    legacy_candidates_str=$(IFS=', '; printf '%s' "${LEGACY_RIP_CANDIDATES[*]}")
    log_err "Script post-backup (do_rip) introuvable: ${legacy_candidates_str}"
    exit 52
  fi
else
  LEGACY_RIP_BIN_RESOLVED=""
fi
if [[ -n "$LEGACY_RIP_BIN_RESOLVED" ]]; then
  log_debug "Script post-backup actif: $LEGACY_RIP_BIN_RESOLVED"
else
  log_debug "Aucun script post-backup configuré"
fi

process_job() {
  local job="$1"
  log_info "Traitement du job $job"
  log_debug "Lecture du contenu job depuis $job"
  if [[ ! -f "$job" ]]; then
    log_warn "Job $job introuvable"
    return
  fi
  # shellcheck disable=SC1090
  source "$job"
  log_debug "Paramètres du job: DEVICE=${DEVICE:-?} ACTION=${ACTION:-?} JOB_TS=${JOB_TS:-?} JOB_ID=${JOB_ID:-?}"
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
  log_info "Exécution do_backup: $DO_BACKUP_BIN_RESOLVED"
  log_debug "Début do_backup pour $job"
  if "$DO_BACKUP_BIN_RESOLVED"; then
    exit_code=0
  else
    exit_code=$?
    log_debug "do_backup s'est terminé avec le code $exit_code"
  fi
  if [[ $exit_code -eq 0 && -n "$LEGACY_RIP_BIN_RESOLVED" ]]; then
    log_info "Exécution post-backup (do_rip): $LEGACY_RIP_BIN_RESOLVED"
    log_debug "Début do_rip pour $job"
    if "$LEGACY_RIP_BIN_RESOLVED"; then
      exit_code=0
    else
      exit_code=$?
      log_debug "do_rip s'est terminé avec le code $exit_code"
    fi
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -f "${status_file}.done"
    mv "$job" "${status_file}.done"
    log_info "Job terminé: ${status_file}.done"
    log_debug "Job ${status_file} déplacé en .done"
  else
    rm -f "${status_file}.err"
    mv "$job" "${status_file}.err"
    log_err "Job en échec (code $exit_code): ${status_file}.err"
    log_debug "Job ${status_file} déplacé en .err (code $exit_code)"
  fi
}

main() {
  ensure_dirs
  local jobs=()
  mapfile -t jobs < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name 'JOB_*.job' | sort)
  log_debug "Jobs détectés: ${#jobs[@]}"
  if [[ ${#jobs[@]} -eq 0 ]]; then
    log_info "Aucun job à consommer"
    return 0
  fi
  for job in "${jobs[@]}"; do
    log_debug "Traitement en file: $job"
    if [[ -f "$job" ]]; then
      process_job "$job"
    fi
  done
}

main "$@"
