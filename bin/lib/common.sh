#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/dvdarchiver.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

DEST="${DEST:-/mnt/media_master}"
QUEUE_DIR="${QUEUE_DIR:-/var/spool/dvdarchiver}"
LOG_DIR="${LOG_DIR:-/var/log/dvdarchiver}"
TMP_DIR="${TMP_DIR:-/var/tmp/dvdarchiver}"
DEVICE="${DEVICE:-/dev/sr0}"
MAKEMKV_BIN="${MAKEMKV_BIN:-makemkvcon}"
ISOINFO_BIN="${ISOINFO_BIN:-isoinfo}"
LSDVD_BIN="${LSDVD_BIN:-lsdvd}"
EJECT_BIN="${EJECT_BIN:-eject}"
MOUNT_OPTS="${MOUNT_OPTS:-udf,iso9660,ro}"
MAKEMKV_OPTS="${MAKEMKV_OPTS:---minlength=0}"
MAKEMKV_BACKUP_ENABLE="${MAKEMKV_BACKUP_ENABLE:-1}"
MAKEMKV_BACKUP_OPTS="${MAKEMKV_BACKUP_OPTS:---decrypt}"
KEEP_MENU_VOBS="${KEEP_MENU_VOBS:-1}"
MENU_VOB_GLOB="${MENU_VOB_GLOB:-VIDEO_TS.VOB VTS_*_0.VOB}"
MOUNT_TMP_DIR="${MOUNT_TMP_DIR:-/mnt/dvd_tmp}"
DISC_HASH_COUNT_SECT="${DISC_HASH_COUNT_SECT:-64}"
DISC_HASH_SKIP_SECT="${DISC_HASH_SKIP_SECT:-32768}"
DISC_HASH_EXTRA_OFFSETS="${DISC_HASH_EXTRA_OFFSETS:-0 262144}"
DISC_HASH_TRIM="${DISC_HASH_TRIM:-16}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"
EJECT_ON_DONE="${EJECT_ON_DONE:-1}"
ALLOW_ISO_DUMP="${ALLOW_ISO_DUMP:-0}"
ARCHIVE_LAYOUT_VERSION="${ARCHIVE_LAYOUT_VERSION:-1.0}"

LOG_TAG="dvdarchiver"

_ts_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_message() {
  local level="$1"; shift || true
  local msg="$*"
  local timestamp severity
  timestamp=$(_ts_now)
  mkdir -p "$LOG_DIR"
  printf '%s [%s] %s\n' "$timestamp" "$level" "$msg" >>"$LOG_DIR/dvdarchiver.log"
  case "$level" in
    INFO) severity="info" ;;
    WARN) severity="warning" ;;
    ERR) severity="err" ;;
    *) severity="notice" ;;
  esac
  if command -v logger >/dev/null 2>&1; then
    logger -t "$LOG_TAG" -p "user.${severity}" -- "$msg"
  fi
}

log_info() {
  log_message "INFO" "$*"
}

log_warn() {
  log_message "WARN" "$*"
}

log_err() {
  log_message "ERR" "$*"
}

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log_err "Dépendance manquante: $bin"
    printf 'Commande requise introuvable: %s\n' "$bin" >&2
    exit 12
  fi
}

ensure_dirs() {
  mkdir -p "$DEST" "$QUEUE_DIR" "$LOG_DIR" "$TMP_DIR"
}

check_free_space_gb() {
  local path="$1"
  local min_gb="$2"
  local free_gb
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path"
  fi
  free_gb=$(df --output=avail -BG "$path" | tail -n 1 | tr -dc '0-9')
  free_gb=${free_gb:-0}
  if (( free_gb < min_gb )); then
    log_err "Espace disque insuffisant sur $path: ${free_gb}G < ${min_gb}G"
    printf 'Espace disque insuffisant sur %s: %sG disponibles, requis: %sG\n' "$path" "$free_gb" "$min_gb" >&2
    exit 20
  fi
}

safe_umount() {
  local mountpoint="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    if mountpoint -q "$mountpoint"; then
      umount "$mountpoint" || log_warn "Impossible de démonter $mountpoint"
    fi
  else
    umount "$mountpoint" >/dev/null 2>&1 || true
  fi
}

ts() {
  _ts_now
}

json_escape() {
  local str="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$str" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1])[1:-1], end='')
PY
  else
    local dq='"'
    str=${str//\\/\\\\}
    str=${str//${dq}/\\${dq}}
    str=${str//$'\n'/ }
    str=${str//$'\r'/ }
    str=${str//$'\t'/ }
    printf '%s' "$str"
  fi
}
