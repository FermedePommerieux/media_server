# Agents & flux

- **Agent udev** : règle `99-dvdarchiver.rules` déclenche `queue_enqueue.sh` lors de l'insertion d'un disque.
- **Queue Consumer (systemd)** : `dvdarchiver-queue-consumer.service` surveille la file et appelle `queue_consumer.sh`.
- **Ripper** : `do_backup.sh` réalise le backup complet et génère `tech/` + `meta/` (vide) selon l'empreinte disque.
- **Scanner IA (à venir)** : consommera `mkv/` et `tech/` pour écrire `meta/metadata_ia.json`.

```
[udev] --(JOB)-> [QUEUE_DIR] --(path/timer)-> [queue_consumer.sh] --(exec)-> [do_backup.sh] --(artefacts)-> DEST
```
