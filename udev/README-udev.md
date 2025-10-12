# Règle udev DVD Archiver

Cette règle déclenche l'enfilement automatique d'un job dès qu'un média est inséré dans le lecteur optique principal (`sr0`).

## Installation

```bash
sudo cp udev/99-dvdarchiver.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=block --attr-match=devtype=cd
```

Adaptez `KERNEL=="sr0"` si vous utilisez plusieurs lecteurs. Pour certaines distributions, il peut être nécessaire d'ajouter `ENV{ID_CDROM_MEDIA_DVD}=="1"` pour filtrer uniquement les DVD.

Assurez-vous que l'utilisateur exécutant les scripts possède les droits de lecture sur le périphérique et les points de montage temporaires.
