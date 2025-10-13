# Unités systemd – DVD Archiver

Deux couples `.path`/`.service` automatisent les phases 2 et 3 du pipeline.

## Phase 2 – Scan + IA

- `dvdarchiver-scan-consumer.service` : exécute `scan_consumer.sh` qui dépile les jobs de `SCAN_QUEUE_DIR` et lance `scanner.py`.
- `dvdarchiver-scan-consumer.path` : surveille `${DEST}/*/raw/VIDEO_TS_BACKUP/VIDEO_TS/VIDEO_TS.VOB` et déclenche la phase 2 dès qu'un backup est disponible.

## Phase 3 – Build MKV

- `dvdarchiver-mkv-build-consumer.service` : exécute `mkv_build_consumer.sh` pour générer les `.mkv` (validation du JSON, appel MakeMKV, génération optionnelle des `.nfo`).
- `dvdarchiver-mkv-build-consumer.path` : surveille `${DEST}/*/meta/metadata_ia.json` et déclenche la phase 3 uniquement lorsque la métadonnée est présente.

## Installation

```bash
sudo cp dvdarchiver-*.service dvdarchiver-*.path /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dvdarchiver-scan-consumer.path
sudo systemctl enable --now dvdarchiver-mkv-build-consumer.path
```

Les services lisent `/etc/dvdarchiver.conf` pour connaître les dossiers de destination, files d'attente, modèles de nommage, etc.

## Supervision

- Suivre la Phase 2 : `journalctl -u dvdarchiver-scan-consumer.service -f`
- Suivre la Phase 3 : `journalctl -u dvdarchiver-mkv-build-consumer.service -f`

Les logs détaillés sont également disponibles dans `${SCAN_LOG_DIR}` et `${BUILD_LOG_DIR}`.

## Désactivation

Pour désactiver l'une des phases :

```bash
sudo systemctl disable --now dvdarchiver-scan-consumer.path
sudo systemctl disable --now dvdarchiver-mkv-build-consumer.path
```

Les services resteront inactifs jusqu'à réactivation.
