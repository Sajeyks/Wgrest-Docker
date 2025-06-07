#!/bin/bash
set -e

echo "🚀 Setting up WireGuard with External Database Backup..."

# Load environment
if [ ! -f .env ]; then
    echo "❌ .env file not found. Please create it first."
    exit 1
fi

source .env

# Test external database connection
echo "🔍 Testing external database connection..."
if ! psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT 1;" &>/dev/null; then
    echo "❌ Cannot connect to external database"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   User: $DB_USER"
    echo ""
    echo "Please ensure:"
    echo "   1. PostgreSQL server is running and accessible"
    echo "   2. Database '$DB_NAME' exists"
    echo "   3. User '$DB_USER' has access to the database"
    echo "   4. Network connectivity is working"
    echo ""
    echo "To create the database schema, run:"
    echo "   psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f sql/init.sql"
    exit 1
fi

echo "✅ External database connection successful"

# Check if database schema exists
TABLES_EXIST=$(psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('interfaces', 'peers', 'server_keys', 'sync_status');" | xargs)

if [ "$TABLES_EXIST" -lt 4 ]; then
    echo "🗄️  Setting up database schema..."
    if ! psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f sql/init.sql; then
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

# Generate WireGuard keys
echo "🔑 Generating WireGuard keys..."
WG0_PRIVATE=$(wg genkey)
WG0_PUBLIC=$(echo $WG0_PRIVATE | wg pubkey)
WG1_PRIVATE=$(wg genkey)
WG1_PUBLIC=$(echo $WG1_PRIVATE | wg pubkey)

# Store keys in database
echo "💾 Storing server keys in database..."
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME << EOF
INSERT INTO server_keys (interface_name, private_key, public_key) 
VALUES ('wg0', '$WG0_PRIVATE', '$WG0_PUBLIC')
ON CONFLICT (interface_name) DO UPDATE SET
    private_key = EXCLUDED.private_key,
    public_key = EXCLUDED.public_key,
    generated_at = CURRENT_TIMESTAMP;

INSERT INTO server_keys (interface_name, private_key, public_key) 
VALUES ('wg1', '$WG1_PRIVATE', '$WG1_PUBLIC')
ON CONFLICT (interface_name) DO UPDATE SET
    private_key = EXCLUDED.private_key,
    public_key = EXCLUDED.public_key,
    generated_at = CURRENT_TIMESTAMP;
EOF

# Create initial WireGuard configs
echo "📝 Creating initial WireGuard configurations..."
sudo mkdir -p /etc/wireguard

# wg0 config (FreeRADIUS)
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
EOF

# wg1 config (MikroTik)  
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

# Setup iptables rules
echo "🔥 Setting up firewall rules..."
sudo iptables -A INPUT -p udp --dport $WG0_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p udp --dport $WG1_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p tcp --dport $WGREST_PORT -j ACCEPT 2>/dev/null || true

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Start services
echo "🚀 Starting Docker services..."
docker-compose up -d

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 30

# Test wgrest API
echo "🧪 Testing wgrest API..."
if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/api/v1/interfaces >/dev/null; then
    echo "✅ wgrest API is responding"
else
    echo "❌ wgrest API is not responding"
    docker-compose logs wgrest
    exit 1
fi

# Check sync service
echo "🔄 Checking sync service..."
sleep 10
if docker-compose logs wgrest-sync | grep -q "Sync completed\|Connected to PostgreSQL"; then
    echo "✅ Sync service is working"
else
    echo "⚠️  Sync service may still be starting..."
    docker-compose logs wgrest-sync
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   🌐 wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   🔑 API Key: $WGREST_API_KEY"
echo "   🔑 wg0 Public Key: $WG0_PUBLIC"
echo "   🔑 wg1 Public Key: $WG1_PUBLIC"
echo "   🗄️  External Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo ""
echo "🔧 Next steps:"
echo "   1. Configure your Django app to use this wgrest API"
echo "   2. Create peers via Django -> wgrest API"
echo "   3. Database automatically syncs every 60 seconds"
echo ""
echo "💾 Backup strategy:"
echo "   - Backup external PostgreSQL database: pg_dump $DB_NAME"
echo "   - Restoration: restore database + run './scripts/restore.sh'"
```iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
EOF

# Set permissions
sudo chmod 600 /etc/wireguard/wg*.conf

# Setup iptables rules
echo "🔥 Setting up firewall rules..."
sudo iptables -A INPUT -p udp --dport $WG0_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p udp --dport $WG1_PORT -j ACCEPT 2>/dev/null || true
sudo iptables -A INPUT -p tcp --dport $WGREST_PORT -j ACCEPT 2>/dev/null || true

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Start services
echo "🚀 Starting Docker services..."
docker-compose up -d

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 30

# Test wgrest API
echo "🧪 Testing wgrest API..."
if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/api/v1/interfaces >/dev/null; then
    echo "✅ wgrest API is responding"
else
    echo "❌ wgrest API is not responding"
    docker-compose logs wgrest
    exit 1
fi

# Check sync service
echo "🔄 Checking sync service..."
sleep 10
if docker-compose logs wgrest-sync | grep -q "Sync completed"; then
    echo "✅ Sync service is working"
else
    echo "⚠️  Sync service may still be starting..."
    docker-compose logs wgrest-sync
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   🌐 wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   🔑 API Key: $WGREST_API_KEY"
echo "   🔑 wg0 Public Key: $WG0_PUBLIC"
echo "   🔑 wg1 Public Key: $WG1_PUBLIC"
echo "   🗄️  Database: localhost:5432/wgrest_backup"
echo ""
echo "🔧 Next steps:"
echo "   1. Configure your Django app to use this wgrest API"
echo "   2. Create peers via Django -> wgrest API"
echo "   3. Database automatically syncs every 60 seconds"
echo ""
echo "💾 Backup strategy:"
echo "   - Backup PostgreSQL database: pg_dump wgrest_backup"
echo "   - Restoration: restore database + run './scripts/restore.sh'"