# Analyse du script `bin/do_rip.py`

## Vue d'ensemble
Suite au portage en Python, `do_rip.py` conserve l'interface historique du script shell mais la logique métier est désormais
implémentée en Python. Le wrapper `do_rip.sh` vérifie simplement la présence de `python3` et délègue au script Python pour rester
compatible avec les intégrations existantes.

Le script automatise l'extraction d'un DVD via `makemkvcon`. Il gère la journalisation, l'identification du disque, la création de
répertoires de sortie, la vérification d'espace disque, la prévention des exécutions simultanées sur le même disque et l'éjection
automatique du média en fin de traitement.

## Paramétrage et dépendances
- **Variables configurables** : chemin du journal (`LOG`), périphérique optique (`DEVICE`), répertoire de destination (`DEST`),
  seuil d'espace disque (`MIN_FREE_GB`), paramètres de calcul d'empreinte (`DISC_HASH_*`), options MakeMKV (`MAKEMKV_OPTS`),
  priorités I/O et CPU (`IONICE_*`, `NICE_PRIO`).
- **Intégration TMDb** : `TMDB_API_KEY` active la recherche distante ; `TMDB_LANGUAGE` (par défaut `fr-FR`) et `TMDB_YEAR_HINT`
  permettent d'affiner la requête.
- **Sécurité d'exécution** : les exceptions sont propagées et converties en `RipError` pour signaler explicitement les cas
  d'échec attendus.
- **Dépendances vérifiées** : `dd`, `md5sum`, `makemkvcon`. `eject` et `volname` sont facultatifs.
- **Compatibilité** : `do_rip.sh` s'assure que `python3` est disponible avant de lancer `do_rip.py`.

## Fonctions clés
- `log`, `log_error` : formatage des traces dans le fichier de journal (écriture synchrone avec duplication sur `stderr`).
- `require_bins` : vérifie la présence des binaires requis.
- `check_free_space_gb` : calcule l'espace libre, en Go entiers, sur la partition de destination via `os.statvfs`.
- `normalize_title` : agrège plusieurs sources (MakeMKV, `blkid`, `volname`) pour déterminer le titre, translittère les caractères
  accentués via `unicodedata`, puis nettoie le nom pour n'autoriser que les caractères sûrs.
- `lookup_disc_metadata` : si `TMDB_API_KEY` est fourni, interroge TMDb directement via `urllib` (plus besoin de `curl`) pour
  journaliser le meilleur candidat correspondant au titre détecté.
- `compute_disc_id` : construit un hash MD5 à partir du titre et d'un sous-ensemble des secteurs du DVD (après un offset configuré),
  optionnellement tronqué. Sert d'identifiant stable du disque.

## Déroulement principal
1. **Préparation** : création des répertoires cible et du fichier de log, vérification du périphérique optique et des dépendances.
2. **Détection du titre et de l'empreinte** : normalise le titre, calcule `DISC_ID`, prépare le répertoire de sortie (`$DEST/$TITLE/$DISC_ID`).
3. **Verrouillage** : crée un fichier `.riplock` pour éviter les rips concurrents sur le même disque et assure son nettoyage via un
   bloc `finally` Python.
4. **Idempotence** : si des fichiers `.mkv` existent déjà dans le répertoire cible, le script s'arrête pour éviter les doublons.
5. **Vérification de l'espace libre** : abandonne si l'espace disponible est inférieur au seuil.
6. **Lancement de MakeMKV** : exécute `makemkvcon` avec options configurables, en abaissant les priorités I/O et CPU si possible
   (via `ionice`/`nice` si présents). La sortie standard et d'erreur est redirigée vers le fichier de log partagé.
7. **Validation et nettoyage** :
   - émet une erreur si `makemkvcon` échoue ; supprime alors le dossier vide ;
   - vérifie qu'au moins un fichier `.mkv` a été produit ;
   - journalise le succès et nettoie le verrou ;
   - éjecte systématiquement le disque en fin de traitement (succès ou échec).

## Comportement de sortie
- Codes de retour principaux :
  - `0` : rip réussi ou déjà effectué.
  - `2` : échec MakeMKV.
  - `3` : espace disque insuffisant.
  - `4` : aucun MKV trouvé malgré un succès apparent de MakeMKV.
- En cas d'erreur d'environnement (binaire manquant, périphérique absent), `RipError` est journalisée et un code 1 est renvoyé.

## Points de vigilance
- La translittération ne dépend plus de `iconv`; `unicodedata` assure le repli interne. Les caractères non ASCII restants sont
  retirés lors du nettoyage.
- Les paramètres numériques fournis via l'environnement sont validés ; une valeur invalide déclenche un avertissement et un repli
  sur la valeur par défaut.
- Le wrapper Bash n'est plus responsable de la logique métier ; tout le comportement est centralisé dans `do_rip.py`.

## Améliorations potentielles
- Ajouter une gestion plus fine des priorités (p. ex. `chrt` temps réel ou cgroup).
- Implémenter une rotation de journal ou une taille maximale.
- Ajouter des tests automatisés sur les fonctions pures (normalisation du titre, calcul de l'empreinte) via `pytest`.
- Introduire un mode simulation pour valider la configuration sans lancer MakeMKV.
