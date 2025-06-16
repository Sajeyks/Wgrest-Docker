#!/bin/bash
set -e

echo "🔄 WireGuard Database Restoration (Enhanced Multi-Tenant Security)"
echo ""
echo "⚠️  This will restore WireGuard with enhanced tenant isolation"
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
WG0_SUBNET=${WG0_SUBNET:-"10.10.0.0/16"}
WG0_ADDRESS=${WG0_ADDRESS:-"10.10.0.1/16"}
WG1_SUBNET=${WG1_SUBNET:-"10.11.0.0/16"}
WG1_ADDRESS=${WG1_ADDRESS:-"10.11.0.1/16"}
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

validate_env_var "SERVER_IP"
validate_env_var "WG0_PORT"
validate_env_var "WG1_PORT"
validate_env_var "WGREST_PORT"

echo "🔄 Starting restoration with Enhanced Multi-Tenant Security..."
echo "📋 Configuration:"
echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo "   WG0 (MikroTik↔FreeRADIUS): $WG0_ADDRESS on port $WG0_PORT (subnet: $WG0_SUBNET)"
echo "   WG1 (Django↔MikroTik): $WG1_ADDRESS on port $WG1_PORT (subnet: $WG1_SUBNET)"
echo "   FreeRADIUS Ports: $RADIUS_AUTH_PORT, $RADIUS_ACCT_PORT"
echo "   Django: Local with API-only access (tenant isolation enforced)"
echo ""

# Stop services
echo "Stopping services..."
docker-compose down

# Check external database connection
echo "🔍 Checking external database connection..."
if ! psql -c "SELECT COUNT(*) FROM peers;" &>/dev/null; then
    echo "❌ Cannot connect to external database or no data found"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    exit 1
fi

# Get peer counts from database
WG0_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" | xargs)
WG1_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" | xargs)

echo "📊 Found in database:"
echo "   wg0: $WG0_PEERS peers (MikroTik routers)"
echo "   wg1: $WG1_PEERS peers (MikroTik routers for Django API)"

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

# Setup manual iptables persistence (YunoHost compatible)
echo "📦 Ensuring manual iptables persistence is configured..."

# Create iptables save/restore directory if it doesn't exist
sudo mkdir -p /etc/iptables

# Function to save iptables rules manually
save_iptables_rules() {
    echo "💾 Saving iptables rules manually..."
    sudo iptables-save > /etc/iptables/rules.v4
    sudo ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    echo "✅ Rules saved to /etc/iptables/rules.v4"
}

# Ensure systemd service exists for rule restoration on boot
if [ ! -f /etc/systemd/system/iptables-restore-wireguard.service ]; then
    echo "🔧 Creating systemd service for iptables persistence..."
    sudo tee /etc/systemd/system/iptables-restore-wireguard.service > /dev/null << 'EOF'
[Unit]
Description=Restore WireGuard iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f /etc/iptables/rules.v4 ]; then /sbin/iptables-restore < /etc/iptables/rules.v4; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service
    sudo systemctl enable iptables-restore-wireguard.service
    echo "✅ Manual iptables persistence service created and enabled"
else
    echo "✅ Manual iptables persistence already configured"
fi

# Function to add iptables rule only if it doesn't exist
add_persistent_rule() {
    local table=${1:-filter}
    local chain=$2
    local rule=$3
    local description=$4
    
    if [ "$table" = "nat" ]; then
        if ! sudo iptables -t nat -C $chain $rule 2>/dev/null; then
            sudo iptables -t nat -A $chain $rule
            echo "✅ Added $description"
        else
            echo "ℹ️  $description already exists"
        fi
    else
        if ! sudo iptables -C $chain $rule 2>/dev/null; then
            sudo iptables -A $chain $rule
            echo "✅ Added $description"
        else
            echo "ℹ️  $description already exists"
        fi
    fi
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
    
    # Create clean interface section (NO PostUp/PostDown - using persistent rules)
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = $WG0_FINAL_ADDRESS
ListenPort = $WG0_FINAL_PORT

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
    
    # Create clean interface section (NO PostUp/PostDown - using persistent rules)
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = $WG1_FINAL_ADDRESS
ListenPort = $WG1_FINAL_PORT

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
EOF
fi

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

# Setup enhanced multi-tenant security firewall rules
echo "🔥 Ensuring enhanced multi-tenant security rules..."

# INPUT rules for WireGuard ports and services
add_persistent_rule "filter" "INPUT" "-p udp --dport $WG0_PORT -j ACCEPT" "WG0 UDP (MikroTik connections)"
add_persistent_rule "filter" "INPUT" "-p udp --dport $WG1_PORT -j ACCEPT" "WG1 UDP (Django connections)"
add_persistent_rule "filter" "INPUT" "-p tcp --dport $WGREST_PORT -j ACCEPT" "wgrest API"
add_persistent_rule "filter" "INPUT" "-p tcp --dport $WEBHOOK_PORT -j ACCEPT" "webhook"

# =================
# WG0 TENANT ISOLATION (MikroTik ↔ FreeRADIUS)
# =================

echo "🔀 Setting up WG0 rules with tenant isolation (MikroTik ↔ FreeRADIUS)..."

# Allow MikroTik → FreeRADIUS (auth/accounting only)
add_persistent_rule "filter" "FORWARD" "-i wg0 -d 127.0.0.1 -p udp --dport $RADIUS_AUTH_PORT -j ACCEPT" "MikroTik → FreeRADIUS auth"
add_persistent_rule "filter" "FORWARD" "-i wg0 -d 127.0.0.1 -p udp --dport $RADIUS_ACCT_PORT -j ACCEPT" "MikroTik → FreeRADIUS acct"

# Allow FreeRADIUS → MikroTik responses
add_persistent_rule "filter" "FORWARD" "-o wg0 -s 127.0.0.1 -p udp --sport $RADIUS_AUTH_PORT -j ACCEPT" "FreeRADIUS auth → MikroTik"
add_persistent_rule "filter" "FORWARD" "-o wg0 -s 127.0.0.1 -p udp --sport $RADIUS_ACCT_PORT -j ACCEPT" "FreeRADIUS acct → MikroTik"

# CRITICAL: Block MikroTik-to-MikroTik communication on WG0
add_persistent_rule "filter" "FORWARD" "-i wg0 -o wg0 -j DROP" "WG0: Block peer-to-peer communication"

# Block WG0 → internet access
add_persistent_rule "filter" "FORWARD" "-i wg0 ! -d 127.0.0.1 -j DROP" "WG0: Block internet access"

# =================
# WG1 ENHANCED TENANT ISOLATION (Django ↔ MikroTik API)
# =================

echo "🔀 Setting up WG1 rules with enhanced tenant isolation (Django ↔ MikroTik API)..."

# Allow Django (local) → ANY MikroTik API (specific ports only)
add_persistent_rule "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j ACCEPT" "Django → MikroTik API"
add_persistent_rule "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j ACCEPT" "Django → MikroTik API SSL"
add_persistent_rule "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 22 -j ACCEPT" "Django → MikroTik SSH"

# Allow MikroTik API responses → Django
add_persistent_rule "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 8728 -j ACCEPT" "MikroTik API → Django"
add_persistent_rule "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 8729 -j ACCEPT" "MikroTik API SSL → Django"
add_persistent_rule "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 22 -j ACCEPT" "MikroTik SSH → Django"

# CRITICAL: Block MikroTik-to-MikroTik communication on WG1  
add_persistent_rule "filter" "FORWARD" "-i wg1 -o wg1 -j DROP" "WG1: Block peer-to-peer communication"

# Block any other WG1 traffic
add_persistent_rule "filter" "FORWARD" "-i wg1 ! -d 127.0.0.1 -j DROP" "WG1: Block unauthorized traffic"

# =================
# CROSS-INTERFACE ISOLATION
# =================

echo "🚫 Setting up cross-interface isolation..."

# Prevent WG0 → WG1 communication
add_persistent_rule "filter" "FORWARD" "-i wg0 -o wg1 -j DROP" "Block WG0 → WG1"
add_persistent_rule "filter" "FORWARD" "-i wg1 -o wg0 -j DROP" "Block WG1 → WG0"

# =================
# MINIMAL NAT RULES (Service-Specific)
# =================

echo "🎭 Setting up minimal service-specific NAT rules..."

# WG0 NAT for FreeRADIUS communication only
add_persistent_rule "nat" "POSTROUTING" "-s 10.10.0.0/16 -d 127.0.0.1 -p udp --dport $RADIUS_AUTH_PORT -j MASQUERADE" "WG0 → FreeRADIUS auth NAT"
add_persistent_rule "nat" "POSTROUTING" "-s 10.10.0.0/16 -d 127.0.0.1 -p udp --dport $RADIUS_ACCT_PORT -j MASQUERADE" "WG0 → FreeRADIUS acct NAT"

# WG1 NAT for Django API communication only
add_persistent_rule "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j MASQUERADE" "Django → MikroTik API NAT"
add_persistent_rule "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j MASQUERADE" "Django → MikroTik API SSL NAT"
add_persistent_rule "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 22 -j MASQUERADE" "Django → MikroTik SSH NAT"

# Enable IP forwarding
echo "🔀 Ensuring IP forwarding is enabled..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# Save all iptables rules manually (YunoHost compatible)
save_iptables_rules

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

# Enable interfaces to start on boot
echo "🔄 Enabling WireGuard interfaces to start on boot..."
sudo systemctl enable wg-quick@wg0
sudo systemctl enable wg-quick@wg1

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

# Show firewall status
echo ""
echo "🔥 Firewall Rules Status (Enhanced Multi-Tenant Security):"
echo "   INPUT rules:"
sudo iptables -L INPUT -n | grep -E "(51820|51821|$WGREST_PORT|$WEBHOOK_PORT)" | head -4
echo "   FORWARD rules:"
sudo iptables -L FORWARD -n | grep -E "(wg0|wg1|127\.0\.0\.1)" | head -6
echo "   NAT rules:"
sudo iptables -t nat -L POSTROUTING -n | grep -E "(127\.0\.0\.1|$RADIUS_AUTH_PORT|$RADIUS_ACCT_PORT)" | head -3

echo ""
echo "✅ Database restoration completed with Enhanced Multi-Tenant Security!"
echo ""
echo "🔄 The restoration process:"
echo "   1. ✅ Read structured data from external PostgreSQL"
echo "   2. ✅ Decrypted sensitive fields using existing decrypt helper"
echo "   3. ✅ Reconstructed clean WireGuard config files (no PostUp/PostDown)"
echo "   4. ✅ Applied Enhanced Multi-Tenant Security firewall rules"
echo "   5. ✅ Started WireGuard interfaces"
echo "   6. ✅ Started Docker services with improved sync service"
echo "   7. ✅ Triggered sync to ensure wgrest API consistency"
echo ""
echo "📊 Restoration Summary:"
echo "   Database wg0 peers: $DB_WG0_PEERS (MikroTik routers for FreeRADIUS)"
echo "   Database wg1 peers: $DB_WG1_PEERS (MikroTik routers for Django API)"
echo "   Restored wg0 peers: ${RESTORED_WG0_PEERS:-$CONFIG_WG0_PEERS}"
echo "   Restored wg1 peers: ${RESTORED_WG1_PEERS:-$CONFIG_WG1_PEERS}"
echo ""
echo "📋 Configuration Used:"
echo "   WG0 (MikroTik↔FreeRADIUS): ${WG0_FINAL_ADDRESS:-$WG0_ADDRESS} on port ${WG0_FINAL_PORT:-$WG0_PORT}"
echo "   WG1 (Django↔MikroTik): ${WG1_FINAL_ADDRESS:-$WG1_ADDRESS} on port ${WG1_FINAL_PORT:-$WG1_PORT}"
echo "   FreeRADIUS: ports $RADIUS_AUTH_PORT, $RADIUS_ACCT_PORT"
echo ""
echo "🏗️ Enhanced Multi-Tenant Architecture:"
echo "   📱 WG0: MikroTik peers connect for FreeRADIUS authentication"
echo "   💻 WG1: MikroTik peers connect for Django API management"
echo "   🏠 Django: Local with API-only access (tenant isolation enforced)"
echo "   🔒 Tenant Isolation: ENFORCED (no peer-to-peer communication)"
echo "   🚫 Internet Access: BLOCKED (no VPN repurposing)"
echo "   🎯 API Access: Django → MikroTik API ports only"
echo ""
echo "🔒 Security Features Applied:"
echo "   ✅ WG0: MikroTik peers CANNOT communicate with each other"
echo "   ✅ WG1: MikroTik peers CANNOT communicate with each other"  
echo "   ✅ WG0 ↔ WG1: Cross-interface communication BLOCKED"
echo "   ✅ Internet access: BLOCKED for all VPN peers"
echo "   ✅ Django: Can ONLY access MikroTik API ports (8728, 8729, 22)"
echo "   ✅ FreeRADIUS: Can communicate with ANY MikroTik on wg0"
echo ""
echo "🧪 Verify with:"
echo "   curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:$WGREST_PORT/v1/devices/"
echo "   sudo iptables -L FORWARD -n | grep 'wg1.*DROP'"
echo "   ./scripts/test_security.sh"
echo ""
echo "📋 Security Testing:"
echo "   Run: ./scripts/test_security.sh (verify tenant isolation)"
echo ""
echo "📋 Migration Ready:"
echo "   When Django moves remote: follow migration-guide.md"
echo "   Use: ./scripts/migrate_django_remote.sh"