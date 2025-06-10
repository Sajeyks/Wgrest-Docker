# #!/usr/bin/env python3
# """
# Event-driven wgrest → PostgreSQL sync service with structured data storage
# Stores only structured data, reconstructs config files during restoration
# FIXED: Proper server key encryption using existing encryption functions
# """

# import json
# import time
# import logging
# import os
# import requests
# import psycopg2
# import psycopg2.extras
# import schedule
# from datetime import datetime
# from cryptography.fernet import Fernet
# import base64
# import hashlib
# from watchdog.observers import Observer
# from watchdog.events import FileSystemEventHandler
# import threading
# from flask import Flask, request, jsonify
# from werkzeug.serving import make_server
# import subprocess

# # Configuration
# WGREST_PORT = os.getenv('WGREST_PORT', '51822')
# WGREST_API_URL = os.getenv('WGREST_API_URL', f'http://localhost:{WGREST_PORT}')
# WGREST_API_KEY = os.getenv('WGREST_API_KEY')
# DATABASE_URL = os.getenv('DATABASE_URL')

# # Event-driven configuration
# SYNC_MODE = os.getenv('SYNC_MODE', 'event-driven')
# POLLING_INTERVAL = int(os.getenv('SYNC_INTERVAL', 300))
# DEBOUNCE_SECONDS = int(os.getenv('DEBOUNCE_SECONDS', 5))
# WEBHOOK_PORT = int(os.getenv('WEBHOOK_PORT', '8090'))
# WEBHOOK_ENABLED = os.getenv('WEBHOOK_ENABLED', 'true').lower() == 'true'

# # Encryption configuration
# ENCRYPTION_KEY = os.getenv('DB_ENCRYPTION_KEY')
# if not ENCRYPTION_KEY:
#     key_material = hashlib.sha256(WGREST_API_KEY.encode()).digest()
#     ENCRYPTION_KEY = base64.urlsafe_b64encode(key_material)

# # Cleanup configuration
# CLEANUP_ENABLED = os.getenv('CLEANUP_ENABLED', 'true').lower() == 'true'
# CLEANUP_OLDER_THAN_HOURS = int(os.getenv('CLEANUP_OLDER_THAN_HOURS', 24))
# CLEANUP_TIME = os.getenv('CLEANUP_TIME', '02:00')

# # Environment variables
# SERVER_IP = os.getenv('SERVER_IP', 'localhost')
# WG0_PORT = os.getenv('WG0_PORT', '51820')
# WG1_PORT = os.getenv('WG1_PORT', '51821')
# TARGET_WEBSITE_IP = os.getenv('TARGET_WEBSITE_IP', '127.0.0.1')

# logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
# logger = logging.getLogger(__name__)

# # Global sync service instance
# sync_service = None

# class EncryptionHelper:
#     def __init__(self, key):
#         self.cipher = Fernet(key)
    
#     def encrypt(self, data):
#         if not data or data == '':
#             return None
#         try:
#             return self.cipher.encrypt(data.encode()).decode()
#         except Exception as e:
#             logger.error(f"Encryption failed: {e}")
#             return None
    
#     def decrypt(self, encrypted_data):
#         if not encrypted_data:
#             return None
#         try:
#             return self.cipher.decrypt(encrypted_data.encode()).decode()
#         except Exception as e:
#             logger.error(f"Decryption failed: {e}")
#             return None

# class WireGuardFileHandler(FileSystemEventHandler):
#     def __init__(self, sync_service):
#         self.sync_service = sync_service
#         self.last_sync = 0
#         self.debounce_timer = None
        
#     def on_modified(self, event):
#         if event.is_directory:
#             return
            
#         if event.src_path.endswith(('.conf')):
#             logger.info(f"WireGuard config changed: {event.src_path}")
#             self.debounced_sync()
    
#     def debounced_sync(self):
#         if self.debounce_timer:
#             self.debounce_timer.cancel()
            
#         self.debounce_timer = threading.Timer(DEBOUNCE_SECONDS, self.trigger_sync)
#         self.debounce_timer.start()
    
#     def trigger_sync(self):
#         current_time = time.time()
#         if current_time - self.last_sync > DEBOUNCE_SECONDS:
#             logger.info("Triggering sync due to file changes...")
#             self.sync_service.sync_to_database()
#             self.last_sync = current_time

# class WgrestSyncService:
#     def __init__(self):
#         self.headers = {'Authorization': f'Bearer {WGREST_API_KEY}'}
#         self.conn = None
#         self.encryption = EncryptionHelper(ENCRYPTION_KEY)
#         self.observer = None
#         self.webhook_server = None
        
#     def connect_db(self):
#         try:
#             self.conn = psycopg2.connect(DATABASE_URL)
#             self.conn.autocommit = True
#             logger.info("Connected to PostgreSQL with structured data encryption")
#         except Exception as e:
#             logger.error(f"Database connection failed: {e}")
#             raise
    
#     def setup_file_monitoring(self):
#         if SYNC_MODE != 'event-driven':
#             return
            
#         try:
#             self.observer = Observer()
#             event_handler = WireGuardFileHandler(self)
#             self.observer.schedule(event_handler, '/etc/wireguard', recursive=False)
#             self.observer.start()
#             logger.info("File monitoring started for /etc/wireguard")
#         except Exception as e:
#             logger.error(f"Failed to setup file monitoring: {e}")
    
#     def setup_webhook_server(self):
#         if not WEBHOOK_ENABLED:
#             return
            
#         app = Flask(__name__)
        
#         @app.route('/sync', methods=['POST'])
#         def webhook_sync():
#             try:
#                 auth_header = request.headers.get('Authorization')
#                 if not auth_header or auth_header != f'Bearer {WGREST_API_KEY}':
#                     return jsonify({'error': 'Unauthorized'}), 401
                
#                 logger.info("Webhook triggered sync")
#                 threading.Thread(target=self.sync_to_database).start()
                
#                 return jsonify({'status': 'sync_triggered'}), 200
                
#             except Exception as e:
#                 logger.error(f"Webhook error: {e}")
#                 return jsonify({'error': str(e)}), 500
        
#         @app.route('/health', methods=['GET'])
#         def health_check():
#             return jsonify({'status': 'healthy', 'mode': SYNC_MODE}), 200
        
#         def run_webhook():
#             try:
#                 self.webhook_server = make_server('0.0.0.0', WEBHOOK_PORT, app, threaded=True)
#                 logger.info(f"Webhook server started on port {WEBHOOK_PORT}")
#                 self.webhook_server.serve_forever()
#             except Exception as e:
#                 logger.error(f"Webhook server error: {e}")
        
#         webhook_thread = threading.Thread(target=run_webhook, daemon=True)
#         webhook_thread.start()
            
#     def cleanup_old_sync_logs(self):
#         if not CLEANUP_ENABLED:
#             return
            
#         try:
#             with self.conn.cursor() as cur:
#                 cur.execute("""
#                     DELETE FROM sync_status 
#                     WHERE last_sync < NOW() - INTERVAL '%s hours'
#                 """, (CLEANUP_OLDER_THAN_HOURS,))
                
#                 deleted_count = cur.rowcount
#                 if deleted_count > 0:
#                     logger.info(f"Cleaned up {deleted_count} old sync status records")
#         except Exception as e:
#             logger.error(f"Failed to cleanup old sync logs: {e}")
    
#     def generate_public_key_from_private(self, private_key):
#         """Generate public key from private key using wg command"""
#         if not private_key or private_key.strip() == '':
#             logger.error("Cannot generate public key: private key is empty")
#             return ''
            
#         try:
#             # Ensure private key ends with newline for wg command
#             private_key_input = private_key.strip() + '\n'
            
#             result = subprocess.run(
#                 ['wg', 'pubkey'], 
#                 input=private_key_input.encode(), 
#                 capture_output=True, 
#                 text=True,
#                 timeout=10
#             )
#             if result.returncode == 0:
#                 public_key = result.stdout.strip()
#                 logger.debug(f"Generated public key: {public_key[:20]}...")
#                 return public_key
#             else:
#                 logger.error(f"wg pubkey failed with return code {result.returncode}: {result.stderr}")
#                 return ''
#         except subprocess.TimeoutExpired:
#             logger.error("wg pubkey command timed out")
#             return ''
#         except FileNotFoundError:
#             logger.error("wg command not found - ensure wireguard-tools is installed")
#             return ''
#         except Exception as e:
#             logger.error(f"Error generating public key: {e}")
#             return ''
            
#     def get_wgrest_data(self):
#         try:
#             devices_resp = requests.get(f"{WGREST_API_URL}/v1/devices/", headers=self.headers)
#             devices_resp.raise_for_status()
#             devices = devices_resp.json()
            
#             interfaces = {}
#             for device in devices:
#                 interfaces[device['name']] = device
            
#             all_peers = {}
#             for device_name in ['wg0', 'wg1']:
#                 try:
#                     peers_resp = requests.get(f"{WGREST_API_URL}/v1/devices/{device_name}/peers/", headers=self.headers)
#                     peers_resp.raise_for_status()
#                     all_peers[device_name] = peers_resp.json()
#                 except requests.exceptions.HTTPError as e:
#                     if e.response.status_code == 404:
#                         all_peers[device_name] = []
#                     else:
#                         raise
                        
#             return interfaces, all_peers
#         except Exception as e:
#             logger.error(f"Failed to fetch wgrest data: {e}")
#             return None, None
            
#     def parse_wireguard_config(self, config_content, interface_name):
#         if not config_content:
#             return {}
            
#         details = {}
#         lines = config_content.split('\n')
        
#         for line in lines:
#             line = line.strip()
#             if '=' in line and not line.startswith('#'):
#                 key, value = line.split('=', 1)
#                 key = key.strip().lower()
#                 value = value.strip()
                
#                 if key == 'address':
#                     details['address'] = value
#                 elif key == 'listenport':
#                     details['listen_port'] = int(value)
#                 elif key == 'privatekey':
#                     details['private_key'] = value
#                 elif key == 'postup':
#                     details['post_up'] = value
#                 elif key == 'postdown':
#                     details['post_down'] = value
                    
#         if 'address' in details:
#             if interface_name == 'wg0':
#                 details['subnet'] = '10.10.0.0/24'
#                 details['endpoint'] = f"{SERVER_IP}:{WG0_PORT}"
#             elif interface_name == 'wg1':
#                 details['subnet'] = '10.11.0.0/24'
#                 details['endpoint'] = f"{SERVER_IP}:{WG1_PORT}"
                
#         return details
        
#     def read_wireguard_configs(self):
#         configs = {}
#         for interface in ['wg0', 'wg1']:
#             try:
#                 with open(f'/etc/wireguard/{interface}.conf', 'r') as f:
#                     configs[interface] = f.read()
#             except FileNotFoundError:
#                 configs[interface] = None
#                 logger.warning(f"Config file for {interface} not found")
#         return configs
        
#     def sync_server_keys_to_database(self, configs):
#         """
#         FIXED: Sync server keys with PROPER encryption using existing encryption functions
#         This ensures server private keys are encrypted consistently
#         """
#         try:
#             with self.conn.cursor() as cur:
#                 for interface_name, config_content in configs.items():
#                     if config_content:
#                         config_details = self.parse_wireguard_config(config_content, interface_name)
#                         private_key = config_details.get('private_key')
                        
#                         if private_key:
#                             # Generate public key from private key
#                             public_key = self.generate_public_key_from_private(private_key)
                            
#                             # Fallback: if wg command fails, try to get from wgrest API
#                             if not public_key:
#                                 logger.warning(f"Failed to generate public key for {interface_name}, trying wgrest API...")
#                                 try:
#                                     interfaces_resp = requests.get(f"{WGREST_API_URL}/v1/devices/", headers=self.headers)
#                                     if interfaces_resp.status_code == 200:
#                                         devices = interfaces_resp.json()
#                                         for device in devices:
#                                             if device['name'] == interface_name:
#                                                 public_key = device.get('public_key', '')
#                                                 logger.info(f"Retrieved public key for {interface_name} from wgrest API")
#                                                 break
#                                 except Exception as e:
#                                     logger.error(f"Failed to get public key from API: {e}")
                            
#                             if not public_key:
#                                 logger.error(f"Could not determine public key for {interface_name}")
#                                 continue
                            
#                             # CRITICAL FIX: Use the existing encryption helper instead of storing plaintext
#                             private_key_encrypted = self.encryption.encrypt(private_key)
                            
#                             if private_key_encrypted:  # Only store if encryption succeeded
#                                 cur.execute("""
#                                     INSERT INTO server_keys (interface_name, private_key, public_key) 
#                                     VALUES (%(interface_name)s, %(private_key)s, %(public_key)s)
#                                     ON CONFLICT (interface_name) DO UPDATE SET
#                                         private_key = EXCLUDED.private_key,
#                                         public_key = EXCLUDED.public_key,
#                                         generated_at = CURRENT_TIMESTAMP
#                                 """, {
#                                     'interface_name': interface_name,
#                                     'private_key': private_key_encrypted,
#                                     'public_key': public_key
#                                 })
                                
#                                 logger.info(f"Server key for {interface_name} encrypted and stored successfully (public key: {public_key[:20]}...)")
#                             else:
#                                 logger.error(f"Failed to encrypt private key for {interface_name}")
#                         else:
#                             logger.warning(f"No private key found in config for {interface_name}")
                            
#         except Exception as e:
#             logger.error(f"Failed to sync server keys: {e}")
        
#     def sync_to_database(self):
#         logger.info("Starting structured data sync with encryption...")
        
#         interfaces, all_peers = self.get_wgrest_data()
#         if interfaces is None:
#             logger.error("Failed to get wgrest data, skipping sync")
#             return
            
#         configs = self.read_wireguard_configs()
        
#         # FIXED: Sync server keys with PROPER encryption using existing functions
#         self.sync_server_keys_to_database(configs)
        
#         try:
#             with self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                
#                 # Sync interfaces with structured data (NO config_content field)
#                 for interface_name, interface_data in interfaces.items():
#                     config_content = configs.get(interface_name, '')
#                     config_details = self.parse_wireguard_config(config_content, interface_name)
                    
#                     # Get the private key from config and encrypt it properly
#                     private_key_raw = config_details.get('private_key', '')
#                     private_key_encrypted = self.encryption.encrypt(private_key_raw) if private_key_raw else None
                    
#                     # Store only structured data, not entire config file
#                     cur.execute("""
#                         INSERT INTO interfaces (name, private_key, public_key, address, listen_port, subnet, endpoint)
#                         VALUES (%(name)s, %(private_key)s, %(public_key)s, %(address)s, %(listen_port)s, %(subnet)s, %(endpoint)s)
#                         ON CONFLICT (name) DO UPDATE SET
#                             private_key = EXCLUDED.private_key,
#                             public_key = EXCLUDED.public_key,
#                             address = EXCLUDED.address,
#                             listen_port = EXCLUDED.listen_port,
#                             subnet = EXCLUDED.subnet,
#                             endpoint = EXCLUDED.endpoint,
#                             last_updated = CURRENT_TIMESTAMP
#                     """, {
#                         'name': interface_name,
#                         'private_key': private_key_encrypted,  # FIXED: Use encrypted version
#                         'public_key': interface_data.get('public_key', ''),
#                         'address': config_details.get('address', ''),
#                         'listen_port': interface_data.get('listen_port', config_details.get('listen_port', 0)),
#                         'subnet': config_details.get('subnet', ''),
#                         'endpoint': config_details.get('endpoint', '')
#                     })
                
#                 # Clear and sync peers with encryption
#                 cur.execute("DELETE FROM peers")
                
#                 total_peers = 0
#                 for interface_name, peers in all_peers.items():
#                     for peer in peers:
#                         # Handle preshared key encryption
#                         preshared_key_raw = peer.get('preshared_key', '')
#                         preshared_key_encrypted = None
#                         if preshared_key_raw and preshared_key_raw.strip():
#                             preshared_key_encrypted = self.encryption.encrypt(preshared_key_raw)
#                             if not preshared_key_encrypted:
#                                 logger.warning(f"Failed to encrypt preshared key for peer {peer.get('public_key', 'unknown')[:20]}...")
                        
#                         # Generate a proper name from public key or use provided name
#                         peer_name = peer.get('name', '')
#                         if not peer_name:
#                             # Use last 8 chars of public key as name if no name provided
#                             pub_key = peer.get('public_key', '')
#                             peer_name = f"peer_{pub_key[-8:]}" if pub_key else f"peer_{total_peers + 1}"
                        
#                         # Handle allowed IPs - ensure it's always a valid JSON array
#                         allowed_ips = peer.get('allowed_ips', [])
#                         if not isinstance(allowed_ips, list):
#                             # Convert string to list if needed
#                             if isinstance(allowed_ips, str):
#                                 allowed_ips = [ip.strip() for ip in allowed_ips.split(',') if ip.strip()]
#                             else:
#                                 allowed_ips = []
                        
#                         # Handle persistent keepalive
#                         keepalive = peer.get('persistent_keepalive_interval')
#                         if keepalive is not None:
#                             try:
#                                 keepalive = int(keepalive) if keepalive > 0 else None
#                             except (ValueError, TypeError):
#                                 keepalive = None
                        
#                         # Get endpoint
#                         endpoint = peer.get('endpoint', '')
#                         if endpoint and not isinstance(endpoint, str):
#                             endpoint = str(endpoint)
                        
#                         cur.execute("""
#                             INSERT INTO peers (interface_name, name, private_key, public_key, allowed_ips, 
#                                              endpoint, persistent_keepalive, enabled, preshared_key)
#                             VALUES (%(interface_name)s, %(name)s, %(private_key)s, %(public_key)s, 
#                                    %(allowed_ips)s, %(endpoint)s, %(persistent_keepalive)s, %(enabled)s, %(preshared_key)s)
#                         """, {
#                             'interface_name': interface_name,
#                             'name': peer_name[:100],  # Reasonable limit for name
#                             'private_key': '',  # Client private keys not exposed by wgrest API
#                             'public_key': peer.get('public_key', ''),
#                             'allowed_ips': json.dumps(allowed_ips),
#                             'endpoint': endpoint if endpoint else None,
#                             'persistent_keepalive': keepalive,
#                             'enabled': peer.get('enabled', True),
#                             'preshared_key': preshared_key_encrypted
#                         })
#                         total_peers += 1
                        
#                         # Log peer sync details
#                         logger.debug(f"Synced peer {peer_name} on {interface_name}: "
#                                    f"IPs={len(allowed_ips)}, PSK={'yes' if preshared_key_encrypted else 'no'}, "
#                                    f"Endpoint={'yes' if endpoint else 'no'}")
                        
                
#                 # Update sync status - FIXED: Always create sync status record
#                 wg0_count = len(all_peers.get('wg0', []))
#                 wg1_count = len(all_peers.get('wg1', []))
                
#                 cur.execute("""
#                     INSERT INTO sync_status (peer_count_wg0, peer_count_wg1, status) 
#                     VALUES (%(wg0)s, %(wg1)s, 'completed')
#                 """, {'wg0': wg0_count, 'wg1': wg1_count})
                
#                 logger.info(f"Structured sync completed: {total_peers} peers synced ({wg0_count} wg0, {wg1_count} wg1)")
                
#                 # Verify encryption worked
#                 cur.execute("SELECT COUNT(*) FROM server_keys WHERE private_key IS NOT NULL AND private_key != ''")
#                 encrypted_keys_count = cur.fetchone()[0]
                
#                 cur.execute("SELECT COUNT(*) FROM interfaces WHERE private_key IS NOT NULL AND private_key != ''")
#                 encrypted_interfaces_count = cur.fetchone()[0]
                
#                 # Verify peer encryption (count peers with encrypted PSKs)
#                 cur.execute("SELECT COUNT(*) FROM peers WHERE preshared_key IS NOT NULL AND preshared_key != ''")
#                 encrypted_psk_count = cur.fetchone()[0]
                
#                 logger.info(f"Encryption verification: {encrypted_keys_count} server keys encrypted, "
#                           f"{encrypted_interfaces_count} interface keys encrypted, "
#                           f"{encrypted_psk_count} peer PSKs encrypted")
                
#                 # Log peer details for debugging
#                 if total_peers > 0:
#                     cur.execute("""
#                         SELECT interface_name, COUNT(*) as peer_count, 
#                                COUNT(CASE WHEN preshared_key IS NOT NULL THEN 1 END) as psk_count,
#                                COUNT(CASE WHEN endpoint IS NOT NULL THEN 1 END) as endpoint_count
#                         FROM peers 
#                         GROUP BY interface_name
#                     """)
#                     peer_stats = cur.fetchall()
#                     for interface_name, peer_count, psk_count, endpoint_count in peer_stats:
#                         logger.info(f"Interface {interface_name}: {peer_count} peers, "
#                                   f"{psk_count} with PSK, {endpoint_count} with endpoints")
                
#         except Exception as e:
#             logger.error(f"Database sync failed: {e}")
#             raise

# def main():
#     global sync_service
#     sync_service = WgrestSyncService()
#     sync_service.connect_db()
    
#     logger.info("Performing initial structured sync with proper encryption...")
#     sync_service.sync_to_database()
    
#     if SYNC_MODE == 'event-driven':
#         logger.info("Starting event-driven sync mode with structured data storage")
#         sync_service.setup_file_monitoring()
#         sync_service.setup_webhook_server()
        
#         if CLEANUP_ENABLED:
#             schedule.every().day.at(CLEANUP_TIME).do(sync_service.cleanup_old_sync_logs)
#             logger.info(f"Daily cleanup scheduled for {CLEANUP_TIME}")
            
#         try:
#             while True:
#                 schedule.run_pending()
#                 time.sleep(60)
#         except KeyboardInterrupt:
#             logger.info("Shutting down sync service")
#             if sync_service.observer:
#                 sync_service.observer.stop()
#                 sync_service.observer.join()
#             if sync_service.webhook_server:
#                 sync_service.webhook_server.shutdown()
#     else:
#         logger.info(f"Starting polling mode with structured data storage (interval: {POLLING_INTERVAL}s)")
#         schedule.every(POLLING_INTERVAL).seconds.do(sync_service.sync_to_database)
        
#         if CLEANUP_ENABLED:
#             schedule.every().day.at(CLEANUP_TIME).do(sync_service.cleanup_old_sync_logs)
            
#         while True:
#             try:
#                 schedule.run_pending()
#                 time.sleep(1)
#             except KeyboardInterrupt:
#                 logger.info("Shutting down sync service")
#                 break

# if __name__ == "__main__":
#     main()