# DVD Archiver

Pipeline complet « Backup → OCR/IA → MKV » pour archiver des DVD vidéo en trois phases idempotentes.

## Vue d'ensemble

1. **Backup décrypté (Phase 1)** : `bin/do_backup.sh` lance `makemkvcon backup --decrypt` pour créer une copie complète du DVD (menus inclus) dans `raw/VIDEO_TS_BACKUP/`. La commande calcule un `disc_uid`, écrit `tech/fingerprint.json` ainsi que `tech/structure.lsdvd.yml`, puis enfile automatiquement la Phase 2.
2. **Analyse menus + IA (Phase 2)** : `scan_consumer.sh` consomme les jobs de scan, extrait les menus `.VOB` via ffmpeg, exécute Tesseract, agrège les heuristiques et interroge un LLM local (Qwen2.5-14B via Ollama par défaut) pour produire `meta/metadata_ia.json` conforme au schéma imposé.
3. **Build MKV (Phase 3)** : `mkv_build_consumer.sh` ne traite que les disques dont la métadonnée a été validée. Pour chaque titre, il appelle `makemkvcon mkv file:... title:X`, renomme les fichiers selon les templates, écrit optionnellement des sidecars `.nfo` et affiche un récapitulatif.

Les scripts s'appuient sur `/etc/dvdarchiver.conf` (copié depuis `etc/dvdarchiver.conf.sample`) pour éviter tout chemin en dur. Toutes les étapes sont relançables sans effets de bord.

## Gating métadonnées

- La validation repose sur `bin/scan/validator.py` (Pydantic ≥ 2) qui applique des règles conditionnelles : un film doit exposer un item `main` et un mapping associé, une série doit fournir un `series_title` non vide et couvrir tous les épisodes avec leurs saisons/numéros, tandis que la catégorie `autre` exige soit un `main`, soit au minimum deux bonus/bandes-annonces avec une confiance ≥ 0,5.
- `scanner.py` vérifie la réponse du LLM **avant** d'écrire `meta/metadata_ia.json`. En cas d'échec, aucun fichier n'est créé et le job passe en `.err`, ce qui permet une relance après correction.
- `mkv_build_consumer.sh` recharge et revalide systématiquement `metadata_ia.json`. Si le JSON devient invalide (édition manuelle, corruption…), la Phase 3 s'arrête immédiatement, ne lance pas MakeMKV et renvoie le job en `.err`.
- Les noms finaux (`OUTPUT_NAMING_TEMPLATE_*`) et l'éventuelle génération `.nfo` ne sont déclenchés que lorsque les métadonnées respectent le schéma.

## Pourquoi cette séquence ?

- **Une seule lecture du DVD** : la Phase 1 réalise un backup complet et décrypté ; les phases suivantes travaillent exclusivement sur cette copie locale.
- **OCR fiable sur les menus** : les menus `.VOB` sont nécessaires pour identifier les épisodes, bonus ou bandes-annonces. La Phase 2 extrait des frames prétraitées, détecte la langue, normalise les libellés et envoie les informations techniques + OCR au LLM.
- **Gating strict avant les MKV** : aucun fichier `.mkv` n'est généré tant que `meta/metadata_ia.json` n'est pas conforme (schéma, complétude film/série, mapping des titres). Un échec de validation laisse le job en `.err` afin de corriger puis relancer.

## Installation rapide

```bash
sudo make install            # ou sudo ./install.sh
```

Le script d'installation :

- vérifie la présence des dépendances (`makemkvcon`, `lsdvd`, `ffmpeg`, `tesseract`, `mkvmerge`, `python3`, `curl`...),
- installe Ollama si nécessaire puis tente `ollama pull qwen2.5:14b-instruct-q4_K_M`,
- copie les scripts shell dans `/usr/local/bin/`, les modules Python dans `/usr/local/bin/scan/`,
- crée `/etc/dvdarchiver.conf` si absent et prépare les répertoires (`DEST`, queues, logs),
- installe les unités systemd (`dvdarchiver-scan-consumer.*`, `dvdarchiver-mkv-build-consumer.*`) puis active les `.path`.

## Test manuel

```bash
sudo /usr/local/bin/do_backup.sh         # Phase 1 sur le DVD présent dans le lecteur
journalctl -u dvdarchiver-scan-consumer.service -f
journalctl -u dvdarchiver-mkv-build-consumer.service -f
```

Le premier journal affiche la progression OCR/IA, le second la création des MKV dès que `metadata_ia.json` est valide.

## Structure générée

```
$DEST/<DISC_UID>/
├── raw/VIDEO_TS_BACKUP/VIDEO_TS/*.VOB
├── tech/
│   ├── fingerprint.json
│   └── structure.lsdvd.yml
├── meta/
│   ├── metadata_ia.json
│   └── menu_frames/*.png
└── mkv/
    ├── <Nom propre>.mkv
    └── <Nom propre>.nfo (optionnel)
```

`metadata_ia.json` contient :

- `disc_uid`, `content_type`, titres film/série, année, langue,
- la liste `items[]` (type main/episode/bonus, `title_index`, durée, langues audio/sous-titres, saison/épisode le cas échéant),
- `mapping` (`title_X` → libellé humain),
- `confidence` (0–1) et `sources` (OCR, dump technique, fournisseur LLM).

## Dépendances essentielles

- **Phase 1** : `makemkvcon`, `lsdvd`, `eject`, `sha256sum`.
- **Phase 2** : `ffmpeg`, `tesseract-ocr`, `python3`, `requests` (pour Ollama), modèle LLM via Ollama.
- **Phase 3** : `makemkvcon`, `mkvmerge` (fallback technique), `python3`.

Tous ces binaires doivent être accessibles par l'utilisateur système exécutant les services.

## Idempotence & reprise

- `do_backup.sh` s'arrête si un backup existe déjà (présence de `.VOB` dans `raw/VIDEO_TS_BACKUP/VIDEO_TS/`).
- `scan_enqueue.sh` ne crée pas de job si `meta/metadata_ia.json` est déjà présent.
- `mkv_build_enqueue.sh` refuse d'ajouter un job tant que la métadonnée manque.
- Les consommateurs déplacent chaque job en `.done` ou `.err` et conservent un log détaillé.

## Configuration clé

Voir `etc/dvdarchiver.conf.sample` pour la liste complète :

- `MENU_SCENE_MODE`, `MENU_PREPROC_FILTERS` pour contrôler l'extraction de frames.
- `LLM_*` pour sélectionner le fournisseur et le modèle (Ollama par défaut).
- `OUTPUT_NAMING_TEMPLATE_*` pour personnaliser le nom des MKV.
- `WRITE_NFO=1` pour générer des sidecars Jellyfin/Kodi.

## Dépannage

- Vérifiez les logs dans `/var/log/dvdarchiver-scan/` et `/var/log/dvdarchiver-build/`.
- Utilisez `journalctl -u dvdarchiver-*-consumer.service` pour suivre les services.
- En cas d'échec IA, la Phase 2 laisse un `.err` ; corrigez la configuration ou relancez une fois le LLM disponible (`scan_consumer.sh` est idempotent).
- Assurez-vous que le service Ollama est démarré (`systemctl status ollama`).

Bonne sauvegarde !
