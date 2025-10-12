# Unités systemd – Phase 2 (Scan IA)

## Installation

```bash
cp systemd/dvdarchiver-scan-consumer.service /etc/systemd/system/
cp systemd/dvdarchiver-scan-consumer.path /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dvdarchiver-scan-consumer.service
systemctl enable --now dvdarchiver-scan-consumer.path
```

## Journaux

* `journalctl -u dvdarchiver-scan-consumer.service`
* Fichiers détaillés : `${SCAN_LOG_DIR}/scan-<disc>-<timestamp>.log`

## Test manuel

```bash
scan_enqueue.sh "${DEST}/<DISC_UID>"
```
