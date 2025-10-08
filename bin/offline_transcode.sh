#!/usr/bin/env bash
# /usr/local/bin/offline_transcode.sh
# offline_transcode.sh — profil Archivage (x265), respecte .riplock par répertoire
set -euo pipefail

SRC="${SRC:-/mnt/media_master}"    # rips/matériels bruts
DST="${DST:-/mnt/nas_media}"       # sorties pour Jellyfin
LOG="${LOG:-/var/log/offline_transcode.log}"
LOCK="${LOCK:-/tmp/offline_transcode.lock}"

THREADS_RAW="${THREADS:-}"
THREADS_RAW_CLEAN="${THREADS_RAW//[[:space:]]/}"
PRESET="${PRESET:-medium}"
CRF_SD="${CRF_SD:-18}"       # <=576p
CRF_720="${CRF_720:-21}"
CRF_1080="${CRF_1080:-22}"
X265_PARAMS="${X265_PARAMS:-"aq-mode=3:aq-strength=1.0:psy-rd=2.0:psy-rdoq=1.0:deblock=-1:-1:rd=4"}"
MAPARGS=( -map 0 )
VFILT="${VFILT:-bwdif=mode=send_field:parity=auto:deint=all}"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG"
}

warn() {
  log "ATTENTION: $*"
}

fatal() {
  log "ERREUR: $*"
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fatal "binaire manquant: $1"
}

mkdir -p "$(dirname "$LOG")"
touch "$LOG"

require_bin ffmpeg
require_bin ffprobe
require_bin md5sum

THREAD_ARGS=()
THREAD_LABEL=""
if [[ -z "$THREADS_RAW_CLEAN" ]]; then
  THREADS=2
  THREAD_ARGS=( -threads "$THREADS" )
  THREAD_LABEL="${THREADS} (défaut)"
elif [[ "$THREADS_RAW_CLEAN" =~ ^[0-9]+$ ]]; then
  THREADS=$THREADS_RAW_CLEAN
  if (( THREADS == 0 )); then
    THREAD_ARGS=()
    THREAD_LABEL="auto (THREADS=0)"
  else
    THREAD_ARGS=( -threads "$THREADS" )
    THREAD_LABEL="$THREADS"
  fi
elif [[ "$THREADS_RAW_CLEAN" =~ ^[Aa][Uu][Tt][Oo]$ ]]; then
  THREADS=0
  THREAD_ARGS=()
  THREAD_LABEL="auto"
else
  warn "THREADS='$THREADS_RAW' invalide, utilisation de la valeur par défaut 2"
  THREADS=2
  THREAD_ARGS=( -threads "$THREADS" )
  THREAD_LABEL="${THREADS} (fallback)"
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  log "Processus déjà actif, sortie."
  exit 0
fi

log "=== Offline transcode (ARCHIVE) démarré ==="
log "Configuration: SRC=$SRC, DST=$DST, preset=$PRESET, threads=$THREAD_LABEL"
log "CRF: <=576p=$CRF_SD, 720p=$CRF_720, 1080p=$CRF_1080"
log "Filtre vidéo: $VFILT"
log "Paramètres x265: $X265_PARAMS"

shopt -s nullglob

log "Début de l'énumération des répertoires depuis $SRC"
if ! mapfile -d '' -t DIRS < <(find "$SRC" -type d -print0 2>>"$LOG" | sort -z); then
  status_dirs=("${PIPESTATUS[@]}")
  fatal "Échec lors de l'énumération des répertoires (PIPESTATUS=${status_dirs[*]})"
fi
status_dirs=("${PIPESTATUS[@]}")
log "Énumération terminée (PIPESTATUS=${status_dirs[*]})"

SKIP_LOCKED=0
SKIP_DONE=0
SKIP_EMPTY=0
TRANSCODED=0
FAILED=0

total_dirs=${#DIRS[@]}
log "Répertoires détectés: $total_dirs"

for DIR in "${DIRS[@]}"; do
  dir_start=$SECONDS
  REL_DIR="${DIR#$SRC/}"
  [[ "$REL_DIR" == "$DIR" ]] && REL_DIR=""

  log "Inspection du répertoire: ${REL_DIR:-.} (chemin complet: $DIR)"

  if [[ ! -r "$DIR" ]]; then
    ((FAILED++))
    warn "Répertoire illisible, permissions manquantes? ${REL_DIR:-.}"
    continue
  fi

  if [[ -f "$DIR/.riplock" ]]; then
    ((SKIP_LOCKED++))
    log "Skip dir (rip lock): ${REL_DIR:-.}"
    continue
  fi

  FILES=()
  log "Recherche de fichiers médias dans ${REL_DIR:-.}"
  if ! mapfile -d '' -t FILES < <(find "$DIR" -maxdepth 1 -type f \
    \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.vob" -o -iname "*.m2ts" \) -print0 2>>"$LOG" | sort -z); then
    status_files=("${PIPESTATUS[@]}")
    ((FAILED++))
    warn "Échec de la recherche de fichiers médias dans ${REL_DIR:-.} (PIPESTATUS=${status_files[*]})"
    continue
  fi
  status_files=("${PIPESTATUS[@]}")
  log "Fichiers médias détectés dans ${REL_DIR:-.}: ${#FILES[@]} (PIPESTATUS=${status_files[*]})"

  if (( ${#FILES[@]} == 0 )); then
    ((SKIP_EMPTY++))
    log "Aucun média exploitable dans ${REL_DIR:-.}, on passe."
    continue
  fi

  for F in "${FILES[@]}"; do
    REL="${F#$SRC/}"
    [[ "$REL" == "$F" ]] && REL="${F##*/}"

    H=$(md5sum "$F" | awk '{print $1}')
    DF="${F}.done_${H}"
    if [[ -f "$DF" ]]; then
      ((SKIP_DONE++))
      log "Skip (déjà traité): $REL (marqueur $(basename "$DF"))"
      continue
    fi

    HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$F" || echo 0)
    HEIGHT="${HEIGHT//$'\r'/}"
    HEIGHT="${HEIGHT//[^0-9]/}"
    [[ -z "$HEIGHT" ]] && HEIGHT=0

    if [[ $HEIGHT -ge 1080 ]]; then
      CRF="$CRF_1080"
    elif [[ $HEIGHT -ge 720 ]]; then
      CRF="$CRF_720"
    else
      CRF="$CRF_SD"
    fi

    REL_PARENT="$(dirname "$REL")"
    BASENAME="$(basename "${F%.*}")"
    OUT_DIR="$DST/$REL_PARENT"
    OUT="$OUT_DIR/${BASENAME}_arch_h265.mkv"
    mkdir -p "$OUT_DIR"

    log "Transcoding: $REL -> ${OUT#$DST/} (hauteur=${HEIGHT}p, x265 CRF=${CRF}, preset=${PRESET}, threads=$THREAD_LABEL)"

    if [[ -e "$OUT" ]]; then
      warn "Le fichier de sortie existe déjà, suppression avant nouveau transcodage: ${OUT#$DST/}"
      rm -f "$OUT"
    fi

    FFMPEG_CMD=(
      ffmpeg -hide_banner -loglevel error -nostdin -y
      "${THREAD_ARGS[@]}"
      -i "$F"
      "${MAPARGS[@]}" -map_chapters 0
      -vf "$VFILT"
      -c:v libx265 -preset "$PRESET" -crf "$CRF" -x265-params "$X265_PARAMS"
      -c:a copy -c:s copy "$OUT"
    )

    log "Commande FFmpeg: $(printf '%q ' "${FFMPEG_CMD[@]}")"

    if ! "${FFMPEG_CMD[@]}" >> "$LOG" 2>&1; then
      ((FAILED++))
      warn "Échec du transcodage: $REL (voir détails FFmpeg ci-dessus)"
      [[ -f "$OUT" ]] && rm -f "$OUT"
      continue
    fi

    touch "$DF"
    ((TRANSCODED++))
    log "Succès: $REL (marqueur $(basename "$DF"))"
  done

  dir_duration=$(( SECONDS - dir_start ))
  log "Inspection terminée pour ${REL_DIR:-.} (durée=${dir_duration}s)"

done

log "Résumé: transcodés=$TRANSCODED, échecs=$FAILED, déjà marqués=$SKIP_DONE, riplock=$SKIP_LOCKED, sans média=$SKIP_EMPTY"
log "=== Offline transcode (ARCHIVE) terminé ==="
