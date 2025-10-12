# DVD Archiver

Pipeline d'archivage DVD en deux étapes :

1. **Extraction** : rip complet du disque avec MakeMKV, génération d'empreintes robustes, backup décrypté des menus et collecte des artefacts techniques.
2. **Enrichissement IA** : OCR des menus `.VOB`, analyse par LLM (Ollama par défaut) et écriture de `meta/metadata_ia.json`.

Le dépôt fournit une intégration cohérente avec `systemd`, `udev` et un fichier de configuration centralisé (`/etc/dvdarchiver.conf`).

## Pré-requis

Installez les dépendances suivantes (paquets Debian/Ubuntu indiqués) :

```bash
sudo apt install makemkv-bin cdrkit lsdvd ffmpeg eject util-linux coreutils \
                 tesseract-ocr mkvtoolnix curl
```

`install.sh` déclenche automatiquement l'installation du modèle Ollama `qwen2.5:14b-instruct-q4_K_M` (si le réseau est disponible). Vérifiez que le lecteur DVD est accessible sous `/dev/sr0` (modifiable via la configuration).

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

# Phase 1 : backup menus
KEEP_MENU_VOBS=1
MENU_VOB_GLOB="VIDEO_TS.VOB VTS_*_0.VOB"
MAKEMKV_BACKUP_ENABLE=1
MAKEMKV_BACKUP_OPTS="--decrypt"

# Phase 2 : OCR + IA
FFMPEG_BIN="ffmpeg"
TESSERACT_BIN="tesseract"
OCR_LANGS="eng+fra+spa+ita+deu"
MENU_FRAME_FPS=1
MENU_MAX_FRAMES=30
MENU_SCENE_MODE=1
MENU_SCENE_THRESHOLD=0.4
MENU_PREPROC_FILTERS="yadif,eq=contrast=1.1:brightness=0.02"
LLM_PROVIDER="ollama"
LLM_MODEL="qwen2.5:14b-instruct-q4_K_M"
LLM_ENDPOINT="http://127.0.0.1:11434"
```

Chaque script source ce fichier puis applique ses valeurs par défaut. Il est possible de surcharger temporairement une variable en exportant la valeur avant l'appel (ex. `DEVICE=/dev/sr1 queue_enqueue.sh`).

### Backup des menus VIDEO_TS décryptés

Le rip MakeMKV réalise désormais un backup complet du DVD (option `makemkvcon backup --decrypt`) pour conserver les menus `.VOB` dans `raw/VIDEO_TS_BACKUP/VIDEO_TS/`. Ces fichiers sont indispensables au pipeline OCR : sans menus décryptés, aucun texte ne peut être extrait pour alimenter l'IA. L'idempotence est respectée : si les `.VOB` sont déjà présents, le backup n'est pas relancé.

## Démarrage des services

1. Installer la règle udev (`udev/README-udev.md`).
2. Installer et activer les unités systemd (`systemd/README-systemd.md`).

La règle udev place un job dans la file lors de l'insertion d'un disque. L'unité `.path` déclenche le consommateur qui appelle `do_rip.sh`.

## Fonctionnement

- **File d'attente** : les jobs sont des fichiers dans `${QUEUE_DIR}` (par défaut `/var/spool/dvdarchiver`). Ils contiennent l'environnement minimal (`DEVICE`, `ACTION`).
- **Consommateur** : `queue_consumer.sh` traite les jobs triés, appelle `do_rip.sh` et déplace le job en `.done` ou `.err` selon le résultat.
- **Ripper** : `do_rip.sh` vérifie les dépendances, calcule une empreinte robuste (hash secteurs + structure VIDEO_TS), lance MakeMKV (mode `--minlength=0` par défaut), génère `fingerprint.json`, `structure.lsdvd.yml` et sauvegarde les menus décryptés dans `raw/VIDEO_TS_BACKUP/`.
- **Idempotence** : si un dossier `mkv/` avec au moins un fichier existe déjà pour l'empreinte donnée, le rip est ignoré (code de retour 0).
- **Logs** : envoyés vers le journal systemd (`logger`) et vers `${LOG_DIR}/dvdarchiver.log`, plus un fichier de rip dédié.

La phase 2 s'appuie sur les scripts `scan_enqueue.sh` / `scan_consumer.sh` et `bin/scan/scanner.py` pour : détecter les VOB de menus, extraire jusqu'à 30 frames par VOB, lancer Tesseract multilingue, normaliser les libellés (Lecture, Bonus, Chapitres...), interroger l'IA (Ollama par défaut) et produire `meta/metadata_ia.json`.

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
│   ├── metadata_ia.json
│   └── menu_frames/ (frames extraites pour l'OCR)
└── raw/
    ├── dvd.iso (si ALLOW_ISO_DUMP=1)
    └── VIDEO_TS_BACKUP/
        └── VIDEO_TS/*.VOB
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

`metadata_ia.json` regroupe le résumé OCR, l'analyse du LLM et les informations techniques utiles (durées, langues, empreinte du disque). Les scripts consignent également les outils utilisés (ffmpeg, tesseract, modèle Ollama).

## Sécurité & légalité

Le projet vise l'archivage domestique de médias dont vous possédez les droits. Aucune fonctionnalité de contournement de DRM n'est fournie. Respectez la législation locale.

## Dépannage

- **Espace disque insuffisant** : augmentez `MIN_FREE_GB` ou libérez de l'espace sur la destination.
- **Dépendances manquantes** : vérifiez que `makemkvcon`, `isoinfo`, `lsdvd`, `ffmpeg`, `tesseract`, `mkvmerge` (ou `ffprobe`) et `ollama` sont accessibles.
- **Permissions** : assurez-vous que l'utilisateur systemd a accès au périphérique optique et aux répertoires `DEST`, `QUEUE_DIR`, `LOG_DIR`, `TMP_DIR`.
- **Règle udev inactive** : validez avec `udevadm monitor` et ajustez `KERNEL=="sr0"` si nécessaire.

## Tests rapides

- `shellcheck bin/*.sh bin/lib/*.sh` pour valider la syntaxe.
- `QUEUE_DIR=/tmp/dvdarch bin/queue_enqueue.sh` puis `QUEUE_DIR=/tmp/dvdarch bin/queue_consumer.sh` pour un test à blanc (sans disque, le rip échouera mais la file sera exercée).
