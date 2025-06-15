#!/bin/bash
set -e

echo "🚀 Setting up WireGuard with Django Local Privileges Architecture..."

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

# Validate all required variables
validate_env_var "SERVER_IP"
validate_env_var "WG0_PORT"
validate_env_var "WG1_PORT"
validate_env_var "WGREST_PORT"

# Set defaults for subnet/address variables if not provided
WG0_SUBNET=${WG0_SUBNET:-"10.10.0.0/16"}
WG0_ADDRESS=${WG0_ADDRESS:-"10.10.0.1/16"}
WG1_SUBNET=${WG1_SUBNET:-"10.11.0.0/16"}
WG1_ADDRESS=${WG1_ADDRESS:-"10.11.0.1/16"}
RADIUS_AUTH_PORT=${RADIUS_AUTH_PORT:-"1812"}
RADIUS_ACCT_PORT=${RADIUS_ACCT_PORT:-"1813"}
WEBHOOK_PORT=${WEBHOOK_PORT:-"8090"}

echo "📋 Django Local Privileges Configuration:"
echo "   Server IP: $SERVER_IP"
echo "   WG0 (MikroTik↔FreeRADIUS): $WG0_ADDRESS on port $WG0_PORT (subnet: $WG0_SUBNET)"
echo "   WG1 (Django↔MikroTik): $WG1_ADDRESS on port $WG1_PORT (subnet: $WG1_SUBNET)"
echo "   wgrest Port: $WGREST_PORT"
echo "   Webhook Port: $WEBHOOK_PORT"
echo "   FreeRADIUS Ports: $RADIUS_AUTH_PORT, $RADIUS_ACCT_PORT"
echo "   Django: Local privileges (no peer config needed)"
echo ""

# Test external database connection
echo "🔍 Testing external database connection..."
if ! psql -c "SELECT 1;" &>/dev/null; then
    echo "❌ Cannot connect to external database"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   User: $DB_USER"
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

# Manual iptables persistence for YunoHost compatibility
echo "📦 Setting up manual iptables persistence (YunoHost compatible)..."

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

# Generate WireGuard keys
echo "🔑 Generating WireGuard keys..."
WG0_PRIVATE=$(wg genkey)
WG0_PUBLIC=$(echo $WG0_PRIVATE | wg pubkey)
WG1_PRIVATE=$(wg genkey)
WG1_PUBLIC=$(echo $WG1_PRIVATE | wg pubkey)

echo "🔐 Keys will be encrypted and stored by sync service after configs are created"

# Create initial WireGuard configurations (NO PostUp/PostDown - using persistent rules)
echo "📝 Creating clean WireGuard configurations..."
sudo mkdir -p /etc/wireguard

# Backup existing configs if they exist
if [ -f /etc/wireguard/wg0.conf ]; then
    sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.backup.$(date +%s)
fi
if [ -f /etc/wireguard/wg1.conf ]; then
    sudo cp /etc/wireguard/wg1.conf /etc/wireguard/wg1.conf.backup.$(date +%s)
fi

# wg0 config (MikroTik ↔ FreeRADIUS)
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = $WG0_ADDRESS
ListenPort = $WG0_PORT
EOF

# wg1 config (Django ↔ MikroTik)
sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = $WG1_ADDRESS
ListenPort = $WG1_PORT
EOF

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

# Setup correct firewall rules for Django Local Privileges architecture
echo "🔥 Setting up firewall rules for Django Local Privileges..."

# INPUT rules for WireGuard ports and services (keep existing - these are correct)
add_persistent_rule "filter" "INPUT" "-p udp --dport $WG0_PORT -j ACCEPT" "WG0 UDP (MikroTik connections)"
add_persistent_rule "filter" "INPUT" "-p udp --dport $WG1_PORT -j ACCEPT" "WG1 UDP (Django connections)"
add_persistent_rule "filter" "INPUT" "-p tcp --dport $WGREST_PORT -j ACCEPT" "wgrest API"
add_persistent_rule "filter" "INPUT" "-p tcp --dport $WEBHOOK_PORT -j ACCEPT" "webhook"

# FORWARD rules for WG0: MikroTik ↔ FreeRADIUS (bidirectional)
echo "🔀 Setting up WG0 FORWARD rules (MikroTik ↔ FreeRADIUS)..."
add_persistent_rule "filter" "FORWARD" "-i wg0 -d 127.0.0.1 -p udp --dport $RADIUS_AUTH_PORT -j ACCEPT" "MikroTik → FreeRADIUS auth"
add_persistent_rule "filter" "FORWARD" "-i wg0 -d 127.0.0.1 -p udp --dport $RADIUS_ACCT_PORT -j ACCEPT" "MikroTik → FreeRADIUS acct"
add_persistent_rule "filter" "FORWARD" "-o wg0 -s 127.0.0.1 -p udp --sport $RADIUS_AUTH_PORT -j ACCEPT" "FreeRADIUS auth → MikroTik"
add_persistent_rule "filter" "FORWARD" "-o wg0 -s 127.0.0.1 -p udp --sport $RADIUS_ACCT_PORT -j ACCEPT" "FreeRADIUS acct → MikroTik"

# FORWARD rules for WG1: Django (localhost) ↔ MikroTik (bidirectional)
echo "🔀 Setting up WG1 FORWARD rules (Django local ↔ MikroTik)..."
add_persistent_rule "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -j ACCEPT" "Django (local) → MikroTik"
add_persistent_rule "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -j ACCEPT" "MikroTik → Django (local)"

# Block general internet access for security
echo "🔒 Blocking general internet access..."
add_persistent_rule "filter" "FORWARD" "-i wg0 ! -d 127.0.0.1 -j DROP" "Block WG0 internet access"
add_persistent_rule "filter" "FORWARD" "-i wg1 ! -d 127.0.0.1 -j DROP" "Block WG1 internet access"

# NAT rules: Minimal masquerading for required services only
echo "🎭 Setting up minimal NAT rules..."
add_persistent_rule "nat" "POSTROUTING" "-s 10.10.0.0/16 -d 127.0.0.1 -p udp --dport $RADIUS_AUTH_PORT -j MASQUERADE" "WG0 → FreeRADIUS auth NAT"
add_persistent_rule "nat" "POSTROUTING" "-s 10.10.0.0/16 -d 127.0.0.1 -p udp --dport $RADIUS_ACCT_PORT -j MASQUERADE" "WG0 → FreeRADIUS acct NAT"
add_persistent_rule "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -j MASQUERADE" "Django (local) → MikroTik NAT"

# Enable IP forwarding
echo "🔀 Enabling IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# Save all iptables rules manually (YunoHost compatible)
save_iptables_rules

# Start WireGuard interfaces
echo "🚀 Starting WireGuard interfaces..."

# Start wg0
if sudo wg-quick up wg0; then
    echo "✅ wg0 interface started successfully on $WG0_ADDRESS:$WG0_PORT"
else
    echo "❌ Failed to start wg0 interface"
    exit 1
fi

# Start wg1
if sudo wg-quick up wg1; then
    echo "✅ wg1 interface started successfully on $WG1_ADDRESS:$WG1_PORT"
else
    echo "❌ Failed to start wg1 interface"
    exit 1
fi

# Enable interfaces to start on boot
echo "🔄 Enabling WireGuard interfaces to start on boot..."
sudo systemctl enable wg-quick@wg0
sudo systemctl enable wg-quick@wg1

# Clean up any existing containers
echo "🧹 Cleaning up existing containers..."
docker-compose down 2>/dev/null || true

# Build and start services
echo "🔨 Building and starting Docker services..."
echo "   This may take a few minutes as we build wgrest from source..."
docker-compose up -d --build

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 45

# Test wgrest API
echo "🧪 Testing wgrest API..."
API_RETRIES=0
MAX_RETRIES=6

while [ $API_RETRIES -lt $MAX_RETRIES ]; do
    if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/v1/devices/ >/dev/null; then
        echo "✅ wgrest API is responding on port $WGREST_PORT"
        break
    else
        echo "⏳ wgrest API not ready yet, waiting... (attempt $((API_RETRIES + 1))/$MAX_RETRIES)"
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
    exit 1
fi

# Trigger initial sync
echo "🔄 Triggering initial sync..."
sleep 5

SYNC_RETRIES=0
MAX_SYNC_RETRIES=10

while [ $SYNC_RETRIES -lt $MAX_SYNC_RETRIES ]; do
    if curl -s -X POST -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WEBHOOK_PORT/sync | grep -q "sync_triggered"; then
        echo "✅ Initial sync triggered successfully"
        break
    else
        echo "⏳ Sync service not ready yet, waiting... (attempt $((SYNC_RETRIES + 1))/$MAX_SYNC_RETRIES)"
        sleep 10
        SYNC_RETRIES=$((SYNC_RETRIES + 1))
    fi
done

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

# Final verification
echo "🧪 Final verification..."
for interface in wg0 wg1; do
    PEER_COUNT=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
                      "http://localhost:$WGREST_PORT/v1/devices/$interface/peers/" 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "Interface $interface: $PEER_COUNT peers (expected: 0 for fresh install)"
done

echo ""
echo "🎉 Setup completed successfully with Django Local Privileges architecture!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   🌐 wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   🔑 API Key: $WGREST_API_KEY"
echo "   🔑 wg0 Public Key: $WG0_PUBLIC"
echo "   🔑 wg1 Public Key: $WG1_PUBLIC"
echo "   🗄️  External Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo ""
echo "🏗️ Architecture Summary:"
echo "   📱 WG0: MikroTik routers ↔ FreeRADIUS ($WG0_SUBNET)"
echo "   💻 WG1: Django (local) ↔ MikroTik routers ($WG1_SUBNET)"
echo "   🔒 Security: No general internet access allowed"
echo "   🏠 Django: Local privileges (direct interface access)"
echo ""
echo "🔗 WireGuard Interface Status:"
sudo wg show
echo ""
echo "🚀 Next steps:"
echo "   1. Configure Django to communicate with MikroTik via wg1 interface"
echo "   2. Create MikroTik peer configs for both wg0 and wg1"
echo "   3. Test MikroTik ↔ FreeRADIUS authentication"
echo "   4. Test Django ↔ MikroTik API communication"
echo ""
echo "📋 Migration ready:"
echo "   When Django moves remote, run migration guide in migration-guide.md"