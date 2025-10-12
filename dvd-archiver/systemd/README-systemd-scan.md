# Unités systemd – Phase 2 (Scan MKV + IA)

Ces unités assurent la consommation de la file de scan et l'analyse IA des disques rippés.

## Fichiers

- `dvdarchiver-scan-consumer.service` : lance `scan_consumer.sh` qui dépile les jobs et appelle `scanner.py` (analyse MKV uniquement).
- `dvdarchiver-scan-consumer.path` : surveille le motif configuré (`SCAN_TRIGGER_GLOB`) et démarre le service dès qu'un MKV est présent.

Les deux unités attendent que la configuration `/etc/dvdarchiver.conf` fournisse les chemins (file, destination, modèle IA, etc.).

## Installation

Après copie dans `/etc/systemd/system/` (ou via `install.sh`), rechargez systemd puis activez le path :

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dvdarchiver-scan-consumer.path
```

Le `.path` déclenchera automatiquement le service quand un fichier correspondant à `SCAN_TRIGGER_GLOB` apparaît.

## Vérification & journaux

Pour vérifier l'état :

```bash
systemctl status dvdarchiver-scan-consumer.path
systemctl status dvdarchiver-scan-consumer.service
```

Suivre les journaux en direct :

```bash
journalctl -u dvdarchiver-scan-consumer.service -f
```

Les logs détaillés de chaque traitement sont également écrits dans `${SCAN_LOG_DIR}`.

## Désactivation

Pour désactiver temporairement la phase 2 :

```bash
sudo systemctl disable --now dvdarchiver-scan-consumer.path
sudo systemctl stop dvdarchiver-scan-consumer.service
```

Remettez `LLM_ENABLE=0` dans `/etc/dvdarchiver.conf` pour forcer un mode heuristique sans appels réseau.

