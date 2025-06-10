#!/usr/bin/env python3
"""
File system monitoring for WireGuard configuration changes
Triggers sync when config files are modified
"""

import logging
import threading
import time
from typing import Callable, Optional
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

logger = logging.getLogger(__name__)

class WireGuardFileHandler(FileSystemEventHandler):
    """File system event handler for WireGuard config changes"""
    
    def __init__(self, sync_callback: Callable, debounce_seconds: int = 5):
        """
        Initialize file handler
        
        Args:
            sync_callback: Function to call when sync is needed
            debounce_seconds: Seconds to wait before triggering sync
        """
        super().__init__()
        self.sync_callback = sync_callback
        self.debounce_seconds = debounce_seconds
        self.last_sync = 0
        self.debounce_timer: Optional[threading.Timer] = None
        
    def on_modified(self, event):
        """Handle file modification events"""
        if event.is_directory:
            return
            
        if event.src_path.endswith('.conf'):
            logger.info(f"WireGuard config changed: {event.src_path}")
            self.debounced_sync()
    
    def on_created(self, event):
        """Handle file creation events"""
        if event.is_directory:
            return
            
        if event.src_path.endswith('.conf'):
            logger.info(f"WireGuard config created: {event.src_path}")
            self.debounced_sync()
    
    def debounced_sync(self):
        """Trigger sync with debouncing to avoid too frequent syncs"""
        if self.debounce_timer:
            self.debounce_timer.cancel()
            
        self.debounce_timer = threading.Timer(self.debounce_seconds, self.trigger_sync)
        self.debounce_timer.start()
    
    def trigger_sync(self):
        """Actually trigger the sync after debounce period"""
        current_time = time.time()
        if current_time - self.last_sync > self.debounce_seconds:
            logger.info("Triggering sync due to file changes...")
            try:
                self.sync_callback()
                self.last_sync = current_time
            except Exception as e:
                logger.error(f"Error during file-triggered sync: {e}")

class FileWatcher:
    """File system watcher for WireGuard configurations"""
    
    def __init__(self, watch_dir: str, sync_callback: Callable, debounce_seconds: int = 5):
        """
        Initialize file watcher
        
        Args:
            watch_dir: Directory to watch for changes
            sync_callback: Function to call when sync is needed
            debounce_seconds: Seconds to debounce file changes
        """
        self.watch_dir = watch_dir
        self.sync_callback = sync_callback
        self.debounce_seconds = debounce_seconds
        self.observer: Optional[Observer] = None
        self.event_handler: Optional[WireGuardFileHandler] = None
    
    def start(self):
        """Start watching for file changes"""
        try:
            self.observer = Observer()
            self.event_handler = WireGuardFileHandler(
                sync_callback=self.sync_callback,
                debounce_seconds=self.debounce_seconds
            )
            
            if self.observer and self.event_handler:
                self.observer.schedule(
                    self.event_handler, 
                    self.watch_dir, 
                    recursive=False
                )
                
                self.observer.start()
                logger.info(f"File monitoring started for {self.watch_dir}")
            
        except Exception as e:
            logger.error(f"Failed to start file monitoring: {e}")
            raise
    
    def stop(self):
        """Stop watching for file changes"""
        if self.observer:
            try:
                self.observer.stop()
                self.observer.join(timeout=5)
                logger.info("File monitoring stopped")
            except Exception as e:
                logger.error(f"Error stopping file watcher: {e}")
        
        if self.event_handler and self.event_handler.debounce_timer:
            self.event_handler.debounce_timer.cancel()
            self.event_handler.debounce_timer = None
    
    def is_running(self) -> bool:
        """Check if file watcher is running"""
        return self.observer is not None and self.observer.is_alive()