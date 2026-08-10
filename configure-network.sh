#!/usr/bin/env bash
# Inject an OpenWrt UCI network configuration into a disk image.

set -euo pipefail

# libguestfs needs writable runtime paths in some WSL environments.
export TMPDIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="$TMPDIR"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <openwrt-image> <network-config-file>" >&2
    exit 1
fi

image="$1"
network_config="$2"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

require_command guestfish

if [[ ! -f "$image" ]]; then
    echo "Error: image does not exist: $image" >&2
    exit 1
fi
if [[ ! -f "$network_config" ]]; then
    echo "Error: network configuration does not exist: $network_config" >&2
    exit 1
fi

echo "Injecting network configuration from ${network_config}..."
guestfish --rw -a "$image" -i upload "$network_config" /etc/config/network
guestfish --rw -a "$image" -i chmod 0644 /etc/config/network
guestfish --rw -a "$image" -i sync

echo "Ready: ${image}"
echo 'Network mapping: eth0 = WAN, eth1 = LAN'
