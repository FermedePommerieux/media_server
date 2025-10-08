#!/bin/bash
# /usr/local/bin/dvd_ripd.sh
# script called by udev
set -euo pipefail
QUEUE="/var/lib/dvdqueue"
LOG="/var/log/dvd_rip.log"
LOCK="/tmp/dvd-ripd.lock"
mkdir -p "$QUEUE"
exec 9>"$LOCK"; flock -n 9 || { echo "$(date): dvd-ripd already running" >> "$LOG"; exit 0; }
echo "=== $(date): dvd-ripd started ===" >> "$LOG"
while true; do
  JOB=$(find "$QUEUE" -type f -name "*.job" | sort | head -n 1)
  if [[ -n "${JOB:-}" ]]; then
    echo "$(date): found $JOB" >> "$LOG"
    rm -f "$JOB"
    /usr/local/bin/do_rip.sh >> "$LOG" 2>&1 || echo "$(date): rip failed" >> "$LOG"
  fi
  sleep 15
done
