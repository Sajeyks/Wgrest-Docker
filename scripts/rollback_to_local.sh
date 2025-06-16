#!/bin/bash
# Rollback Django to Local Script
# Reverts Django from remote peer back to local privileges with enhanced security

set -e

echo "🔄 Django Rollback to Local - Enhanced Multi-Tenant Security"
echo ""
echo "⚠️  This will:"
echo "   1. Remove Django remote peer from wg1"
echo "   2. Remove remote Django firewall rules"
echo "   3. Restore local Django API-only access"
echo "   4. Maintain enhanced tenant isolation"
echo ""
read -p "Continue with rollback to local Django? (y/N): " -n 1 -r
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
WGREST_PORT=${WGREST_PORT:-8080}

echo "📋 Rollback Configuration:"
echo "   Django Remote IP: $DJANGO_REMOTE_IP"
echo "   wgrest API: http://localhost:$WGREST_PORT"
echo ""

# Function to safely remove rules
safe_remove_rule() {
    local table=${1:-filter}
    local chain=$2
    local rule=$3
    local description=$4
    
    if [ "$table" = "nat" ]; then
        if sudo iptables -t nat -C $chain $rule 2>/dev/null; then
            sudo iptables -t nat -D $chain $rule
            echo "✅ Removed $description"
        else
            echo "ℹ️  $description (not found)"
        fi
    else
        if sudo iptables -C $chain $rule 2>/dev/null; then
            sudo iptables -D $chain $rule
            echo "✅ Removed $description"
        else
            echo "ℹ️  $description (not found)"
        fi
    fi
}

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

# Step 1: Find and remove Django remote peer
echo "🗑️  Step 1: Removing Django remote peer..."

# Get Django peer ID
DJANGO_PEER_ID=$(curl -s -H "Authorization: Bearer $WGREST_API_KEY" \
    "http://localhost:$WGREST_PORT/v1/devices/wg1/peers/" | \
    jq -r ".[] | select(.allowed_ips[]? | contains(\"$DJANGO_REMOTE_IP\")) | .id" 2>/dev/null | head -1)

if [ ! -z "$DJANGO_PEER_ID" ] && [ "$DJANGO_PEER_ID" != "null" ]; then
    echo "Found Django peer ID: $DJANGO_PEER_ID"
    
    DELETE_RESPONSE=$(curl -s -X DELETE \
        -H "Authorization: Bearer $WGREST_API_KEY" \
        "http://localhost:$WGREST_PORT/v1/devices/wg1/peers/$DJANGO_PEER_ID")
    
    if [ $? -eq 0 ]; then
        echo "✅ Django remote peer removed successfully"
    else
        echo "⚠️  Failed to remove Django peer via API"
    fi
else
    echo "ℹ️  Django remote peer not found (may already be removed)"
fi

# Step 2: Remove remote Django firewall rules
echo "🗑️  Step 2: Removing remote Django firewall rules..."

# Remove Remote Django → MikroTik API rules
safe_remove_rule "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8728 -j ACCEPT" "Remote Django → MikroTik API"
safe_remove_rule "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8729 -j ACCEPT" "Remote Django → MikroTik API SSL"
safe_remove_rule "filter" "FORWARD" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 22 -j ACCEPT" "Remote Django → MikroTik SSH"

# Remove MikroTik API → Remote Django rules
safe_remove_rule "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 8728 -j ACCEPT" "MikroTik API → Remote Django"
safe_remove_rule "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 8729 -j ACCEPT" "MikroTik API SSL → Remote Django"
safe_remove_rule "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp --sport 22 -j ACCEPT" "MikroTik SSH → Remote Django"

# Remove Remote Django protection rules
safe_remove_rule "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP ! -p tcp -j DROP" "Block non-TCP to Remote Django"
safe_remove_rule "filter" "FORWARD" "-i wg1 -d $DJANGO_REMOTE_IP -p tcp ! --sport 8728 ! --sport 8729 ! --sport 22 -j DROP" "Block non-API ports to Remote Django"

# Remove Remote Django NAT rules
safe_remove_rule "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8728 -j MASQUERADE" "Remote Django → MikroTik API NAT"
safe_remove_rule "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 8729 -j MASQUERADE" "Remote Django → MikroTik API SSL NAT"
safe_remove_rule "nat" "POSTROUTING" "-s $DJANGO_REMOTE_IP -o wg1 -p tcp --dport 22 -j MASQUERADE" "Remote Django → MikroTik SSH NAT"

# Step 3: Restore local Django API-only access
echo "🏠 Step 3: Restoring local Django API-only access..."

# Add local Django → MikroTik API rules (specific ports only)
add_rule_if_not_exists "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j ACCEPT" "Django → MikroTik API"
add_rule_if_not_exists "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j ACCEPT" "Django → MikroTik API SSL"
add_rule_if_not_exists "filter" "FORWARD" "-s 127.0.0.1 -o wg1 -p tcp --dport 22 -j ACCEPT" "Django → MikroTik SSH"

# Add MikroTik API → local Django rules
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 8728 -j ACCEPT" "MikroTik API → Django"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 8729 -j ACCEPT" "MikroTik API SSL → Django"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -d 127.0.0.1 -p tcp --sport 22 -j ACCEPT" "MikroTik SSH → Django"

# Add local Django NAT rules
add_rule_if_not_exists "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 8728 -j MASQUERADE" "Django → MikroTik API NAT"
add_rule_if_not_exists "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 8729 -j MASQUERADE" "Django → MikroTik API SSL NAT"
add_rule_if_not_exists "nat" "POSTROUTING" "-s 127.0.0.1 -o wg1 -p tcp --dport 22 -j MASQUERADE" "Django → MikroTik SSH NAT"

# Step 4: Ensure tenant isolation remains enforced
echo "🔒 Step 4: Verifying enhanced tenant isolation..."

# Ensure critical tenant isolation rules are still in place
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -o wg1 -j DROP" "WG1: Block peer-to-peer communication"
add_rule_if_not_exists "filter" "FORWARD" "-i wg0 -o wg0 -j DROP" "WG0: Block peer-to-peer communication"
add_rule_if_not_exists "filter" "FORWARD" "-i wg0 -o wg1 -j DROP" "Block WG0 → WG1"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 -o wg0 -j DROP" "Block WG1 → WG0"
add_rule_if_not_exists "filter" "FORWARD" "-i wg1 ! -d 127.0.0.1 -j DROP" "WG1: Block unauthorized traffic"
add_rule_if_not_exists "filter" "FORWARD" "-i wg0 ! -d 127.0.0.1 -j DROP" "WG0: Block internet access"

# Step 5: Save updated firewall rules
echo "💾 Step 5: Saving updated firewall rules..."
sudo iptables-save > /etc/iptables/rules.v4

# Step 6: Restart WireGuard interface to refresh peer list
echo "🔄 Step 6: Refreshing WireGuard interface..."
if sudo wg show wg1 >/dev/null 2>&1; then
    sudo wg-quick down wg1 2>/dev/null || true
    sleep 2
    sudo wg-quick up wg1
    echo "✅ WireGuard wg1 interface refreshed"
else
    echo "⚠️  WireGuard wg1 interface not found"
fi

# Step 7: Verification
echo "🧪 Step 7: Verifying rollback..."

# Check Django peer no longer exists
if sudo wg show wg1 | grep -q "$DJANGO_REMOTE_IP"; then
    echo "⚠️  Django remote peer still found in wg1 interface"
    echo "   May need manual removal or interface restart"
else
    echo "✅ Django remote peer removed from wg1 interface"
fi

# Verify firewall rules
echo "📊 Firewall rules verification:"
echo "   Local Django API rules: $(sudo iptables -L FORWARD -n | grep -c "127.0.0.1.*wg1.*8728")"
echo "   Remote Django rules removed: $(sudo iptables -L FORWARD -n | grep -c "$DJANGO_REMOTE_IP" || echo "0")"
echo "   Tenant isolation rules: $(sudo iptables -L FORWARD -n | grep -c "wg1.*wg1.*DROP")"

# Clean up client config directory if it exists
if [ -d "django-client-config" ]; then
    echo "🗑️  Cleaning up client configuration..."
    rm -rf django-client-config
    echo "✅ Client configuration directory removed"
fi

echo ""
echo "✅ Django Rollback to Local completed successfully!"
echo ""
echo "🔒 Enhanced Security Status Restored:"
echo "   ✅ Django: Local with API-only access (8728, 8729, 22)"
echo "   ✅ Tenant Isolation: ENFORCED (no peer-to-peer communication)"
echo "   ✅ Internet Access: BLOCKED for all peers"
echo "   ✅ Cross-interface: WG0 ↔ WG1 communication blocked"
echo ""
echo "🏠 Local Django Configuration:"
echo "   Django can now access MikroTik APIs directly from localhost"
echo "   No WireGuard client configuration needed on Django server"
echo "   API access limited to specific ports only"
echo ""
echo "📋 Next Steps:"
echo "   1. Update Django application to use localhost/127.0.0.1"
echo "   2. Remove WireGuard client from Django server (if deployed)"
echo "   3. Test Django → MikroTik API functionality"
echo "   4. Run security test: ./scripts/test_security.sh"
echo ""
echo "🔄 Migration (if needed again):"
echo "   Run: ./scripts/migrate_django_remote.sh"