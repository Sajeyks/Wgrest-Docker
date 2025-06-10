#!/usr/bin/env python3
"""
Modular WireGuard sync service
Event-driven synchronization between wgrest API and PostgreSQL database
"""

import logging
import schedule
import time
from typing import Optional

# Import our modular components
from config import SyncConfig
from encryption import EncryptionHelper
from wgrest_api import WgrestApiClient
from config_parser import WireGuardConfigParser
from database import SyncDatabase
from webhook import WebhookServer
from file_watcher import FileWatcher
from data_processor import DataProcessor

# Setup logging
logging.basicConfig(
    level=logging.INFO, 
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class WgrestSyncService:
    """
    Main sync service coordinating all components
    """
    
    def __init__(self):
        """Initialize the sync service with all components"""
        # Load configuration
        self.config = SyncConfig()
        logger.info("Configuration loaded successfully")
        
        # Initialize core components
        self.encryption = EncryptionHelper(self.config.encryption_key)
        self.config_parser = WireGuardConfigParser()
        self.api_client = WgrestApiClient(
            self.config.wgrest_api_url, 
            self.config.request_headers
        )
        self.database = SyncDatabase(self.config.database_url)
        
        # Initialize data processor
        self.data_processor = DataProcessor(
            encryption_helper=self.encryption,
            config_parser=self.config_parser,
            subnet_config_func=self.config.get_subnet_config
        )
        
        # Initialize optional components
        self.webhook_server: Optional[WebhookServer] = None
        self.file_watcher: Optional[FileWatcher] = None
        
        logger.info("All components initialized successfully")
    
    def setup_event_driven_components(self):
        """Setup components for event-driven mode"""
        if self.config.sync_mode != 'event-driven':
            return
        
        # Setup webhook server
        if self.config.webhook_enabled:
            self.webhook_server = WebhookServer(
                port=self.config.webhook_port,
                api_key=self.config.wgrest_api_key,
                sync_callback=self.sync_to_database
            )
            self.webhook_server.start()
            logger.info(f"Webhook server started on port {self.config.webhook_port}")
        
        # Setup file watcher
        try:
            self.file_watcher = FileWatcher(
                watch_dir='/etc/wireguard',
                sync_callback=self.sync_to_database,
                debounce_seconds=self.config.debounce_seconds
            )
            self.file_watcher.start()
            logger.info("File monitoring started for /etc/wireguard")
        except Exception as e:
            logger.error(f"Failed to setup file monitoring: {e}")
    
    def sync_to_database(self):
        """
        Main sync method - orchestrates the entire sync process
        """
        logger.info("Starting structured data sync with encryption...")
        
        try:
            # Step 1: Get data from wgrest API
            wgrest_interfaces, all_peers = self._fetch_wgrest_data()
            if wgrest_interfaces is None:
                logger.error("Failed to get wgrest data, skipping sync")
                return
            
            # Step 2: Read WireGuard config files
            configs = self.config_parser.read_all_configs()
            
            # Step 3: Process and sync server keys
            server_keys_data = self.data_processor.process_server_keys(
                configs, self.api_client
            )
            if server_keys_data:
                self.database.sync_server_keys(server_keys_data)
            
            # Step 4: Process and sync interfaces
            interfaces_data = self.data_processor.process_interfaces(
                wgrest_interfaces, configs
            )
            if interfaces_data:
                self.database.sync_interfaces(interfaces_data)
            
            # Step 5: Process and sync peers
            if all_peers is not None:
                peers_data, peer_counts = self.data_processor.process_peers(all_peers)
                if peers_data:
                    self.database.sync_peers(peers_data)
            else:
                peer_counts = {}
            
            # Step 6: Update sync status
            self.database.update_sync_status(peer_counts, 'completed')
            
            # Step 7: Log verification statistics
            self._log_sync_verification(peer_counts)
            
            logger.info("Structured sync completed successfully")
            
        except Exception as e:
            logger.error(f"Database sync failed: {e}")
            # Update sync status as failed
            try:
                self.database.update_sync_status({}, 'failed')
            except:
                pass  # Don't fail on status update failure
            raise
    
    def _fetch_wgrest_data(self):
        """Fetch data from wgrest API with error handling"""
        try:
            # Get interfaces
            wgrest_interfaces = self.api_client.get_interfaces()
            if wgrest_interfaces is None:
                return None, None
            
            # Get all peers
            all_peers = self.api_client.get_all_peers(['wg0', 'wg1'])
            if all_peers is None:
                return None, None
            
            logger.debug(f"Fetched {len(wgrest_interfaces)} interfaces and "
                        f"{sum(len(peers) for peers in all_peers.values())} total peers")
            
            return wgrest_interfaces, all_peers
            
        except Exception as e:
            logger.error(f"Failed to fetch wgrest data: {e}")
            return None, None
    
    def _log_sync_verification(self, peer_counts: dict):
        """Log verification statistics after sync"""
        try:
            # Get encryption stats
            encryption_stats = self.database.get_encryption_stats()
            
            # Get peer stats
            peer_stats = self.database.get_peer_stats()
            
            # Log encryption verification
            logger.info(f"Encryption verification: "
                       f"{encryption_stats.get('encrypted_server_keys', 0)} server keys encrypted, "
                       f"{encryption_stats.get('encrypted_interface_keys', 0)} interface keys encrypted, "
                       f"{encryption_stats.get('encrypted_psks', 0)} peer PSKs encrypted")
            
            # Log peer details
            total_peers = sum(peer_counts.values())
            if total_peers > 0:
                for interface_name, peer_count, psk_count, endpoint_count in peer_stats:
                    logger.info(f"Interface {interface_name}: {peer_count} peers, "
                               f"{psk_count} with PSK, {endpoint_count} with endpoints")
            
        except Exception as e:
            logger.error(f"Failed to log verification stats: {e}")
    
    def cleanup_old_sync_logs(self):
        """Clean up old sync status records"""
        if not self.config.cleanup_enabled:
            return
        
        try:
            self.database.cleanup_old_sync_logs(self.config.cleanup_older_than_hours)
        except Exception as e:
            logger.error(f"Failed to cleanup old sync logs: {e}")
    
    def run_event_driven_mode(self):
        """Run the service in event-driven mode"""
        logger.info("Starting event-driven sync mode with structured data storage")
        
        # Setup event-driven components
        self.setup_event_driven_components()
        
        # Schedule cleanup if enabled
        if self.config.cleanup_enabled:
            schedule.every().day.at(self.config.cleanup_time).do(self.cleanup_old_sync_logs)
            logger.info(f"Daily cleanup scheduled for {self.config.cleanup_time}")
        
        try:
            # Main event loop
            while True:
                schedule.run_pending()
                time.sleep(60)  # Check scheduled tasks every minute
                
        except KeyboardInterrupt:
            logger.info("Shutting down sync service")
            self.shutdown()
    
    def run_polling_mode(self):
        """Run the service in polling mode"""
        logger.info(f"Starting polling mode with structured data storage "
                   f"(interval: {self.config.polling_interval}s)")
        
        # Schedule regular sync
        schedule.every(self.config.polling_interval).seconds.do(self.sync_to_database)
        
        # Schedule cleanup if enabled
        if self.config.cleanup_enabled:
            schedule.every().day.at(self.config.cleanup_time).do(self.cleanup_old_sync_logs)
            logger.info(f"Daily cleanup scheduled for {self.config.cleanup_time}")
        
        try:
            # Main polling loop
            while True:
                schedule.run_pending()
                time.sleep(1)
                
        except KeyboardInterrupt:
            logger.info("Shutting down sync service")
            self.shutdown()
    
    def run(self):
        """Run the sync service in the configured mode"""
        # Perform initial sync
        logger.info("Performing initial structured sync with proper encryption...")
        try:
            self.sync_to_database()
        except Exception as e:
            logger.error(f"Initial sync failed: {e}")
            # Continue running even if initial sync fails
        
        # Run in appropriate mode
        if self.config.sync_mode == 'event-driven':
            self.run_event_driven_mode()
        else:
            self.run_polling_mode()
    
    def shutdown(self):
        """Gracefully shutdown the service"""
        logger.info("Shutting down sync service...")
        
        # Stop webhook server
        if self.webhook_server:
            self.webhook_server.stop()
        
        # Stop file watcher
        if self.file_watcher:
            self.file_watcher.stop()
        
        # Close database connection
        if self.database:
            self.database.close()
        
        logger.info("Shutdown complete")

def main():
    """Main entry point"""
    try:
        sync_service = WgrestSyncService()
        sync_service.run()
    except Exception as e:
        logger.error(f"Failed to start sync service: {e}")
        raise

if __name__ == "__main__":
    main()