#!/usr/bin/env bash
# Inject an OpenWrt UCI network configuration into a disk image.

set -euo pipefail

# libguestfs needs writable runtime paths in some WSL environments.
export TMPDIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="$TMPDIR"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <openwrt-image> <network-config-file> [firewall-config-file]" >&2
    exit 1
fi

image="$1"
network_config="$2"
firewall_config="${3:-}"

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
if [[ -n "$firewall_config" && ! -f "$firewall_config" ]]; then
    echo "Error: firewall configuration does not exist: $firewall_config" >&2
    exit 1
fi

echo "Injecting network configuration from ${network_config}..."
guestfish --rw -a "$image" -i upload "$network_config" /etc/config/network
guestfish --rw -a "$image" -i chmod 0644 /etc/config/network
if [[ -n "$firewall_config" ]]; then
    echo "Injecting firewall configuration from ${firewall_config}..."
    guestfish --rw -a "$image" -i upload "$firewall_config" /etc/config/firewall
    guestfish --rw -a "$image" -i chmod 0600 /etc/config/firewall
fi
guestfish --rw -a "$image" -i sync

echo "Ready: ${image}"
