#!/usr/bin/env python3
"""
Configuration management for the WireGuard sync service
Centralizes all environment variable handling and validation
"""

import os
import logging
from typing import Optional

logger = logging.getLogger(__name__)

class SyncConfig:
    """Configuration class for the sync service"""
    
    def __init__(self):
        # Core API Configuration
        self.wgrest_port = os.getenv('WGREST_PORT', '51822')
        self.wgrest_api_url = os.getenv('WGREST_API_URL', f'http://localhost:{self.wgrest_port}')
        self.wgrest_api_key = os.getenv('WGREST_API_KEY')
        self.database_url = os.getenv('DATABASE_URL')
        
        # Event-driven Configuration
        self.sync_mode = os.getenv('SYNC_MODE', 'event-driven')
        self.polling_interval = int(os.getenv('SYNC_INTERVAL', 300))
        self.debounce_seconds = int(os.getenv('DEBOUNCE_SECONDS', 5))
        self.webhook_port = int(os.getenv('WEBHOOK_PORT', '8090'))
        self.webhook_enabled = os.getenv('WEBHOOK_ENABLED', 'true').lower() == 'true'
        
        # Encryption Configuration
        self.encryption_key = self._setup_encryption_key()
        
        # Cleanup Configuration
        self.cleanup_enabled = os.getenv('CLEANUP_ENABLED', 'true').lower() == 'true'
        self.cleanup_older_than_hours = int(os.getenv('CLEANUP_OLDER_THAN_HOURS', 24))
        self.cleanup_time = os.getenv('CLEANUP_TIME', '02:00')
        
        # Server Configuration
        self.server_ip = os.getenv('SERVER_IP', 'localhost')
        self.wg0_port = os.getenv('WG0_PORT', '51820')
        self.wg1_port = os.getenv('WG1_PORT', '51821')
        self.target_website_ip = os.getenv('TARGET_WEBSITE_IP', '127.0.0.1')
        
        # Validate required settings
        self._validate_config()
    
    def _setup_encryption_key(self) -> Optional[str]:
        """Setup encryption key from environment or derive from API key"""
        import hashlib
        import base64
        
        encryption_key = os.getenv('DB_ENCRYPTION_KEY')
        if not encryption_key and self.wgrest_api_key:
            key_material = hashlib.sha256(self.wgrest_api_key.encode()).digest()
            encryption_key = base64.urlsafe_b64encode(key_material).decode()
        
        return encryption_key
    
    def _validate_config(self):
        """Validate required configuration parameters"""
        required_vars = [
            ('WGREST_API_KEY', self.wgrest_api_key),
            ('DATABASE_URL', self.database_url),
        ]
        
        missing_vars = [name for name, value in required_vars if not value]
        
        if missing_vars:
            raise ValueError(f"Missing required environment variables: {', '.join(missing_vars)}")
        
        if not self.encryption_key:
            raise ValueError("Could not setup encryption key")
        
        logger.info(f"Configuration loaded: sync_mode={self.sync_mode}, "
                   f"webhook_enabled={self.webhook_enabled}, cleanup_enabled={self.cleanup_enabled}")
    
    @property
    def request_headers(self) -> dict:
        """Get headers for wgrest API requests"""
        return {'Authorization': f'Bearer {self.wgrest_api_key}'}
    
    def get_subnet_config(self, interface_name: str) -> dict:
        """Get subnet configuration for interface"""
        if interface_name == 'wg0':
            return {
                'subnet': '10.10.0.0/24',
                'endpoint': f"{self.server_ip}:{self.wg0_port}"
            }
        elif interface_name == 'wg1':
            return {
                'subnet': '10.11.0.0/24',
                'endpoint': f"{self.server_ip}:{self.wg1_port}"
            }
        else:
            return {'subnet': '', 'endpoint': ''}