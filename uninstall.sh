#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[désinstallation] %s\n' "$*"
}

warn() {
  printf '[désinstallation][avertissement] %s\n' "$*" >&2
}

WITH_SYSTEMD=1
WITH_UDEV=1
REMOVE_OLLAMA_MODEL=1
PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/dvdarchiver"
SCAN_PY_DIR="${BINDIR}/scan"
CONFIG_FILE="/etc/dvdarchiver.conf"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"
MODEL_NAME="qwen2.5:14b-instruct-q4_K_M"

usage() {
  cat <<USAGE
Usage: $0 [--prefix=PATH] [--no-systemd] [--no-udev] [--keep-model]
Supprime les composants installés par install.sh.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*)
      PREFIX="${arg#*=}"
      BINDIR="${PREFIX}/bin"
      LIBDIR="${PREFIX}/lib/dvdarchiver"
      SCAN_PY_DIR="${BINDIR}/scan"
      ;;
    --no-systemd)
      WITH_SYSTEMD=0
      ;;
    --no-udev)
      WITH_UDEV=0
      ;;
    --keep-model)
      REMOVE_OLLAMA_MODEL=0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      warn "Option inconnue: $arg"
      usage
      exit 1
      ;;
  esac
done

remove_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -f "$path"
    log "Supprimé $path"
  fi
}

remove_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then
    rm -rf "$path"
    log "Supprimé $path"
  fi
}

# Supprimer les binaires et bibliothèques installés
for script in do_backup.sh queue_enqueue.sh queue_consumer.sh scan_enqueue.sh scan_consumer.sh; do
  remove_file "${BINDIR}/${script}"
done
remove_dir "$SCAN_PY_DIR"
remove_dir "$LIBDIR"

# Nettoyage systemd
if [[ $WITH_SYSTEMD -eq 1 ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    for unit in dvdarchiver-queue-consumer.service dvdarchiver-queue-consumer.path \
      dvdarchiver-queue-consumer.timer dvdarchiver-scan-consumer.service \
      dvdarchiver-scan-consumer.path; do
      if systemctl list-unit-files | grep -q "^${unit}"; then
        set +e
        systemctl disable --now "$unit" >/dev/null 2>&1
        set -e
      fi
      remove_file "${SYSTEMD_DIR}/${unit}"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    for unit in dvdarchiver-queue-consumer.service dvdarchiver-queue-consumer.path \
      dvdarchiver-queue-consumer.timer dvdarchiver-scan-consumer.service \
      dvdarchiver-scan-consumer.path; do
      remove_file "${SYSTEMD_DIR}/${unit}"
    done
  fi
fi

# Nettoyage udev
if [[ $WITH_UDEV -eq 1 ]]; then
  remove_file "${UDEV_DIR}/99-dvdarchiver.rules"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload >/dev/null 2>&1 || true
  fi
fi

# Supprimer la configuration par défaut si elle n'a pas été modifiée
if [[ -f "$CONFIG_FILE" ]]; then
  if cmp -s "$CONFIG_FILE" "$SCRIPT_DIR/etc/dvdarchiver.conf.sample"; then
    remove_file "$CONFIG_FILE"
  else
    warn "Configuration personnalisée conservée: $CONFIG_FILE"
  fi
fi

# Charger la configuration pour connaître les répertoires à nettoyer
DEFAULT_DEST="/mnt/media_master"
DEFAULT_QUEUE_DIR="/var/spool/dvdarchiver"
DEFAULT_LOG_DIR="/var/log/dvdarchiver"
DEFAULT_TMP_DIR="/var/tmp/dvdarchiver"
DEFAULT_SCAN_QUEUE_DIR="/var/spool/dvdarchiver-scan"
DEFAULT_SCAN_LOG_DIR="/var/log/dvdarchiver-scan"

DEST="$DEFAULT_DEST"
QUEUE_DIR="$DEFAULT_QUEUE_DIR"
LOG_DIR="$DEFAULT_LOG_DIR"
TMP_DIR="$DEFAULT_TMP_DIR"
SCAN_QUEUE_DIR="$DEFAULT_SCAN_QUEUE_DIR"
SCAN_LOG_DIR="$DEFAULT_SCAN_LOG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

cleanup_data_dir() {
  local path="$1"
  local default="$2"
  local label="$3"

  if [[ "$path" != "$default" ]]; then
    warn "$label personnalisé conservé: $path"
    return
  fi
  if [[ -d "$path" ]]; then
    remove_dir "$path"
  fi
}

cleanup_data_dir "$QUEUE_DIR" "$DEFAULT_QUEUE_DIR" "Répertoire de file d'attente"
cleanup_data_dir "$LOG_DIR" "$DEFAULT_LOG_DIR" "Répertoire de journaux"
cleanup_data_dir "$TMP_DIR" "$DEFAULT_TMP_DIR" "Répertoire temporaire"
cleanup_data_dir "$SCAN_QUEUE_DIR" "$DEFAULT_SCAN_QUEUE_DIR" "Répertoire de file d'attente (scan)"
cleanup_data_dir "$SCAN_LOG_DIR" "$DEFAULT_SCAN_LOG_DIR" "Répertoire de journaux (scan)"

if [[ "$DEST" == "$DEFAULT_DEST" && -d "$DEST" ]]; then
  warn "Répertoire de destination conservé: $DEST"
elif [[ "$DEST" != "$DEFAULT_DEST" ]]; then
  warn "Répertoire de destination personnalisé conservé: $DEST"
fi

# Nettoyer le modèle Ollama téléchargé
if [[ $REMOVE_OLLAMA_MODEL -eq 1 && -x "$(command -v ollama || true)" ]]; then
  set +e
  ollama rm "$MODEL_NAME" >/dev/null 2>&1
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    log "Modèle Ollama supprimé: $MODEL_NAME"
  else
    warn "Impossible de supprimer le modèle Ollama (peut-être absent?)"
  fi
fi

log "Désinstallation terminée"
