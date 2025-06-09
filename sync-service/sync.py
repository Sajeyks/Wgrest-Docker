#!/usr/bin/env python3
"""
Event-driven wgrest → PostgreSQL sync service with webhook endpoint
Syncs on initial startup, file changes, and API webhook calls
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
from cryptography.fernet import Fernet
import base64
import hashlib
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import threading
from flask import Flask, request, jsonify
from werkzeug.serving import make_server

# Configuration
WGREST_PORT = os.getenv('WGREST_PORT', '51822')
WGREST_API_URL = os.getenv('WGREST_API_URL', f'http://localhost:{WGREST_PORT}')
WGREST_API_KEY = os.getenv('WGREST_API_KEY')
DATABASE_URL = os.getenv('DATABASE_URL')

# Event-driven configuration
SYNC_MODE = os.getenv('SYNC_MODE', 'event-driven')
POLLING_INTERVAL = int(os.getenv('SYNC_INTERVAL', 300))
DEBOUNCE_SECONDS = int(os.getenv('DEBOUNCE_SECONDS', 5))
WEBHOOK_PORT = int(os.getenv('WEBHOOK_PORT', '8090'))
WEBHOOK_ENABLED = os.getenv('WEBHOOK_ENABLED', 'true').lower() == 'true'

# Encryption configuration
ENCRYPTION_KEY = os.getenv('DB_ENCRYPTION_KEY')
if not ENCRYPTION_KEY:
    key_material = hashlib.sha256(WGREST_API_KEY.encode()).digest()
    ENCRYPTION_KEY = base64.urlsafe_b64encode(key_material)

# Cleanup configuration
CLEANUP_ENABLED = os.getenv('CLEANUP_ENABLED', 'true').lower() == 'true'
CLEANUP_OLDER_THAN_HOURS = int(os.getenv('CLEANUP_OLDER_THAN_HOURS', 24))
CLEANUP_TIME = os.getenv('CLEANUP_TIME', '02:00')

# Environment variables
SERVER_IP = os.getenv('SERVER_IP', 'localhost')
WG0_PORT = os.getenv('WG0_PORT', '51820')
WG1_PORT = os.getenv('WG1_PORT', '51821')

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Global sync service instance
sync_service = None

class EncryptionHelper:
    def __init__(self, key):
        self.cipher = Fernet(key)
    
    def encrypt(self, data):
        if not data:
            return None
        return self.cipher.encrypt(data.encode()).decode()
    
    def decrypt(self, encrypted_data):
        if not encrypted_data:
            return None
        return self.cipher.decrypt(encrypted_data.encode()).decode()

class WireGuardFileHandler(FileSystemEventHandler):
    def __init__(self, sync_service):
        self.sync_service = sync_service
        self.last_sync = 0
        self.debounce_timer = None
        
    def on_modified(self, event):
        if event.is_directory:
            return
            
        if event.src_path.endswith(('.conf')):
            logger.info(f"WireGuard config changed: {event.src_path}")
            self.debounced_sync()
    
    def debounced_sync(self):
        if self.debounce_timer:
            self.debounce_timer.cancel()
            
        self.debounce_timer = threading.Timer(DEBOUNCE_SECONDS, self.trigger_sync)
        self.debounce_timer.start()
    
    def trigger_sync(self):
        current_time = time.time()
        if current_time - self.last_sync > DEBOUNCE_SECONDS:
            logger.info("Triggering sync due to file changes...")
            self.sync_service.sync_to_database()
            self.last_sync = current_time

class WgrestSyncService:
    def __init__(self):
        self.headers = {'Authorization': f'Bearer {WGREST_API_KEY}'}
        self.conn = None
        self.encryption = EncryptionHelper(ENCRYPTION_KEY)
        self.observer = None
        self.webhook_server = None
        
    def connect_db(self):
        try:
            self.conn = psycopg2.connect(DATABASE_URL)
            self.conn.autocommit = True
            logger.info("Connected to PostgreSQL with encryption enabled")
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            raise
    
    def setup_file_monitoring(self):
        if SYNC_MODE != 'event-driven':
            return
            
        try:
            self.observer = Observer()
            event_handler = WireGuardFileHandler(self)
            self.observer.schedule(event_handler, '/etc/wireguard', recursive=False)
            self.observer.start()
            logger.info("File monitoring started for /etc/wireguard")
        except Exception as e:
            logger.error(f"Failed to setup file monitoring: {e}")
    
    def setup_webhook_server(self):
        """Setup webhook server to receive sync triggers"""
        if not WEBHOOK_ENABLED:
            return
            
        app = Flask(__name__)
        
        @app.route('/sync', methods=['POST'])
        def webhook_sync():
            try:
                # Verify webhook auth
                auth_header = request.headers.get('Authorization')
                if not auth_header or auth_header != f'Bearer {WGREST_API_KEY}':
                    return jsonify({'error': 'Unauthorized'}), 401
                
                # Trigger sync
                logger.info("Webhook triggered sync")
                threading.Thread(target=self.sync_to_database).start()
                
                return jsonify({'status': 'sync_triggered'}), 200
                
            except Exception as e:
                logger.error(f"Webhook error: {e}")
                return jsonify({'error': str(e)}), 500
        
        @app.route('/health', methods=['GET'])
        def health_check():
            return jsonify({'status': 'healthy', 'mode': SYNC_MODE}), 200
        
        # Run webhook server in thread
        def run_webhook():
            try:
                self.webhook_server = make_server('0.0.0.0', WEBHOOK_PORT, app, threaded=True)
                logger.info(f"Webhook server started on port {WEBHOOK_PORT}")
                self.webhook_server.serve_forever()
            except Exception as e:
                logger.error(f"Webhook server error: {e}")
        
        webhook_thread = threading.Thread(target=run_webhook, daemon=True)
        webhook_thread.start()
            
    def cleanup_old_sync_logs(self):
        if not CLEANUP_ENABLED:
            return
            
        try:
            with self.conn.cursor() as cur:
                cur.execute("""
                    DELETE FROM sync_status 
                    WHERE last_sync < NOW() - INTERVAL '%s hours'
                """, (CLEANUP_OLDER_THAN_HOURS,))
                
                deleted_count = cur.rowcount
                if deleted_count > 0:
                    logger.info(f"Cleaned up {deleted_count} old sync status records")
        except Exception as e:
            logger.error(f"Failed to cleanup old sync logs: {e}")
            
    def get_wgrest_data(self):
        try:
            devices_resp = requests.get(f"{WGREST_API_URL}/v1/devices/", headers=self.headers)
            devices_resp.raise_for_status()
            devices = devices_resp.json()
            
            interfaces = {}
            for device in devices:
                interfaces[device['name']] = device
            
            all_peers = {}
            for device_name in ['wg0', 'wg1']:
                try:
                    peers_resp = requests.get(f"{WGREST_API_URL}/v1/devices/{device_name}/peers/", headers=self.headers)
                    peers_resp.raise_for_status()
                    all_peers[device_name] = peers_resp.json()
                except requests.exceptions.HTTPError as e:
                    if e.response.status_code == 404:
                        all_peers[device_name] = []
                    else:
                        raise
                        
            return interfaces, all_peers
        except Exception as e:
            logger.error(f"Failed to fetch wgrest data: {e}")
            return None, None
            
    def parse_wireguard_config(self, config_content, interface_name):
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
                    
        if 'address' in details:
            if interface_name == 'wg0':
                details['subnet'] = '10.10.0.0/24'
                details['endpoint'] = f"{SERVER_IP}:{WG0_PORT}"
            elif interface_name == 'wg1':
                details['subnet'] = '10.11.0.0/24'
                details['endpoint'] = f"{SERVER_IP}:{WG1_PORT}"
                
        return details
        
    def read_wireguard_configs(self):
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
        logger.info("Starting sync with encryption...")
        
        interfaces, all_peers = self.get_wgrest_data()
        if interfaces is None:
            logger.error("Failed to get wgrest data, skipping sync")
            return
            
        configs = self.read_wireguard_configs()
        
        try:
            with self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                
                # Sync interfaces with encryption
                for interface_name, interface_data in interfaces.items():
                    config_content = configs.get(interface_name, '')
                    config_details = self.parse_wireguard_config(config_content, interface_name)
                    
                    private_key_encrypted = self.encryption.encrypt(config_details.get('private_key', ''))
                    config_content_encrypted = self.encryption.encrypt(config_content) if config_content else None
                    
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
                        'private_key': private_key_encrypted,
                        'public_key': interface_data.get('public_key', ''),
                        'address': config_details.get('address', ''),
                        'listen_port': interface_data.get('listen_port', config_details.get('listen_port', 0)),
                        'subnet': config_details.get('subnet', ''),
                        'endpoint': config_details.get('endpoint', ''),
                        'config_content': config_content_encrypted
                    })
                
                cur.execute("DELETE FROM peers")
                
                total_peers = 0
                for interface_name, peers in all_peers.items():
                    for peer in peers:
                        preshared_key_encrypted = self.encryption.encrypt(peer.get('preshared_key', '')) if peer.get('preshared_key') else None
                        
                        cur.execute("""
                            INSERT INTO peers (interface_name, name, private_key, public_key, allowed_ips, 
                                             endpoint, persistent_keepalive, enabled, preshared_key)
                            VALUES (%(interface_name)s, %(name)s, %(private_key)s, %(public_key)s, 
                                   %(allowed_ips)s, %(endpoint)s, %(persistent_keepalive)s, %(enabled)s, %(preshared_key)s)
                        """, {
                            'interface_name': interface_name,
                            'name': peer.get('url_safe_public_key', peer.get('public_key', ''))[:50],
                            'private_key': '',
                            'public_key': peer.get('public_key', ''),
                            'allowed_ips': json.dumps(peer.get('allowed_ips', [])),
                            'endpoint': peer.get('endpoint'),
                            'persistent_keepalive': None,
                            'enabled': True,
                            'preshared_key': preshared_key_encrypted
                        })
                        total_peers += 1
                
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
    global sync_service
    sync_service = WgrestSyncService()
    sync_service.connect_db()
    
    # Initial sync on startup
    logger.info("Performing initial sync...")
    sync_service.sync_to_database()
    
    if SYNC_MODE == 'event-driven':
        logger.info("Starting event-driven sync mode")
        sync_service.setup_file_monitoring()
        sync_service.setup_webhook_server()
        
        if CLEANUP_ENABLED:
            schedule.every().day.at(CLEANUP_TIME).do(sync_service.cleanup_old_sync_logs)
            logger.info(f"Daily cleanup scheduled for {CLEANUP_TIME}")
            
        try:
            while True:
                schedule.run_pending()
                time.sleep(60)
        except KeyboardInterrupt:
            logger.info("Shutting down sync service")
            if sync_service.observer:
                sync_service.observer.stop()
                sync_service.observer.join()
            if sync_service.webhook_server:
                sync_service.webhook_server.shutdown()
    else:
        logger.info(f"Starting polling mode (interval: {POLLING_INTERVAL}s)")
        schedule.every(POLLING_INTERVAL).seconds.do(sync_service.sync_to_database)
        
        if CLEANUP_ENABLED:
            schedule.every().day.at(CLEANUP_TIME).do(sync_service.cleanup_old_sync_logs)
            
        while True:
            try:
                schedule.run_pending()
                time.sleep(1)
            except KeyboardInterrupt:
                logger.info("Shutting down sync service")
                break

if __name__ == "__main__":
    main()