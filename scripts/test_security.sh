#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

WGREST_PORT=${WGREST_PORT:-8080}
DJANGO_WG_IP=${DJANGO_WG_IP:-10.11.0.100/32}
DJANGO_IP=$(echo $DJANGO_WG_IP | cut -d'/' -f1)

PASS=0
FAIL=0

check() {
    if eval "$2" > /dev/null 2>&1; then
        echo "✓ $1"
        ((PASS++))
    else
        echo "✗ $1"
        ((FAIL++))
    fi
}

echo "WireGuard Security Check"
echo "========================"
echo ""

echo "Interfaces:"
check "wg0 is up" "ip link show wg0 | grep -q UP"
check "wg1 is up" "ip link show wg1 | grep -q UP"
echo ""

echo "Services:"
check "wgrest API responding" "curl -sf http://localhost:$WGREST_PORT/v1/devices/"
check "Docker containers running" "docker ps | grep -q wgrest"
echo ""

echo "Firewall - Input:"
check "WG0 port open" "iptables -L INPUT -n | grep -q '51820'"
check "WG1 port open" "iptables -L INPUT -n | grep -q '51821'"
check "wgrest port open" "iptables -L INPUT -n | grep -q '$WGREST_PORT'"
echo ""

echo "Firewall - Peer Isolation:"
check "wg0-to-wg0 blocked" "iptables -L FORWARD -n | grep -q 'wg0.*wg0.*DROP'"
check "wg1-to-wg1 blocked" "iptables -L FORWARD -n | grep -q 'wg1.*wg1.*DROP'"
check "wg0-to-wg1 blocked" "iptables -L FORWARD -n | grep -q 'wg0.*wg1.*DROP'"
check "wg1-to-wg0 blocked" "iptables -L FORWARD -n | grep -q 'wg1.*wg0.*DROP'"
echo ""

echo "Firewall - Allowed Traffic:"
check "RADIUS 1812 allowed" "iptables -L FORWARD -n | grep -q '10.10.0.1.*1812.*ACCEPT'"
check "RADIUS 1813 allowed" "iptables -L FORWARD -n | grep -q '10.10.0.1.*1813.*ACCEPT'"
check "Django to MikroTik 8728" "iptables -L FORWARD -n | grep -q '$DJANGO_IP.*8728.*ACCEPT'"
check "Django to MikroTik 8729" "iptables -L FORWARD -n | grep -q '$DJANGO_IP.*8729.*ACCEPT'"
echo ""

echo "Firewall - Default Drops:"
check "wg0 default drop" "iptables -L FORWARD -n | grep 'wg0' | tail -1 | grep -q DROP"
check "wg1 default drop" "iptables -L FORWARD -n | grep 'wg1' | tail -1 | grep -q DROP"
echo ""

echo "========================"
echo "Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    exit 1
fi