#!/bin/sh
# Nightly backup of Tuwunel RocksDB from Oracle VM to Synology.
# Run as root on the Synology. Logs to /var/log/matrix-backup.log.
set -e
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP] Starting matrix backup"
rsync -az --delete \
    -e "ssh -i /volume1/docker/matrix-tunnel/backup_key -o StrictHostKeyChecking=no -o BatchMode=yes" \
    ubuntu@79.76.114.255:/var/lib/tuwunel/ \
    /volume1/matrix-backup/tuwunel/
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete"
