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

# Validate TARGET_WEBSITE_IP
if [ -z "$TARGET_WEBSITE_IP" ]; then
    echo "❌ TARGET_WEBSITE_IP not set in .env file"
    echo "   Please add: TARGET_WEBSITE_IP=1.2.3.4"
    exit 1
fi

echo "🔄 Starting restoration from external database..."
echo "📋 Configuration:"
echo "   Target Website IP: $TARGET_WEBSITE_IP"
echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo ""

# Stop services
echo "Stopping services..."
docker-compose down

# Check external database connection
echo "🔍 Checking external database connection..."
if ! psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT COUNT(*) FROM peers;" &>/dev/null; then
    echo "❌ Cannot connect to external database or no data found"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   Make sure:"
    echo "   1. Database server is accessible"
    echo "   2. Credentials are correct"
    echo "   3. Database has been restored from backup"
    exit 1
fi

# Get peer counts from database
WG0_PEERS=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" | xargs)
WG1_PEERS=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" | xargs)

echo "📊 Found in database:"
echo "   wg0: $WG0_PEERS peers"
echo "   wg1: $WG1_PEERS peers"

# Restore WireGuard configs from database
echo "📝 Restoring WireGuard configurations..."
sudo rm -f /etc/wireguard/wg*.conf

# Get server keys from database
WG0_PRIVATE=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT private_key FROM server_keys WHERE interface_name='wg0';" | xargs)
WG1_PRIVATE=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT private_key FROM server_keys WHERE interface_name='wg1';" | xargs)

# Restore wg0 config
WG0_CONFIG=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT config_content FROM interfaces WHERE name='wg0';" | sed 's/^[ \t]*//;s/[ \t]*$//')
if [ ! -z "$WG0_CONFIG" ] && [ "$WG0_CONFIG" != "" ]; then
    echo "$WG0_CONFIG" | sudo tee /etc/wireguard/wg0.conf > /dev/null
    echo "✅ wg0.conf restored from database"
else
    echo "⚠️  wg0.conf not found in database, creating basic config"
    if [ ! -z "$WG0_PRIVATE" ]; then
        sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
EOF
    fi
fi

# Restore wg1 config - FIXED to use TARGET_WEBSITE_IP
WG1_CONFIG=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT config_content FROM interfaces WHERE name='wg1';" | sed 's/^[ \t]*//;s/[ \t]*$//')
if [ ! -z "$WG1_CONFIG" ] && [ "$WG1_CONFIG" != "" ]; then
    echo "$WG1_CONFIG" | sudo tee /etc/wireguard/wg1.conf > /dev/null
    echo "✅ wg1.conf restored from database"
else
    echo "⚠️  wg1.conf not found in database, creating basic config"
    if [ ! -z "$WG1_PRIVATE" ]; then
        sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = 10.11.0.1/24
ListenPort = $WG1_PORT
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
EOF
    fi
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

# Wait for sync to complete (it will restore all peers to wgrest)
echo "🔄 Waiting for database sync to restore peers..."
sleep 30

# Verify restoration
echo "🧪 Verifying restoration..."
for interface in wg0 wg1; do
    PEER_COUNT=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
                      "http://localhost:$WGREST_PORT/v1/devices/$interface/peers/" 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "Interface $interface: $PEER_COUNT peers restored via API"
done

echo ""
echo "✅ Database restoration completed!"
echo ""
echo "🔄 The sync service automatically:"
echo "   1. Read all peer data from external PostgreSQL"
echo "   2. Recreated all peers in wgrest"  
echo "   3. Updated WireGuard configurations"
echo "   4. Started all tunnels"
echo ""
echo "🔗 WireGuard Interface Status:"
sudo wg show
echo ""
echo "🧪 Verify with: curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:$WGREST_PORT/v1/devices/"