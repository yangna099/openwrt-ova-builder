#!/usr/bin/env bash
# Create a 512 MiB QEMU QCOW2 disk from an OpenWrt raw image.
# This script uses libguestfs and does not require sudo or loop devices.

set -euo pipefail

readonly IMAGE_SIZE='512M'

# Some restricted environments do not provide /var/tmp, libguestfs's default.
export TMPDIR="${TMPDIR:-/tmp}"
# Avoid a read-only XDG runtime directory when libguestfs creates its socket.
export XDG_RUNTIME_DIR="$TMPDIR"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <input.img> <output.qcow2>" >&2
    exit 1
fi

input_image="$1"
qcow2_image="$2"

work_dir=''

cleanup() {
    [[ -z "$work_dir" ]] || rm -rf "$work_dir"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

for command in qemu-img virt-filesystems virt-resize awk; do
    require_command "$command"
done

if [[ ! -f "$input_image" ]]; then
    echo "Error: input image does not exist: $input_image" >&2
    exit 1
fi
if [[ -e "$qcow2_image" ]]; then
    echo "Replacing existing QEMU disk: $qcow2_image"
fi

# OpenWrt's EFI image has an EFI system partition and an ext4 root partition.
root_partition="$(virt-filesystems --format=raw -a "$input_image" --filesystems --long \
    | awk '$2 == "filesystem" && $3 == "ext4" { print $1; exit }')"
if [[ -z "$root_partition" ]]; then
    echo 'Error: unable to find an ext4 filesystem in the input image.' >&2
    exit 1
fi

work_dir="$(mktemp -d)"
expanded_image="${work_dir}/openwrt-expanded.img"

echo "Creating a ${IMAGE_SIZE} expanded raw disk..."
qemu-img create -f raw "$expanded_image" "$IMAGE_SIZE" >/dev/null

echo "Expanding ${root_partition} and its ext4 filesystem..."
virt-resize --format=raw --expand "$root_partition" "$input_image" "$expanded_image"

echo "Creating QEMU disk: ${qcow2_image}"
qemu-img convert -p -f raw -O qcow2 "$expanded_image" "$qcow2_image"

qemu-img info "$qcow2_image"
echo "Ready: ${qcow2_image}"
