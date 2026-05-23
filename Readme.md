# WGREST-Docker

WireGuard server for Davina ISP management system.

## Architecture

```text
Single Server (WireGuard + Django/Coolify)
├── wg0 interface (10.10.0.1) ─── MikroTik RADIUS traffic
├── wg1 interface (10.11.0.1) ─── MikroTik API traffic
├── FreeRADIUS (binds to 10.10.0.1)
├── wgrest API (0.0.0.0:7070, firewalled — LAN/host only)
└── Coolify
    └── Django container (connects via host.docker.internal:7070)
```

## Traffic Rules

| From | To | Allowed |
| ------ | ---- | --------- |
| MikroTik (wg0) | FreeRADIUS (10.10.0.1:1812,1813) | ✓ |
| MikroTik (wg0) | Other MikroTik | ✗ |
| MikroTik (wg0) | Internet | ✗ |
| MikroTik (wg1) | Other MikroTik | ✗ |
| MikroTik (wg1) | Internet | ✗ |
| Django (host/container) | wgrest API (host:7070) | ✓ |
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

Make the scripts executable:

```bash
chmod +x scripts/setup.sh
chmod +x scripts/restore.sh
chmod +x scripts/test_security.sh
```

Run the setup:

```bash
sudo ./scripts/setup.sh
```

Run the security test:

```bash
sudo ./scripts/test_security.sh
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
  wgrest API: http://localhost:7070
```

Save these for Django configuration.

---

## Configure Django (Coolify)

### Django .env

> **Coolify note**: Django runs inside a Docker container. `localhost` inside
> the container refers to the container itself, not the host. Use
> `http://host.docker.internal:7070` so Django can reach wgrest on the host.
> Add `extra_hosts: ["host.docker.internal:host-gateway"]` to the Django
> service in your Coolify compose config (or equivalent Docker flag
> `--add-host=host.docker.internal:host-gateway`).

```bash
# Coolify / Docker-based Django:
WGREST_API_URL=http://host.docker.internal:7070

# Plain host-based Django (non-Docker):
# WGREST_API_URL=http://localhost:7070

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
curl -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:7070/v1/devices/
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
curl http://localhost:7070/v1/devices/
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

### WireGuard handshake times out even after importing Django config

Symptom: MikroTik log shows `Handshake for peer did not complete after 5 seconds`
even though you downloaded the WireGuard config from Django and imported it.

**Why this happens — two separate keys are in play:**

The config Django generates contains:
1. **MikroTik's private key** — sets MikroTik's identity (its public key is derived from this)
2. **VPS server public keys** — listed as `[Peer]` entries so MikroTik knows who to connect to

Importing the config correctly gives MikroTik the right private key. But the VPS's wg1 (via wgrest) also needs to have **MikroTik's resulting public key** registered as a peer. If that registration never made it into `wg1.conf`, the VPS silently drops every handshake initiation from MikroTik — it doesn't recognise the source.

**Most likely cause — peer was never registered:**

If Django was running inside a Docker container (Coolify) while wgrest was bound to `10.11.0.1:7070` only, Django's API call to register the peer on wgrest would have failed — `localhost:7070` inside the container routes to the container, not the host. Django stores the public key in its own database, but it was never written to `wg1.conf`.

**Confirm on the VPS:**

```bash
sudo grep -c "\[Peer\]" /etc/wireguard/wg1.conf
# Should equal the number of registered gateways.
# If 0, no peers were ever registered.

sudo wg show wg1
# Should list peers with allowed-ips matching your gateways.
```

**Fix:**

1. Deploy this wgrest-docker update (`WGREST_LISTEN=0.0.0.0:7070`) and restart the container:
   ```bash
   docker compose pull && docker compose up -d
   ```
2. Set `WGREST_API_URL=http://host.docker.internal:7070` in Django's env and redeploy Django.
3. For each affected gateway, POST to the resync endpoint to force peer registration:
   ```
   POST /wireguard/resync-keys/<gateway_id>/
   public_key=<the public key shown in Django's gateway detail page>
   ```
   This deletes any stale peer entry and re-creates it with the correct key.
   Since MikroTik already has the matching private key (from the imported config),
   the WireGuard handshake will complete as soon as the peer is registered.
4. Verify: `sudo wg show wg1` should show `latest handshake` within 30 seconds.
