#!/usr/bin/env bash
# Boot a prepared OpenWrt x86-64 EFI QCOW2 image in QEMU.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <openwrt.qcow2>" >&2
    exit 1
fi

image="$1"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly network_file="${OPENWRT_NETWORK_CONFIG:-${script_dir}/network.conf}"
readonly network_mode="${OPENWRT_NETWORK_MODE:-dual}"
readonly network_interface="${OPENWRT_NETWORK_INTERFACE:-lan}"
readonly memory="${QEMU_MEMORY:-512M}"
readonly cpus="${QEMU_CPUS:-2}"
readonly luci_port="${OPENWRT_LUCI_PORT:-8080}"
readonly ssh_port="${OPENWRT_SSH_PORT:-22222}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

require_command qemu-system-x86_64
require_command awk

if [[ ! -f "$image" ]]; then
    echo "Error: image does not exist: $image" >&2
    exit 1
fi

if [[ ! -f "$network_file" ]]; then
    echo "Error: network configuration does not exist: $network_file" >&2
    exit 1
fi

get_interface_option() {
    awk -v wanted_interface="$1" -v wanted_option="$2" '
        $1 == "config" && $2 == "interface" {
            interface = $3
            gsub(/^['\''"]|['\''"]$/, "", interface)
            in_wanted_interface = (interface == wanted_interface)
            next
        }
        in_wanted_interface && $1 == "option" && $2 == wanted_option {
            value = $3
            gsub(/^['\''"]|['\''"]$/, "", value)
            print value
            exit
        }
    ' "$network_file"
}

ipv4_to_int() {
    local address="$1" octet
    local -a octets

    IFS=. read -r -a octets <<<"$address"
    if [[ ${#octets[@]} -ne 4 ]]; then
        return 1
    fi

    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^[0-9]+$ ]] || ((10#$octet > 255)); then
            return 1
        fi
    done

    printf '%u\n' "$(((10#${octets[0]} << 24) | (10#${octets[1]} << 16) | (10#${octets[2]} << 8) | 10#${octets[3]}))"
}

int_to_ipv4() {
    local value="$1"
    printf '%d.%d.%d.%d\n' \
        "$(((value >> 24) & 255))" \
        "$(((value >> 16) & 255))" \
        "$(((value >> 8) & 255))" \
        "$((value & 255))"
}

netmask_prefix() {
    local mask="$1" prefix=0 bit seen_zero=0

    for ((bit = 31; bit >= 0; bit--)); do
        if (((mask >> bit) & 1)); then
            if ((seen_zero)); then
                return 1
            fi
            ((prefix += 1))
        else
            seen_zero=1
        fi
    done

    printf '%d\n' "$prefix"
}

case "$network_mode" in
    dual|single) ;;
    *)
        echo "Error: OPENWRT_NETWORK_MODE must be 'dual' or 'single': $network_mode" >&2
        exit 1
        ;;
esac

interface_ip="$(get_interface_option "$network_interface" ipaddr)"
interface_netmask="$(get_interface_option "$network_interface" netmask)"
interface_gateway="$(get_interface_option "$network_interface" gateway)"
if [[ -z "$interface_ip" || -z "$interface_netmask" ]]; then
    echo "Error: ${network_interface} ipaddr or netmask is missing from: $network_file" >&2
    exit 1
fi

if ! interface_ip_int="$(ipv4_to_int "$interface_ip")" || \
    ! interface_mask_int="$(ipv4_to_int "$interface_netmask")"; then
    echo "Error: invalid ${network_interface} IPv4 address or netmask in: $network_file" >&2
    exit 1
fi

if ! interface_prefix="$(netmask_prefix "$interface_mask_int")"; then
    echo "Error: ${network_interface} netmask is not contiguous: $interface_netmask" >&2
    exit 1
fi

interface_network="$(int_to_ipv4 "$((interface_ip_int & interface_mask_int))")/${interface_prefix}"
if [[ -n "$interface_gateway" ]] && ! ipv4_to_int "$interface_gateway" >/dev/null; then
    echo "Error: invalid ${network_interface} gateway in: $network_file" >&2
    exit 1
fi

ovmf_code=''
ovmf_vars_template=''
for firmware_dir in /usr/share/OVMF /usr/share/edk2-ovmf/x64; do
    for firmware_variant in '' '_4M'; do
        candidate_code="${firmware_dir}/OVMF_CODE${firmware_variant}.fd"
        candidate_vars="${firmware_dir}/OVMF_VARS${firmware_variant}.fd"
        if [[ -f "$candidate_code" && -f "$candidate_vars" ]]; then
            ovmf_code="$candidate_code"
            ovmf_vars_template="$candidate_vars"
            break 2
        fi
    done
done

if [[ -z "$ovmf_code" ]]; then
    echo 'Error: OVMF firmware was not found. Install the ovmf package.' >&2
    exit 1
fi

# Keep a writable UEFI variable store beside the image so boot settings persist.
ovmf_vars="${image}.vars.fd"
if [[ ! -e "$ovmf_vars" ]]; then
    cp -- "$ovmf_vars_template" "$ovmf_vars"
fi

cat <<MESSAGE
Starting OpenWrt.
  LuCI: http://127.0.0.1:${luci_port}/
  SSH:  ssh -i <private-key> -p ${ssh_port} root@127.0.0.1

The QEMU serial console is attached to this terminal.  Press Ctrl+A, then X
to quit QEMU.
MESSAGE

if [[ "$network_mode" == 'single' ]]; then
    netdev="user,id=network,net=${interface_network}"
    [[ -z "$interface_gateway" ]] || netdev+=",host=${interface_gateway}"
    netdev+=",hostfwd=tcp:127.0.0.1:${luci_port}-${interface_ip}:80"
    netdev+=",hostfwd=tcp:127.0.0.1:${ssh_port}-${interface_ip}:22"
    network_arguments=(
        -netdev "$netdev"
        -device virtio-net-pci,netdev=network,mac=52:54:00:00:00:10
    )
else
    network_arguments=(
        -netdev user,id=wan
        -device virtio-net-pci,netdev=wan,mac=52:54:00:00:00:10
        -netdev "user,id=lan,net=${interface_network},hostfwd=tcp:127.0.0.1:${luci_port}-${interface_ip}:80,hostfwd=tcp:127.0.0.1:${ssh_port}-${interface_ip}:22"
        -device virtio-net-pci,netdev=lan,mac=52:54:00:00:00:11
    )
fi

exec qemu-system-x86_64 \
    -name openwrt \
    -machine q35,accel=kvm:tcg \
    -cpu max \
    -m "$memory" \
    -smp "$cpus" \
    -display none \
    -monitor none \
    -serial stdio \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$ovmf_vars" \
    -drive file="$image",if=none,id=openwrt_disk,format=qcow2 \
    -device virtio-blk-pci,drive=openwrt_disk,bootindex=1 \
    "${network_arguments[@]}"
