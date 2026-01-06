#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

WG0_PORT=${WG0_PORT:-51820}
WG1_PORT=${WG1_PORT:-51821}
WG0_ADDRESS=${WG0_ADDRESS:-10.10.0.1/16}
WG1_ADDRESS=${WG1_ADDRESS:-10.11.0.1/16}
WGREST_PORT=${WGREST_PORT:-8080}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root"
    fi
}

install_dependencies() {
    log "Installing dependencies..."
    apt-get update
    apt-get install -y wireguard wireguard-tools jq curl
    
    if ! command -v docker &> /dev/null; then
        log "Installing Docker..."
        apt-get install -y docker.io docker-compose
        systemctl enable docker
        systemctl start docker
    else
        log "Docker already installed, skipping..."
    fi
}

generate_server_keys() {
    log "Generating WireGuard server keys..."
    
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    
    if [ ! -f /etc/wireguard/wg0.key ]; then
        wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
        chmod 600 /etc/wireguard/wg0.key
    fi
    
    if [ ! -f /etc/wireguard/wg1.key ]; then
        wg genkey | tee /etc/wireguard/wg1.key | wg pubkey > /etc/wireguard/wg1.pub
        chmod 600 /etc/wireguard/wg1.key
    fi
    
    WG0_PRIVATE=$(cat /etc/wireguard/wg0.key)
    WG0_PUBLIC=$(cat /etc/wireguard/wg0.pub)
    WG1_PRIVATE=$(cat /etc/wireguard/wg1.key)
    WG1_PUBLIC=$(cat /etc/wireguard/wg1.pub)
    
    log "WG0 Public Key: $WG0_PUBLIC"
    log "WG1 Public Key: $WG1_PUBLIC"
}

create_wg_configs() {
    log "Creating WireGuard configs..."
    
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $WG0_PRIVATE
Address = $WG0_ADDRESS
ListenPort = $WG0_PORT
EOF
    
    cat > /etc/wireguard/wg1.conf << EOF
[Interface]
PrivateKey = $WG1_PRIVATE
Address = $WG1_ADDRESS
ListenPort = $WG1_PORT
EOF
    
    chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/wg1.conf
}

setup_firewall() {
    log "Configuring firewall rules..."
    
    sysctl -w net.ipv4.ip_forward=1
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    create_firewall_script
    /usr/local/bin/wg-firewall.sh
    create_systemd_service
}

create_firewall_script() {
    cat > /usr/local/bin/wg-firewall.sh << 'SCRIPT'
#!/bin/bash
WG0_PORT=${WG0_PORT:-51820}
WG1_PORT=${WG1_PORT:-51821}

remove_wg_rules() {
    iptables -S INPUT | grep -E "(${WG0_PORT}|${WG1_PORT})" | while read rule; do
        iptables $(echo "$rule" | sed 's/-A/-D/')
    done 2>/dev/null || true
    
    iptables -S FORWARD | grep -E "(wg0|wg1)" | while read rule; do
        iptables $(echo "$rule" | sed 's/-A/-D/')
    done 2>/dev/null || true
}

remove_wg_rules

iptables -A INPUT -p udp --dport $WG0_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $WG1_PORT -j ACCEPT

iptables -A FORWARD -i wg0 -o wg0 -j DROP
iptables -A FORWARD -i wg1 -o wg1 -j DROP
iptables -A FORWARD -i wg0 -o wg1 -j DROP
iptables -A FORWARD -i wg1 -o wg0 -j DROP

iptables -A FORWARD -i wg0 -d 10.10.0.1 -p udp --dport 1812 -j ACCEPT
iptables -A FORWARD -i wg0 -d 10.10.0.1 -p udp --dport 1813 -j ACCEPT
iptables -A FORWARD -i wg0 -j DROP
iptables -A FORWARD -i wg1 -j DROP
SCRIPT

    sed -i "s/WG0_PORT=\${WG0_PORT:-51820}/WG0_PORT=${WG0_PORT}/" /usr/local/bin/wg-firewall.sh
    sed -i "s/WG1_PORT=\${WG1_PORT:-51821}/WG1_PORT=${WG1_PORT}/" /usr/local/bin/wg-firewall.sh
    
    chmod +x /usr/local/bin/wg-firewall.sh
}

create_systemd_service() {
    cat > /etc/systemd/system/wg-firewall.service << EOF
[Unit]
Description=WireGuard Firewall Rules
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-firewall.service
}

start_wireguard() {
    log "Starting WireGuard interfaces..."
    
    wg-quick down wg0 2>/dev/null || true
    wg-quick down wg1 2>/dev/null || true
    
    wg-quick up wg0
    wg-quick up wg1
    
    systemctl enable wg-quick@wg0
    systemctl enable wg-quick@wg1
}

start_docker() {
    log "Starting Docker services..."
    cd "$PROJECT_DIR"
    docker-compose down 2>/dev/null || true
    docker-compose up -d
}

wait_for_wgrest() {
    log "Waiting for wgrest API..."
    for i in {1..30}; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WGREST_PORT/v1/devices/" | grep -q "200\|401"; then
            log "wgrest API is ready"
            return 0
        fi
        sleep 1
    done
    error "wgrest API did not become ready"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "Setup Complete"
    echo "=========================================="
    echo ""
    echo "Server Public Keys (add to Django settings):"
    echo "  WG0: $(cat /etc/wireguard/wg0.pub)"
    echo "  WG1: $(cat /etc/wireguard/wg1.pub)"
    echo ""
    echo "Endpoints:"
    echo "  WG0: ${SERVER_IP:-<SERVER_IP>}:$WG0_PORT"
    echo "  WG1: ${SERVER_IP:-<SERVER_IP>}:$WG1_PORT"
    echo "  wgrest API: http://localhost:$WGREST_PORT"
    echo ""
}

main() {
    check_root
    install_dependencies
    generate_server_keys
    create_wg_configs
    setup_firewall
    start_wireguard
    start_docker
    wait_for_wgrest
    print_summary
}

main "$@"
