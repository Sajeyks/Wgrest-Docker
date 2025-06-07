#!/bin/bash
set -e

source .env

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="wireguard_backup_$TIMESTAMP.tar.gz"

echo "Creating backup..."

# Create backup
tar -czf "/tmp/$BACKUP_NAME" \
    --exclude='*.log' \
    -C $(pwd) .

# Upload to R2 if configured
if [ ! -z "$R2_BUCKET" ]; then
    docker run --rm -v $(pwd)/rclone.conf:/config/rclone/rclone.conf \
                    -v /tmp:/data \
                    rclone/rclone \
                    copy "/data/$BACKUP_NAME" "r2:$R2_BUCKET/"
fi

echo "Backup completed: $BACKUP_NAME"