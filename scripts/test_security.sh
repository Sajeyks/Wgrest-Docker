#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

WGREST_PORT=${WGREST_PORT:-8080}

PASS=0
FAIL=0

# Dump iptables to temp file for reliable parsing
TMPFILE=$(mktemp)
iptables -L FORWARD -n -v > "$TMPFILE"
INPUT_TMPFILE=$(mktemp)
iptables -L INPUT -n -v > "$INPUT_TMPFILE"

check() {
    if eval "$2" > /dev/null 2>&1; then
        echo "✓ $1"
        ((PASS++))
    else
        echo "✗ $1"
        ((FAIL++))
    fi
}

check_forward() {
    if grep -E "$2" "$TMPFILE" > /dev/null 2>&1; then
        echo "✓ $1"
        ((PASS++))
    else
        echo "✗ $1"
        ((FAIL++))
    fi
}

check_input() {
    if grep -E "$2" "$INPUT_TMPFILE" > /dev/null 2>&1; then
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
check_input "WG0 port open" "dpt:51820"
check_input "WG1 port open" "dpt:51821"
echo ""

echo "Firewall - Peer Isolation:"
check_forward "wg0-to-wg0 blocked" "DROP.+wg0.+wg0"
check_forward "wg1-to-wg1 blocked" "DROP.+wg1.+wg1"
check_forward "wg0-to-wg1 blocked" "DROP.+wg0.+wg1"
check_forward "wg1-to-wg0 blocked" "DROP.+wg1.+wg0"
echo ""

echo "Firewall - Allowed Traffic:"
check_forward "RADIUS 1812 allowed" "ACCEPT.+10\.10\.0\.1.+dpt:1812"
check_forward "RADIUS 1813 allowed" "ACCEPT.+10\.10\.0\.1.+dpt:1813"
echo ""

echo "Firewall - Default Drops:"
check_forward "wg0 default drop" "DROP.+wg0 +\* +0\.0\.0\.0/0 +0\.0\.0\.0/0"
check_forward "wg1 default drop" "DROP.+wg1 +\* +0\.0\.0\.0/0 +0\.0\.0\.0/0"
echo ""

# Cleanup
rm -f "$TMPFILE" "$INPUT_TMPFILE"

echo "========================"
echo "Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    exit 1
fi