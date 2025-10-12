# Phase 2 – Scan + OCR + IA

Cette phase analyse les disques déjà rippés pour produire `meta/metadata_ia.json` en combinant informations techniques, OCR des menus et raisonnement IA (LLM par défaut via Ollama / Qwen2.5-14B-Instruct Q4).

## Flux global

```text
[scan_enqueue.sh] -> file d'attente (${SCAN_QUEUE_DIR}) -> [scan_consumer.sh] -> scanner.py -> meta/metadata_ia.json
```

1. **Enqueue** : `scan_enqueue.sh` ajoute un job par disque à scanner (idempotent, ignorer si `meta/metadata_ia.json` existe).
2. **Consumer** : `scan_consumer.sh` lit la file, appelle `scanner.py` et journalise dans `${SCAN_LOG_DIR}`.
3. **Scanner** : `scanner.py` orchestre parsing technique (`techparse`), extraction/ocr des menus, heuristiques et appel IA (`ai_analyzer`).
4. **Écriture** : `writers.write_metadata_json` consolide les données, y compris la provenance (LLM utilisé, temps de traitement, etc.).

## Dépendances

- Python ≥ 3.10 (modules `requests`, `pytesseract`, `Pillow`, `PyYAML`).
- Binaires : `tesseract-ocr`, `ffmpeg`, `ffprobe`, `lsdvd`, `mkvmerge`.
- Ollama (service `ollama.service`) pour tirer/servir `qwen2.5:14b-instruct-q4_K_M` (configurable).

## Installation rapide

```bash
cd dvd-archiver
chmod +x install.sh
sudo ./install.sh
```

Le script :

- vérifie les dépendances,
- installe Ollama si besoin puis `ollama pull qwen2.5:14b-instruct-q4_K_M`,
- copie les scripts dans `/usr/local/bin/` (`scan_enqueue.sh`, `scan_consumer.sh`, `scan/scanner.py`, ...),
- crée les répertoires `${DEST}`, `${SCAN_QUEUE_DIR}`, `${SCAN_LOG_DIR}` avec valeurs par défaut (`DEST=/mnt/media_master`),
- installe `/etc/dvdarchiver.conf` si absent et active `dvdarchiver-scan-consumer.path`.

## Configuration

Toutes les valeurs sont lues dans `/etc/dvdarchiver.conf` (copie de `etc/dvdarchiver.conf.sample`). Extraits importants :

```bash
DEST="/mnt/media_master"
SCAN_QUEUE_DIR="/var/spool/dvdarchiver-scan"
SCAN_LOG_DIR="/var/log/dvdarchiver-scan"
LLM_PROVIDER="ollama"
LLM_MODEL="qwen2.5:14b-instruct-q4_K_M"
LLM_ENDPOINT="http://127.0.0.1:11434"
LLM_ENABLE=1
```

Surcharger via variables d'environnement au besoin (`LLM_PROVIDER`, `LLM_MODEL`, `LLM_ENDPOINT`, `LLM_API_KEY`, etc.). Mettre `LLM_ENABLE=0` pour désactiver l'IA et n'utiliser que les heuristiques.

## Test rapide

```bash
scan_enqueue.sh "${DEST}/<DISC_UID>"
journalctl -u dvdarchiver-scan-consumer.service -f
cat "${DEST}/<DISC_UID>/meta/metadata_ia.json"
```

Le premier appel place un job (si aucun `metadata_ia.json`). `journalctl` permet de suivre l'exécution, puis vérifier le fichier généré.

## Dépannage

- **Pas de menus VOB (`raw/`)** : le scanner basculera sur `STRUCT_FALLBACK_FROM_MKV=1` et utilisera `mkvmerge -J` pour récupérer les durées.
- **LLM indisponible** : si Ollama ou le modèle ne répond pas, l'analyse retombe sur `heuristics.fallback_payload` avec un marquage `source="heuristics"`.
- **Tesseract absent** : `install.sh` avertit et l'OCR retournera un texte vide, mais le pipeline continue avec heuristiques/IA.
- **File saturée** : `scan_consumer.sh` garde une trace `.done`/`.err` pour chaque job et envoie la sortie dans `${SCAN_LOG_DIR}` + journal systemd.

