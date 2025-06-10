#!/usr/bin/env python3
"""
Encryption helper for sensitive data in the sync service
Handles encryption/decryption of private keys and preshared keys
"""

import logging
from typing import Optional
from cryptography.fernet import Fernet

logger = logging.getLogger(__name__)

class EncryptionHelper:
    """Handles encryption and decryption of sensitive data"""
    
    def __init__(self, encryption_key: str):
        """Initialize with base64-encoded encryption key"""
        try:
            self.cipher = Fernet(encryption_key.encode() if isinstance(encryption_key, str) else encryption_key)
            logger.debug("Encryption helper initialized successfully")
        except Exception as e:
            logger.error(f"Failed to initialize encryption: {e}")
            raise
    
    def encrypt(self, data: str) -> Optional[str]:
        """
        Encrypt sensitive data
        
        Args:
            data: Plain text data to encrypt
            
        Returns:
            Encrypted data as string, or None if encryption fails
        """
        if not data or data == '':
            return None
            
        try:
            encrypted_bytes = self.cipher.encrypt(data.encode())
            encrypted_str = encrypted_bytes.decode()
            logger.debug(f"Successfully encrypted data (length: {len(encrypted_str)})")
            return encrypted_str
        except Exception as e:
            logger.error(f"Encryption failed: {e}")
            return None
    
    def decrypt(self, encrypted_data: str) -> Optional[str]:
        """
        Decrypt sensitive data
        
        Args:
            encrypted_data: Encrypted data as string
            
        Returns:
            Decrypted plain text, or None if decryption fails
        """
        if not encrypted_data:
            return None
            
        try:
            decrypted_bytes = self.cipher.decrypt(encrypted_data.encode())
            decrypted_str = decrypted_bytes.decode()
            logger.debug(f"Successfully decrypted data")
            return decrypted_str
        except Exception as e:
            logger.error(f"Decryption failed: {e}")
            return None
    
    def encrypt_if_present(self, data: str) -> Optional[str]:
        """
        Encrypt data only if it's present and non-empty
        
        Args:
            data: Data to encrypt
            
        Returns:
            Encrypted data or None if data is empty/None
        """
        if data and data.strip():
            return self.encrypt(data)
        return None
    
    def is_encrypted(self, data: str) -> bool:
        """
        Check if data appears to be encrypted
        
        Args:
            data: Data to check
            
        Returns:
            True if data appears encrypted (long and base64-like)
        """
        if not data:
            return False
        
        # Simple heuristic: encrypted data is typically longer than 50 chars
        # and contains base64-like characters
        return len(data) > 50 and all(c.isalnum() or c in '=+-_' for c in data)