#/usr/local/bin/queue_dvd.sh 
#!/bin/bash
set -euo pipefail
QUEUE_DIR="/var/lib/dvdqueue"
mkdir -p "$QUEUE_DIR"
JOBFILE="$QUEUE_DIR/$(date +%Y%m%d_%H%M%S).job"
echo "DVD detected at $(date)" > "$JOBFILE"; chown media:media "$JOBFILE"
