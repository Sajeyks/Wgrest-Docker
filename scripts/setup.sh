#!/bin/bash
set -e

echo "🚀 Setting up WireGuard Docker (Database-Only Persistence)..."

# Load environment
if [ ! -f .env ]; then
    echo "❌ .env file not found. Please create it first."
    exit 1
fi

source .env

# Check if PostgreSQL database exists and is accessible
echo "📋 Checking PostgreSQL database..."
if ! psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1;" &>/dev/null; then
    echo "❌ Cannot connect to PostgreSQL database. Please ensure:"
    echo "   - PostgreSQL is running on $DB_HOST:$DB_PORT"
    echo "   - Database '$DB_NAME' exists"
    echo "   - User '$DB_USER' has access"
    exit 1
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

# Generate WireGuard keys if they don't exist in database
echo "🔑 Setting up WireGuard keys..."

# Check if wgrest has existing interface configs in database
WG0_EXISTS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "SELECT EXISTS(SELECT 1 FROM interfaces WHERE name='wg0');" 2>/dev/null | xargs || echo "false")
WG1_EXISTS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "SELECT EXISTS(SELECT 1 FROM interfaces WHERE name='wg1');" 2>/dev/null | xargs || echo "false")

if [ "$WG0_EXISTS" = "false" ] || [ "$WG1_EXISTS" = "false" ]; then
    echo "🔑 Generating new WireGuard keys..."
    WG0_PRIVATE=$(wg genkey)
    WG0_PUBLIC=$(echo $WG0_PRIVATE | wg pubkey)
    WG1_PRIVATE=$(wg genkey)
    WG1_PUBLIC=$(echo $WG1_PRIVATE | wg pubkey)
    
    echo "   wg0 Public Key: $WG0_PUBLIC"
    echo "   wg1 Public Key: $WG1_PUBLIC"
else
    echo "✅ Using existing keys from database"
fi

# Create initial WireGuard configs (wgrest will manage these)
echo "📝 Creating initial WireGuard configurations..."
sudo mkdir -p /etc/wireguard

# Basic wg0 config (peers will be added by wgrest)
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = ${WG0_PRIVATE:-PLACEHOLDER}
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
EOF

# Basic wg1 config (peers will be added by wgrest)  
sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = ${WG1_PRIVATE:-PLACEHOLDER}
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
sleep 15

# Test wgrest API
echo "🧪 Testing wgrest API..."
if curl -s -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:$WGREST_PORT/api/v1/interfaces >/dev/null; then
    echo "✅ wgrest API is responding"
else
    echo "❌ wgrest API is not responding"
    echo "📋 Service status:"
    docker-compose ps
    exit 1
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   🌐 wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   🔑 API Key: $WGREST_API_KEY"
echo "   📋 Database: $DB_HOST:$DB_PORT/$DB_NAME"
echo ""
echo "🔧 Next steps:"
echo "   1. Test API: curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:$WGREST_PORT/api/v1/interfaces"
echo "   2. Configure your Django app to use this wgrest API"
echo "   3. Create peers via Django -> wgrest API"
echo ""
echo "💾 Backup strategy:"
echo "   - Just backup your PostgreSQL database ($DB_NAME)"
echo "   - Restoration: restore database + run 'docker-compose up -d'"