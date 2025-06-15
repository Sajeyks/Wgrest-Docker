# Django Remote Migration Guide

## 🎯 **Migration Overview**

This guide walks you through migrating Django from local (same server as WireGuard) to remote (different server) while maintaining the same functionality.

### **Current State: Django Local Privileges**

```bash
┌─────────────────────────────────────────┐
│            WireGuard Server             │
│                                         │
│  Django ──────► wg1 ──────► MikroTik    │
│  (local)       interface   (peers)      │
└─────────────────────────────────────────┘
```

### **Target State: Django Remote Peer**

```bash
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  Django Server  │      │ WireGuard Server │      │  MikroTik Router │
│                 │      │                 │      │                 │
│ Django ─────────┼─────►│ wg1 ─────────────┼─────►│ RouterOS API    │
│ (peer client)   │      │ (interface)     │      │ (peer client)   │
└─────────────────┘      └─────────────────┘      └─────────────────┘
```

---

## 📋 **Prerequisites**

### **Before Starting:**

- ✅ Django currently working with local privileges
- ✅ MikroTik routers connected and working via wg1
- ✅ Remote server prepared for Django deployment
- ✅ Network connectivity between all servers

### **Required Information:**

- Remote Django server IP address
- Available IP address in wg1 subnet (e.g., `10.11.0.100/16`)
- WireGuard server details (IP, ports, API key)

---

## 🚀 **Migration Steps**

### **Phase 1: Prepare Django Peer Configuration**

#### **1.1 Generate Django Peer on WireGuard Server**

```bash
# On WireGuard server
sudo wg show wg1

# Expected output should show:
# - Django peer (10.11.0.100) connected
# - MikroTik peers (10.11.0.x) connected
# - Traffic counters increasing

# Check peer status via API
curl -H "Authorization: Bearer $WGREST_API_KEY" \
  http://localhost:51800/v1/devices/wg1/peers/
```

---

## 🔄 **Rollback Plan**

If migration fails, you can quickly rollback:

### **Emergency Rollback Steps:**

```bash
# 1. Stop Django remote server
sudo systemctl stop django

# 2. On WireGuard server, restore Django local privileges
sudo iptables -A FORWARD -s 127.0.0.1 -o wg1 -j ACCEPT
sudo iptables -A FORWARD -i wg1 -d 127.0.0.1 -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 127.0.0.1 -o wg1 -j MASQUERADE

# 3. Save rules and restart Django locally
sudo iptables-save > /etc/iptables/rules.v4
sudo systemctl start django

# 4. Remove Django peer from wg1 (optional)
curl -X DELETE -H "Authorization: Bearer $WGREST_API_KEY" \
  http://localhost:51800/v1/devices/wg1/peers/[django-peer-id]
```

---

## 🎯 **Migration Benefits**

### **✅ After Migration:**

- **Scalability**: Django can run on dedicated hardware
- **Security**: Django isolated from WireGuard server
- **Flexibility**: Django can be load balanced/clustered
- **Maintenance**: Independent server maintenance windows
- **Performance**: Dedicated resources for Django

### **📊 Traffic Flow Comparison:**

#### **Before (Local):**

```output
Django (localhost) → wg1 interface → MikroTik (10.11.0.x)
```

#### **After (Remote):**

```output
Django (10.11.0.100) → WireGuard tunnel → wg1 interface → MikroTik (10.11.0.x)
```

---

## 🔧 **Advanced Configuration**

### **Multiple Django Instances:**

```bash
# For load balancing, add multiple Django peers
curl -X POST -H "Authorization: Bearer $WGREST_API_KEY" \
  http://localhost:51800/v1/devices/wg1/peers/ \
  -d '{"name": "django-server-2", "allowed_ips": ["10.11.0.101/32"]}'

curl -X POST -H "Authorization: Bearer $WGREST_API_KEY" \
  http://localhost:51800/v1/devices/wg1/peers/ \
  -d '{"name": "django-server-3", "allowed_ips": ["10.11.0.102/32"]}'
```

### **Geographic Distribution:**

```bash
# Django servers in different regions
# US East: 10.11.0.100/32
# EU West: 10.11.0.110/32  
# Asia:    10.11.0.120/32
```

### **High Availability Setup:**

```bash
# Django cluster with shared wg1 subnet
# Primary:   10.11.0.100/32
# Secondary: 10.11.0.101/32
# Failover:  10.11.0.102/32
```

---

## 🚨 **Troubleshooting**

### **Common Issues:**

#### **1. Django Can't Connect to WireGuard**

```bash
# Check Django server connectivity
ping YOUR-WIREGUARD-SERVER-IP  # Should work
sudo wg show                   # Should show wg1 interface

# Check firewall on Django server
sudo iptables -L OUTPUT -n | grep 51821  # Should allow outbound UDP 51821
```

#### **2. Django Connected but Can't Reach MikroTiks**

```bash
# Check wg1 routing
ip route show table main | grep wg1
ping 10.11.0.1  # Should reach WireGuard server

# Check WireGuard server forwarding
# On WireGuard server:
sudo iptables -L FORWARD -n | grep wg1  # Should show forwarding rules
```

#### **3. MikroTik API Not Responding**

```bash
# Test ports specifically
nc -zv 10.11.0.2 8728  # RouterOS API
nc -zv 10.11.0.2 8729  # RouterOS API SSL
nc -zv 10.11.0.2 22    # SSH

# Check MikroTik API is enabled
# /ip service print
# /ip service enable api
```

#### **4. Performance Issues**

```bash
# Check WireGuard performance
sudo wg show wg1  # Look for increasing transfer counters

# Test bandwidth
iperf3 -c 10.11.0.2  # If iperf3 installed on MikroTik

# Check MTU issues
ping -M do -s 1472 10.11.0.2  # Test large packets
```

---

## 📋 **Migration Checklist**

### **Pre-Migration:**

- [ ] Django working with local privileges
- [ ] Remote server prepared
- [ ] Network connectivity tested
- [ ] Backup current configuration

### **During Migration:**

- [ ] Django peer configuration generated
- [ ] WireGuard client installed on Django server
- [ ] Django peer connected and tested
- [ ] Django application updated for remote operation
- [ ] WireGuard server firewall updated

### **Post-Migration:**

- [ ] End-to-end connectivity tested
- [ ] Django → MikroTik API calls working
- [ ] Performance acceptable
- [ ] Monitoring updated for new topology
- [ ] Documentation updated

### **Optional Cleanup:**

- [ ] Remove Django local privileges rules (if not needed for rollback)
- [ ] Update monitoring systems
- [ ] Update backup procedures
- [ ] Test disaster recovery procedures

---

## 🎉 **Success Validation**

Your migration is successful when:

1. ✅ **Django server shows wg1 interface active**
2. ✅ **WireGuard server shows Django as connected peer**
3. ✅ **Django can ping all MikroTik routers via tunnel**
4. ✅ **Django → MikroTik API calls complete successfully**
5. ✅ **MikroTik → Django responses work correctly**
6. ✅ **Performance meets requirements**
7. ✅ **No error logs in Django or WireGuard**

**Congratulations!** Django is now successfully running as a remote WireGuard peer while maintaining all the same functionality it had with local privileges! 🚀

```bash
curl -X POST \
  -H "Authorization: Bearer $WGREST_API_KEY" \
  -H "Content-Type: application/json" \
  http://localhost:51800/v1/devices/wg1/peers/ \
  -d '{
    "name": "django-server",
    "allowed_ips": ["10.11.0.100/32"]
  }'
```

### **1.2 Get Django Client Configuration**

```bash
# Get the peer configuration for Django
curl -H "Authorization: Bearer $WGREST_API_KEY" \
  http://localhost:51800/v1/devices/wg1/peers/[peer-id]/config
```

This will return something like:

```ini
[Interface]
PrivateKey = <generated-private-key>
Address = 10.11.0.100/16
DNS = 1.1.1.1

[Peer]
PublicKey = <wg1-server-public-key>
Endpoint = YOUR-SERVER-IP:51821
AllowedIPs = 10.11.0.0/16
PersistentKeepalive = 25
```

---

### **Phase 2: Setup Remote Django Server**

#### **2.1 Install WireGuard on Django Server**

```bash
# On remote Django server
sudo apt update
sudo apt install wireguard

# Create config directory
sudo mkdir -p /etc/wireguard
```

#### **2.2 Deploy Django Peer Configuration**

```bash
# Create wg1 client config
sudo tee /etc/wireguard/wg1.conf > /dev/null << 'EOF'
[Interface]
PrivateKey = <paste-private-key-from-step-1.2>
Address = 10.11.0.100/16
DNS = 1.1.1.1

[Peer]
PublicKey = <paste-server-public-key>
Endpoint = YOUR-WIREGUARD-SERVER-IP:51821
AllowedIPs = 10.11.0.0/16
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/wg1.conf
```

#### **2.3 Start WireGuard Client**

```bash
# Start wg1 interface
sudo wg-quick up wg1

# Enable on boot
sudo systemctl enable wg-quick@wg1

# Verify connection
sudo wg show
ping 10.11.0.1  # Should ping WireGuard server
```

---

### **Phase 3: Update Django Application**

#### **3.1 Update Django Network Configuration**

Update your Django settings to use the WireGuard interface:

```python
# Django settings.py
MIKROTIK_API_SETTINGS = {
    # Django will now connect to MikroTiks via WireGuard tunnel
    'BIND_INTERFACE': 'wg1',  # Optional: bind to wg1 interface
    'SOURCE_IP': '10.11.0.100',  # Django's IP in wg1 network
    
    # MikroTik connections will be in 10.11.0.0/16 range
    'MIKROTIK_SUBNET': '10.11.0.0/16',
}
```

#### **3.2 Update MikroTik API Client Code**

```python
# Example: Update your MikroTik API client
import socket
from librouteros import connect

def connect_to_mikrotik(mikrotik_ip, username, password):
    # Create socket bound to wg1 interface
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('10.11.0.100', 0))  # Bind to Django's wg1 IP
    
    # Connect via WireGuard tunnel
    api = connect(
        host=mikrotik_ip,  # Will be something like 10.11.0.2
        username=username,
        password=password,
        sock=sock
    )
    return api
```

#### **3.3 Test Django → MikroTik Connectivity**

```bash
# On Django server, test connectivity to MikroTik routers
ping 10.11.0.2  # Test ping to first MikroTik
ping 10.11.0.3  # Test ping to second MikroTik

# Test API port connectivity
nc -zv 10.11.0.2 8728  # Test RouterOS API port
nc -zv 10.11.0.2 8729  # Test RouterOS API SSL port
```

---

### **Phase 4: Update WireGuard Server Firewall**

#### **4.1 Remove Django Local Privileges**

```bash
# On WireGuard server, remove old rules for local Django
sudo iptables -D FORWARD -s 127.0.0.1 -o wg1 -j ACCEPT
sudo iptables -D FORWARD -i wg1 -d 127.0.0.1 -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s 127.0.0.1 -o wg1 -j MASQUERADE

echo "✅ Removed Django local privileges"
```

#### **4.2 Add Django Peer Rules (Optional)**

The existing wg1 rules should handle peer-to-peer communication automatically, but you can add specific rules if needed:

```bash
# Optional: Add specific rules for Django peer
sudo iptables -A FORWARD -s 10.11.0.100 -o wg1 -j ACCEPT
sudo iptables -A FORWARD -i wg1 -d 10.11.0.100 -j ACCEPT

echo "✅ Added Django peer-specific rules"
```

#### **4.3 Save Updated Firewall Rules**

```bash
# Save the updated rules
sudo iptables-save > /etc/iptables/rules.v4
echo "✅ Firewall rules updated and saved"
```

---

### **Phase 5: Validation and Testing**

#### **5.1 Network Connectivity Tests**

```bash
# On Django server
ping 10.11.0.1              # WireGuard server
ping 10.11.0.2              # First MikroTik
nc -zv 10.11.0.2 8728       # RouterOS API
nc -zv 10.11.0.2 22         # SSH to MikroTik
```

#### **5.2 Django Application Tests**

```python
# Test Django → MikroTik API functionality
def test_mikrotik_connection():
    try:
        # Your existing MikroTik API code
        api = connect_to_mikrotik('10.11.0.2', 'admin', 'password')
        system_info = api('/system/resource/print')
        print("✅ Django → MikroTik API working!")
        return True
    except Exception as e:
        print(f"❌ Django → MikroTik API failed: {e}")
        return False
```
