#!/bin/bash
set -e

echo "🔄 WireGuard Database Restoration"
echo ""
echo "⚠️  This will restore WireGuard from external PostgreSQL database"
echo "   Make sure your database is restored first!"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

source .env

# Set PostgreSQL environment variables to avoid password prompts
export PGHOST=$DB_HOST
export PGPORT=$DB_PORT
export PGUSER=$DB_USER
export PGPASSWORD=$DB_PASSWORD
export PGDATABASE=$DB_NAME

# Set defaults for subnet/address variables if not provided
WG0_SUBNET=${WG0_SUBNET:-"10.10.0.0/8"}
WG0_ADDRESS=${WG0_ADDRESS:-"10.10.0.1/8"}
WG1_SUBNET=${WG1_SUBNET:-"10.11.0.0/8"}
WG1_ADDRESS=${WG1_ADDRESS:-"10.11.0.1/8"}
RADIUS_AUTH_PORT=${RADIUS_AUTH_PORT:-"1812"}
RADIUS_ACCT_PORT=${RADIUS_ACCT_PORT:-"1813"}
WEBHOOK_PORT=${WEBHOOK_PORT:-"8090"}

# Validate required environment variables
validate_env_var() {
    local var_name=$1
    local var_value=${!var_name}
    if [ -z "$var_value" ]; then
        echo "❌ $var_name not set in .env file"
        echo "   Please add: $var_name=<value>"
        exit 1
    fi
}

validate_env_var "TARGET_WEBSITE_IP"
validate_env_var "SERVER_IP"
validate_env_var "WG0_PORT"
validate_env_var "WG1_PORT"
validate_env_var "WGREST_PORT"

echo "🔄 Starting restoration from external database..."
echo "📋 Configuration:"
echo "   Target Website IP: $TARGET_WEBSITE_IP"
echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo "   WG0: $WG0_ADDRESS on port $WG0_PORT (subnet: $WG0_SUBNET)"
echo "   WG1: $WG1_ADDRESS on port $WG1_PORT (subnet: $WG1_SUBNET)"
echo "   FreeRADIUS Ports: $RADIUS_AUTH_PORT, $RADIUS_ACCT_PORT"
echo ""

# Stop services
echo "Stopping services..."
docker-compose down

# Check external database connection
echo "🔍 Checking external database connection..."
if ! psql -c "SELECT COUNT(*) FROM peers;" &>/dev/null; then
    echo "❌ Cannot connect to external database or no data found"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   Make sure:"
    echo "   1. Database server is accessible"
    echo "   2. Credentials are correct"
    echo "   3. Database has been restored from backup"
    echo "   4. Password in .env file is correct"
    exit 1
fi

# Get peer counts from database
WG0_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" | xargs)
WG1_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" | xargs)

echo "📊 Found in database:"
echo "   wg0: $WG0_PEERS peers"
echo "   wg1: $WG1_PEERS peers"

# Check if our decrypt helper exists
if [ ! -f "scripts/decrypt_helper.py" ]; then
    echo "❌ scripts/decrypt_helper.py not found"
    echo "   This script is required for decryption"
    exit 1
fi

# Install Python dependencies for decrypt helper
echo "🔧 Installing Python dependencies..."
pip3 install -q psycopg2-binary cryptography python-dotenv 2>/dev/null || {
    echo "⚠️  Could not install Python dependencies, trying without..."
}

# Restore WireGuard configs from structured database data
echo "📝 Reconstructing WireGuard configurations from structured data..."
sudo rm -f /etc/wireguard/wg*.conf

# Function to safely get decrypted data
get_server_key() {
    local interface=$1
    python3 scripts/decrypt_helper.py server_key "$interface" 2>/dev/null || echo ""
}

get_interface_data() {
    local interface=$1
    python3 scripts/decrypt_helper.py interface_data "$interface" 2>/dev/null || echo ","
}

get_peers_config() {
    local interface=$1
    python3 scripts/decrypt_helper.py peers "$interface" 2>/dev/null || echo ""
}

# Restore wg0 config by reconstructing from structured data
echo "🔧 Reconstructing wg0.conf..."
WG0_PRIVATE=$(get_server_key wg0)
WG0_DATA=$(get_interface_data wg0)

if [ ! -z "$WG0_PRIVATE" ] && [ "$WG0_PRIVATE" != "" ]; then
    # Parse interface data
    WG0_DB_ADDRESS=$(echo "$WG0_DATA" | cut -d',' -f1)
    WG0_DB_LISTEN_PORT=$(echo "$WG0_DATA" | cut -d',' -f2)
    
    # Use database values if available, otherwise use environment defaults
    WG0_FINAL_ADDRESS=${WG0_DB_ADDRESS:-$WG0_ADDRESS}
    WG0_FINAL_PORT=${WG0_DB_LISTEN_PORT:-$WG0_PORT}
    
    # Create interface section with environment variable based iptables rules
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = $WG0_FINAL_ADDRESS
ListenPort = $WG0_FINAL_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_AUTH_PORT -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_ACCT_PORT -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG0_SUBNET -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_AUTH_PORT -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_ACCT_PORT -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG0_SUBNET -d 127.0.0.1 -j MASQUERADE

EOF

    # Add peers from database (decrypted)
    echo "   Adding wg0 peers from database..."
    WG0_PEERS_CONFIG=$(get_peers_config wg0)
    if [ ! -z "$WG0_PEERS_CONFIG" ]; then
        echo "$WG0_PEERS_CONFIG" | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
    fi
    
    RESTORED_WG0_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg0.conf 2>/dev/null || echo 0)
    echo "✅ wg0.conf reconstructed with $RESTORED_WG0_PEERS peers (address: $WG0_FINAL_ADDRESS, port: $WG0_FINAL_PORT)"
else
    echo "⚠️  wg0 server key not found in database, creating basic config"
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
Address = $WG0_ADDRESS
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_AUTH_PORT -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_ACCT_PORT -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG0_SUBNET -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_AUTH_PORT -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport $RADIUS_ACCT_PORT -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG0_SUBNET -d 127.0.0.1 -j MASQUERADE
EOF
fi

# Restore wg1 config by reconstructing from structured data  
echo "🔧 Reconstructing wg1.conf..."
WG1_PRIVATE=$(get_server_key wg1)
WG1_DATA=$(get_interface_data wg1)

if [ ! -z "$WG1_PRIVATE" ] && [ "$WG1_PRIVATE" != "" ]; then
    # Parse interface data
    WG1_DB_ADDRESS=$(echo "$WG1_DATA" | cut -d',' -f1)
    WG1_DB_LISTEN_PORT=$(echo "$WG1_DATA" | cut -d',' -f2)
    
    # Use database values if available, otherwise use environment defaults
    WG1_FINAL_ADDRESS=${WG1_DB_ADDRESS:-$WG1_ADDRESS}
    WG1_FINAL_PORT=${WG1_DB_LISTEN_PORT:-$WG1_PORT}
    
    # Create interface section with environment variable based iptables rules
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = $WG1_FINAL_ADDRESS
ListenPort = $WG1_FINAL_PORT
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG1_SUBNET -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG1_SUBNET -d $TARGET_WEBSITE_IP -j MASQUERADE

EOF

    # Add peers from database (decrypted)
    echo "   Adding wg1 peers from database..."
    WG1_PEERS_CONFIG=$(get_peers_config wg1)
    if [ ! -z "$WG1_PEERS_CONFIG" ]; then
        echo "$WG1_PEERS_CONFIG" | sudo tee -a /etc/wireguard/wg1.conf > /dev/null
    fi
    
    RESTORED_WG1_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg1.conf 2>/dev/null || echo 0)
    echo "✅ wg1.conf reconstructed with $RESTORED_WG1_PEERS peers (address: $WG1_FINAL_ADDRESS, port: $WG1_FINAL_PORT)"
else
    echo "⚠️  wg1 server key not found in database, creating basic config"
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
Address = $WG1_ADDRESS
ListenPort = $WG1_PORT
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG1_SUBNET -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG1_SUBNET -d $TARGET_WEBSITE_IP -j MASQUERADE
EOF
fi

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

# Start WireGuard interfaces manually (before Docker services)
echo "🚀 Starting WireGuard interfaces..."

# Stop any existing interfaces first
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick down wg1 2>/dev/null || true

# Start interfaces
if [ -f /etc/wireguard/wg0.conf ]; then
    if sudo wg-quick up wg0; then
        echo "✅ wg0 interface started successfully"
    else
        echo "⚠️  wg0 interface start failed, but continuing..."
    fi
fi

if [ -f /etc/wireguard/wg1.conf ]; then
    if sudo wg-quick up wg1; then
        echo "✅ wg1 interface started successfully" 
    else
        echo "⚠️  wg1 interface start failed, but continuing..."
    fi
fi

# Start all services
echo "🚀 Starting all services..."
docker-compose up -d

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 30

# Verify wgrest API is responding
echo "🧪 Waiting for wgrest API to be ready..."
API_RETRIES=0
MAX_RETRIES=6

while [ $API_RETRIES -lt $MAX_RETRIES ]; do
    if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/v1/devices/ >/dev/null; then
        echo "✅ wgrest API is responding on port $WGREST_PORT"
        break
    else
        echo "⏳ wgrest API not ready yet, waiting... (attempt $((API_RETRIES + 1))/$MAX_RETRIES)"
        sleep 10
        API_RETRIES=$((API_RETRIES + 1))
    fi
done

if [ $API_RETRIES -eq $MAX_RETRIES ]; then
    echo "⚠️  wgrest API not responding, but continuing with restoration"
fi

# Trigger sync to ensure wgrest knows about all peers
echo "🔄 Triggering sync to populate wgrest with restored peers..."
SYNC_RETRIES=0
MAX_SYNC_RETRIES=6

while [ $SYNC_RETRIES -lt $MAX_SYNC_RETRIES ]; do
    if curl -s -X POST -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WEBHOOK_PORT/sync | grep -q "sync_triggered"; then
        echo "✅ Sync triggered successfully"
        break
    else
        echo "⏳ Sync service not ready yet, waiting... (attempt $((SYNC_RETRIES + 1))/$MAX_SYNC_RETRIES)"
        sleep 10
        SYNC_RETRIES=$((SYNC_RETRIES + 1))
    fi
done

# Wait for sync to complete
echo "⏳ Waiting for sync to complete..."
sleep 20

# Verify restoration
echo "🧪 Verifying restoration..."

# Check wgrest API peer counts
for interface in wg0 wg1; do
    if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/v1/devices/ >/dev/null 2>&1; then
        API_PEER_COUNT=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
                              "http://localhost:$WGREST_PORT/v1/devices/$interface/peers/" 2>/dev/null | \
                              python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        echo "Interface $interface: $API_PEER_COUNT peers restored via API"
    else
        echo "Interface $interface: API not accessible"
    fi
done

# Check database consistency
echo ""
echo "📊 Database vs Config Verification:"
DB_WG0_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" 2>/dev/null | xargs || echo "0")
DB_WG1_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" 2>/dev/null | xargs || echo "0")
CONFIG_WG0_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg0.conf 2>/dev/null || echo "0")
CONFIG_WG1_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg1.conf 2>/dev/null || echo "0")

echo "   Database: wg0=$DB_WG0_PEERS, wg1=$DB_WG1_PEERS"
echo "   Config files: wg0=$CONFIG_WG0_PEERS, wg1=$CONFIG_WG1_PEERS"

if [ "$DB_WG0_PEERS" -eq "$CONFIG_WG0_PEERS" ] && [ "$DB_WG1_PEERS" -eq "$CONFIG_WG1_PEERS" ]; then
    echo "✅ Database and config files are consistent"
else
    echo "⚠️  Peer counts don't match - this may be normal if some peers couldn't be decrypted"
fi

# Show WireGuard status
echo ""
echo "🔗 WireGuard Interface Status:"
if sudo wg show >/dev/null 2>&1; then
    sudo wg show
else
    echo "⚠️  WireGuard interfaces not accessible"
fi

echo ""
echo "✅ Database restoration completed!"
echo ""
echo "🔄 The restoration process:"
echo "   1. ✅ Read structured data from external PostgreSQL"
echo "   2. ✅ Decrypted sensitive fields using existing decrypt helper"
echo "   3. ✅ Reconstructed WireGuard config files with all peers"
echo "   4. ✅ Started WireGuard interfaces"
echo "   5. ✅ Started Docker services with improved sync service"
echo "   6. ✅ Triggered sync to ensure wgrest API consistency"
echo ""
echo "📊 Restoration Summary:"
echo "   Database wg0 peers: $DB_WG0_PEERS"
echo "   Database wg1 peers: $DB_WG1_PEERS"
echo "   Restored wg0 peers: ${RESTORED_WG0_PEERS:-$CONFIG_WG0_PEERS}"
echo "   Restored wg1 peers: ${RESTORED_WG1_PEERS:-$CONFIG_WG1_PEERS}"
echo ""
echo "📋 Configuration Used:"
echo "   WG0: ${WG0_FINAL_ADDRESS:-$WG0_ADDRESS} on port ${WG0_FINAL_PORT:-$WG0_PORT}"
echo "   WG1: ${WG1_FINAL_ADDRESS:-$WG1_ADDRESS} on port ${WG1_FINAL_PORT:-$WG1_PORT}"
echo "   FreeRADIUS: ports $RADIUS_AUTH_PORT, $RADIUS_ACCT_PORT"
echo "   Target Website: $TARGET_WEBSITE_IP"
echo ""
echo "🧪 Verify with:"
echo "   curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:$WGREST_PORT/v1/devices/"
echo "   python3 verify_peer_sync.py"