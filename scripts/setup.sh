#!/bin/bash
set -e

echo "🚀 Setting up Simple WireGuard with wgrest..."

# Load environment
source .env

# Install Docker if needed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
fi

# Install Docker Compose if needed
if ! command -v docker-compose &> /dev/null; then
    echo "Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

# Generate WireGuard keys
echo "Generating WireGuard keys..."
WG0_PRIVATE=$(wg genkey)
WG0_PUBLIC=$(echo $WG0_PRIVATE | wg pubkey)
WG1_PRIVATE=$(wg genkey)
WG1_PUBLIC=$(echo $WG1_PRIVATE | wg pubkey)

# Create WireGuard configs
echo "Creating WireGuard configurations..."
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
echo "Setting up firewall rules..."
sudo iptables -A INPUT -p udp --dport $WG0_PORT -j ACCEPT
sudo iptables -A INPUT -p udp --dport $WG1_PORT -j ACCEPT
sudo iptables -A INPUT -p tcp --dport $WGREST_PORT -j ACCEPT
sudo iptables -A INPUT -p udp --dport 1812 -j ACCEPT  # FreeRADIUS auth
sudo iptables -A INPUT -p udp --dport 1813 -j ACCEPT  # FreeRADIUS accounting

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Create rclone config if R2 credentials provided
if [ ! -z "$R2_BUCKET" ]; then
    echo "Setting up backup configuration..."
    # You'll need to add your R2 credentials to rclone.conf manually
fi

# Start services
echo "Starting services..."
docker-compose up -d

# Wait for services
sleep 15

# Verify setup
echo "Verifying setup..."
echo "✅ Services status:"
docker-compose ps

echo ""
echo "🎯 Setup completed successfully!"
echo ""
echo "📊 Your WireGuard server details:"
echo "   wg0 Public Key: $WG0_PUBLIC"
echo "   wg1 Public Key: $WG1_PUBLIC"
echo "   wgrest API: http://$SERVER_IP:$WGREST_PORT"
echo "   API Key: $WGREST_API_KEY"
echo ""
echo "🔧 Next steps:"
echo "   1. Configure your Django app to use this wgrest API"
echo "   2. Test peer creation via API"
echo "   3. Set up R2 backup credentials (optional)"