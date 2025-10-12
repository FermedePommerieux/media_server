# DVD Archiver

Pipeline d'archivage DVD en deux étapes :

1. **Extraction** : rip complet du disque avec MakeMKV, génération d'empreintes robustes et collecte des artefacts techniques.
2. **Enrichissement ultérieur** : analyses IA/OCR futures qui consommeront les données présentes dans `meta/`.

Le dépôt fournit une intégration cohérente avec `systemd`, `udev` et un fichier de configuration centralisé (`/etc/dvdarchiver.conf`).

## Pré-requis

Installez les dépendances suivantes (paquets Debian/Ubuntu indiqués) :

```bash
sudo apt install makemkv-bin cdrkit lsdvd ffmpeg eject util-linux coreutils
```

`ffmpeg` est facultatif mais utile pour les vérifications ultérieures. Vérifiez que le lecteur DVD est accessible sous `/dev/sr0` (modifiable via la configuration).

## Installation

Deux options sont proposées :

### Via `make`

```bash
sudo make install
```

Cette commande copie les scripts dans `/usr/local/bin`, installe la configuration si absente (`/etc/dvdarchiver.conf`), et prépare les répertoires nécessaires.

### Via `install.sh`

```bash
sudo ./install.sh --with-systemd --with-udev
```

Le script prend en charge :

- la copie des scripts (`bin/`) dans `/usr/local/bin/` et des bibliothèques dans `/usr/local/lib/dvdarchiver/` ;
- l'installation de `/etc/dvdarchiver.conf` si le fichier n'existe pas (copie du sample) ;
- l'installation optionnelle des unités systemd et de la règle udev.

## Configuration

Toutes les options résident dans `/etc/dvdarchiver.conf`. Exemple :

```bash
DEST="/mnt/media_master"
QUEUE_DIR="/var/spool/dvdarchiver"
LOG_DIR="/var/log/dvdarchiver"
TMP_DIR="/var/tmp/dvdarchiver"
DEVICE="/dev/sr0"
MAKEMKV_OPTS="--minlength=0"
DISC_HASH_COUNT_SECT=64
DISC_HASH_SKIP_SECT=32768
DISC_HASH_EXTRA_OFFSETS="0 262144"
DISC_HASH_TRIM=16
MIN_FREE_GB=10
EJECT_ON_DONE=1
ALLOW_ISO_DUMP=0
```

Chaque script source ce fichier puis applique ses valeurs par défaut. Il est possible de surcharger temporairement une variable en exportant la valeur avant l'appel (ex. `DEVICE=/dev/sr1 queue_enqueue.sh`).

## Démarrage des services

1. Installer la règle udev (`udev/README-udev.md`).
2. Installer et activer les unités systemd (`systemd/README-systemd.md`).

La règle udev place un job dans la file lors de l'insertion d'un disque. L'unité `.path` déclenche le consommateur qui appelle `do_rip.sh`.

## Fonctionnement

- **File d'attente** : les jobs sont des fichiers dans `${QUEUE_DIR}` (par défaut `/var/spool/dvdarchiver`). Ils contiennent l'environnement minimal (`DEVICE`, `ACTION`).
- **Consommateur** : `queue_consumer.sh` traite les jobs triés, appelle `do_rip.sh` et déplace le job en `.done` ou `.err` selon le résultat.
- **Ripper** : `do_rip.sh` vérifie les dépendances, calcule une empreinte robuste (hash secteurs + structure VIDEO_TS), lance MakeMKV (mode `--minlength=0` par défaut) puis génère les artefacts nécessaires (`fingerprint.json`, dump `lsdvd`).
- **Idempotence** : si un dossier `mkv/` avec au moins un fichier existe déjà pour l'empreinte donnée, le rip est ignoré (code de retour 0).
- **Logs** : envoyés vers le journal systemd (`logger`) et vers `${LOG_DIR}/dvdarchiver.log`, plus un fichier de rip dédié.

## Structure d'archive

```
$DEST/<DISC_SHA_SHORT>/
├── mkv/
│   ├── title00.mkv
│   └── ...
├── tech/
│   ├── fingerprint.json
│   └── structure.lsdvd.yml
├── meta/
└── raw/
    └── dvd.iso (si ALLOW_ISO_DUMP=1)
```

`fingerprint.json` contient :

```json
{
  "disc_uid": "abcd1234ef567890",
  "volume_id": "MON_DVD",
  "struct_sha256": "<sha256>",
  "generated_at": "2024-01-01T12:00:00Z",
  "layout_version": "1.0"
}
```

L'étape 2 (non incluse) utilisera `mkv/` et `tech/` pour produire des fichiers enrichis dans `meta/`.

## Sécurité & légalité

Le projet vise l'archivage domestique de médias dont vous possédez les droits. Aucune fonctionnalité de contournement de DRM n'est fournie. Respectez la législation locale.

## Dépannage

- **Espace disque insuffisant** : augmentez `MIN_FREE_GB` ou libérez de l'espace sur la destination.
- **Dépendances manquantes** : vérifiez que `makemkvcon`, `isoinfo`, `lsdvd`, `eject`, `mount` sont accessibles.
- **Permissions** : assurez-vous que l'utilisateur systemd a accès au périphérique optique et aux répertoires `DEST`, `QUEUE_DIR`, `LOG_DIR`, `TMP_DIR`.
- **Règle udev inactive** : validez avec `udevadm monitor` et ajustez `KERNEL=="sr0"` si nécessaire.

## Tests rapides

- `shellcheck bin/*.sh bin/lib/*.sh` pour valider la syntaxe.
- `QUEUE_DIR=/tmp/dvdarch bin/queue_enqueue.sh` puis `QUEUE_DIR=/tmp/dvdarch bin/queue_consumer.sh` pour un test à blanc (sans disque, le rip échouera mais la file sera exercée).
