# WireGuard Project Architecture

## 🏗️ **High-Level Architecture**

```bash
┌─────────────────────────────────────────────────────────────────┐
│                        HOST SYSTEM                             │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   DOCKER ENVIRONMENT                       ││
│  │                                                             ││
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     ││
│  │  │   wgrest     │  │ wgrest-sync  │  │  wireguard   │     ││
│  │  │  Container   │  │  Container   │  │  Container   │     ││
│  │  └──────────────┘  └──────────────┘  └──────────────┘     ││
│  │         │                │                 │              ││
│  └─────────┼────────────────┼─────────────────┼──────────────┘│
│            │                │                 │               │
│  ┌─────────▼────────────────▼─────────────────▼──────────────┐ │
│  │              HOST NETWORK STACK                           │ │
│  │   Port 51820 (wg0)  │  Port 51821 (wg1)  │  Port 51822   │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                HOST FILE SYSTEM                             ││
│  │  /etc/wireguard/wg0.conf  │  /etc/wireguard/wg1.conf       ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │   External PostgreSQL   │
                    │       Database          │
                    │   (NOT containerized)   │
                    └─────────────────────────┘
```

## 📦 **What's In Containers**

### **Container 1: `wgrest`**

```yaml
┌─────────────────────────────────┐
│          wgrest Container       │
├─────────────────────────────────┤
│ • Go binary (wgrest)            │
│ • HTTP API server (port 51822)  │
│ • TOML config processor         │
│ • WireGuard file manager        │
│                                 │
│ Volumes Mounted:                │
│ • /etc/wireguard (host → cont)  │
│ • config template (host → cont) │
│ • data volume (docker volume)   │
│                                 │
│ Network: host mode              │
│ Privileges: yes (for wg tools)  │
└─────────────────────────────────┘
```

**What it does:**

- Serves REST API on `localhost:51822`
- Manages WireGuard peer configurations
- Reads/writes `/etc/wireguard/wg0.conf` and `/etc/wireguard/wg1.conf`
- Processes API calls to add/remove peers

### **Container 2: `wgrest-sync`**

```yaml
┌─────────────────────────────────┐
│       wgrest-sync Container     │
├─────────────────────────────────┤
│ • Python sync service          │
│ • Polls wgrest API every 60s    │
│ • PostgreSQL client             │
│ • JSON/TOML processor           │
│                                 │
│ Volumes Mounted:                │
│ • /etc/wireguard (readonly)     │
│ • wgrest data (readonly)        │
│                                 │
│ Network: host mode              │
│ Privileges: no                  │
└─────────────────────────────────┘
```

**What it does:**

- Reads wgrest API data
- Reads WireGuard config files
- Syncs everything to external PostgreSQL
- Enables backup/restore functionality

### **Container 3: `wireguard`**

```yaml
┌─────────────────────────────────┐
│      wireguard Container        │
├─────────────────────────────────┤
│ • LinuxServer WireGuard image   │
│ • Kernel module loader          │
│ • One-time initialization      │
│                                 │
│ Volumes Mounted:                │
│ • /lib/modules (host → cont)    │
│                                 │
│ Network: host mode              │
│ Privileges: yes (NET_ADMIN)     │
└─────────────────────────────────┘
```

**What it does:**

- Loads WireGuard kernel modules
- Runs once then exits with echo command
- Ensures WireGuard is available to host

## 🖥️ **What's On The Host (NOT Containerized)**

### **Host Network Stack**

```yaml
┌─────────────────────────────────┐
│         HOST NETWORK            │
├─────────────────────────────────┤
│ • wg0 interface (10.10.0.1/24)  │
│ • wg1 interface (10.11.0.1/24)  │
│ • Port 51820 (wg0 listening)    │
│ • Port 51821 (wg1 listening)    │
│ • Port 51822 (wgrest API)       │
│ • iptables rules                │
│ • IP forwarding                 │
└─────────────────────────────────┘
```

### **Host File System**

```yaml
┌─────────────────────────────────┐
│       HOST FILE SYSTEM          │
├─────────────────────────────────┤
│ /etc/wireguard/                 │
│ ├── wg0.conf                    │
│ └── wg1.conf                    │
│                                 │
│ Project Directory:              │
│ ├── .env                        │
│ ├── docker-compose.yml          │
│ ├── config/wgrest.conf.template │
│ ├── scripts/                    │
│ └── backups/                    │
└─────────────────────────────────┘
```

### **External Database (Remote)**

```yaml
┌─────────────────────────────────┐
│     EXTERNAL POSTGRESQL         │
├─────────────────────────────────┤
│ • NOT on this server            │
│ • postgres.yourcompany.com      │
│ • Database: wgrest_backup       │
│ • Tables: peers, interfaces,    │
│   server_keys, sync_status      │
│                                 │
│ Purpose: Complete state backup  │
└─────────────────────────────────┘
```

## 🔄 **Data Flow**

### **1. Peer Creation Flow:**

```output
Django App → wgrest API (container) → wg0.conf (host) → Host Network
```

### **2. Backup Flow:**

```output
wgrest API ← wgrest-sync (container) → External PostgreSQL
WireGuard configs (host) ← wgrest-sync (container) → External PostgreSQL
```

### **3. Network Traffic Flow:**

```output
Client Device ← UDP 51820/51821 → Host Network → wg0/wg1 interfaces → Target
```

## 🔌 **Why `network_mode: host`?**

All containers use `host` networking because:

1. **WireGuard interfaces** must be on the host network stack
2. **Port binding** is simpler (no Docker port mapping needed)
3. **Performance** - no Docker network overhead
4. **iptables integration** works directly with host rules

## 💾 **Volume Sharing**

```yaml
Host → Containers:
├── /etc/wireguard/ → wgrest (read/write)
├── /etc/wireguard/ → wgrest-sync (read-only)
├── config template → wgrest (read-only)
└── /lib/modules → wireguard (read-only)

Docker Volumes:
└── wgrest_data → shared between wgrest & wgrest-sync
```

## 🎯 **Key Architectural Benefits**

✅ **Separation of Concerns:**

- wgrest = API management
- wgrest-sync = Backup/restore
- wireguard = Kernel module loading

✅ **Host Integration:**

- Real WireGuard interfaces on host
- Direct iptables/firewall integration
- No Docker networking complexity

✅ **External State:**

- Database lives outside this server
- Can restore entire setup from database backup
- Multiple servers can share same database

✅ **Container Benefits:**

- Easy deployment with docker-compose
- Isolated dependencies
- Consistent environment

This hybrid approach gives you the benefits of containerization while maintaining the performance and integration advantages of host networking for VPN traffic!
