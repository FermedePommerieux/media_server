#!/usr/bin/env bash
set -euo pipefail

WITH_SYSTEMD=1
WITH_UDEV=1
PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/dvdarchiver"
CONFIG_FILE="/etc/dvdarchiver.conf"
CONFIG_SAMPLE="$SCRIPT_DIR/etc/dvdarchiver.conf.sample"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"

APT_UPDATED=0

ensure_package() {
  local pkg="$1"
  if ! command -v dpkg >/dev/null 2>&1; then
    echo "dpkg absent, veuillez installer $pkg manuellement" >&2
    return
  fi
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get indisponible, impossible d'installer $pkg automatiquement" >&2
    return
  fi
  if [[ $APT_UPDATED -eq 0 ]]; then
    echo "Mise à jour de l'index APT..."
    set +e
    apt-get update >/dev/null 2>&1
    APT_UPDATED=1
    set -e
  fi
  echo "Installation du paquet $pkg"
  set +e
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "Avertissement: installation de $pkg impossible" >&2
  fi
}

ensure_command() {
  local bin="$1" pkg="${2:-$1}"
  if command -v "$bin" >/dev/null 2>&1; then
    return
  fi
  echo "Commande $bin absente, tentative d'installation via $pkg"
  ensure_package "$pkg"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Avertissement: la commande $bin reste indisponible après l'installation de $pkg" >&2
  fi
}

install_ollama() {
  if command -v ollama >/dev/null 2>&1; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl requis pour installer Ollama" >&2
    return
  fi
  echo "Installation d'Ollama..."
  set +e
  curl -fsSL https://ollama.com/install.sh | sh
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "Avertissement: installation Ollama échouée" >&2
    return
  fi
  if command -v systemctl >/dev/null 2>&1; then
    set +e
    systemctl enable --now ollama >/dev/null 2>&1
    set -e
  fi
}

usage() {
  cat <<USAGE
Usage: $0 [--with-systemd] [--with-udev] [--prefix=PATH]
Installe le pipeline DVD Archiver.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --with-systemd)
      WITH_SYSTEMD=1
      ;;
    --with-udev)
      WITH_UDEV=1
      ;;
    --prefix=*)
      PREFIX="${arg#*=}"
      BINDIR="${PREFIX}/bin"
      LIBDIR="${PREFIX}/lib/dvdarchiver"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

SCAN_PY_DIR="${PREFIX}/bin/scan"

install -d "$BINDIR" "$LIBDIR" "$SCAN_PY_DIR"

REQUIRED_COMMANDS=(
  "tesseract:tesseract-ocr"
  "ffmpeg:ffmpeg"
  "mkvmerge:mkvtoolnix"
  "curl:curl"
  "lsdvd:lsdvd"
  "isoinfo:genisoimage"
  "eject:eject"
  "python3:python3"
)

for spec in "${REQUIRED_COMMANDS[@]}"; do
  IFS=':' read -r bin pkg <<<"$spec"
  ensure_command "$bin" "$pkg"
done

install_ollama
if command -v ollama >/dev/null 2>&1; then
  echo "Mise à jour du modèle Ollama qwen2.5:14b-instruct-q4_K_M"
  set +e
  ollama pull qwen2.5:14b-instruct-q4_K_M >/dev/null 2>&1
  set -e
fi

for script in "$SCRIPT_DIR"/dvd-archiver/bin/do_backup.sh "$SCRIPT_DIR"/bin/do_rip.sh "$SCRIPT_DIR"/bin/queue_enqueue.sh "$SCRIPT_DIR"/bin/queue_consumer.sh "$SCRIPT_DIR"/bin/scan_enqueue.sh "$SCRIPT_DIR"/bin/scan_consumer.sh; do
  install -m 0755 "$script" "$BINDIR/$(basename "$script")"
  echo "Installé $BINDIR/$(basename "$script")"
done

for lib in "$SCRIPT_DIR"/bin/lib/common.sh "$SCRIPT_DIR"/bin/lib/hash.sh "$SCRIPT_DIR"/bin/lib/techdump.sh; do
  install -m 0755 "$lib" "$LIBDIR/$(basename "$lib")"
  echo "Installé $LIBDIR/$(basename "$lib")"
done

for module in "$SCRIPT_DIR"/bin/scan/*.py; do
  mode=0644
  [[ $(basename "$module") == "scanner.py" ]] && mode=0755
  install -m "$mode" "$module" "$SCAN_PY_DIR/$(basename "$module")"
  echo "Installé $SCAN_PY_DIR/$(basename "$module")"
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  install -Dm0644 "$CONFIG_SAMPLE" "$CONFIG_FILE"
  echo "Configuration initiale copiée vers $CONFIG_FILE"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
QUEUE_DIR="${QUEUE_DIR:-/var/spool/dvdarchiver}"
LOG_DIR="${LOG_DIR:-/var/log/dvdarchiver}"
TMP_DIR="${TMP_DIR:-/var/tmp/dvdarchiver}"
SCAN_QUEUE_DIR="${SCAN_QUEUE_DIR:-/var/spool/dvdarchiver-scan}"
SCAN_LOG_DIR="${SCAN_LOG_DIR:-/var/log/dvdarchiver-scan}"

mkdir -p "$DEST" "$QUEUE_DIR" "$LOG_DIR" "$TMP_DIR" "$SCAN_QUEUE_DIR" "$SCAN_LOG_DIR"

if [[ $WITH_SYSTEMD -eq 1 ]]; then
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.service "$SYSTEMD_DIR/dvdarchiver-queue-consumer.service"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.path "$SYSTEMD_DIR/dvdarchiver-queue-consumer.path"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.timer "$SYSTEMD_DIR/dvdarchiver-queue-consumer.timer"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-scan-consumer.service "$SYSTEMD_DIR/dvdarchiver-scan-consumer.service"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-scan-consumer.path "$SYSTEMD_DIR/dvdarchiver-scan-consumer.path"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    set +e
    if systemctl enable --now dvdarchiver-queue-consumer.path >/dev/null 2>&1; then
      echo "Unité dvdarchiver-queue-consumer.path activée"
    else
      echo "Avertissement: impossible d'activer dvdarchiver-queue-consumer.path automatiquement" >&2
    fi
    if systemctl enable --now dvdarchiver-scan-consumer.path >/dev/null 2>&1; then
      echo "Unité dvdarchiver-scan-consumer.path activée"
    else
      echo "Avertissement: impossible d'activer dvdarchiver-scan-consumer.path automatiquement" >&2
    fi
    if systemctl enable --now dvdarchiver-queue-consumer.timer >/dev/null 2>&1; then
      echo "Timer dvdarchiver-queue-consumer.timer activé"
    else
      echo "Avertissement: impossible d'activer dvdarchiver-queue-consumer.timer automatiquement" >&2
    fi
    set -e
  else
    echo "systemctl introuvable, activez les unités systemd manuellement" >&2
  fi
  echo "Unités systemd installées"
fi

if [[ $WITH_UDEV -eq 1 ]]; then
  install -Dm0644 "$SCRIPT_DIR"/udev/99-dvdarchiver.rules "$UDEV_DIR/99-dvdarchiver.rules"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload
  fi
  echo "Règle udev installée"
fi

echo
echo "Tests rapides suggérés :"
echo "  scan_enqueue.sh \"${DEST}/<DISC_UID>\""
echo "  journalctl -u dvdarchiver-scan-consumer.service -f"
echo "  cat ${DEST}/<DISC_UID>/meta/metadata_ia.json"

echo "Installation terminée"
