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

# Set PostgreSQL environment variables to avoid password prompts
export PGHOST=$DB_HOST
export PGPORT=$DB_PORT
export PGUSER=$DB_USER
export PGPASSWORD=$DB_PASSWORD
export PGDATABASE=$DB_NAME

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
if ! psql -c "SELECT COUNT(*) FROM peers;" &>/dev/null; then
    echo "❌ Cannot connect to external database or no data found"
    echo "   Database: $DB_HOST:$DB_PORT/$DB_NAME"
    echo "   Make sure:"
    echo "   1. Database server is accessible"
    echo "   2. Credentials are correct"
    echo "   3. Database has been restored from backup"
    echo "   4. Password in .env file is correct"
    exit 1
fi

# Get peer counts from database
WG0_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg0';" | xargs)
WG1_PEERS=$(psql -t -c "SELECT COUNT(*) FROM peers WHERE interface_name='wg1';" | xargs)

echo "📊 Found in database:"
echo "   wg0: $WG0_PEERS peers"
echo "   wg1: $WG1_PEERS peers"

# Create decryption helper script
echo "🔧 Creating decryption helper..."
cat > /tmp/decrypt_helper.py << 'DECRYPT_SCRIPT'
#!/usr/bin/env python3
import os, sys, psycopg2, hashlib, base64, json
from cryptography.fernet import Fernet

def setup_encryption():
    WGREST_API_KEY = os.getenv('WGREST_API_KEY')
    ENCRYPTION_KEY = os.getenv('DB_ENCRYPTION_KEY')
    if not ENCRYPTION_KEY:
        key_material = hashlib.sha256(WGREST_API_KEY.encode()).digest()
        ENCRYPTION_KEY = base64.urlsafe_b64encode(key_material)
    return Fernet(ENCRYPTION_KEY)

def decrypt_field(cipher, encrypted_data):
    if not encrypted_data: 
        return None
    try: 
        return cipher.decrypt(encrypted_data.encode()).decode()
    except: 
        return encrypted_data

DATABASE_URL = os.getenv('DATABASE_URL')
conn = psycopg2.connect(DATABASE_URL)
cur = conn.cursor()
cipher = setup_encryption()

if sys.argv[1] == "server_key":
    cur.execute("SELECT private_key FROM server_keys WHERE interface_name = %s", (sys.argv[2],))
    result = cur.fetchone()
    if result: 
        print(decrypt_field(cipher, result[0]))

elif sys.argv[1] == "interface_data":
    cur.execute("SELECT address, listen_port FROM interfaces WHERE name = %s", (sys.argv[2],))
    result = cur.fetchone()
    if result: 
        print(f"{result[0]},{result[1]}")

elif sys.argv[1] == "peers":
    cur.execute("""
        SELECT public_key, preshared_key, allowed_ips, endpoint, persistent_keepalive 
        FROM peers 
        WHERE interface_name = %s AND enabled = true 
        ORDER BY name
    """, (sys.argv[2],))
    
    for row in cur.fetchall():
        print("[Peer]")
        print(f"PublicKey = {row[0]}")
        if row[1]: 
            print(f"PresharedKey = {decrypt_field(cipher, row[1])}")
        if row[2]: 
            try:
                ips = json.loads(row[2])
                print(f"AllowedIPs = {', '.join(ips)}")
            except:
                print(f"AllowedIPs = {row[2]}")
        if row[3]: 
            print(f"Endpoint = {row[3]}")
        if row[4]: 
            print(f"PersistentKeepalive = {row[4]}")
        print()

conn.close()
DECRYPT_SCRIPT

# Restore WireGuard configs from structured database data
echo "📝 Reconstructing WireGuard configurations from structured data..."
sudo rm -f /etc/wireguard/wg*.conf

# Restore wg0 config by reconstructing from structured data
echo "🔧 Reconstructing wg0.conf..."
WG0_PRIVATE=$(python3 /tmp/decrypt_helper.py server_key wg0 2>/dev/null)
WG0_DATA=$(python3 /tmp/decrypt_helper.py interface_data wg0 2>/dev/null)

if [ ! -z "$WG0_PRIVATE" ] && [ "$WG0_PRIVATE" != "" ]; then
    # Parse interface data
    WG0_ADDRESS=$(echo "$WG0_DATA" | cut -d',' -f1)
    WG0_LISTEN_PORT=$(echo "$WG0_DATA" | cut -d',' -f2)
    
    # Create interface section
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = ${WG0_ADDRESS:-10.10.0.1/24}
ListenPort = ${WG0_LISTEN_PORT:-$WG0_PORT}
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE

EOF

    # Add peers from database (decrypted)
    echo "   Adding wg0 peers from database..."
    python3 /tmp/decrypt_helper.py peers wg0 2>/dev/null | sudo tee -a /etc/wireguard/wg0.conf > /dev/null
    
    RESTORED_WG0_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg0.conf || echo 0)
    echo "✅ wg0.conf reconstructed with $RESTORED_WG0_PEERS peers"
else
    echo "⚠️  wg0 server key not found in database, creating basic config"
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
Address = 10.10.0.1/24
ListenPort = $WG0_PORT
PostUp = iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1812 -j ACCEPT; iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport 1813 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -d 127.0.0.1 -j MASQUERADE
EOF
fi

# Restore wg1 config by reconstructing from structured data  
echo "🔧 Reconstructing wg1.conf..."
WG1_PRIVATE=$(python3 /tmp/decrypt_helper.py server_key wg1 2>/dev/null)
WG1_DATA=$(python3 /tmp/decrypt_helper.py interface_data wg1 2>/dev/null)

if [ ! -z "$WG1_PRIVATE" ] && [ "$WG1_PRIVATE" != "" ]; then
    # Parse interface data
    WG1_ADDRESS=$(echo "$WG1_DATA" | cut -d',' -f1)
    WG1_LISTEN_PORT=$(echo "$WG1_DATA" | cut -d',' -f2)
    
    # Create interface section
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = ${WG1_ADDRESS:-10.11.0.1/24}
ListenPort = ${WG1_LISTEN_PORT:-$WG1_PORT}
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE

EOF

    # Add peers from database (decrypted)
    echo "   Adding wg1 peers from database..."
    python3 /tmp/decrypt_helper.py peers wg1 2>/dev/null | sudo tee -a /etc/wireguard/wg1.conf > /dev/null
    
    RESTORED_WG1_PEERS=$(sudo grep -c '\[Peer\]' /etc/wireguard/wg1.conf || echo 0)
    echo "✅ wg1.conf reconstructed with $RESTORED_WG1_PEERS peers"
else
    echo "⚠️  wg1 server key not found in database, creating basic config"
    sudo tee /etc/wireguard/wg1.conf > /dev/null << EOF
[Interface]
Address = 10.11.0.1/24
ListenPort = $WG1_PORT
PostUp = iptables -A FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -d $TARGET_WEBSITE_IP -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.11.0.0/24 -d $TARGET_WEBSITE_IP -j MASQUERADE
EOF
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

# Show WireGuard status
echo ""
echo "🔗 WireGuard Interface Status:"
if sudo wg show >/dev/null 2>&1; then
    sudo wg show
else
    echo "⚠️  WireGuard interfaces not accessible"
fi

# Cleanup temporary files
rm -f /tmp/decrypt_helper.py

echo ""
echo "✅ Database restoration completed!"
echo ""
echo "🔄 The restoration process:"
echo "   1. ✅ Read structured data from external PostgreSQL"
echo "   2. ✅ Decrypted sensitive fields (private keys, PSKs)"
echo "   3. ✅ Reconstructed WireGuard config files with all peers"
echo "   4. ✅ Started WireGuard interfaces"
echo "   5. ✅ Started Docker services"
echo "   6. ✅ Sync service automatically syncs any changes"
echo ""
echo "📊 Restoration Summary:"
echo "   Database wg0 peers: $WG0_PEERS"
echo "   Database wg1 peers: $WG1_PEERS"
if [ ! -z "$RESTORED_WG0_PEERS" ]; then
    echo "   Restored wg0 peers: $RESTORED_WG0_PEERS"
fi
if [ ! -z "$RESTORED_WG1_PEERS" ]; then
    echo "   Restored wg1 peers: $RESTORED_WG1_PEERS"
fi
echo ""
echo "🧪 Verify with: curl -H 'Authorization: Bearer $WGREST_API_KEY' http://localhost:$WGREST_PORT/v1/devices/"