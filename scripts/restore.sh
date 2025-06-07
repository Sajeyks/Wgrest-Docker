#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <backup_file_or_name>"
    echo "Available backups:"
    ls -la backups/*.tar.gz 2>/dev/null || echo "No local backups found"
    
    # List R2 backups if configured
    if [ -f "rclone.conf" ] && [ -f ".env" ]; then
        source .env
        if [ ! -z "$R2_BUCKET" ]; then
            echo "R2 backups:"
            docker run --rm -v $(pwd)/rclone.conf:/config/rclone/rclone.conf \
                            rclone/rclone \
                            ls "r2:$R2_BUCKET/" 2>/dev/null || echo "No R2 backups found"
        fi
    fi
    exit 1
fi

BACKUP_FILE="$1"

echo "Restoring from: $BACKUP_FILE"

# Stop current services
echo "Stopping services..."
docker-compose down 2>/dev/null || true

# Download from R2 if it's not a local file
if [ ! -f "$BACKUP_FILE" ] && [ ! -f "backups/$BACKUP_FILE" ]; then
    if [ -f "rclone.conf" ] && [ -f ".env" ]; then
        source .env
        echo "Downloading from R2..."
        docker run --rm -v $(pwd)/rclone.conf:/config/rclone/rclone.conf \
                        -v $(pwd):/data \
                        rclone/rclone \
                        copy "r2:$R2_BUCKET/$BACKUP_FILE" /data/
    else
        echo "Backup file not found and no R2 configured"
        exit 1
    fi
elif [ -f "backups/$BACKUP_FILE" ]; then
    BACKUP_FILE="backups/$BACKUP_FILE"
fi

# Create temporary restore directory
RESTORE_DIR="/tmp/wireguard_restore_$(date +%s)"
mkdir -p "$RESTORE_DIR"

# Extract backup
echo "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

# Backup current state
echo "Backing up current state..."
CURRENT_BACKUP="current_state_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "/tmp/$CURRENT_BACKUP" --exclude='*.log' -C $(pwd) . 2>/dev/null || true

# Restore files
echo "Restoring configuration..."
cp -r "$RESTORE_DIR"/* ./

# Set proper permissions
chmod +x scripts/*.sh
chmod 600 config/wg*.conf 2>/dev/null || true

# Start services
echo "Starting services..."
docker-compose up -d

# Wait for services to start
sleep 5

# Verify services are running
echo "Verifying services..."
docker-compose ps

# Clean up
rm -rf "$RESTORE_DIR"

echo "Restore completed successfully!"
echo "Current state was backed up to: /tmp/$CURRENT_BACKUP"