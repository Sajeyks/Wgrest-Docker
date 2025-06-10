#!/usr/bin/env python3
"""
Database operations for the sync service
Handles all PostgreSQL interactions and data persistence
"""

import json
import logging
import psycopg2
import psycopg2.extras
from typing import Dict, List, Optional, Tuple, Any, Union
from datetime import datetime

logger = logging.getLogger(__name__)

class SyncDatabase:
    """Database operations for syncing WireGuard data"""
    
    def __init__(self, database_url: str):
        """
        Initialize database connection
        
        Args:
            database_url: PostgreSQL connection URL
        """
        self.database_url = database_url
        self.conn: Optional[psycopg2.extensions.connection] = None
        self.connect()
    
    def connect(self):
        """Establish database connection"""
        try:
            self.conn = psycopg2.connect(self.database_url)
            if self.conn:
                self.conn.autocommit = True
            logger.info("Connected to PostgreSQL database")
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            raise
    
    def ensure_connection(self):
        """Ensure database connection is active"""
        try:
            if self.conn and self.conn.closed:
                self.connect()
        except Exception as e:
            logger.error(f"Failed to reconnect to database: {e}")
            raise
    
    def sync_server_keys(self, server_keys_data: List[Tuple[str, str, str]]):
        """
        Sync server keys to database
        
        Args:
            server_keys_data: List of tuples (interface_name, encrypted_private_key, public_key)
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    for interface_name, encrypted_private_key, public_key in server_keys_data:
                        if encrypted_private_key and public_key:
                            cur.execute("""
                                INSERT INTO server_keys (interface_name, private_key, public_key) 
                                VALUES (%(interface_name)s, %(private_key)s, %(public_key)s)
                                ON CONFLICT (interface_name) DO UPDATE SET
                                    private_key = EXCLUDED.private_key,
                                    public_key = EXCLUDED.public_key,
                                    generated_at = CURRENT_TIMESTAMP
                            """, {
                                'interface_name': interface_name,
                                'private_key': encrypted_private_key,
                                'public_key': public_key
                            })
                            
                            logger.info(f"Server key for {interface_name} encrypted and stored (public: {public_key[:20]}...)")
                        else:
                            logger.warning(f"Skipping {interface_name} - missing encrypted key or public key")
        except Exception as e:
            logger.error(f"Failed to sync server keys: {e}")
            raise
    
    def sync_interfaces(self, interfaces_data: List[dict]):
        """
        Sync interface data to database
        
        Args:
            interfaces_data: List of interface data dictionaries
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    for interface_data in interfaces_data:
                        cur.execute("""
                            INSERT INTO interfaces (name, private_key, public_key, address, listen_port, subnet, endpoint)
                            VALUES (%(name)s, %(private_key)s, %(public_key)s, %(address)s, %(listen_port)s, %(subnet)s, %(endpoint)s)
                            ON CONFLICT (name) DO UPDATE SET
                                private_key = EXCLUDED.private_key,
                                public_key = EXCLUDED.public_key,
                                address = EXCLUDED.address,
                                listen_port = EXCLUDED.listen_port,
                                subnet = EXCLUDED.subnet,
                                endpoint = EXCLUDED.endpoint,
                                last_updated = CURRENT_TIMESTAMP
                        """, interface_data)
                    
                logger.info(f"Synced {len(interfaces_data)} interfaces to database")
        except Exception as e:
            logger.error(f"Failed to sync interfaces: {e}")
            raise
    
    def sync_peers(self, peers_data: List[dict]):
        """
        Sync peer data to database
        
        Args:
            peers_data: List of peer data dictionaries
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    # Clear existing peers
                    cur.execute("DELETE FROM peers")
                    
                    # Insert new peers
                    for peer_data in peers_data:
                        cur.execute("""
                            INSERT INTO peers (interface_name, name, private_key, public_key, allowed_ips, 
                                             endpoint, persistent_keepalive, enabled, preshared_key)
                            VALUES (%(interface_name)s, %(name)s, %(private_key)s, %(public_key)s, 
                                   %(allowed_ips)s, %(endpoint)s, %(persistent_keepalive)s, %(enabled)s, %(preshared_key)s)
                        """, peer_data)
                    
                logger.info(f"Synced {len(peers_data)} peers to database")
        except Exception as e:
            logger.error(f"Failed to sync peers: {e}")
            raise
    
    def update_sync_status(self, peer_counts: Dict[str, int], status: str = 'completed'):
        """
        Update sync status in database
        
        Args:
            peer_counts: Dictionary mapping interface names to peer counts
            status: Sync status string
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    wg0_count = peer_counts.get('wg0', 0)
                    wg1_count = peer_counts.get('wg1', 0)
                    
                    cur.execute("""
                        INSERT INTO sync_status (peer_count_wg0, peer_count_wg1, status) 
                        VALUES (%(wg0)s, %(wg1)s, %(status)s)
                    """, {
                        'wg0': wg0_count, 
                        'wg1': wg1_count, 
                        'status': status
                    })
                    
                    logger.debug(f"Updated sync status: wg0={wg0_count}, wg1={wg1_count}, status={status}")
        except Exception as e:
            logger.error(f"Failed to update sync status: {e}")
            raise
    
    def get_encryption_stats(self) -> Dict[str, int]:
        """
        Get encryption statistics from database
        
        Returns:
            Dictionary with encryption statistics
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    # Count encrypted server keys
                    cur.execute("SELECT COUNT(*) FROM server_keys WHERE private_key IS NOT NULL AND private_key != ''")
                    result = cur.fetchone()
                    encrypted_server_keys = result[0] if result else 0
                    
                    # Count encrypted interface keys
                    cur.execute("SELECT COUNT(*) FROM interfaces WHERE private_key IS NOT NULL AND private_key != ''")
                    result = cur.fetchone()
                    encrypted_interface_keys = result[0] if result else 0
                    
                    # Count encrypted PSKs
                    cur.execute("SELECT COUNT(*) FROM peers WHERE preshared_key IS NOT NULL AND preshared_key != ''")
                    result = cur.fetchone()
                    encrypted_psks = result[0] if result else 0
                    
                    return {
                        'encrypted_server_keys': encrypted_server_keys,
                        'encrypted_interface_keys': encrypted_interface_keys,
                        'encrypted_psks': encrypted_psks
                    }
        except Exception as e:
            logger.error(f"Failed to get encryption stats: {e}")
            return {}
    
    def get_peer_stats(self) -> List[Tuple[str, int, int, int]]:
        """
        Get peer statistics by interface
        
        Returns:
            List of tuples (interface_name, peer_count, psk_count, endpoint_count)
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    cur.execute("""
                        SELECT interface_name, COUNT(*) as peer_count, 
                               COUNT(CASE WHEN preshared_key IS NOT NULL THEN 1 END) as psk_count,
                               COUNT(CASE WHEN endpoint IS NOT NULL THEN 1 END) as endpoint_count
                        FROM peers 
                        GROUP BY interface_name
                    """)
                    
                    return cur.fetchall()
        except Exception as e:
            logger.error(f"Failed to get peer stats: {e}")
            return []
    
    def cleanup_old_sync_logs(self, older_than_hours: int):
        """
        Clean up old sync status records
        
        Args:
            older_than_hours: Remove records older than this many hours
        """
        self.ensure_connection()
        
        try:
            if self.conn:
                with self.conn.cursor() as cur:
                    cur.execute("""
                        DELETE FROM sync_status 
                        WHERE last_sync < NOW() - INTERVAL '%s hours'
                    """, (older_than_hours,))
                    
                    deleted_count = cur.rowcount
                    if deleted_count > 0:
                        logger.info(f"Cleaned up {deleted_count} old sync status records")
        except Exception as e:
            logger.error(f"Failed to cleanup old sync logs: {e}")
    
    def close(self):
        """Close database connection"""
        if self.conn and not self.conn.closed:
            self.conn.close()
            logger.debug("Database connection closed")