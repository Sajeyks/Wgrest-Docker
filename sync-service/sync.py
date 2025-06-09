#!/usr/bin/env python3
"""
wgrest → PostgreSQL sync service
Continuously backs up wgrest state to PostgreSQL for one-command restoration
"""

import json
import time
import logging
import os
import requests
import psycopg2
import psycopg2.extras
import schedule
from datetime import datetime

# Configuration
WGREST_PORT = os.getenv('WGREST_PORT', '51822')
WGREST_API_URL = os.getenv('WGREST_API_URL', f'http://localhost:{WGREST_PORT}')
WGREST_API_KEY = os.getenv('WGREST_API_KEY')
DATABASE_URL = os.getenv('DATABASE_URL')
SYNC_INTERVAL = int(os.getenv('SYNC_INTERVAL', 60))

# Environment variables for config parsing
SERVER_IP = os.getenv('SERVER_IP', 'localhost')
WG0_PORT = os.getenv('WG0_PORT', '51820')
WG1_PORT = os.getenv('WG1_PORT', '51821')

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class WgrestSyncService:
    def __init__(self):
        self.headers = {'Authorization': f'Bearer {WGREST_API_KEY}'}
        self.conn = None
        
    def connect_db(self):
        """Connect to PostgreSQL"""
        try:
            self.conn = psycopg2.connect(DATABASE_URL)
            self.conn.autocommit = True
            logger.info("Connected to PostgreSQL")
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            raise
            
    def get_wgrest_data(self):
        """Fetch complete state from wgrest API using correct endpoints"""
        try:
            # Get devices (interfaces) - correct endpoint
            devices_resp = requests.get(f"{WGREST_API_URL}/v1/devices/", headers=self.headers)
            devices_resp.raise_for_status()
            devices = devices_resp.json()
            
            # Convert devices list to dict for compatibility
            interfaces = {}
            for device in devices:
                interfaces[device['name']] = device
            
            # Get peers for each interface using correct endpoints
            all_peers = {}
            for device_name in ['wg0', 'wg1']:
                try:
                    peers_resp = requests.get(f"{WGREST_API_URL}/v1/devices/{device_name}/peers/", headers=self.headers)
                    peers_resp.raise_for_status()
                    all_peers[device_name] = peers_resp.json()
                except requests.exceptions.HTTPError as e:
                    if e.response.status_code == 404:
                        all_peers[device_name] = []
                        logger.warning(f"Device {device_name} not found, assuming no peers")
                    else:
                        raise
                        
            return interfaces, all_peers
            
        except Exception as e:
            logger.error(f"Failed to fetch wgrest data: {e}")
            return None, None
            
    def parse_wireguard_config(self, config_content, interface_name):
        """Parse WireGuard config to extract interface details"""
        if not config_content:
            return {}
            
        details = {}
        lines = config_content.split('\n')
        
        for line in lines:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                key, value = line.split('=', 1)
                key = key.strip().lower()
                value = value.strip()
                
                if key == 'address':
                    details['address'] = value
                elif key == 'listenport':
                    details['listen_port'] = int(value)
                elif key == 'privatekey':
                    details['private_key'] = value
                    
        # Set subnet based on address
        if 'address' in details:
            if interface_name == 'wg0':
                details['subnet'] = '10.10.0.0/24'
                details['endpoint'] = f"{SERVER_IP}:{WG0_PORT}"
            elif interface_name == 'wg1':
                details['subnet'] = '10.11.0.0/24'
                details['endpoint'] = f"{SERVER_IP}:{WG1_PORT}"
                
        return details
        
    def read_wireguard_configs(self):
        """Read WireGuard config files"""
        configs = {}
        for interface in ['wg0', 'wg1']:
            try:
                with open(f'/etc/wireguard/{interface}.conf', 'r') as f:
                    configs[interface] = f.read()
            except FileNotFoundError:
                configs[interface] = None
                logger.warning(f"Config file for {interface} not found")
        return configs
        
    def sync_to_database(self):
        """Sync wgrest state to PostgreSQL"""
        logger.info("Starting sync...")
        
        # Get data from wgrest
        interfaces, all_peers = self.get_wgrest_data()
        if interfaces is None:
            logger.error("Failed to get wgrest data, skipping sync")
            return
            
        # Get WireGuard configs
        configs = self.read_wireguard_configs()
        
        try:
            with self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                
                # Sync interfaces (devices) with enhanced data extraction
                for interface_name, interface_data in interfaces.items():
                    # Parse config file for additional details
                    config_content = configs.get(interface_name, '')
                    config_details = self.parse_wireguard_config(config_content, interface_name)
                    
                    cur.execute("""
                        INSERT INTO interfaces (name, private_key, public_key, address, listen_port, subnet, endpoint, config_content)
                        VALUES (%(name)s, %(private_key)s, %(public_key)s, %(address)s, %(listen_port)s, %(subnet)s, %(endpoint)s, %(config_content)s)
                        ON CONFLICT (name) DO UPDATE SET
                            private_key = EXCLUDED.private_key,
                            public_key = EXCLUDED.public_key,
                            address = EXCLUDED.address,
                            listen_port = EXCLUDED.listen_port,
                            subnet = EXCLUDED.subnet,
                            endpoint = EXCLUDED.endpoint,
                            config_content = EXCLUDED.config_content,
                            last_updated = CURRENT_TIMESTAMP
                    """, {
                        'name': interface_name,
                        'private_key': config_details.get('private_key', ''),  # From config file
                        'public_key': interface_data.get('public_key', ''),   # From wgrest API
                        'address': config_details.get('address', ''),         # From config file
                        'listen_port': interface_data.get('listen_port', config_details.get('listen_port', 0)),  # Prefer API, fallback to config
                        'subnet': config_details.get('subnet', ''),           # From our parsing
                        'endpoint': config_details.get('endpoint', ''),       # From our parsing
                        'config_content': config_content                      # Full config file
                    })
                
                # Clear existing peers for clean sync
                cur.execute("DELETE FROM peers")
                
                # Sync all peers
                total_peers = 0
                for interface_name, peers in all_peers.items():
                    for peer in peers:
                        cur.execute("""
                            INSERT INTO peers (interface_name, name, private_key, public_key, allowed_ips, 
                                             endpoint, persistent_keepalive, enabled, preshared_key)
                            VALUES (%(interface_name)s, %(name)s, %(private_key)s, %(public_key)s, 
                                   %(allowed_ips)s, %(endpoint)s, %(persistent_keepalive)s, %(enabled)s, %(preshared_key)s)
                        """, {
                            'interface_name': interface_name,
                            'name': peer.get('url_safe_public_key', peer.get('public_key', ''))[:50],  # Use public key as name
                            'private_key': '',  # wgrest doesn't store client private keys
                            'public_key': peer.get('public_key', ''),
                            'allowed_ips': json.dumps(peer.get('allowed_ips', [])),
                            'endpoint': peer.get('endpoint'),
                            'persistent_keepalive': None,  # Parse from persistent_keepalive_interval if needed
                            'enabled': True,
                            'preshared_key': peer.get('preshared_key')
                        })
                        total_peers += 1
                
                # Update sync status
                wg0_count = len(all_peers.get('wg0', []))
                wg1_count = len(all_peers.get('wg1', []))
                
                cur.execute("""
                    INSERT INTO sync_status (peer_count_wg0, peer_count_wg1) 
                    VALUES (%(wg0)s, %(wg1)s)
                """, {'wg0': wg0_count, 'wg1': wg1_count})
                
                logger.info(f"Sync completed: {total_peers} peers synced ({wg0_count} wg0, {wg1_count} wg1)")
                
        except Exception as e:
            logger.error(f"Database sync failed: {e}")
            raise

def main():
    """Main sync loop"""
    sync_service = WgrestSyncService()
    sync_service.connect_db()
    
    # Schedule regular sync
    schedule.every(SYNC_INTERVAL).seconds.do(sync_service.sync_to_database)
    
    # Initial sync
    sync_service.sync_to_database()
    
    logger.info(f"Starting sync service (interval: {SYNC_INTERVAL}s)")
    
    while True:
        try:
            schedule.run_pending()
            time.sleep(1)
        except KeyboardInterrupt:
            logger.info("Shutting down sync service")
            break
        except Exception as e:
            logger.error(f"Sync service error: {e}")
            time.sleep(30)  # Wait before retrying

if __name__ == "__main__":
    main()