# Pipeline « Backup → OCR+IA → MKV »

## Phase 1 – Backup complet décrypté

- Script : `bin/do_backup.sh`.
- Actions principales :
  - Vérification des dépendances (`makemkvcon`, `lsdvd`, `sha256sum`, `df`).
  - Lecture unique du DVD via `makemkvcon -r backup --decrypt disc:0 <DEST>/<DISC_UID>/raw/VIDEO_TS_BACKUP/`.
  - Calcul d'un `DISC_UID` (hash SHA-256 combinant sortie `makemkvcon info` et titre disque) et écriture de `tech/fingerprint.json`.
  - Dump technique avec `lsdvd -Oy` → `tech/structure.lsdvd.yml` (fallback mkvmerge en Phase 2 si vide).
  - Enqueue automatique de la Phase 2 (`scan_enqueue.sh`).

Le script est idempotent : si des `.VOB` sont déjà présents dans `raw/VIDEO_TS_BACKUP/VIDEO_TS/`, aucune nouvelle lecture du DVD n'est lancée.

## Phase 2 – OCR menus + IA obligatoire

- Enqueue : `scan_enqueue.sh` ajoute un fichier `SCAN_<ts>_<rand>.job` dans `SCAN_QUEUE_DIR` sauf si `meta/metadata_ia.json` existe déjà.
- Consommation : `scan_consumer.sh` appelle `python3 /usr/local/bin/scan/scanner.py` et journalise le résultat. En cas de succès, la Phase 3 est automatiquement enfilée.
- `scanner.py` réalise :
  1. Validation de la présence du backup (`raw/VIDEO_TS_BACKUP/VIDEO_TS/`) et de `tech/`.
  2. Extraction des frames de menus via ffmpeg (`fps` fixe ou détection de scènes selon `MENU_SCENE_MODE`, filtres `MENU_PREPROC_FILTERS`).
  3. OCR Tesseract multilingue + normalisation des libellés (`ocr.py`).
  4. Lecture de la structure technique (`techparse.parse_lsdvd` puis fallback `techparse.probe_backup_titles` avec `mkvmerge -J`).
  5. Heuristiques (`heuristics.py`) : détection du contenu principal, mapping par défaut, fusion avec les suggestions IA.
  6. Appel du LLM (`ai_analyzer.py` → Ollama/Qwen2.5-14B par défaut) avec prompt francophone imposant le schéma JSON final.
  7. Validation stricte dans `scanner.py` (content_type, titres, mapping, épisodes film/série, confiance) avant écriture.
  8. `writers.py` écrit `meta/metadata_ia.json` si et seulement si la validation passe.

Schéma JSON requis :

```json
{
  "disc_uid": "string",
  "content_type": "film|serie|autre",
  "movie_title": "string|null",
  "series_title": "string|null",
  "year": 2000,
  "language": "fr|en|...|unknown",
  "items": [
    {
      "type": "main|episode|bonus|trailer",
      "title_index": 1,
      "label": "Main Feature|Episode 1|Bonus ...",
      "season": 1,
      "episode": 1,
      "episode_title": "string|null",
      "runtime_seconds": 7122,
      "audio_langs": ["fra", "eng"],
      "sub_langs": ["fra", "eng"]
    }
  ],
  "mapping": {
    "title_1": "Main Feature"
  },
  "confidence": 0.0,
  "sources": {
    "ocr": "tech/menu_frames/",
    "tech_dump": "tech/structure.lsdvd.yml",
    "llm": {"provider": "ollama", "model": "qwen2.5:14b-instruct-q4_K_M"}
  }
}
```

Règles de complétude dans `scanner.py` :

- Chaque `items[].title_index` doit correspondre à un titre connu.
- `content_type` ∈ {film, serie, autre}.
- `film` : `movie_title` non vide ou `confidence ≥ 0,7`.
- `serie` : `series_title` non vide ET chaque épisode possède `season` + `episode` définis + mapping couvrant tous les épisodes.
- `mapping` doit couvrir au minimum le contenu principal et tous les épisodes.
- `confidence` ∈ [0,1].
- Échec → pas de fichier écrit, code de retour ≠ 0 (job `.err`).

## Phase 3 – Build MKV (gated)

- Enqueue : `mkv_build_enqueue.sh` ajoute `BUILD_<ts>_<rand>.job` uniquement si `meta/metadata_ia.json` existe.
- Consommation : `mkv_build_consumer.sh` charge le job, valide à nouveau `metadata_ia.json` (relecture de la structure, appel `scanner.validate_metadata`), calcule le plan de nommage et exécute `makemkvcon mkv` pour chaque titre.

Commande MakeMKV utilisée :

```bash
makemkvcon -r --progress=-stdout mkv "file:$DEST/<DISC_UID>/$RAW_BACKUP_DIR" title:<index> "$DEST/<DISC_UID>/mkv" ${MAKEMKV_MKV_OPTS}
```

Après création, le fichier généré (`title_tXX.mkv`) est renommé selon les templates (`OUTPUT_NAMING_TEMPLATE_*`). Les sorties existantes (>0 octet) sont ignorées pour garantir l'idempotence. Si `WRITE_NFO=1`, un `.nfo` minimal est créé (film ou `episodedetails`).

La fin du script affiche un récapitulatif (nombre de fichiers générés/ignorés).

## Reprise sur erreur

- Toute erreur IA ou manque de complétude laisse un job `.err` en Phase 2 ; corrigez la configuration ou relancez `scan_consumer.sh`.
- Phase 3 vérifie à nouveau la métadonnée : si la validation échoue ou si MakeMKV retourne une erreur, le job est déplacé en `.err` et les logs restent dans `BUILD_LOG_DIR`.

## Journaux & supervision

- Phase 2 : `/var/log/dvdarchiver-scan/scan-<disc>-<ts>.log` + `journalctl -u dvdarchiver-scan-consumer.service`.
- Phase 3 : `/var/log/dvdarchiver-build/build-<disc>-<ts>.log` + `journalctl -u dvdarchiver-mkv-build-consumer.service`.
- Unités `.path` (`systemd/`) surveillent l'apparition de `VIDEO_TS.VOB` et `metadata_ia.json` pour déclencher les enqueue automatiques.

## Check-list déploiement

1. Copier `etc/dvdarchiver.conf.sample` vers `/etc/dvdarchiver.conf` et ajuster les chemins/devices.
2. Installer les dépendances systèmes (`makemkvcon`, `lsdvd`, `ffmpeg`, `tesseract`, `mkvmerge`, `ollama`).
3. Lancer `install.sh` ou `make install`.
4. Vérifier que `ollama` est opérationnel (`ollama serve`, `ollama pull qwen2.5:14b-instruct-q4_K_M`).
5. Suivre les services avec `journalctl -u dvdarchiver-*-consumer.service -f`.

Une fois ces étapes effectuées, insérer un DVD déclenchera l'ensemble du pipeline sans relecture physique inutile.
