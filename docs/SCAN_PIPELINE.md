# Phase 2 – Pipeline Scan & IA

La phase 2 complète le rip en analysant les archives DVD existantes pour produire `meta/metadata_ia.json`.

## Prérequis

Installer les dépendances suivantes (best-effort) :

```bash
apt install tesseract-ocr ffmpeg mkvtoolnix lsdvd python3-venv
```

## Configuration

Le fichier `/etc/dvdarchiver.conf` doit inclure la section « Phase 2 » :

```bash
# --- Phase 2: Scan & OCR ---
SCAN_QUEUE_DIR="/var/spool/dvdarchiver-scan"
SCAN_LOG_DIR="/var/log/dvdarchiver-scan"
SCAN_TRIGGER_GLOB="${DEST:-/mnt/media_master}/*/mkv/title*.mkv"
# ... voir etc/dvdarchiver.conf.sample pour la liste complète
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

1. Lecture de la structure (`tech/structure.lsdvd.yml` ou fallback `mkvmerge -J`).
2. Extraction d’images de menus (`ffmpeg` sur `raw/*.VOB`).
3. OCR (`pytesseract` ou CLI Tesseract) puis normalisation des libellés.
4. Heuristiques : détection du main feature, bonus, épisodes.
5. Appel IA via `ai_providers` (OpenAI, Ollama ou mock). Si `LLM_ENABLE=0`, heuristique seule.
6. Écriture de `meta/metadata_ia.json` via `writers.py` (idempotent).

Les logs détaillent les étapes et durées. En cas d’échec OCR/IA, un JSON minimal reste généré.

## Sortie `metadata_ia.json`

```json
{
  "disc_uid": "dvd_xxxxx",
  "layout_version": "1.0",
  "structure": {...},
  "menus": {...},
  "inferred": {
    "movie_title": "...",
    "content_type": "film|serie|autre",
    "language": "fr|en|...|unknown",
    "confidence": 0.0-1.0,
    "source": "ia|heuristics",
    "menu_labels": [...],
    "mapping": {...}
  }
}
```

## Dépannage

* **Pas de VOB dans `raw/`** : l’OCR est ignoré, la structure provient des fichiers MKV si le fallback est activé.
* **LLM désactivé (`LLM_ENABLE=0`)** : la sortie provient des heuristiques locales.
* **Absence de PyYAML/pytesseract** : le module bascule sur des parseurs / OCR CLI best-effort.

## Lancement systemd

Voir `systemd/README-systemd-scan.md` pour l’activation du `path` et du service consumer.
