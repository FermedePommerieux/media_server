#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="${PREFIX}/bin"
SCANDIR="${BINDIR}/scan"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="/etc/dvdarchiver.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SAMPLE="${SCRIPT_DIR}/etc/dvdarchiver.conf.sample"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install][WARN] %s\n' "$*" >&2; }
error() { printf '[install][ERREUR] %s\n' "$*" >&2; }

check_dep() {
  local bin="$1"
  if command -v "$bin" >/dev/null 2>&1; then
    log "Dépendance présente: $bin"
  else
    warn "Dépendance manquante: $bin"
  fi
}

install_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    log "Ollama déjà installé"
    return
  fi
  warn "Ollama absent, tentative d'installation"
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl indisponible, installez Ollama manuellement: https://ollama.ai"
    return
  fi
  set +e
  curl -fsSL https://ollama.ai/install.sh | sh
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "Installation Ollama échouée (code $rc). Installez-le manuellement."
    return
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl enable --now ollama >/dev/null 2>&1; then
      warn "Impossible d'activer le service ollama (poursuite malgré tout)"
    else
      log "Service ollama activé"
    fi
  fi
}

pull_llm_model() {
  local model="${LLM_MODEL:-qwen2.5:14b-instruct-q4_K_M}"
  if ! command -v ollama >/dev/null 2>&1; then
    warn "Ollama indisponible, impossible de tirer le modèle ${model}."
    warn "Vous pourrez lancer: ollama pull ${model} une fois le service prêt."
    return
  fi
  log "Téléchargement du modèle Ollama (${model})"
  set +e
  ollama pull "${model}"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "Échec du téléchargement du modèle ${model} (code ${rc}). Relancez manuellement."
  fi
}

copy_scripts() {
  install -d "${BINDIR}" "${SCANDIR}"
  install -m 0755 "${SCRIPT_DIR}/bin/do_backup.sh" "${BINDIR}/do_backup.sh"
  install -m 0755 "${SCRIPT_DIR}/bin/scan_enqueue.sh" "${BINDIR}/scan_enqueue.sh"
  install -m 0755 "${SCRIPT_DIR}/bin/scan_consumer.sh" "${BINDIR}/scan_consumer.sh"
  install -m 0755 "${SCRIPT_DIR}/bin/mkv_build_enqueue.sh" "${BINDIR}/mkv_build_enqueue.sh"
  install -m 0755 "${SCRIPT_DIR}/bin/mkv_build_consumer.sh" "${BINDIR}/mkv_build_consumer.sh"
  for module in "${SCRIPT_DIR}"/bin/scan/*.py; do
    local mode=0644
    [[ $(basename "${module}") == "scanner.py" ]] && mode=0755
    install -m "${mode}" "${module}" "${SCANDIR}/$(basename "${module}")"
  done
  log "Scripts installés dans ${BINDIR} et ${SCANDIR}"
}

install_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    install -Dm0644 "${CONFIG_SAMPLE}" "${CONFIG_FILE}"
    log "Configuration initiale copiée vers ${CONFIG_FILE}"
  else
    log "Configuration existante détectée (${CONFIG_FILE}), pas d'écrasement"
    diff -u "${CONFIG_SAMPLE}" "${CONFIG_FILE}" || true
  fi
  # shellcheck disable=SC1091
  if [[ -f "${CONFIG_FILE}" ]]; then source "${CONFIG_FILE}"; fi
  DEST="${DEST:-/mnt/media_master}"
  SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"
  SCAN_LOG_DIR="${SCAN_LOG_DIR:-/var/log/dvdarchiver-scan}"
  BUILD_QUEUE_DIR="${BUILD_QUEUE_DIR:-/var/spool/dvdarchiver-build}"
  BUILD_LOG_DIR="${BUILD_LOG_DIR:-/var/log/dvdarchiver-build}"
  mkdir -p "${DEST}" "${SCAN_QUEUE_DIR}" "${SCAN_LOG_DIR}" "${BUILD_QUEUE_DIR}" "${BUILD_LOG_DIR}" "${TMP_DIR:-/var/tmp/dvdarchiver}"
  log "Répertoires prêts: DEST=${DEST}, SCAN_QUEUE=${SCAN_QUEUE_DIR}, BUILD_QUEUE=${BUILD_QUEUE_DIR}"
}

install_systemd() {
  install -Dm0644 "${SCRIPT_DIR}/systemd/dvdarchiver-scan-consumer.service" "${SYSTEMD_DIR}/dvdarchiver-scan-consumer.service"
  install -Dm0644 "${SCRIPT_DIR}/systemd/dvdarchiver-scan-consumer.path" "${SYSTEMD_DIR}/dvdarchiver-scan-consumer.path"
  install -Dm0644 "${SCRIPT_DIR}/systemd/dvdarchiver-mkv-build-consumer.service" "${SYSTEMD_DIR}/dvdarchiver-mkv-build-consumer.service"
  install -Dm0644 "${SCRIPT_DIR}/systemd/dvdarchiver-mkv-build-consumer.path" "${SYSTEMD_DIR}/dvdarchiver-mkv-build-consumer.path"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if ! systemctl enable --now dvdarchiver-scan-consumer.path >/dev/null 2>&1; then
      warn "Impossible d'activer dvdarchiver-scan-consumer.path. Activez-le manuellement."
    else
      log "Path dvdarchiver-scan-consumer activé"
    fi
    if ! systemctl enable --now dvdarchiver-mkv-build-consumer.path >/dev/null 2>&1; then
      warn "Impossible d'activer dvdarchiver-mkv-build-consumer.path. Activez-le manuellement."
    else
      log "Path dvdarchiver-mkv-build-consumer activé"
    fi
  else
    warn "systemctl indisponible, installez les unités manuellement"
  fi
}

print_summary() {
  cat <<SUMMARY
--- Récapitulatif ---
Binaires installés dans : ${BINDIR}
Scripts Python dans : ${SCANDIR}
Configuration : ${CONFIG_FILE}
Destination : ${DEST:-/mnt/media_master}
File de scan : ${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}
File de build : ${BUILD_QUEUE_DIR:-/var/spool/dvdarchiver-build}
Logs scan : ${SCAN_LOG_DIR:-/var/log/dvdarchiver-scan}
Logs build : ${BUILD_LOG_DIR:-/var/log/dvdarchiver-build}
LLM : provider=${LLM_PROVIDER:-ollama} modèle=${LLM_MODEL:-qwen2.5:14b-instruct-q4_K_M}

Test rapide :
  do_backup.sh
  journalctl -u dvdarchiver-scan-consumer.service -f
  journalctl -u dvdarchiver-mkv-build-consumer.service -f
SUMMARY
}

main() {
  log "Installation Phase 2 (scan + OCR + IA)"

  check_dep python3
  check_dep tesseract
  check_dep ffmpeg
  check_dep lsdvd
  check_dep mkvmerge
  check_dep makemkvcon
  check_dep curl

  install_ollama
  # Peut définir LLM_MODEL via configuration après sourcing
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1091
    source "${CONFIG_FILE}"
  fi
  pull_llm_model || true

  copy_scripts
  install_config
  install_systemd

  print_summary
}

main "$@"
