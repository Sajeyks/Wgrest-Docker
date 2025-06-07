-- Database schema for complete wgrest state backup
CREATE TABLE interfaces (
    name VARCHAR(10) PRIMARY KEY,
    private_key TEXT NOT NULL,
    public_key TEXT NOT NULL,
    address VARCHAR(20) NOT NULL,
    listen_port INTEGER NOT NULL,
    subnet VARCHAR(20) NOT NULL,
    endpoint VARCHAR(100) NOT NULL,
    config_content TEXT,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE peers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    interface_name VARCHAR(10) REFERENCES interfaces(name),
    name VARCHAR(100) NOT NULL,
    private_key TEXT NOT NULL,
    public_key TEXT NOT NULL,
    allowed_ips JSONB NOT NULL,
    endpoint VARCHAR(100),
    persistent_keepalive INTEGER,
    enabled BOOLEAN DEFAULT true,
    preshared_key TEXT,
    last_handshake TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE server_keys (
    interface_name VARCHAR(10) PRIMARY KEY,
    private_key TEXT NOT NULL,
    public_key TEXT NOT NULL,
    generated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE sync_status (
    id SERIAL PRIMARY KEY,
    last_sync TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    peer_count_wg0 INTEGER DEFAULT 0,
    peer_count_wg1 INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active'
);

-- Indexes for performance
CREATE INDEX idx_peers_interface ON peers(interface_name);
CREATE INDEX idx_peers_enabled ON peers(enabled);
CREATE INDEX idx_sync_status_last_sync ON sync_status(last_sync);