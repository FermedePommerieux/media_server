# Phase 2 – Pipeline Scan & IA

La phase 2 complète le rip en analysant les archives DVD existantes pour produire `meta/metadata_ia.json`.

## Prérequis

Installer les dépendances suivantes (best-effort) :

```bash
apt install tesseract-ocr ffmpeg mkvtoolnix lsdvd curl python3-venv
```

Le script `install.sh` vérifie également la présence d’Ollama et récupère le modèle `qwen2.5:14b-instruct-q4_K_M`.

## Configuration

Le fichier `/etc/dvdarchiver.conf` doit inclure la section « Phase 2 » :

```bash
# --- Phase 2: Scan & OCR ---
SCAN_QUEUE_DIR="/var/spool/dvdarchiver-scan"
SCAN_LOG_DIR="/var/log/dvdarchiver-scan"
SCAN_TRIGGER_GLOB="${DEST:-/mnt/media_master}/*/mkv/title*.mkv"
FFMPEG_BIN="ffmpeg"
TESSERACT_BIN="tesseract"
MENU_FRAME_FPS=1
MENU_MAX_FRAMES=30
MENU_SCENE_MODE=1
MENU_SCENE_THRESHOLD=0.4
MENU_PREPROC_FILTERS="yadif,eq=contrast=1.1:brightness=0.02"
LLM_PROVIDER="ollama"
LLM_MODEL="qwen2.5:14b-instruct-q4_K_M"
LLM_ENDPOINT="http://127.0.0.1:11434"
```

Chaque script source ce fichier et les variables peuvent être surchargées via l’environnement.

## File d’attente

* `scan_enqueue.sh <DISC_DIR>` ajoute un job `SCAN_*.job` dans `${SCAN_QUEUE_DIR}`
  * Idempotent (un seul job par disque).
  * Ignore les disques déjà scannés (`meta/metadata_ia.json`).
* `scan_consumer.sh` tourne en boucle :
  * détecte les dossiers prêts via `SCAN_TRIGGER_GLOB` et appelle `scan_enqueue.sh`.
  * consomme la file, lance `scanner.py` et journalise dans `${SCAN_LOG_DIR}`.

## Orchestrateur Python

`bin/scan/scanner.py` pilote les étapes :

1. Lecture de la structure `lsdvd` puis enrichissement avec `mkvmerge -J` (ou fallback `ffprobe`).
2. Recherche des menus décryptés dans `raw/VIDEO_TS_BACKUP/VIDEO_TS/` puis extraction de frames via `ffmpeg` (mode scène ou FPS fixe).
3. OCR Tesseract (sortie TSV) et normalisation multilingue des libellés (Lecture/Play, Chapitres/Chapters, Bonus...).
4. Heuristiques locales : estimation du contenu (film/série), titre principal et premier mapping.
5. Appel LLM via `ai_providers` (Ollama par défaut, JSON strict). Si `LLM_ENABLE=0` ou en cas d'erreur, fallback heuristique.
6. Écriture idempotente de `meta/metadata_ia.json` avec les sources, outils utilisés et réponses brutes du LLM.

Les logs détaillent les étapes et durées. En cas d’échec OCR/IA, un JSON minimal reste généré.

## Sortie `metadata_ia.json`

```json
{
  "disc_uid": "dvd_xxxxx",
  "layout_version": "1.0",
  "menus": {
    "normalized": {"play": ["Lecture"], ...},
    "items": [{"vob": "VIDEO_TS.VOB", "text": "Lecture"}],
    "language": "fr"
  },
  "mkv": {
    "titles": [
      {"index": 1, "filename": "title00.mkv", "runtime_s": 5400, "audio_langs": ["fra"], ...}
    ]
  },
  "analysis": {
    "movie_title": "Le Film",
    "content_type": "film",
    "language": "fr",
    "menu_labels": ["Play", "Chapitres"],
    "mapping": {"title00.mkv": "Main Feature"},
    "confidence": 0.82
  },
  "sources": {
    "menus_vob_dir": ".../raw/VIDEO_TS_BACKUP/VIDEO_TS",
    "frames_dir": ".../meta/menu_frames",
    "llm": {"provider": "ollama", "model": "qwen2.5:14b-instruct-q4_K_M", "used": true},
    "tools": {"ffmpeg": "ffmpeg", "tesseract": "tesseract"}
  },
  "raw_llm_responses": ["{...}"]
}
```

## Dépannage

* **Pas de VOB dans `raw/VIDEO_TS_BACKUP/VIDEO_TS`** : l’OCR est ignoré, la structure provient des fichiers MKV si le fallback est activé.
* **LLM désactivé (`LLM_ENABLE=0`)** : la sortie provient des heuristiques locales.
* **Absence de PyYAML/pytesseract** : le module bascule sur des parseurs / OCR CLI best-effort.

## Lancement systemd

Voir `systemd/README-systemd-scan.md` pour l’activation du `path` et du service consumer.
