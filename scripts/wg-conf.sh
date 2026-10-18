#!/bin/bash
# Sourced by setup.sh and restore.sh.
#
# wgrest dumps `wg showconf` every 10 minutes, and that format has no Address
# line. When it dumped straight over /etc/wireguard, the next reboot brought
# wg0/wg1 up with no IP: wgrest could not bind 10.11.0.1 and FreeRADIUS could
# not bind 10.10.0.1. So wgrest now writes to its own directory, and wg-quick
# owns /etc/wireguard, loading peers back from wgrest's copy on every boot.

WGREST_STATE_DIR=/var/lib/wgrest/wireguard

write_wg_conf() {
    local iface=$1 private_key=$2 address=$3 port=$4
    local peers="$WGREST_STATE_DIR/$iface.conf"

    mkdir -p "$WGREST_STATE_DIR"
    chmod 700 "$WGREST_STATE_DIR"

    # First run after upgrading from the old layout: keep the live peers, or
    # every router stays dark until Django re-syncs it.
    if [ ! -s "$peers" ] && wg show "$iface" >/dev/null 2>&1; then
        wg showconf "$iface" > "$peers"
        chmod 600 "$peers"
    fi

    # wgrest's own peer saves include Address, which `wg addconf` rejects,
    # hence the strip.
    cat > "/etc/wireguard/$iface.conf" << EOF
[Interface]
PrivateKey = $private_key
Address = $address
ListenPort = $port
PostUp = [ -s $peers ] && wg addconf %i <(wg-quick strip $peers) || true
EOF
    chmod 600 "/etc/wireguard/$iface.conf"
}
