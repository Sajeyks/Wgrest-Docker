#!/usr/bin/env python3
"""
Data processing logic for the sync service
Handles transformation and validation of data between wgrest API and database
"""

import json
import logging
from typing import Dict, List, Tuple, Optional

logger = logging.getLogger(__name__)

class DataProcessor:
    """Processes and transforms data for sync operations"""
    
    def __init__(self, encryption_helper, config_parser, subnet_config_func):
        """
        Initialize data processor
        
        Args:
            encryption_helper: EncryptionHelper instance
            config_parser: WireGuardConfigParser instance  
            subnet_config_func: Function to get subnet config for interface
        """
        self.encryption = encryption_helper
        self.config_parser = config_parser
        self.get_subnet_config = subnet_config_func
    
    def process_server_keys(self, configs: Dict[str, str], api_client) -> List[Tuple[str, str, str]]:
        """
        Process server keys from configs and generate encrypted data
        
        Args:
            configs: Dictionary mapping interface names to config content
            api_client: WgrestApiClient for fallback public key retrieval
            
        Returns:
            List of tuples (interface_name, encrypted_private_key, public_key)
        """
        server_keys_data = []
        
        for interface_name, config_content in configs.items():
            if not config_content:
                continue
                
            config_details = self.config_parser.parse_config_content(
                config_content, interface_name, self.get_subnet_config(interface_name)
            )
            
            private_key = config_details.get('private_key')
            if not private_key:
                logger.warning(f"No private key found in config for {interface_name}")
                continue
            
            # Generate public key from private key
            public_key = self.config_parser.generate_public_key_from_private(private_key)
            
            # Fallback: try to get public key from API if generation fails
            if not public_key:
                logger.warning(f"Failed to generate public key for {interface_name}, trying API...")
                public_key = self._get_public_key_from_api(interface_name, api_client)
            
            if not public_key:
                logger.error(f"Could not determine public key for {interface_name}")
                continue
            
            # Encrypt private key
            encrypted_private_key = self.encryption.encrypt(private_key)
            if not encrypted_private_key:
                logger.error(f"Failed to encrypt private key for {interface_name}")
                continue
            
            server_keys_data.append((interface_name, encrypted_private_key, public_key))
            logger.debug(f"Processed server key for {interface_name}")
        
        return server_keys_data
    
    def process_interfaces(self, wgrest_interfaces: Dict[str, dict], configs: Dict[str, str]) -> List[dict]:
        """
        Process interface data from wgrest API and configs
        
        Args:
            wgrest_interfaces: Interface data from wgrest API
            configs: Configuration file contents
            
        Returns:
            List of interface data dictionaries for database
        """
        interfaces_data = []
        
        for interface_name, interface_data in wgrest_interfaces.items():
            config_content = configs.get(interface_name, '')
            config_details = self.config_parser.parse_config_content(
                config_content, interface_name, self.get_subnet_config(interface_name)
            )
            
            # Get and encrypt private key
            private_key_raw = config_details.get('private_key', '')
            private_key_encrypted = self.encryption.encrypt(private_key_raw) if private_key_raw else None
            
            interface_db_data = {
                'name': interface_name,
                'private_key': private_key_encrypted,
                'public_key': interface_data.get('public_key', ''),
                'address': config_details.get('address', ''),
                'listen_port': interface_data.get('listen_port', config_details.get('listen_port', 0)),
                'subnet': config_details.get('subnet', ''),
                'endpoint': config_details.get('endpoint', '')
            }
            
            interfaces_data.append(interface_db_data)
            logger.debug(f"Processed interface {interface_name}")
        
        return interfaces_data
    
    def process_peers(self, all_peers: Dict[str, List[dict]]) -> Tuple[List[dict], Dict[str, int]]:
        """
        Process peer data from wgrest API
        
        Args:
            all_peers: Dictionary mapping interface names to peer lists
            
        Returns:
            Tuple of (processed_peer_data, peer_counts)
        """
        peers_data = []
        peer_counts = {}
        total_peers = 0
        
        for interface_name, peers in all_peers.items():
            interface_peer_count = 0
            
            for peer in peers:
                processed_peer = self._process_single_peer(peer, interface_name, total_peers + 1)
                if processed_peer:
                    peers_data.append(processed_peer)
                    interface_peer_count += 1
                    total_peers += 1
            
            peer_counts[interface_name] = interface_peer_count
            logger.debug(f"Processed {interface_peer_count} peers for {interface_name}")
        
        logger.info(f"Processed {total_peers} total peers")
        return peers_data, peer_counts
    
    def _process_single_peer(self, peer: dict, interface_name: str, peer_number: int) -> Optional[dict]:
        """
        Process a single peer's data
        
        Args:
            peer: Peer data from wgrest API
            interface_name: Interface this peer belongs to
            peer_number: Sequential peer number for naming
            
        Returns:
            Processed peer data dictionary, or None if processing fails
        """
        try:
            # Handle preshared key encryption
            preshared_key_raw = peer.get('preshared_key', '')
            preshared_key_encrypted = None
            if preshared_key_raw and preshared_key_raw.strip():
                preshared_key_encrypted = self.encryption.encrypt(preshared_key_raw)
                if not preshared_key_encrypted:
                    logger.warning(f"Failed to encrypt preshared key for peer {peer.get('public_key', 'unknown')[:20]}...")
            
            # Generate peer name
            peer_name = self._generate_peer_name(peer, peer_number)
            
            # Handle allowed IPs
            allowed_ips = self._process_allowed_ips(peer.get('allowed_ips', []))
            
            # Handle persistent keepalive
            keepalive = self._process_keepalive(peer.get('persistent_keepalive_interval'))
            
            # Handle endpoint
            endpoint = self._process_endpoint(peer.get('endpoint', ''))
            
            peer_data = {
                'interface_name': interface_name,
                'name': peer_name[:100],  # Reasonable limit for name
                'private_key': '',  # Client private keys not exposed by wgrest API
                'public_key': peer.get('public_key', ''),
                'allowed_ips': json.dumps(allowed_ips),
                'endpoint': endpoint,
                'persistent_keepalive': keepalive,
                'enabled': peer.get('enabled', True),
                'preshared_key': preshared_key_encrypted
            }
            
            logger.debug(f"Processed peer {peer_name} on {interface_name}: "
                        f"IPs={len(allowed_ips)}, PSK={'yes' if preshared_key_encrypted else 'no'}, "
                        f"Endpoint={'yes' if endpoint else 'no'}")
            
            return peer_data
            
        except Exception as e:
            logger.error(f"Failed to process peer: {e}")
            return None
    
    def _generate_peer_name(self, peer: dict, peer_number: int) -> str:
        """Generate a meaningful name for the peer"""
        peer_name = peer.get('name', '')
        if not peer_name:
            # Use last 8 chars of public key as name if no name provided
            pub_key = peer.get('public_key', '')
            if pub_key and len(pub_key) >= 8:
                peer_name = f"peer_{pub_key[-8:]}"
            else:
                peer_name = f"peer_{peer_number}"
        return peer_name
    
    def _process_allowed_ips(self, allowed_ips) -> List[str]:
        """Process and validate allowed IPs"""
        if not allowed_ips:
            return []
        
        if isinstance(allowed_ips, list):
            return [ip.strip() for ip in allowed_ips if ip.strip()]
        elif isinstance(allowed_ips, str):
            # Convert string to list if needed
            return [ip.strip() for ip in allowed_ips.split(',') if ip.strip()]
        else:
            logger.warning(f"Unexpected allowed_ips format: {type(allowed_ips)}")
            return []
    
    def _process_keepalive(self, keepalive) -> Optional[int]:
        """Process persistent keepalive value"""
        if keepalive is not None:
            try:
                keepalive_int = int(keepalive)
                return keepalive_int if keepalive_int > 0 else None
            except (ValueError, TypeError):
                logger.warning(f"Invalid keepalive value: {keepalive}")
                return None
        return None
    
    def _process_endpoint(self, endpoint) -> Optional[str]:
        """Process endpoint value"""
        if endpoint and not isinstance(endpoint, str):
            endpoint = str(endpoint)
        return endpoint if endpoint else None
    
    def _get_public_key_from_api(self, interface_name: str, api_client) -> str:
        """Fallback method to get public key from wgrest API"""
        try:
            interfaces = api_client.get_interfaces()
            if interfaces and interface_name in interfaces:
                return interfaces[interface_name].get('public_key', '')
        except Exception as e:
            logger.error(f"Failed to get public key from API for {interface_name}: {e}")
        return ''