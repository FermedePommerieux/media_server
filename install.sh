#!/usr/bin/env bash
set -euo pipefail

WITH_SYSTEMD=0
WITH_UDEV=0
PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/dvdarchiver"
CONFIG_FILE="/etc/dvdarchiver.conf"
CONFIG_SAMPLE="$SCRIPT_DIR/etc/dvdarchiver.conf.sample"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_DIR="/etc/udev/rules.d"

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

install -d "$BINDIR" "$LIBDIR"

for script in "$SCRIPT_DIR"/bin/do_rip.sh "$SCRIPT_DIR"/bin/queue_enqueue.sh "$SCRIPT_DIR"/bin/queue_consumer.sh; do
  install -m 0755 "$script" "$BINDIR/$(basename "$script")"
  echo "Installé $BINDIR/$(basename "$script")"
done

for lib in "$SCRIPT_DIR"/bin/lib/common.sh "$SCRIPT_DIR"/bin/lib/hash.sh "$SCRIPT_DIR"/bin/lib/techdump.sh; do
  install -m 0755 "$lib" "$LIBDIR/$(basename "$lib")"
  echo "Installé $LIBDIR/$(basename "$lib")"
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

mkdir -p "$DEST" "$QUEUE_DIR" "$LOG_DIR" "$TMP_DIR"

if [[ $WITH_SYSTEMD -eq 1 ]]; then
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.service "$SYSTEMD_DIR/dvdarchiver-queue-consumer.service"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.path "$SYSTEMD_DIR/dvdarchiver-queue-consumer.path"
  install -Dm0644 "$SCRIPT_DIR"/systemd/dvdarchiver-queue-consumer.timer "$SYSTEMD_DIR/dvdarchiver-queue-consumer.timer"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
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

echo "Installation terminée"
