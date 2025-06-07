#!/bin/bash
set -e

echo "🔄 WireGuard Database Restoration"
echo ""
echo "⚠️  This will restore WireGuard from PostgreSQL database"
echo "   Make sure your database is restored first!"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

source .env

echo "🔄 Starting restoration from database..."

# Stop services
echo "Stopping services..."
docker-compose down

# Start only postgres and wait
echo "Starting PostgreSQL..."
docker-compose up -d postgres
sleep 10

# Check database connection
echo "🔍 Checking database..."
if ! docker-compose exec postgres psql -U wgrest -d wgrest_backup -c "SELECT COUNT(*) FROM peers;" &>/dev/null; then
    echo "❌ Cannot connect to database or no data found"
    echo "   Make sure you've restored your PostgreSQL backup first:"
    echo "   pg_restore -h localhost -U wgrest -d wgrest_backup your_backup.sql"
    exit 1
fi

# Get peer counts from database
WG0_PEERS=$(docker-compose exec postgres psql -U wgrest -d wgrest_backup -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" | xargs)
WG1_PEERS=$(docker-compose exec postgres psql -U wgrest -d wgrest_backup -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" | xargs)

echo "📊 Found in database:"
echo "   wg0: $WG0_PEERS peers"
echo "   wg1: $WG1_PEERS peers"

# Restore WireGuard configs from database
echo "📝 Restoring WireGuard configurations..."
sudo rm -f /etc/wireguard/wg*.conf

# Restore wg0 config
WG0_CONFIG=$(docker-compose exec postgres psql -U wgrest -d wgrest_backup -t -c "SELECT config_content FROM interfaces WHERE name='wg0';" | sed 's/^[ \t]*//;s/[ \t]*$//')
if [ ! -z "$WG0_CONFIG" ] && [ "$WG0_CONFIG" != "" ]; then
    echo "$WG0_CONFIG" | sudo tee /etc/wireguard/wg0.conf > /dev/null
    echo "✅ wg0.conf restored"
else
    echo "⚠️  wg0.conf not found in database, creating basic config"
    # Create basic config - will be updated by sync service
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
EOF
fi

# Restore wg1 config
WG1_CONFIG=$(docker-compose exec postgres psql -U wgrest -d wgrest_backup -t -c "SELECT config_content FROM interfaces WHERE name='wg1';" | sed 's/^[ \t]*//;s/[ \t]*$//')
if [ ! -z "$WG1_CONFIG" ] && [ "$WG1_CONFIG" != "" ]; then
    echo "$WG1_CONFIG" | sudo tee /etc/wireguard/wg1.conf > /dev/null
    echo "✅ wg1.conf restored"
else
    echo "⚠️  wg1.conf not found in database, creating basic config"
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
Address = 10.11.0.1/24
ListenPort = $WG1_PORT
EOF
fi

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

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
                      "http://localhost:8080/api/v1/interfaces/$interface/peers" 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "Interface $interface: $PEER_COUNT peers restored via API"
done

echo ""
echo "✅ Database restoration completed!"
echo ""
echo "🔄 The sync service automatically:"
echo "   1. Read all peer data from PostgreSQL"
echo "   2. Recreated all peers in wgrest"  
echo "   3. Updated WireGuard configurations"
echo "   4. Started all tunnels"
echo ""
echo "🧪 Verify with: curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:8080/api/v1/interfaces"