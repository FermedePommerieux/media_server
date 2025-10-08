# Media Server Automation

Ce dépôt regroupe les scripts et fichiers d'un poste dédié à l'extraction et à l'encodage de médias physiques (DVD) vers une bibliothèque numérique compatible, par exemple, avec Jellyfin. L'objectif est d'automatiser l'intégralité du flux : détection d'un disque, extraction via MakeMKV, puis transcodage hors-ligne en H.265.

## Aperçu des composants

| Chemin | Rôle |
| ------ | ---- |
| `bin/do_rip.sh` | Script principal d'extraction d'un DVD à l'aide de `makemkvcon`. Gère la journalisation, la prévention des doublons et la vérification de l'espace disque. |
| `bin/dvd-ripd.sh` | Démon de file d'attente. Traite les jobs en attente (déposés dans `/var/lib/dvdqueue`) et appelle `do_rip.sh`. |
| `bin/offline_transcode.sh` | Pipeline de transcodage H.265 destiné à la production de fichiers optimisés pour la lecture (ex. Jellyfin). |
| `etc/systemd/system/*.service` | Unit files systemd pour exécuter `dvd-ripd.sh` et `offline_transcode.sh`. |
| `etc/systemd/system/offline-transcode.timer` | Timer systemd déclenchant le transcodage quotidien à 02h00. |
| `etc/udev/rules.d/99-dvd-queue.rules` | Règle udev qui détecte l'insertion d'un DVD et déclenche la mise en file. |

## Dépendances principales

- **MakeMKV** (`makemkvcon`) pour l'extraction des flux DVD.
- **ffmpeg** (avec support `libx265`) et `ffprobe` pour le transcodage.
- Utilitaires GNU : `bash`, `find`, `md5sum`, `df`, `dd`, `ionice`, `nice`, `blkid`, `volname`, `eject` (optionnel mais recommandé).
- `systemd` (services & timers) et `udev` pour l'automatisation.

Les scripts supposent l'existence d'un utilisateur de service (par défaut `media`) disposant des droits sur les points de montage utilisés (`/mnt/media_master`, `/mnt/nas_media`).

## Flux opérationnel

1. **Insertion d'un DVD** : udev applique `99-dvd-queue.rules` et exécute `/usr/local/bin/queue_dvd.sh` (script à fournir : il doit créer un fichier `.job` dans `/var/lib/dvdqueue`).
2. **File d'attente** : `dvd-ripd.service` exécute `bin/dvd-ripd.sh` qui consomme les jobs à intervalle régulier et appelle `do_rip.sh`.
3. **Extraction** : `do_rip.sh` identifie le disque, assure l'idempotence via un hash disque et enregistre les journaux dans `/var/log/dvd_rip.log`.
4. **Transcodage hors-ligne** : `offline-transcode.timer` déclenche `offline_transcode.sh` chaque nuit. Le script convertit les sources en H.265 tout en conservant les pistes audio/sous-titres originales.

## Installation

1. **Scripts** :
   ```bash
   sudo install -Dm755 bin/do_rip.sh /usr/local/bin/do_rip.sh
   sudo install -Dm755 bin/dvd-ripd.sh /usr/local/bin/dvd-ripd.sh
   sudo install -Dm755 bin/offline_transcode.sh /usr/local/bin/offline_transcode.sh
   ```
   Ajustez les chemins (`DEVICE`, `DEST`, `SRC`, `DST`, etc.) selon votre environnement.

2. **Services systemd** :
   ```bash
   sudo install -Dm644 etc/systemd/system/dvd-ripd.service /etc/systemd/system/dvd-ripd.service
   sudo install -Dm644 etc/systemd/system/offline-transcode.service /etc/systemd/system/offline-transcode.service
   sudo install -Dm644 etc/systemd/system/offline-transcode.timer /etc/systemd/system/offline-transcode.timer

   sudo systemctl daemon-reload
   sudo systemctl enable --now dvd-ripd.service
   sudo systemctl enable --now offline-transcode.timer
   ```

3. **Règle udev** :
   ```bash
   sudo install -Dm644 etc/udev/rules.d/99-dvd-queue.rules /etc/udev/rules.d/99-dvd-queue.rules
   sudo udevadm control --reload-rules
   ```
   Fournissez un script `queue_dvd.sh` compatible pour créer un fichier job (ex. `touch "/var/lib/dvdqueue/$(date +%s).job"`).

4. **Points de montage & permissions** :
   - `do_rip.sh` écrit les rips dans `/mnt/media_master` par défaut.
   - `offline_transcode.sh` lit depuis `/mnt/media_master` et produit dans `/mnt/nas_media`.
   - Assurez-vous que l'utilisateur `media` possède les droits en lecture/écriture sur ces chemins ainsi que sur les répertoires de logs (`/var/log`).

## Journalisation et verrouillages

- Les scripts créent des fichiers `.riplock` pour éviter les exécutions concurrentes sur un même disque.
- `offline_transcode.sh` dépose des marqueurs `.done_<hash>` à côté des fichiers source pour prévenir un retraitement.
- Les journaux se trouvent par défaut dans `/var/log/dvd_rip.log` et `/var/log/offline_transcode.log`.

## Personnalisation

Chaque script accepte des variables d'environnement pour ajuster son comportement (nombre de threads, priorité I/O, options MakeMKV, seuil d'espace disque, etc.). Consultez les en-têtes des scripts pour la liste complète et leurs valeurs par défaut.

## Sécurité & bonnes pratiques

- Exécutez ces scripts sur une machine de confiance : ils attendent un accès complet aux périphériques block (`/dev/sr0`).
- Sauvegardez régulièrement vos données (`/mnt/media_master`, `/mnt/nas_media`).
- Surveillez les journaux systemd (`journalctl -u dvd-ripd.service`) pour détecter les erreurs de rip/transcodage.

## Pistes d'amélioration

- Ajouter le script `queue_dvd.sh` mentionné dans la règle udev.
- Exposer des métriques (Prometheus) ou des notifications (ex. via e-mail) lors des erreurs.
- Paramétrer des notifications sur la disponibilité de l'espace disque.

