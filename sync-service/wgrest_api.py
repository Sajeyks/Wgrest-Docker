#!/usr/bin/env python3
"""
WireGuard REST API client
Handles all interactions with the wgrest API
"""

import requests
import logging
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

class WgrestApiClient:
    """Client for interacting with wgrest API"""
    
    def __init__(self, api_url: str, headers: dict):
        """
        Initialize API client
        
        Args:
            api_url: Base URL for wgrest API
            headers: Request headers (including authorization)
        """
        self.api_url = api_url.rstrip('/')
        self.headers = headers
        self.timeout = 30
        
    def get_interfaces(self) -> Optional[Dict[str, dict]]:
        """
        Get all WireGuard interfaces from wgrest
        
        Returns:
            Dictionary mapping interface names to interface data, or None on error
        """
        try:
            response = requests.get(
                f"{self.api_url}/v1/devices/", 
                headers=self.headers,
                timeout=self.timeout
            )
            response.raise_for_status()
            devices = response.json()
            
            interfaces = {}
            for device in devices:
                interfaces[device['name']] = device
                
            logger.debug(f"Retrieved {len(interfaces)} interfaces from wgrest")
            return interfaces
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to fetch interfaces from wgrest: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error fetching interfaces: {e}")
            return None
    
    def get_peers(self, interface_name: str) -> Optional[List[dict]]:
        """
        Get all peers for a specific interface
        
        Args:
            interface_name: Name of the interface (e.g., 'wg0')
            
        Returns:
            List of peer data dictionaries, or None on error
        """
        try:
            response = requests.get(
                f"{self.api_url}/v1/devices/{interface_name}/peers/",
                headers=self.headers,
                timeout=self.timeout
            )
            response.raise_for_status()
            peers = response.json()
            
            logger.debug(f"Retrieved {len(peers)} peers from {interface_name}")
            return peers
            
        except requests.exceptions.HTTPError as e:
            if e.response.status_code == 404:
                logger.warning(f"Interface {interface_name} not found, returning empty peer list")
                return []
            else:
                logger.error(f"HTTP error fetching peers for {interface_name}: {e}")
                return None
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to fetch peers for {interface_name}: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error fetching peers for {interface_name}: {e}")
            return None
    
    def get_all_peers(self, interface_names: List[str] = None) -> Optional[Dict[str, List[dict]]]:
        """
        Get peers for all specified interfaces
        
        Args:
            interface_names: List of interface names, defaults to ['wg0', 'wg1']
            
        Returns:
            Dictionary mapping interface names to peer lists, or None on error
        """
        if interface_names is None:
            interface_names = ['wg0', 'wg1']
            
        all_peers = {}
        
        for interface_name in interface_names:
            peers = self.get_peers(interface_name)
            if peers is not None:
                all_peers[interface_name] = peers
            else:
                logger.warning(f"Could not fetch peers for {interface_name}")
                all_peers[interface_name] = []
                
        logger.info(f"Retrieved peers for {len(all_peers)} interfaces")
        return all_peers
    
    def health_check(self) -> bool:
        """
        Check if wgrest API is healthy and responding
        
        Returns:
            True if API is healthy, False otherwise
        """
        try:
            response = requests.get(
                f"{self.api_url}/v1/devices/",
                headers=self.headers,
                timeout=5
            )
            return response.status_code == 200
        except Exception:
            return False