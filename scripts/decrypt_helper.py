#!/usr/bin/env python3
"""
Standalone database decryption helper for WireGuard restoration
Usage: python decrypt_helper.py [server_key|peers|interface_data] [interface_name]
"""

import os
import sys
import psycopg2
import hashlib
import base64
import json
from cryptography.fernet import Fernet

def setup_encryption():
    """Setup encryption helper using same key as sync service"""
    WGREST_API_KEY = os.getenv('WGREST_API_KEY')
    ENCRYPTION_KEY = os.getenv('DB_ENCRYPTION_KEY')
    
    if not ENCRYPTION_KEY:
        key_material = hashlib.sha256(WGREST_API_KEY.encode()).digest()
        ENCRYPTION_KEY = base64.urlsafe_b64encode(key_material)
    
    return Fernet(ENCRYPTION_KEY)

def decrypt_field(cipher, encrypted_data):
    """Decrypt a database field - handles both encrypted and plaintext data"""
    if not encrypted_data:
        return None
    try:
        # Try to decrypt - if it fails, assume it's already plaintext
        return cipher.decrypt(encrypted_data.encode()).decode()
    except Exception:
        # Return as-is if decryption fails (probably plaintext)
        return encrypted_data

def get_decrypted_server_key(interface_name):
    """Get decrypted server private key for interface"""
    DATABASE_URL = os.getenv('DATABASE_URL')
    
    try:
        conn = psycopg2.connect(DATABASE_URL)
        cur = conn.cursor()
        
        cur.execute("SELECT private_key FROM server_keys WHERE interface_name = %s", (interface_name,))
        result = cur.fetchone()
        
        if result:
            cipher = setup_encryption()
            encrypted_key = result[0]
            decrypted_key = decrypt_field(cipher, encrypted_key)
            conn.close()
            return decrypted_key
        
        conn.close()
        return None
        
    except Exception as e:
        print(f"Error getting server key: {e}", file=sys.stderr)
        return None

def get_interface_data(interface_name):
    """Get interface configuration data"""
    DATABASE_URL = os.getenv('DATABASE_URL')
    
    try:
        conn = psycopg2.connect(DATABASE_URL)
        cur = conn.cursor()
        
        cur.execute("SELECT address, listen_port FROM interfaces WHERE name = %s", (interface_name,))
        result = cur.fetchone()
        
        if result:
            conn.close()
            return result[0], result[1]  # address, listen_port
        
        conn.close()
        return None, None
        
    except Exception as e:
        print(f"Error getting interface data: {e}", file=sys.stderr)
        return None, None

def get_decrypted_peers(interface_name):
    """Get decrypted peer data for interface"""
    DATABASE_URL = os.getenv('DATABASE_URL')
    
    try:
        conn = psycopg2.connect(DATABASE_URL)
        cur = conn.cursor()
        
        cur.execute("""
            SELECT public_key, preshared_key, allowed_ips, endpoint, persistent_keepalive
            FROM peers 
            WHERE interface_name = %s AND enabled = true
            ORDER BY name
        """, (interface_name,))
        
        results = cur.fetchall()
        cipher = setup_encryption()
        
        peers = []
        for row in results:
            public_key, encrypted_psk, allowed_ips, endpoint, keepalive = row
            
            # Decrypt PSK if present
            preshared_key = decrypt_field(cipher, encrypted_psk) if encrypted_psk else None
            
            peers.append({
                'public_key': public_key,
                'preshared_key': preshared_key,
                'allowed_ips': allowed_ips,
                'endpoint': endpoint,
                'persistent_keepalive': keepalive
            })
        
        conn.close()
        return peers
        
    except Exception as e:
        print(f"Error getting peers: {e}", file=sys.stderr)
        return []

def print_peers_config(peers):
    """Print peers in WireGuard config format"""
    for peer in peers:
        print("[Peer]")
        print(f"PublicKey = {peer['public_key']}")
        
        if peer['preshared_key']:
            print(f"PresharedKey = {peer['preshared_key']}")
            
        if peer['allowed_ips']:
            # Parse JSON array and join
            try:
                ips = json.loads(peer['allowed_ips'])
                print(f"AllowedIPs = {', '.join(ips)}")
            except:
                print(f"AllowedIPs = {peer['allowed_ips']}")
                
        if peer['endpoint']:
            print(f"Endpoint = {peer['endpoint']}")
            
        if peer['persistent_keepalive']:
            print(f"PersistentKeepalive = {peer['persistent_keepalive']}")
            
        print()  # Empty line between peers

def main():
    if len(sys.argv) < 3:
        print("Usage: python decrypt_helper.py [server_key|peers|interface_data] [interface_name]")
        print("")
        print("Commands:")
        print("  server_key wg0        - Get decrypted server private key for wg0")
        print("  interface_data wg0    - Get interface address and port")
        print("  peers wg0            - Get all peers for wg0 in config format")
        print("")
        print("Examples:")
        print("  python decrypt_helper.py server_key wg0")
        print("  python decrypt_helper.py peers wg1")
        sys.exit(1)
    
    command = sys.argv[1]
    interface_name = sys.argv[2]
    
    # Load environment variables
    from dotenv import load_dotenv
    load_dotenv()
    
    if command == "server_key":
        key = get_decrypted_server_key(interface_name)
        if key:
            print(key)
        else:
            print(f"No server key found for {interface_name}", file=sys.stderr)
            sys.exit(1)
    
    elif command == "interface_data":
        address, port = get_interface_data(interface_name)
        if address and port:
            print(f"{address},{port}")
        else:
            print(f"No interface data found for {interface_name}", file=sys.stderr)
            sys.exit(1)
    
    elif command == "peers":
        peers = get_decrypted_peers(interface_name)
        if peers:
            print_peers_config(peers)
        else:
            print(f"# No peers found for {interface_name}")
    
    else:
        print("Invalid command. Use 'server_key', 'interface_data', or 'peers'")
        sys.exit(1)

if __name__ == "__main__":
    main()