#!/usr/bin/env python3
"""
WireGuard configuration file parser
Handles reading and parsing WireGuard configuration files
"""

import os
import logging
import subprocess
from typing import Dict, Optional

logger = logging.getLogger(__name__)

class WireGuardConfigParser:
    """Parser for WireGuard configuration files"""
    
    def __init__(self, config_dir: str = "/etc/wireguard"):
        """
        Initialize config parser
        
        Args:
            config_dir: Directory containing WireGuard config files
        """
        self.config_dir = config_dir
    
    def read_config_file(self, interface_name: str) -> Optional[str]:
        """
        Read WireGuard configuration file content
        
        Args:
            interface_name: Interface name (e.g., 'wg0')
            
        Returns:
            Configuration file content as string, or None if not found
        """
        config_path = os.path.join(self.config_dir, f"{interface_name}.conf")
        
        try:
            with open(config_path, 'r') as f:
                content = f.read()
            logger.debug(f"Read config file for {interface_name} ({len(content)} chars)")
            return content
        except FileNotFoundError:
            logger.warning(f"Config file for {interface_name} not found at {config_path}")
            return None
        except PermissionError:
            logger.error(f"Permission denied reading config file for {interface_name}")
            return None
        except Exception as e:
            logger.error(f"Error reading config file for {interface_name}: {e}")
            return None
    
    def read_all_configs(self, interface_names: list = None) -> Dict[str, Optional[str]]:
        """
        Read all WireGuard configuration files
        
        Args:
            interface_names: List of interfaces to read, defaults to ['wg0', 'wg1']
            
        Returns:
            Dictionary mapping interface names to config content
        """
        if interface_names is None:
            interface_names = ['wg0', 'wg1']
        
        configs = {}
        for interface_name in interface_names:
            configs[interface_name] = self.read_config_file(interface_name)
        
        logger.info(f"Read {sum(1 for c in configs.values() if c is not None)} config files")
        return configs
    
    def parse_config_content(self, config_content: str, interface_name: str, subnet_config: dict) -> dict:
        """
        Parse WireGuard configuration content into structured data
        
        Args:
            config_content: Raw configuration file content
            interface_name: Interface name for context
            subnet_config: Subnet configuration from config
            
        Returns:
            Dictionary with parsed configuration details
        """
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
                    try:
                        details['listen_port'] = int(value)
                    except ValueError:
                        logger.warning(f"Invalid listen port '{value}' for {interface_name}")
                elif key == 'privatekey':
                    details['private_key'] = value
                elif key == 'postup':
                    details['post_up'] = value
                elif key == 'postdown':
                    details['post_down'] = value
        
        # Add subnet configuration if address is present
        if 'address' in details and subnet_config:
            details.update(subnet_config)
        
        logger.debug(f"Parsed config for {interface_name}: {list(details.keys())}")
        return details
    
    def generate_public_key_from_private(self, private_key: str) -> str:
        """
        Generate public key from private key using wg command
        
        Args:
            private_key: WireGuard private key
            
        Returns:
            Public key string, or empty string on failure
        """
        if not private_key or private_key.strip() == '':
            logger.error("Cannot generate public key: private key is empty")
            return ''
        
        try:
            # Ensure private key ends with newline for wg command
            private_key_input = private_key.strip() + '\n'
            
            result = subprocess.run(
                ['wg', 'pubkey'],
                input=private_key_input.encode(),
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode == 0:
                public_key = result.stdout.strip()
                logger.debug(f"Generated public key: {public_key[:20]}...")
                return public_key
            else:
                logger.error(f"wg pubkey failed with return code {result.returncode}: {result.stderr}")
                return ''
                
        except subprocess.TimeoutExpired:
            logger.error("wg pubkey command timed out")
            return ''
        except FileNotFoundError:
            logger.error("wg command not found - ensure wireguard-tools is installed")
            return ''
        except Exception as e:
            logger.error(f"Error generating public key: {e}")
            return ''