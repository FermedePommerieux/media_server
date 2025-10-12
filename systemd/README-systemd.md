# Intégration systemd

Ce répertoire fournit les unités nécessaires pour consommer la file d'attente DVD Archiver à l'aide de systemd.

## Installation

```bash
sudo cp systemd/dvdarchiver-queue-consumer.service /etc/systemd/system/
sudo cp systemd/dvdarchiver-queue-consumer.path /etc/systemd/system/
sudo cp systemd/dvdarchiver-queue-consumer.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dvdarchiver-queue-consumer.path
# Optionnel : activer le timer de secours
sudo systemctl enable --now dvdarchiver-queue-consumer.timer
```

La cible `.path` déclenche automatiquement le service lorsqu'un nouveau job est détecté dans `QUEUE_DIR`. Le timer fournit un filet de sécurité en cas d'événement udev manqué.

## Journaux

Les scripts journalisent à la fois dans le journal systemd et dans les fichiers situés sous `${LOG_DIR}` (défini dans `/etc/dvdarchiver.conf`).
