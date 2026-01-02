# WGREST-Docker

WireGuard server for Davina ISP management system.

## Architecture

```text
WireGuard Server (this repo)          Django (Davina)
├── wg0: MikroTik ↔ FreeRADIUS       └── wg1 peer: 10.11.0.100
├── wg1: MikroTik ↔ Django                │
├── FreeRADIUS (10.10.0.1)                │
└── wgrest API (:8080)                    │
         ▲                                │
         └────────────────────────────────┘
                   wg1 tunnel
```

## Traffic Rules

```text
| From | To | Allowed |
|------|----|---------|
| MikroTik (wg0) | FreeRADIUS (10.10.0.1:1812,1813) | ✓ |
| MikroTik (wg0) | Other MikroTik | ✗ |
| MikroTik (wg0) | Internet | ✗ |
| Django (10.11.0.100) | MikroTik (wg1, ports 8728,8729,22) | ✓ |
| MikroTik (wg1) | Other MikroTik | ✗ |
```

## Setup

1. Clone and configure:

     ```bash
     git clone <repo>
     cd wgrest-docker
     cp .env.example .env
     ```

2. Edit `.env`:

     ```bash
     SERVER_IP=your.server.ip
     WGREST_API_KEY=generate_secure_key
     DJANGO_WG_PUBLIC_KEY=from_django_setup
     ```

3. Run setup:

     ```bash
     sudo ./scripts/setup.sh
     ```

>Note: the server public keys printed at the end - add them to Django settings.

## Django Peer Setup

Django must be a wg1 peer. On the Django server:

1. Generate keys:

     ```bash
     wg genkey | tee django.key | wg pubkey > django.pub
     ```

2. Add the public key to `.env` on WireGuard server:

     ```bash
     DJANGO_WG_PUBLIC_KEY=<contents of django.pub>
     ```

3. Create Django's WireGuard config (`/etc/wireguard/wg1.conf`):

     ```ini
     [Interface]
     PrivateKey = <contents of django.key>
     Address = 10.11.0.100/32

     [Peer]
     PublicKey = <WG1 public key from setup output>
     Endpoint = <SERVER_IP>:51821
     AllowedIPs = 10.11.0.0/16
     PersistentKeepalive = 25
     ```

4. Start WireGuard on Django server:

     ```bash
     sudo wg-quick up wg1
     ```

## Restore After Rebuild

If server is rebuilt, restore from Django:

```bash
sudo ./scripts/restore.sh
```

Requires `DJANGO_API_URL` and `DJANGO_API_TOKEN` in `.env`.

## Verify Setup

```bash
sudo ./scripts/test_security.sh
```

## FreeRADIUS Configuration

FreeRADIUS must bind to the wg0 interface IP:

```conf
# /etc/freeradius/3.0/radiusd.conf
listen {
    ipaddr = 10.10.0.1
    port = 1812
    type = auth
}
```

## Testing

From the WireGuard server itself:

```console
curl -H "Authorization: Bearer $WGREST_API_KEY" http://localhost:8080/v1/devices/
```

From Django (once wg1 tunnel is up):

```console
curl -H "Authorization: Bearer $WGREST_API_KEY" http://10.11.0.1:8080/v1/devices/
```

From public internet - should fail/timeout (that's the point).
