# WireGuard with Database-Backed wgrest - Complete Setup Guide

Production-ready WireGuard setup using wgrest with external PostgreSQL database for complete state backup and one-command restoration.

## 🎯 **Architecture Overview**

```output
Django SaaS → wgrest API → wgrest (files) → Sync Service → External PostgreSQL
                                                               ↓
                                                         Your Backup
```

**Key Benefits:**

- ✅ Keep standard wgrest (no modifications)
- ✅ External database contains complete state
- ✅ One-command restoration from database backup
- ✅ Automatic sync every 60 seconds

---

## 📖 **Setup Guide**

## 🆕 **Scenario 1: Fresh Setup on New Server**

### **Prerequisites**

1. **Ubuntu/Debian server** with root access
2. **External PostgreSQL database** accessible from server
3. **WireGuard support** (kernel module available)

### **Step 1: Prepare External Database**

On your PostgreSQL server, create the database and user:

```sql
-- Connect to PostgreSQL as superuser
CREATE DATABASE wgrest_backup;
CREATE USER wgrest WITH PASSWORD 'your_secure_password';
GRANT ALL PRIVILEGES ON DATABASE wgrest_backup TO wgrest;

-- Connect to the new database
\c wgrest_backup
GRANT ALL ON SCHEMA public TO wgrest;
```

### **Step 2: Clone and Configure Project**

```bash
# 1. Clone the project
git clone <your-repo> wireguard-db
cd wireguard-db

# 2. Create environment configuration
cp .env.example .env
nano .env
```

**Configure your .env file:**

```bash
# Server Configuration
SERVER_IP=203.0.113.10              # Your server's public IP
WG0_PORT=51820
WG1_PORT=51821
WGREST_PORT=8080

# External PostgreSQL Database  
DB_HOST=postgres.yourcompany.com     # Your PostgreSQL server
DB_PORT=5432
DB_NAME=wgrest_backup
DB_USER=wgrest
DB_PASSWORD=your_secure_password

# API Security
WGREST_API_KEY=your_secure_api_key_here

# Target Website for MikroTik tunnels
TARGET_WEBSITE_IP=1.2.3.4
```

### **Step 3: Run Setup**

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Run the setup (this does everything)
sudo ./scripts/setup.sh
```

**What setup.sh does:**

1. ✅ Tests external database connection
2. ✅ Creates database schema if needed
3. ✅ Installs Docker and Docker Compose
4. ✅ Generates WireGuard keys
5. ✅ Stores keys in external database
6. ✅ Creates WireGuard configurations
7. ✅ Sets up firewall rules
8. ✅ Starts all Docker services
9. ✅ Verifies wgrest API and sync service

### **Step 4: Verify Setup**

```bash
# Test wgrest API
curl -H "Authorization: Bearer your_api_key" \
     http://localhost:8080/api/v1/interfaces

# Check services
docker-compose ps

# Verify database sync
docker-compose logs wgrest-sync
```

### **Step 5: Configure Django**

Update your Django application to use the new wgrest API:

```python
# Django settings
WIREGUARD_SERVER_IP = '203.0.113.10'
WIREGUARD_API_KEY = 'your_secure_api_key_here'
WIREGUARD_API_PORT = 8080
```

---

## 🔄 **Scenario 2: Restore from Backup (Existing Setup)**

### **Prerequisites (2)**

1. **PostgreSQL database backup** (.sql file or dump)
2. **Fresh server** or existing server to restore to
3. **Same external PostgreSQL** server accessible

### **Step 1: Restore Database**

On your PostgreSQL server, restore the backup:

```bash
# Method 1: Using pg_restore (for binary dumps)
pg_restore -h postgres.yourcompany.com -U wgrest -d wgrest_backup \
           --clean --if-exists your_backup.dump

# Method 2: Using psql (for SQL dumps)  
psql -h postgres.yourcompany.com -U wgrest -d wgrest_backup \
     < your_backup.sql
```

### **Step 2: Verify Database Contents**

```bash
# Check that data was restored
psql -h postgres.yourcompany.com -U wgrest -d wgrest_backup \
     -c "SELECT interface_name, COUNT(*) FROM peers GROUP BY interface_name;"
```

### **Step 3: Setup Project (if new server)**

If this is a new server, follow **Scenario 1 Steps 2-3** to clone and configure the project.

If the project already exists, just ensure your `.env` file has the correct database settings.

### **Step 4: Run Restoration**

```bash
cd wireguard-db

# This will restore everything from the database
sudo ./scripts/restore.sh
```

**What restore.sh does:**

1. ✅ Connects to external database
2. ✅ Verifies backup data exists
3. ✅ Stops current services
4. ✅ Restores WireGuard configs from database
5. ✅ Starts all services
6. ✅ Sync service automatically recreates all peers in wgrest
7. ✅ Verifies all peers are restored

### **Step 5: Verify Restoration**

```bash
# Check that all peers are restored
curl -H "Authorization: Bearer your_api_key" \
     http://localhost:8080/api/v1/interfaces/wg0/peers

curl -H "Authorization: Bearer your_api_key" \
     http://localhost:8080/api/v1/interfaces/wg1/peers

# Check WireGuard status
sudo wg show

# Verify services
docker-compose ps
```

---

## 🔧 **Scenario 3: Migration to New Server**

### **Step 1: Create Backup on Old Server**

```bash
# On the old server, backup the external database
pg_dump -h postgres.yourcompany.com -U wgrest wgrest_backup \
        > wireguard_backup_$(date +%Y%m%d).sql
```

### **Step 2: Setup New Server**

Follow **Scenario 2** (Restore from Backup) on the new server.

### **Step 3: Update DNS/Firewall**

1. Update your DNS records to point to the new server IP
2. Update firewall rules to allow the new server IP
3. Update your Django configuration with new server details

### **Step 4: Test and Switch**

1. Test the new server with a few peers
2. Verify everything works correctly  
3. Switch your Django app to use the new server
4. Decommission the old server

---

## 📊 **Daily Operations**

### **Adding Peers (Django)**

Your Django application continues to work exactly the same:

```python
# Create wg0 peer (FreeRADIUS)
result = wireguard_service.create_peer(
    interface='wg0',
    name='client1',
    allowed_ips=['10.10.0.2/32']
)

# Create wg1 peer (MikroTik)  
result = wireguard_service.create_peer(
    interface='wg1',
    name='mikrotik1',
    allowed_ips=['10.11.0.2/32']
)
```

### **Monitoring**

```bash
# Check service status
docker-compose ps

# View sync logs
docker-compose logs wgrest-sync

# Check database sync status
psql -h postgres.yourcompany.com -U wgrest -d wgrest_backup \
     -c "SELECT * FROM sync_status ORDER BY last_sync DESC LIMIT 5;"
```

### **Manual Backup**

```bash
# Create manual database backup
pg_dump -h postgres.yourcompany.com -U wgrest wgrest_backup \
        -f "backup_$(date +%Y%m%d_%H%M%S).sql"
```

---

## 🚨 **Troubleshooting**

### **Database Connection Issues**

```bash
# Test database connectivity
psql -h postgres.yourcompany.com -U wgrest -d wgrest_backup -c "SELECT 1;"

# Check sync service logs
docker-compose logs wgrest-sync

# Restart sync service
docker-compose restart wgrest-sync
```

### **wgrest API Not Responding**

```bash
# Check wgrest logs
docker-compose logs wgrest

# Restart wgrest
docker-compose restart wgrest

# Check if WireGuard configs are valid
sudo wg show
```

### **Peers Not Syncing**

```bash
# Check sync service status
docker-compose logs wgrest-sync

# Manual sync trigger (restart sync service)
docker-compose restart wgrest-sync

# Check database for recent sync
psql -h postgres.yourcompany.com -U wgrest -d wgrest_backup \
     -c "SELECT * FROM sync_status ORDER BY last_sync DESC LIMIT 1;"
```

---

## 💾 **Backup Strategy**

### **Automated Backup Setup**

Set up automated backups of your external PostgreSQL database:

```bash
# Add to crontab on database server or backup server
# Daily backup at 2 AM
0 2 * * * pg_dump -h postgres.yourcompany.com -U wgrest wgrest_backup \
          -f "/backups/wireguard_$(date +\%Y\%m\%d).sql"

# Weekly cleanup (keep last 30 days)  
0 3 * * 0 find /backups -name "wireguard_*.sql" -mtime +30 -delete
```

### **Backup Verification**

```bash
# Test restore to temporary database
createdb -h postgres.yourcompany.com -U wgrest wgrest_test
psql -h postgres.yourcompany.com -U wgrest -d wgrest_test < your_backup.sql

# Verify data
psql -h postgres.yourcompany.com -U wgrest -d wgrest_test \
     -c "SELECT COUNT(*) FROM peers;"

# Cleanup
dropdb -h postgres.yourcompany.com -U wgrest wgrest_test
```

---

## ⚡ **Quick Reference**

### **Essential Commands**

```bash
# Fresh setup
sudo ./scripts/setup.sh

# Restore from backup  
sudo ./scripts/restore.sh

# Check status
docker-compose ps

# View logs
docker-compose logs wgrest-sync

# Test API
curl -H "Authorization: Bearer $API_KEY" http://localhost:8080/api/v1/interfaces

# Backup database
pg_dump -h $DB_HOST -U $DB_USER $DB_NAME > backup.sql

# Restore database
psql -h $DB_HOST -U $DB_USER -d $DB_NAME < backup.sql
```

### **File Structure**

```output
wireguard-db/
├── docker-compose.yml          # Container definitions
├── .env                        # Your configuration
├── config/wgrest.yaml         # wgrest configuration  
├── sync-service/              # Custom sync service
├── scripts/setup.sh           # Fresh setup
├── scripts/restore.sh         # Database restoration
└── sql/init.sql              # Database schema
```

This setup gives you **bulletproof peer persistence** with **one-command restoration** while keeping standard wgrest! 🚀
