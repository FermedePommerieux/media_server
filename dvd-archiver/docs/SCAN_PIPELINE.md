# Phase 2 – Scan MKV + IA

La phase 2 traite uniquement les fichiers MKV produits par la phase 1. Les métadonnées techniques (`mkv/*.mkv` + `tech/fingerprint.json`) sont analysées pour produire `meta/metadata_ia.json` à l'aide d'heuristiques et d'un LLM (Qwen2.5-14B-Instruct Q4 via Ollama par défaut).

## Flux global

```text
[scan_enqueue.sh] -> file d'attente (${SCAN_QUEUE_DIR}) -> [scan_consumer.sh] -> scanner.py -> meta/metadata_ia.json
```

1. **Enqueue** : `scan_enqueue.sh` vérifie la présence d'au moins un MKV et ajoute un job idempotent (ignore si `meta/metadata_ia.json` existe déjà).
2. **Consumer** : `scan_consumer.sh` dépile les jobs, lance `scanner.py` et redirige les logs vers `${SCAN_LOG_DIR}` et le journal systemd.
3. **Scanner** : `scanner.py` collecte les métadonnées MKV (`mkvmerge -J`, fallback `mediainfo`), applique des heuristiques (durées, langues) puis interroge le LLM pour nommer le contenu, typer (film/série/compilation) et mapper chaque fichier à un élément logique.
4. **Écriture** : `writers.write_metadata_json` consolide la sortie IA, les heuristiques et les sources (versions outils, prompts, réponse brute) dans `meta/metadata_ia.json`.

## Dépendances

- **Python ≥ 3.10** (bibliothèque standard + `requests`).
- **Binaires** : `mkvmerge` (obligatoire), `mediainfo` (fallback optionnel), `curl` (pour récupérer Ollama).
- **LLM** : Ollama avec le modèle `qwen2.5:14b-instruct-q4_K_M` (configurable via `/etc/dvdarchiver.conf`).

## Installation rapide

```bash
cd dvd-archiver
chmod +x install.sh
sudo ./install.sh
```

Le script :

- vérifie les dépendances principales,
- installe Ollama si nécessaire puis tente `ollama pull qwen2.5:14b-instruct-q4_K_M`,
- copie les scripts dans `/usr/local/bin/` (`scan_enqueue.sh`, `scan_consumer.sh`, `scan/scanner.py`, ...),
- crée `${DEST}`, `${SCAN_QUEUE_DIR}`, `${SCAN_LOG_DIR}` selon la configuration (valeurs par défaut si non définies),
- installe `/etc/dvdarchiver.conf` si absent et active `dvdarchiver-scan-consumer.path`.

## Configuration

Les scripts sourcent `/etc/dvdarchiver.conf` (format `VAR=VALUE`). Extraits utiles :

```bash
DEST="/mnt/media_master"
SCAN_QUEUE_DIR="/var/spool/dvdarchiver-scan"
SCAN_LOG_DIR="/var/log/dvdarchiver-scan"
MKVMERGE_BIN="mkvmerge"
MEDIAINFO_BIN="mediainfo"
LLM_PROVIDER="ollama"
LLM_MODEL="qwen2.5:14b-instruct-q4_K_M"
LLM_ENDPOINT="http://127.0.0.1:11434"
LLM_ENABLE=1
```

Les valeurs peuvent être surchargées via l'environnement au moment de l'exécution.

## Test rapide

```bash
scan_enqueue.sh "${DEST}/<DISC_UID>"
journalctl -u dvdarchiver-scan-consumer.service -f
cat "${DEST}/<DISC_UID>/meta/metadata_ia.json"
```

Le job n'est créé que si des MKV sont présents et si `meta/metadata_ia.json` est absent. Les journaux détaillent l'analyse (heuristiques, prompt IA, éventuelles erreurs).

## Dépannage

- **`mkvmerge` manquant** : l'installation échouera, installez `mkvtoolnix` puis relancez.
- **IA indisponible** : `scanner.py` tente l'appel LLM et, en cas d'échec, produit malgré tout un JSON heuristique minimal (labels génériques, confiance basse).
- **`metadata_ia.json` déjà présent** : l'outil reste idempotent et ne relance pas l'analyse.
- **Absence de MKV** : `scan_enqueue.sh` et `scanner.py` arrêtent le traitement en signalant l'absence d'entrées valides.

