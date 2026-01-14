#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

WGREST_PORT=${WGREST_PORT:-7070}
WGREST_API_KEY=${WGREST_API_KEY:-}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; exit 1; }

if [ -z "$DJANGO_API_URL" ] || [ -z "$DJANGO_API_TOKEN" ]; then
    error "DJANGO_API_URL and DJANGO_API_TOKEN must be set in .env"
fi

log "Fetching configuration from Django..."
CONFIG=$(curl -sf -H "Authorization: Token $DJANGO_API_TOKEN" "$DJANGO_API_URL/api/wireguard/export/")

if [ -z "$CONFIG" ]; then
    error "Failed to fetch config from Django API"
fi

log "Restoring server configurations..."

echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg0") | .private_key' > /tmp/wg0_key
echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg1") | .private_key' > /tmp/wg1_key

WG0_PRIVATE=$(cat /tmp/wg0_key)
WG1_PRIVATE=$(cat /tmp/wg1_key)
WG0_ADDRESS=$(echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg0") | .address')
WG1_ADDRESS=$(echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg1") | .address')
WG0_PORT=$(echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg0") | .listen_port')
WG1_PORT=$(echo "$CONFIG" | jq -r '.servers[] | select(.interface == "wg1") | .listen_port')

rm -f /tmp/wg0_key /tmp/wg1_key

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = $WG0_ADDRESS
ListenPort = $WG0_PORT
EOF

cat > /etc/wireguard/wg1.conf << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = $WG1_ADDRESS
ListenPort = $WG1_PORT
EOF

chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/wg1.conf

log "Restarting WireGuard interfaces..."
wg-quick down wg0 2>/dev/null || true
wg-quick down wg1 2>/dev/null || true
wg-quick up wg0
wg-quick up wg1

log "Waiting for wgrest API..."
sleep 3

log "Restoring peers..."
WG0_PEERS=$(echo "$CONFIG" | jq -c '.peers[] | select(.interface == "wg0")')
WG1_PEERS=$(echo "$CONFIG" | jq -c '.peers[] | select(.interface == "wg1")')

WG0_COUNT=0
WG1_COUNT=0

echo "$WG0_PEERS" | while read -r peer; do
    if [ -n "$peer" ]; then
        PUBLIC_KEY=$(echo "$peer" | jq -r '.public_key')
        ALLOWED_IPS=$(echo "$peer" | jq -r '.allowed_ips')
        NAME=$(echo "$peer" | jq -r '.name // empty')
        
        curl -sf -X POST \
            -H "Authorization: Bearer $WGREST_API_KEY" \
            -H "Content-Type: application/json" \
            "http://localhost:$WGREST_PORT/v1/devices/wg0/peers/" \
            -d "{\"public_key\": \"$PUBLIC_KEY\", \"allowed_ips\": [\"$ALLOWED_IPS\"], \"name\": \"$NAME\"}" \
            > /dev/null && ((WG0_COUNT++)) || true
    fi
done

echo "$WG1_PEERS" | while read -r peer; do
    if [ -n "$peer" ]; then
        PUBLIC_KEY=$(echo "$peer" | jq -r '.public_key')
        ALLOWED_IPS=$(echo "$peer" | jq -r '.allowed_ips')
        NAME=$(echo "$peer" | jq -r '.name // empty')
        
        curl -sf -X POST \
            -H "Authorization: Bearer $WGREST_API_KEY" \
            -H "Content-Type: application/json" \
            "http://localhost:$WGREST_PORT/v1/devices/wg1/peers/" \
            -d "{\"public_key\": \"$PUBLIC_KEY\", \"allowed_ips\": [\"$ALLOWED_IPS\"], \"name\": \"$NAME\"}" \
            > /dev/null && ((WG1_COUNT++)) || true
    fi
done

log "Restore complete"
log "Run ./scripts/test_security.sh to verify"