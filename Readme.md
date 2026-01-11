# WGREST-Docker

WireGuard server for Davina ISP management system.

## Architecture

```text
Single Server (WireGuard + Django/Coolify)
├── wg0 interface (10.10.0.1) ─── MikroTik RADIUS traffic
├── wg1 interface (10.11.0.1) ─── MikroTik API traffic
├── FreeRADIUS (binds to 10.10.0.1)
├── wgrest API (localhost:8080)
└── Coolify
    └── Django container (connects via localhost)
```

## Traffic Rules

| From | To | Allowed |
| ------ | ---- | --------- |
| MikroTik (wg0) | FreeRADIUS (10.10.0.1:1812,1813) | ✓ |
| MikroTik (wg0) | Other MikroTik | ✗ |
| MikroTik (wg0) | Internet | ✗ |
| MikroTik (wg1) | Other MikroTik | ✗ |
| MikroTik (wg1) | Internet | ✗ |
| Django (localhost) | wgrest API | ✓ |
| Django (host) | MikroTik (10.11.0.X) | ✓ |

---

## Setup

### Step 1: Clone and Configure

```bash
git clone <repo-url> wgrest-docker
cd wgrest-docker
cp .env.example .env
nano .env
```

Fill in:

```bash
SERVER_IP=203.0.113.50

WG0_PORT=51820
WG1_PORT=51821

# Run: openssl rand -hex 32
WGREST_API_KEY=your_generated_key_here

WG0_SUBNET=10.10.0.0/16
WG1_SUBNET=10.11.0.0/16
WG0_ADDRESS=10.10.0.1/16
WG1_ADDRESS=10.11.0.1/16

DJANGO_API_URL=http://localhost:8000
DJANGO_API_TOKEN=
```

### Step 2: Run Setup

```bash
sudo ./scripts/setup.sh
```

This will:

- Install WireGuard tools
- Generate server keypairs
- Create wg0.conf and wg1.conf
- Configure firewall rules (Coolify-safe)
- Start WireGuard interfaces
- Start wgrest container

### Step 3: Save Server Public Keys

Setup prints the keys at the end:

```output
==========================================
Setup Complete
==========================================

Server Public Keys (add to Django settings):
  WG0: aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890abcdefg=
  WG1: xYzAbCdEfGhIjKlMnOpQrStUvWxYz0987654321zyxwv=

Endpoints:
  WG0: 203.0.113.50:51820
  WG1: 203.0.113.50:51821
  wgrest API: http://localhost:8080
```

Save these for Django configuration.

---

## Configure Django (Coolify)

### Django .env

```bash
WGREST_API_URL=http://localhost:8080
WGREST_API_KEY=same_key_from_wgrest_server

WIREGUARD_SERVER_HOST=203.0.113.50
WG0_PUBLIC_KEY=aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890abcdefg=
WG1_PUBLIC_KEY=xYzAbCdEfGhIjKlMnOpQrStUvWxYz0987654321zyxwv=

WG0_PORT=51820
WG1_PORT=51821
```

### Run Migrations

```bash
python manage.py makemigrations wireguard
python manage.py migrate
```

### Backup Server Keys

```bash
python manage.py backup_server_keys
```

### Test Connection

```bash
python manage.py shell
```

```python
from wireguard.wgrest_client import wgrest_client
print(wgrest_client.health_check())
print(wgrest_client.get_devices())
```

---

## Configure Restore Capability

Create Django API token:

```bash
python manage.py shell
```

```python
from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token

User = get_user_model()
admin = User.objects.filter(is_superuser=True).first()
token, created = Token.objects.get_or_create(user=admin)
print(f"Token: {token.key}")
```

Add to WireGuard server `.env`:

```bash
DJANGO_API_URL=http://localhost:8000
DJANGO_API_TOKEN=paste_token_here
```

---

## Verification

```bash
sudo wg show
curl -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:8080/v1/devices/
sudo ./scripts/test_security.sh
```

---

## FreeRADIUS Configuration

FreeRADIUS must bind to 10.10.0.1:

`/etc/freeradius/3.0/radiusd.conf`:

```conf
listen {
    ipaddr = 10.10.0.1
    port = 1812
    type = auth
}

listen {
    ipaddr = 10.10.0.1
    port = 1813
    type = acct
}
```

```bash
sudo systemctl restart freeradius
```

---

## Troubleshooting

### wgrest not responding

```bash
docker ps | grep wgrest
docker logs wgrest
curl http://localhost:8080/v1/devices/
```

### Firewall issues

```bash
sudo iptables -L FORWARD -n -v
sudo /usr/local/bin/wg-firewall.sh
```

### WireGuard interfaces

```bash
sudo wg show
sudo wg-quick down wg0 && sudo wg-quick up wg0
sudo wg-quick down wg1 && sudo wg-quick up wg1
```
