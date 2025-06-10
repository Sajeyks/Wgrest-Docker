#!/usr/bin/env python3
"""
Webhook server for event-driven synchronization
Provides HTTP endpoints for triggering sync operations
"""

import logging
import threading
from flask import Flask, request, jsonify
from werkzeug.serving import make_server
from typing import Callable, Optional

logger = logging.getLogger(__name__)

class WebhookServer:
    """HTTP webhook server for sync triggers"""
    
    def __init__(self, port: int, api_key: str, sync_callback: Callable[[], None]):
        """
        Initialize webhook server
        
        Args:
            port: Port to listen on
            api_key: API key for authentication
            sync_callback: Function to call when sync is triggered
        """
        self.port = port
        self.api_key = api_key
        self.sync_callback = sync_callback
        self.app = Flask(__name__)
        self.server: Optional[make_server] = None
        self.server_thread: Optional[threading.Thread] = None
        
        self._setup_routes()
    
    def _setup_routes(self):
        """Setup Flask routes"""
        
        @self.app.route('/sync', methods=['POST'])
        def webhook_sync():
            """Trigger sync via webhook"""
            try:
                # Check authentication
                auth_header = request.headers.get('Authorization')
                if not auth_header or auth_header != f'Bearer {self.api_key}':
                    logger.warning(f"Unauthorized sync request from {request.remote_addr}")
                    return jsonify({'error': 'Unauthorized'}), 401
                
                # Trigger sync in background thread
                logger.info("Webhook triggered sync")
                sync_thread = threading.Thread(target=self.sync_callback, daemon=True)
                sync_thread.start()
                
                return jsonify({'status': 'sync_triggered'}), 200
                
            except Exception as e:
                logger.error(f"Webhook sync error: {e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/health', methods=['GET'])
        def health_check():
            """Health check endpoint"""
            return jsonify({
                'status': 'healthy',
                'service': 'wgrest-sync',
                'port': self.port
            }), 200
        
        @self.app.route('/status', methods=['GET'])
        def status_check():
            """Status endpoint with authentication"""
            try:
                auth_header = request.headers.get('Authorization')
                if not auth_header or auth_header != f'Bearer {self.api_key}':
                    return jsonify({'error': 'Unauthorized'}), 401
                
                return jsonify({
                    'status': 'running',
                    'service': 'wgrest-sync',
                    'port': self.port,
                    'endpoints': ['/sync', '/health', '/status']
                }), 200
                
            except Exception as e:
                logger.error(f"Status check error: {e}")
                return jsonify({'error': str(e)}), 500
    
    def start(self):
        """Start the webhook server in a background thread"""
        def run_server():
            try:
                self.server = make_server('0.0.0.0', self.port, self.app, threaded=True)
                logger.info(f"Webhook server started on port {self.port}")
                if self.server:
                    self.server.serve_forever()
            except Exception as e:
                logger.error(f"Webhook server error: {e}")
        
        self.server_thread = threading.Thread(target=run_server, daemon=True)
        self.server_thread.start()
        logger.info("Webhook server thread started")
    
    def stop(self):
        """Stop the webhook server"""
        if self.server:
            try:
                self.server.shutdown()
                logger.info("Webhook server stopped")
            except Exception as e:
                logger.error(f"Error stopping webhook server: {e}")
        
        if self.server_thread and self.server_thread.is_alive():
            self.server_thread.join(timeout=5)