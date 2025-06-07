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
WGREST_API_URL = os.getenv('WGREST_API_URL', 'http://localhost:8080')
WGREST_API_KEY = os.getenv('WGREST_API_KEY')
DATABASE_URL = os.getenv('DATABASE_URL')
SYNC_INTERVAL = int(os.getenv('SYNC_INTERVAL', 60))

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
        """Fetch complete state from wgrest API"""
        try:
            # Get interfaces
            interfaces_resp = requests.get(f"{WGREST_API_URL}/api/v1/interfaces", headers=self.headers)
            interfaces_resp.raise_for_status()
            interfaces = interfaces_resp.json()
            
            # Get peers for each interface
            all_peers = {}
            for interface_name in ['wg0', 'wg1']:
                try:
                    peers_resp = requests.get(f"{WGREST_API_URL}/api/v1/interfaces/{interface_name}/peers", headers=self.headers)
                    peers_resp.raise_for_status()
                    all_peers[interface_name] = peers_resp.json()
                except requests.exceptions.HTTPError as e:
                    if e.response.status_code == 404:
                        all_peers[interface_name] = []
                    else:
                        raise
                        
            return interfaces, all_peers
            
        except Exception as e:
            logger.error(f"Failed to fetch wgrest data: {e}")
            return None, None
            
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
                
                # Sync interfaces
                for interface_name, interface_data in interfaces.items():
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
                        'private_key': interface_data.get('private_key', ''),
                        'public_key': interface_data.get('public_key', ''),
                        'address': interface_data.get('address', ''),
                        'listen_port': interface_data.get('listen_port', 0),
                        'subnet': interface_data.get('subnet', ''),
                        'endpoint': interface_data.get('endpoint', ''),
                        'config_content': configs.get(interface_name, '')
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
                            'name': peer.get('name', ''),
                            'private_key': peer.get('private_key', ''),
                            'public_key': peer.get('public_key', ''),
                            'allowed_ips': json.dumps(peer.get('allowed_ips', [])),
                            'endpoint': peer.get('endpoint'),
                            'persistent_keepalive': peer.get('persistent_keepalive'),
                            'enabled': peer.get('enabled', True),
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