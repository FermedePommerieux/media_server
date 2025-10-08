#/usr/local/bin/offline_transcode.sh 
#!/bin/bash
# offline_transcode.sh — profil Archivage (x265), respecte .riplock par répertoire
set -euo pipefail

SRC="/mnt/media_master"    # rips/matériels bruts
DST="/mnt/nas_media"       # sorties pour Jellyfin
LOG="/var/log/offline_transcode.log"
LOCK="/tmp/offline_transcode.lock"

THREADS=${THREADS:-2}
PRESET=${PRESET:-medium}
CRF_SD=${CRF_SD:-18}       # <=576p
CRF_720=${CRF_720:-21}
CRF_1080=${CRF_1080:-22}
X265_PARAMS=${X265_PARAMS:-"aq-mode=3:aq-strength=1.0:psy-rd=2.0:psy-rdoq=1.0:deblock=-1:-1:rd=4"}
MAPARGS=( -map 0 )
VFILT="bwdif=mode=send_field:parity=auto:deint=all"

exec 9>"$LOCK"; flock -n 9 || { echo "Already running" >> "$LOG"; exit 0; }
echo "=== $(date): Offline transcode (ARCHIVE) started ===" >> "$LOG"

shopt -s nullglob
# Parcours par répertoire : on traite les fichiers d'un répertoire s'il n'est pas locké,
# puis on fait pareil pour chaque sous-répertoire.
mapfile -d '' -t DIRS < <(find "$SRC" -type d -print0 | sort -z)

for DIR in "${DIRS[@]}"; do
  REL_DIR="${DIR#$SRC/}"

  # si le répertoire courant est locké, on saute ses fichiers
  if [[ -f "$DIR/.riplock" ]]; then
    echo "Skip dir (rip lock): ${REL_DIR:-.}" >> "$LOG"
    continue
  fi

  # fichiers vidéo directement dans ce répertoire (maxdepth=1)
  FILES=()
  mapfile -d '' -t FILES < <(find "$DIR" -maxdepth 1 -type f \
    \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.vob" -o -iname "*.m2ts" \) -print0 | sort -z)
  ((${#FILES[@]}==0)) && continue

  for F in "${FILES[@]}"; do
    REL="${F#$SRC/}"

    # anti-redondance par hash du fichier source
    H=$(md5sum "$F" | awk '{print $1}')
    DF="${F}.done_${H}"
    [[ -f "$DF" ]] && continue

    # détecte la résolution
    HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$F" || echo 0)
    HEIGHT=${HEIGHT:-0}
    if [[ $HEIGHT -ge 1080 ]]; then
      CRF="$CRF_1080"
    elif [[ $HEIGHT -ge 720 ]]; then
      CRF="$CRF_720"
    else
      CRF="$CRF_SD"
    fi

    # réplique l'arborescence SRC -> DST
    REL_PARENT="$(dirname "$REL")"
    BASENAME="$(basename "${F%.*}")"
    OUT_DIR="$DST/$REL_PARENT"
    OUT="$OUT_DIR/${BASENAME}_arch_h265.mkv"
    mkdir -p "$OUT_DIR"

    echo "Transcoding: $REL -> ${OUT#$DST/} (h=${HEIGHT}, x265 CRF=${CRF}, preset=${PRESET})" >> "$LOG"

    if ! ffmpeg -hide_banner -loglevel error -threads "$THREADS" -i "$F" \
        "${MAPARGS[@]}" -map_chapters 0 \
        -vf "$VFILT" \
        -c:v libx265 -preset "$PRESET" -crf "$CRF" -x265-params "$X265_PARAMS" \
        -c:a copy -c:s copy "$OUT" >> "$LOG" 2>&1; then
      echo "Fail: $REL" >> "$LOG"
      [ -f "$OUT" ] && rm -f "$OUT"
      continue
    fi

    touch "$DF"
  done
done

echo "=== $(date): Offline transcode (ARCHIVE) finished ===" >> "$LOG"
