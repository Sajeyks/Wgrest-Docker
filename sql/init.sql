-- Database schema for structured wgrest state backup
-- Stores only structured data, reconstructs config files during restoration

-- Interfaces table: Core interface configuration  
CREATE TABLE IF NOT EXISTS interfaces (
    name VARCHAR(10) PRIMARY KEY,                    -- Interface name (wg0, wg1)
    private_key TEXT,                                -- Encrypted server private key
    public_key TEXT NOT NULL,                        -- Server public key (safe to store plaintext)
    address VARCHAR(20) NOT NULL,                    -- Interface address (e.g., 10.10.0.1/24)
    listen_port INTEGER NOT NULL,                    -- WireGuard listen port (51820, 51821)
    subnet VARCHAR(20) NOT NULL,                     -- Network subnet (e.g., 10.10.0.0/24)
    endpoint VARCHAR(100) NOT NULL,                  -- Public endpoint (server_ip:port)
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Peers table: Individual peer configurations
CREATE TABLE IF NOT EXISTS peers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    interface_name VARCHAR(10) REFERENCES interfaces(name) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,                      -- Peer identifier/name
    private_key TEXT DEFAULT '',                     -- Empty (client keys not exposed by wgrest)
    public_key TEXT NOT NULL,                        -- Peer public key
    allowed_ips JSONB NOT NULL,                      -- Allowed IP ranges for this peer ["10.10.0.2/32"]
    endpoint VARCHAR(100),                           -- Peer endpoint (if known)
    persistent_keepalive INTEGER,                    -- Keepalive interval in seconds
    enabled BOOLEAN DEFAULT true,                    -- Peer enabled status
    preshared_key TEXT,                             -- Encrypted PSK (enhanced security)
    last_handshake TIMESTAMP,                       -- Last successful handshake
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Server keys table: Server cryptographic keys (encrypted)
CREATE TABLE IF NOT EXISTS server_keys (
    interface_name VARCHAR(10) PRIMARY KEY,
    private_key TEXT NOT NULL,                       -- Encrypted server private key
    public_key TEXT NOT NULL,                        -- Server public key
    generated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Sync status table: Track synchronization status and cleanup
CREATE TABLE IF NOT EXISTS sync_status (
    id SERIAL PRIMARY KEY,
    last_sync TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    peer_count_wg0 INTEGER DEFAULT 0,
    peer_count_wg1 INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active'
);

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_peers_interface ON peers(interface_name);
CREATE INDEX IF NOT EXISTS idx_peers_enabled ON peers(enabled);
CREATE INDEX IF NOT EXISTS idx_peers_interface_enabled ON peers(interface_name, enabled);
CREATE INDEX IF NOT EXISTS idx_sync_status_last_sync ON sync_status(last_sync);

-- Comments for documentation
COMMENT ON TABLE interfaces IS 'Core WireGuard interface configuration (wg0, wg1)';
COMMENT ON TABLE peers IS 'Individual peer configurations with encrypted sensitive data';
COMMENT ON TABLE server_keys IS 'Server cryptographic keys with encryption';
COMMENT ON TABLE sync_status IS 'Synchronization tracking and cleanup management';

COMMENT ON COLUMN interfaces.private_key IS 'Encrypted server private key';
COMMENT ON COLUMN peers.preshared_key IS 'Encrypted preshared key for enhanced security';
COMMENT ON COLUMN server_keys.private_key IS 'Encrypted server private key backup';