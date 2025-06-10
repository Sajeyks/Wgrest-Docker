#!/bin/bash
set -e

echo "🚀 Setting up WireGuard with External Database Backup..."

# Load environment
if [ ! -f .env ]; then
    echo "❌ .env file not found. Please create it first."
    exit 1
fi

source .env

# Set PostgreSQL environment variables to avoid password prompts
export PGHOST=$DB_HOST
export PGPORT=$DB_PORT
export PGUSER=$DB_USER
export PGPASSWORD=$DB_PASSWORD
export PGDATABASE=$DB_NAME

# Validate TARGET_WEBSITE_IP
if [ -z "$TARGET_WEBSITE_IP" ]; then
    echo "❌ TARGET_WEBSITE_IP not set in .env file"
    echo "   Please add: TARGET_WEBSITE_IP=1.2.3.4"
    exit 1
fi

echo "📋 Configuration loaded:"
echo "   Server IP: $SERVER_IP"
echo "   WG0 Port: $WG0_PORT"
echo "   WG1 Port: $WG1_PORT"
echo "   wgrest Port: $WGREST_PORT"
echo "   Target Website IP: $TARGET_WEBSITE_IP"
echo ""

# Test external database connection
echo "🔍 Testing external database connection..."
if ! psql -c "SELECT 1;" &>/dev/null; then
    echo "❌ Cannot connect to external database"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   User: $DB_USER"
    echo ""
    echo "Please ensure:"
    echo "   1. PostgreSQL server is running and accessible"
    echo "   2. Database '$DB_NAME' exists"
    echo "   3. User '$DB_USER' has access to the database"
    echo "   4. Network connectivity is working"
    echo "   5. Password in .env file is correct"
    echo ""
    echo "To create the database schema, run:"
    echo "   psql -f sql/init.sql"
    exit 1
fi

echo "✅ External database connection successful"

# Check if database schema exists
TABLES_EXIST=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('interfaces', 'peers', 'server_keys', 'sync_status');" | xargs)

if [ "$TABLES_EXIST" -lt 4 ]; then
    echo "🗄️  Setting up database schema..."
    if ! psql -f sql/init.sql; then
        echo "❌ Failed to create database schema"
        exit 1
    fi
    echo "✅ Database schema created"
else
    echo "✅ Database schema already exists"
fi

# Install Docker if needed
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
fi

# Install Docker Compose if needed
if ! command -v docker-compose &> /dev/null; then
    echo "🐳 Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# Create wgrest-build directory if it doesn't exist
echo "📁 Setting up wgrest build directory..."
mkdir -p wgrest-build

# Check for existing host installations that might conflict
echo "🔍 Checking for existing WireGuard/wgrest installations..."
if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    echo "⚠️  Stopping existing WireGuard wg0 service..."
    sudo systemctl stop wg-quick@wg0
    sudo systemctl disable wg-quick@wg0
fi

if systemctl is-active --quiet wg-quick@wg1 2>/dev/null; then
    echo "⚠️  Stopping existing WireGuard wg1 service..."
    sudo systemctl stop wg-quick@wg1
    sudo systemctl disable wg-quick@wg1
fi

if pgrep -f "wgrest" > /dev/null; then
    echo "⚠️  Stopping existing wgrest processes..."
    sudo pkill -f "wgrest" || true
fi

# Stop any existing WireGuard interfaces to avoid port conflicts
echo "🛑 Stopping existing WireGuard interfaces..."
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick down wg1 2>/dev/null || true

# Check for port conflicts
echo "🔍 Checking for port conflicts..."
if netstat -ulpn | grep -q ":$WG0_PORT "; then
    echo "⚠️  Port $WG0_PORT is in use. Attempting to free it..."
    sudo fuser -k $WG0_PORT/udp 2>/dev/null || true
fi

if netstat -tlpn | grep -q ":$WG1_PORT "; then
    echo "⚠️  Port $WG1_PORT is in use. Attempting to free it..."
    sudo fuser -k $WG1_PORT/udp 2>/dev/null || true
fi

if netstat -tlpn | grep -q ":$WGREST_PORT "; then
    echo "⚠️  Port $WGREST_PORT is in use. Attempting to free it..."
    sudo fuser -k $WGREST_PORT/tcp 2>/dev/null || true
fi

# Generate WireGuard keys (but don't store them yet - let sync service handle it)
echo "🔑 Generating WireGuard keys..."
WG0_PRIVATE=$(wg genkey)
WG0_PUBLIC=$(echo $WG0_PRIVATE | wg pubkey)
WG1_PRIVATE=$(wg genkey)
WG1_PUBLIC=$(echo $WG1_PRIVATE | wg pubkey)

echo "🔐 Keys will be encrypted and stored by sync service after configs are created"

# Create initial WireGuard configs
echo "📝 Creating initial WireGuard configurations..."
sudo mkdir -p /etc/wireguard

# Backup existing configs if they exist
if [ -f /etc/wireguard/wg0.conf ]; then
    sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.backup.$(date +%s)
fi
if [ -f /etc/wireguard/wg1.conf ]; then
    sudo cp /etc/wireguard/wg1.conf /etc/wireguard/wg1.conf.backup.$(date +%s)
fi

# wg0 config (FreeRADIUS)
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
EOF

# wg1 config (MikroTik) - FIXED to use TARGET_WEBSITE_IP
sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = 10.11.0.1/24
ListenPort = $WG1_PORT
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
EOF

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

# Start WireGuard interfaces
echo "🚀 Starting WireGuard interfaces..."

# Stop any existing interfaces first
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick down wg1 2>/dev/null || true

# Start wg0
if sudo wg-quick up wg0; then
    echo "✅ wg0 interface started successfully"
else
    echo "❌ Failed to start wg0 interface"
    exit 1
fi

# Start wg1
if sudo wg-quick up wg1; then
    echo "✅ wg1 interface started successfully"
else
    echo "❌ Failed to start wg1 interface"
    exit 1
fi

# Enable interfaces to start on boot
echo "🔄 Enabling WireGuard interfaces to start on boot..."
sudo systemctl enable wg-quick@wg0
sudo systemctl enable wg-quick@wg1

# Setup iptables rules
echo "🔥 Setting up firewall rules..."
sudo iptables -A INPUT -p udp --dport $WG0_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p udp --dport $WG1_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p tcp --dport $WGREST_PORT -j ACCEPT 2>/dev/null || true

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Clean up any existing containers
echo "🧹 Cleaning up existing containers..."
docker-compose down 2>/dev/null || true

# Build and start services
echo "🔨 Building and starting Docker services..."
echo "   This may take a few minutes as we build wgrest from source..."
docker-compose up -d --build

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 45  # Give more time for build and startup

# Test wgrest API
echo "🧪 Testing wgrest API..."
API_RETRIES=0
MAX_RETRIES=6

while [ $API_RETRIES -lt $MAX_RETRIES ]; do
    if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/v1/devices/ >/dev/null; then
        echo "✅ wgrest API is responding"
        break
    else
        echo "⏳ wgrest API not ready yet, waiting... (attempt $((API_RETRIES + 1))/$MAX_RETRIES)"
        echo "📋 Checking container status..."
        docker-compose ps
        if [ $API_RETRIES -eq 2 ]; then
            echo "📋 wgrest logs:"
            docker-compose logs --tail=20 wgrest
        fi
        sleep 10
        API_RETRIES=$((API_RETRIES + 1))
    fi
done

if [ $API_RETRIES -eq $MAX_RETRIES ]; then
    echo "❌ wgrest API is not responding after $MAX_RETRIES attempts"
    echo "📋 Service status:"
    docker-compose ps
    echo "📋 wgrest logs:"
    docker-compose logs wgrest
    echo ""
    echo "🔍 Troubleshooting suggestions:"
    echo "   1. Check if the binary was built correctly: docker-compose exec wgrest /app/wgrest --help"
    echo "   2. Check architecture: docker-compose exec wgrest uname -m"
    echo "   3. Check for existing processes: ps aux | grep wgrest"
    exit 1
fi

# CRITICAL: Trigger initial sync to encrypt and store everything properly
echo "🔄 Triggering initial sync to encrypt and store configurations..."
sleep 5  # Let sync service fully initialize

SYNC_RETRIES=0
MAX_SYNC_RETRIES=10

while [ $SYNC_RETRIES -lt $MAX_SYNC_RETRIES ]; do
    if curl -s -X POST -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:8090/sync | grep -q "sync_triggered"; then
        echo "✅ Initial sync triggered successfully"
        break
    else
        echo "⏳ Sync service not ready yet, waiting... (attempt $((SYNC_RETRIES + 1))/$MAX_SYNC_RETRIES)"
        if [ $SYNC_RETRIES -eq 3 ]; then
            echo "📋 Sync service logs:"
            docker-compose logs --tail=20 wgrest-sync
        fi
        sleep 10
        SYNC_RETRIES=$((SYNC_RETRIES + 1))
    fi
done

if [ $SYNC_RETRIES -eq $MAX_SYNC_RETRIES ]; then
    echo "⚠️  Could not trigger initial sync via webhook, sync will happen on file change"
    echo "📋 Sync service status:"
    docker-compose logs wgrest-sync
fi

# Wait for sync to complete
echo "⏳ Waiting for initial sync to complete..."
sleep 20

# Verify that encrypted data was stored
echo "🔍 Verifying encrypted data storage..."
STORED_KEYS=$(psql -t -c "SELECT COUNT(*) FROM server_keys WHERE private_key IS NOT NULL AND private_key != '';" | xargs)
STORED_INTERFACES=$(psql -t -c "SELECT COUNT(*) FROM interfaces;" | xargs)
STORED_SYNC_STATUS=$(psql -t -c "SELECT COUNT(*) FROM sync_status;" | xargs)

echo "📊 Database verification:"
echo "   Server keys stored: $STORED_KEYS/2"
echo "   Interfaces stored: $STORED_INTERFACES/2"
echo "   Sync status records: $STORED_SYNC_STATUS"

if [ "$STORED_KEYS" -eq 2 ] && [ "$STORED_INTERFACES" -eq 2 ] && [ "$STORED_SYNC_STATUS" -gt 0 ]; then
    echo "✅ All data properly encrypted and stored in database"
else
    echo "⚠️  Some data may not be properly stored. Check sync service logs:"
    docker-compose logs wgrest-sync
fi

# Final verification
echo "🧪 Final verification..."
for interface in wg0 wg1; do
    PEER_COUNT=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
                      "http://localhost:$WGREST_PORT/v1/devices/$interface/peers/" 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "Interface $interface: $PEER_COUNT peers (expected: 0 for fresh install)"
done

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   🌐 wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   🔑 API Key: $WGREST_API_KEY"
echo "   🔑 wg0 Public Key: $WG0_PUBLIC"
echo "   🔑 wg1 Public Key: $WG1_PUBLIC"
echo "   🗄️  External Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo "   🎯 Target Website IP: $TARGET_WEBSITE_IP"
echo "   🔐 Server keys encrypted and stored in database"
echo ""
echo "🔗 WireGuard Interface Status:"
sudo wg show
echo ""
echo "🔧 Next steps:"
echo "   1. Configure your Django app to use this wgrest API"
echo "   2. Create peers via Django -> wgrest API"
echo "   3. Database automatically syncs on changes (event-driven)"
echo "   4. Manual sync available: curl -X POST -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:8090/sync"
echo ""
echo "💾 Backup strategy:"
echo "   - All data (including encrypted keys) stored in external PostgreSQL"
echo "   - Backup external PostgreSQL database: pg_dump $DB_NAME"
echo "   - Restoration: restore database + run './scripts/restore.sh'"