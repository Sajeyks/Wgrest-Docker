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
        self.wgrest_port = os.getenv('WGREST_PORT', '8080')
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
        
        # WireGuard Configuration - Use environment variables for all subnets and ports
        self.server_ip = os.getenv('SERVER_IP', 'localhost')
        
        # WG0 Configuration
        self.wg0_port = os.getenv('WG0_PORT', '51820')
        self.wg0_subnet = os.getenv('WG0_SUBNET', '10.10.0.0/8')
        self.wg0_address = os.getenv('WG0_ADDRESS', '10.10.0.1/8')
        
        # WG1 Configuration
        self.wg1_port = os.getenv('WG1_PORT', '51821')
        self.wg1_subnet = os.getenv('WG1_SUBNET', '10.11.0.0/8')
        self.wg1_address = os.getenv('WG1_ADDRESS', '10.11.0.1/8')
        
        # FreeRADIUS Configuration
        self.radius_auth_port = os.getenv('RADIUS_AUTH_PORT', '1812')
        self.radius_acct_port = os.getenv('RADIUS_ACCT_PORT', '1813')
        
        # Target configuration
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
            ('SERVER_IP', self.server_ip),
        ]
        
        missing_vars = [name for name, value in required_vars if not value]
        
        if missing_vars:
            raise ValueError(f"Missing required environment variables: {', '.join(missing_vars)}")
        
        if not self.encryption_key:
            raise ValueError("Could not setup encryption key")
        
        logger.info(f"Configuration loaded: sync_mode={self.sync_mode}, "
                   f"webhook_enabled={self.webhook_enabled}, cleanup_enabled={self.cleanup_enabled}")
        logger.info(f"WireGuard subnets: wg0={self.wg0_subnet}, wg1={self.wg1_subnet}")
    
    @property
    def request_headers(self) -> dict:
        """Get headers for wgrest API requests"""
        return {'Authorization': f'Bearer {self.wgrest_api_key}'}
    
    def get_subnet_config(self, interface_name: str) -> dict:
        """Get subnet configuration for interface"""
        if interface_name == 'wg0':
            return {
                'subnet': self.wg0_subnet,
                'endpoint': f"{self.server_ip}:{self.wg0_port}",
                'address': self.wg0_address
            }
        elif interface_name == 'wg1':
            return {
                'subnet': self.wg1_subnet,
                'endpoint': f"{self.server_ip}:{self.wg1_port}",
                'address': self.wg1_address
            }
        else:
            return {'subnet': '', 'endpoint': '', 'address': ''}
    
    def get_wg0_postup_rules(self) -> str:
        """Get PostUp iptables rules for wg0 (FreeRADIUS)"""
        subnet_base = self.wg0_subnet.split('/')[0].rsplit('.', 1)[0] + '.0'
        return (f"iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport {self.radius_auth_port} -j ACCEPT; "
                f"iptables -A FORWARD -i wg0 -p udp -d 127.0.0.1 --dport {self.radius_acct_port} -j ACCEPT; "
                f"iptables -t nat -A POSTROUTING -s {self.wg0_subnet} -d 127.0.0.1 -j MASQUERADE")
    
    def get_wg0_postdown_rules(self) -> str:
        """Get PostDown iptables rules for wg0 (FreeRADIUS)"""
        subnet_base = self.wg0_subnet.split('/')[0].rsplit('.', 1)[0] + '.0'
        return (f"iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport {self.radius_auth_port} -j ACCEPT; "
                f"iptables -D FORWARD -i wg0 -p udp -d 127.0.0.1 --dport {self.radius_acct_port} -j ACCEPT; "
                f"iptables -t nat -D POSTROUTING -s {self.wg0_subnet} -d 127.0.0.1 -j MASQUERADE")
    
    def get_wg1_postup_rules(self) -> str:
        """Get PostUp iptables rules for wg1 (MikroTik)"""
        return (f"iptables -A FORWARD -i wg1 -d {self.target_website_ip} -j ACCEPT; "
                f"iptables -t nat -A POSTROUTING -s {self.wg1_subnet} -d {self.target_website_ip} -j MASQUERADE")
    
    def get_wg1_postdown_rules(self) -> str:
        """Get PostDown iptables rules for wg1 (MikroTik)"""
        return (f"iptables -D FORWARD -i wg1 -d {self.target_website_ip} -j ACCEPT; "
                f"iptables -t nat -D POSTROUTING -s {self.wg1_subnet} -d {self.target_website_ip} -j MASQUERADE")