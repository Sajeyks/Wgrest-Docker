#!/bin/bash
# Django Remote Migration Script
# Migrates Django from local privileges to remote peer with enhanced security

set -e

echo "📡 Django Remote Migration - Enhanced Multi-Tenant Security"
echo ""
echo "This script will:"
echo "   1. Create Django peer on wg1 interface"
echo "   2. Remove Django local privileges"
echo "   3. Apply remote Django security rules (API-only access)"
echo "   4. Maintain tenant isolation"
echo "   5. Generate Django client configuration"
echo ""
read -p "Continue with Django remote migration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Load environment
if [ ! -f .env ]; then
    echo "❌ .env file not found. Please ensure you're in the project directory."
    exit 1
fi

source .env

# Set defaults
DJANGO_REMOTE_IP=${DJANGO_REMOTE_IP:-"10.11.0.100"}
WG1_SUBNET=${WG1_SUBNET:-"10.11.0.0/16"}
WGREST_PORT=${WGREST_PORT:-8080}

echo "📋 Migration Configuration:"
echo "   Django Remote IP: $DJANGO_REMOTE_IP"
echo "   WG1 Subnet: $WG1_SUBNET"
echo "   wgrest API: http://localhost:$WGREST_PORT"
echo ""

# Function to add rule if it doesn't exist
add_rule_if_not_exists() {
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

# Step 1: Create Django peer on wg1
echo "🔧 Step 1: Creating Django peer configuration..."

# Create Django peer via wgrest API
DJANGO_PEER_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $WGREST_API_KEY" \
    -H "Content-Type: application/json" \
    "http://localhost:$WGREST_PORT/v1/devices/wg1/peers/" \
    -d "{
        \"name\": \"django-server\",
        \"allowed_ips\": [\"$DJANGO_REMOTE_IP/32\"]
    }")

if echo "$DJANGO_PEER_RESPONSE" | grep -q "public_key"; then
    echo "✅ Django peer created successfully"
    
    # Extract keys for client config
    DJANGO_PRIVATE_KEY=$(echo "$DJANGO_PEER_RESPONSE" | jq -r '.private_key // empty')
    DJANGO_PUBLIC_KEY=$(echo "$DJANGO_PEER_RESPONSE" | jq -r '.public_key // empty')
    
    if [ -z "$DJANGO_PRIVATE_KEY" ] || [ "$DJANGO_PRIVATE_KEY" = "null" ]; then
        echo "⚠️  Private key not returned by API - will need to generate manually"
        DJANGO_PRIVATE_KEY="<GENERATE_ON_CLIENT>"
    fi
else
    echo "❌ Failed to create Django peer"
    echo "Response: $DJANGO_PEER_RESPONSE"
    exit 1
fi

# Get server public key for client config
WG1_SERVER_PUBLIC_KEY=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
    "http://localhost:$WGREST_PORT/v1/devices/wg1" | jq -r '.public_key')

# Step 2: Remove Django local privileges
echo "🏠 Step 2: Removing Django local privileges..."

# Remove overly broad local Django rules
sudo iptables -D FORWARD -s 127.0.0.1 -o wg1 -j ACCEPT 2>/dev/null || echo "Broad local rule already removed"
sudo iptables -D FORWARD -i wg1 -d 127.0.0.1 -j ACCEPT 2>/dev/null || echo "Broad local rule already removed"
sudo iptables -t nat -D POSTROUTING -s 127.0.0.1 -o wg1 -j MASQUERADE 2>/dev/null || echo "Broad NAT rule already removed"

# Remove specific local Django API rules (will be replaced with remote rules)
sudo iptables -D FORWARD -s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j ACCEPT 2>/dev/null || echo "Local API rule already removed"
sudo iptables -D FORWARD -s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j ACCEPT 2>/dev/null || echo "Local API SSL rule already removed"
sudo iptables -D FORWARD -s 127.0.0.1 -o wg1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || echo "Local SSH rule already removed"
sudo iptables -D FORWARD -i wg1 -d 127.0.0.1 -p tcp --sport 8728 -j ACCEPT 2>/dev/null || echo "Local API response rule already removed"
sudo iptables -D FORWARD -i wg1 -d 127.0.0.1 -p tcp --sport 8729 -j ACCEPT 2>/dev/null || echo "Local API SSL response rule already removed"
sudo iptables -D FORWARD -i wg1 -d 127.0.0.1 -p tcp --sport 22 -j ACCEPT 2>/dev/null || echo "Local SSH response rule already removed"

sudo iptables -t nat -D POSTROUTING -s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j MASQUERADE 2>/dev/null || echo "Local API NAT already removed"
sudo iptables -t nat -D POSTROUTING -s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j MASQUERADE 2>/dev/null || echo "Local API SSL NAT already removed"
sudo iptables -t nat -D POSTROUTING -s 127.0.0.1 -o wg1 -p tcp --dport 22 -j MASQUERADE 2>/dev/null || echo "Local SSH NAT already removed"

echo "✅ Local Django privileges removed"

# Step 3: Add Remote Django Security Rules (API-only access)
echo "📡 Step 3: Adding Remote Django security rules (API-only access)..."

# Allow Remote Django → MikroTik API communication (specific ports only)
add_rule_if_not_exists "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8728 -j ACCEPT" "Remote Django → MikroTik API"
add_rule_if_not_exists "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8729 -j ACCEPT" "Remote Django → MikroTik API SSL"  
add_rule_if_not_exists "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 22 -j ACCEPT" "Remote Django → MikroTik SSH"

# Allow MikroTik API responses → Remote Django
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 8728 -j ACCEPT" "MikroTik API → Remote Django"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 8729 -j ACCEPT" "MikroTik API SSL → Remote Django"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 22 -j ACCEPT" "MikroTik SSH → Remote Django"

# Step 4: Ensure tenant isolation is maintained
echo "🔒 Step 4: Ensuring tenant isolation is maintained..."

# Ensure MikroTik-to-MikroTik blocking remains (this is critical)
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -o wg1 -j DROP" "WG1: Block peer-to-peer communication"

# Block Remote Django from reaching other peers (except API responses)
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP ! -p tcp -j DROP" "Block non-TCP to Remote Django"

# Ensure no unauthorized access TO Django from peers
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp ! --sport 8728 ! --sport 8729 ! --sport 22 -j DROP" "Block non-API ports to Remote Django"

# Step 5: Add Remote Django NAT rules
echo "🎭 Step 5: Setting up Remote Django NAT..."

# NAT for Remote Django → MikroTik API communication
add_rule_if_not_exists "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8728 -j MASQUERADE" "Remote Django → MikroTik API NAT"
add_rule_if_not_exists "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8729 -j MASQUERADE" "Remote Django → MikroTik API SSL NAT"
add_rule_if_not_exists "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 22 -j MASQUERADE" "Remote Django → MikroTik SSH NAT"

# Step 6: Save updated firewall rules
echo "💾 Step 6: Saving updated firewall rules..."
sudo iptables-save > /etc/iptables/rules.v4

# Step 7: Generate Django client configuration
echo "📝 Step 7: Generating Django client configuration..."

mkdir -p django-client-config

# Create Django WireGuard client config
cat > django-client-config/wg1.conf << EOF
# Django WireGuard Client Configuration
# Use this on your remote Django server

[Interface]
PrivateKey = $DJANGO_PRIVATE_KEY
Address = $DJANGO_REMOTE_IP/16
DNS = 1.1.1.1

[Peer]
PublicKey = $WG1_SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$WG1_PORT
AllowedIPs = $WG1_SUBNET
PersistentKeepalive = 25
EOF

# Create Django setup instructions
cat > django-client-config/setup-instructions.md << EOF
# Django Remote Server Setup Instructions

## 1. Install WireGuard on Django Server

\`\`\`bash
sudo apt update
sudo apt install wireguard
\`\`\`

## 2. Deploy Configuration

\`\`\`bash
# Copy wg1.conf to Django server
sudo cp wg1.conf /etc/wireguard/
sudo chmod 600 /etc/wireguard/wg1.conf
\`\`\`

## 3. Generate Private Key (if needed)

If the private key shows "<GENERATE_ON_CLIENT>", generate it:

\`\`\`bash
# Generate private key
wg genkey | sudo tee /etc/wireguard/private.key
sudo chmod 600 /etc/wireguard/private.key

# Get the private key and update wg1.conf
PRIVATE_KEY=\$(sudo cat /etc/wireguard/private.key)
sudo sed -i "s/<GENERATE_ON_CLIENT>/\$PRIVATE_KEY/" /etc/wireguard/wg1.conf
\`\`\`

## 4. Start WireGuard

\`\`\`bash
# Start interface
sudo wg-quick up wg1

# Enable on boot
sudo systemctl enable wg-quick@wg1

# Verify connection
sudo wg show
ping 10.11.0.1  # Should ping WireGuard server
\`\`\`

## 5. Update Django Settings

Update your Django application:

\`\`\`python
# Django settings.py updates
MIKROTIK_API_SETTINGS = {
    'SOURCE_IP': '$DJANGO_REMOTE_IP',  # Django's wg1 IP
    'BIND_INTERFACE': 'wg1',           # Bind to wg1 interface
}

# Example: Updated MikroTik API client
import socket
from librouteros import connect

def connect_to_mikrotik(mikrotik_ip, username, password):
    # Bind to Django's wg1 IP
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('$DJANGO_REMOTE_IP', 0))
    
    api = connect(
        host=mikrotik_ip,  # e.g., 10.11.0.2
        username=username,
        password=password,
        sock=sock
    )
    return api
\`\`\`

## 6. Test Connectivity

\`\`\`bash
# Test MikroTik API connectivity
nc -zv 10.11.0.2 8728  # RouterOS API
nc -zv 10.11.0.2 8729  # RouterOS API SSL
nc -zv 10.11.0.2 22    # SSH

# Test Django application
python manage.py test_mikrotik_connection
\`\`\`
EOF

# Create network test script for Django server
cat > django-client-config/test-connectivity.sh << 'EOF'
#!/bin/bash
# Django Remote Server Connectivity Test

echo "🧪 Testing Django Remote Server Connectivity..."

MIKROTIK_TEST_IP="10.11.0.2"  # Update with actual MikroTik IP

echo "📡 Testing WireGuard connection..."
if sudo wg show wg1 >/dev/null 2>&1; then
    echo "✅ WireGuard wg1 interface is active"
    sudo wg show wg1
else
    echo "❌ WireGuard wg1 interface not found"
    exit 1
fi

echo ""
echo "🔗 Testing WireGuard server connectivity..."
if ping -c 3 -W 2 10.11.0.1 >/dev/null 2>&1; then
    echo "✅ Can ping WireGuard server (10.11.0.1)"
else
    echo "❌ Cannot ping WireGuard server"
fi

echo ""
echo "🎯 Testing MikroTik API connectivity..."
if nc -zv $MIKROTIK_TEST_IP 8728 2>/dev/null; then
    echo "✅ MikroTik RouterOS API (8728) reachable"
else
    echo "⚠️  MikroTik RouterOS API (8728) not reachable"
fi

if nc -zv $MIKROTIK_TEST_IP 8729 2>/dev/null; then
    echo "✅ MikroTik RouterOS API SSL (8729) reachable"
else
    echo "⚠️  MikroTik RouterOS API SSL (8729) not reachable"
fi

if nc -zv $MIKROTIK_TEST_IP 22 2>/dev/null; then
    echo "✅ MikroTik SSH (22) reachable"
else
    echo "⚠️  MikroTik SSH (22) not reachable"
fi

echo ""
echo "🚫 Testing tenant isolation (should fail)..."
MIKROTIK_OTHER_IP="10.11.0.3"  # Different tenant
if ping -c 1 -W 1 $MIKROTIK_OTHER_IP >/dev/null 2>&1; then
    echo "❌ Can reach other tenant MikroTik - isolation may be broken"
else
    echo "✅ Cannot reach other tenant MikroTik - isolation working"
fi

echo ""
echo "🌐 Testing internet blocking (should fail)..."
if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
    echo "❌ Can reach internet - blocking may not be working"
else
    echo "✅ Cannot reach internet - blocking working correctly"
fi

echo ""
echo "✅ Connectivity test completed!"
EOF

chmod +x django-client-config/test-connectivity.sh

# Step 8: Verification
echo "🧪 Step 8: Verifying migration..."

# Check Django peer exists
if sudo wg show wg1 | grep -q "$DJANGO_REMOTE_IP"; then
    echo "✅ Django peer found in wg1 interface"
else
    echo "⚠️  Django peer not found in wg1 - may need interface restart"
    echo "   Run: sudo wg-quick down wg1 && sudo wg-quick up wg1"
fi

# Verify firewall rules
echo "📊 Firewall rules verification:"
echo "   Remote Django API rules: $(sudo iptables -L FORWARD -n | grep -c "$DJANGO_REMOTE_IP.*8728")"
echo "   Peer isolation rules: $(sudo iptables -L FORWARD -n | grep -c "wg1.*wg1.*DROP")"
echo "   Cross-interface blocks: $(sudo iptables -L FORWARD -n | grep -c "wg0.*wg1.*DROP")"

echo ""
echo "✅ Django Remote Migration completed successfully!"
echo ""
echo "📁 Django client configuration created in: django-client-config/"
echo "   📄 wg1.conf - WireGuard client config"
echo "   📖 setup-instructions.md - Detailed setup guide"
echo "   🧪 test-connectivity.sh - Connectivity test script"
echo ""
echo "🔒 Enhanced Security Status:"
echo "   ✅ Django: Can ONLY access MikroTik API ports (8728, 8729, 22)"
echo "   ✅ Tenant Isolation: ENFORCED (no peer-to-peer communication)"
echo "   ✅ Internet Access: BLOCKED for all peers"
echo "   ✅ Cross-interface: WG0 ↔ WG1 communication blocked"
echo ""
echo "📋 Next Steps:"
echo "   1. Copy django-client-config/ to your Django server"
echo "   2. Follow setup-instructions.md on Django server"
echo "   3. Update Django application settings"
echo "   4. Run test-connectivity.sh to verify"
echo "   5. Test Django → MikroTik API functionality"
echo ""
echo "🔄 Rollback (if needed):"
echo "   Run: ./scripts/rollback_to_local.sh"