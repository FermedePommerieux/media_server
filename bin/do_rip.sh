#!/usr/bin/env bash
# /usr/local/bin/do_rip.sh
# script called by dvd-ripd.sh
# dvd_rip.sh — Rip automatique d'un DVD avec MakeMKV
# - Gère les doublons par (TITLE + empreinte de plusieurs secteurs)
# - Journalise proprement
# - Verrouille par disque pour éviter les rips concurrents
# - Éjecte le disque en sortie (succès/erreur)
# - Vérifie l'espace disque disponible

set -euo pipefail

# ------------------ Paramètres (surchageables via env) ------------------
LOG="${LOG:-/var/log/dvd_rip.log}"
DEVICE="${DEVICE:-/dev/sr0}"
DEST="${DEST:-/mnt/media_master}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"          # Espace libre minimal requis
DISC_HASH_SKIP_SECT="${DISC_HASH_SKIP_SECT:-10}"   # secteurs à ignorer avant hash
DISC_HASH_COUNT_SECT="${DISC_HASH_COUNT_SECT:-200}" # nb secteurs utilisés pour hash
DISC_HASH_TRIM="${DISC_HASH_TRIM:-12}"    # longueur du hash (8–16 conseillé)
MAKEMKV_OPTS="${MAKEMKV_OPTS:--r mkv}"    # options par défaut
IONICE_CLASS="${IONICE_CLASS:-2}"         # 2 = best-effort
IONICE_PRIO="${IONICE_PRIO:-7}"           # 0 (haut) → 7 (bas)
NICE_PRIO="${NICE_PRIO:-19}"

# ------------------ Fonctions utilitaires ------------------
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(timestamp)] $*" | tee -a "$LOG" >&2; }
err(){ echo "[$(timestamp)] ERROR: $*" | tee -a "$LOG" >&2; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "binaire manquant: $1"; exit 127; }
}

check_free_space_gb() {
  # Retourne l'espace libre (GB entiers) sur la partition de DEST
  df -Pk "$DEST" | awk 'NR==2 {print int($4/1024/1024)}'
}

normalize_title() {
  # 1) label via blkid, 2) volname, 3) fallback temporel
  local t
  t="$(blkid -o value -s LABEL "$DEVICE" 2>/dev/null || true)"
  if [[ -z "$t" ]] && command -v volname >/dev/null 2>&1; then
    t="$(volname "$DEVICE" 2>/dev/null || true)"
  fi
  [[ -z "$t" ]] && t="dvd_$(date +%Y%m%d_%H%M%S)"
  # Normalisation: espaces → _, caractères sûrs uniquement
  echo "$t" | tr ' ' '_' | tr -cd '[:alnum:]_-'
}

disc_id() {
  # Empreinte robuste = MD5(TITLE + secteurs DVD)
  local title="$1"
  # On lit plusieurs secteurs après un offset pour éviter structures communes
  local md
  md="$(
    {
      printf '%s\n' "$title"
      dd if="$DEVICE" bs=2048 count="$DISC_HASH_COUNT_SECT" skip="$DISC_HASH_SKIP_SECT" status=none 2>/dev/null
    } | md5sum | awk '{print $1}'
  )"
  # On tronque le hash si demandé
  echo "${md:0:$DISC_HASH_TRIM}"
}

# ------------------ Préparatifs & garde-fous ------------------
# Dossiers
install -d -m 775 "$DEST"
install -d -m 775 "$(dirname "$LOG")" || true
touch "$LOG" || { echo "Impossible d'écrire dans $LOG"; exit 1; }

# Dépendances
require_bin dd
require_bin md5sum
require_bin makemkvcon
command -v eject >/dev/null 2>&1 || log "warn: 'eject' non trouvé (pas bloquant)"
command -v volname >/dev/null 2>&1 || log "info: 'volname' non trouvé, fallback sur blkid"

# Éjection systématique quoi qu’il arrive
DEVICE_TO_EJECT="$DEVICE"
on_exit(){
  if command -v eject >/dev/null 2>&1; then
    eject "$DEVICE_TO_EJECT" || true
  fi
}
trap on_exit EXIT INT TERM

# ------------------ Détection titre & ID disque ------------------
TITLE="$(normalize_title)"
BASE="$DEST/$TITLE"
install -d -m 775 "$BASE"

DISC_ID="$(disc_id "$TITLE")"
OUT="$BASE/$DISC_ID"

log "Titre détecté: $TITLE ; DISC_ID=$DISC_ID ; Sortie: $OUT"

# ------------------ Verrouillage par disque ------------------
#LOCKDIR="$OUT/.riplock.d"
LOCK="$OUT/.riplock"

if [[ -f "$LOCK" ]] ; then
  log "Un rip est déjà en cours pour '$TITLE' (lock: $LOCKDIR). Abandon."
  exit 0
fi
# Assure la suppression du lock si arrêt brutal
cleanup_lock(){ rm -rf "$LOCK" 2>/dev/null || true; }
trap 'cleanup_lock; on_exit' EXIT INT TERM

# ------------------ Détection déjà rippé ------------------
if [[ -d "$OUT" ]] && find "$OUT" -maxdepth 1 -type f -iname '*.mkv' -print -quit | grep -q . ; then
  log "Déjà rippé: $TITLE ($DISC_ID) — MKV existants dans $OUT. Abandon."
  cleanup_lock
  exit 0
fi
install -d -m 775 "$OUT"

# ------------------ Vérif espace disque ------------------
FREE="$(check_free_space_gb || echo 0)"
if (( FREE < MIN_FREE_GB )); then
  err "Espace insuffisant sur $(df -Pk "$DEST" | awk 'NR==2{print $1}') : ${FREE}GB libres, requis: ${MIN_FREE_GB}GB"
  rmdir "$OUT" 2>/dev/null || true
  cleanup_lock
  exit 3
fi
log "Espace libre OK: ${FREE}GB (seuil: ${MIN_FREE_GB}GB)"

# ------------------ Rip complet avec MakeMKV ------------------
log "Début du rip: $TITLE ($DISC_ID) -> $OUT"
date +%s > "$LOCK"
# Baisse de priorité I/O + CPU (si disponibles)
RUN_WRAPPER=()
if command -v ionice >/dev/null 2>&1; then
  RUN_WRAPPER+=(ionice -c "$IONICE_CLASS" -n "$IONICE_PRIO")
fi
if command -v nice >/dev/null 2>&1; then
  RUN_WRAPPER+=(nice -n "$NICE_PRIO")
fi

# Format final: mkv dev:"/dev/sr0" all "/chemin/out"
# On ajoute --minlength via $MAKEMKV_OPTS si désiré (ex: "--minlength=1200")
set +e
"${RUN_WRAPPER[@]}" makemkvcon $MAKEMKV_OPTS dev:"$DEVICE" all "$OUT" >>"$LOG" 2>&1
MKV_STATUS=$?
set -e

if (( MKV_STATUS != 0 )); then
  err "Échec MakeMKV ($MKV_STATUS) pour $TITLE ($DISC_ID)."
  # Si répertoire vide → on nettoie
  if [[ -d "$OUT" ]] && [[ -z "$(ls -A "$OUT")" ]]; then
    rmdir "$OUT" 2>/dev/null || true
  fi
  cleanup_lock
  exit 2
fi

# Validation basique: au moins un MKV produit
if ! find "$OUT" -maxdepth 1 -type f -iname '*.mkv' -print -quit | grep -q . ; then
  err "Aucun fichier .mkv trouvé dans $OUT alors que MakeMKV a terminé sans erreur."
  cleanup_lock
  exit 4
fi

log "Rip terminé avec succès: $TITLE ($DISC_ID)"
cleanup_lock
exit 0
