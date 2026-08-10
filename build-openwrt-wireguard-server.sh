#!/usr/bin/env bash
# Build a configured OpenWrt QCOW2 image and package its final state as an OVA.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build-openwrt-wireguard-server.sh --ova FILE [options]

Build steps:
  1. Download the OpenWrt x86-64 EFI image.
  2. Expand it to 512 MiB and convert it to QCOW2.
  3. Configure the root password, SSH key, and network.
  4. Boot QEMU and wait for SSH.
  5. Disable LAN DHCP and LAN-to-WAN forwarding.
  6. Install WireGuard with LuCI support.
  7. Configure the WireGuard server interface and firewall.
  8. Shut down OpenWrt cleanly.
  9. Convert the final disk to VMDK and package FILE as an OVA.

Options:
  --ova FILE          Required OVA output path.
  --disk-dir DIR      Image working directory (default: disk)
  --keys-dir DIR      SSH key directory (default: keys)
  --network FILE      OpenWrt network UCI file (default: networks/server.conf)
  --ssh-port PORT     Host port forwarded to OpenWrt SSH (default: 22222)
  --luci-port PORT    Host port forwarded to LuCI (default: 8080)
  --boot-timeout SEC  Seconds to wait for OpenWrt SSH (default: 180)
  -h, --help          Show this help message

Existing downloaded images, QCOW2 disks, generated SSH keys, and the requested
OVA are replaced. Use separate --disk-dir and --keys-dir values to preserve
working files from another build.
EOF
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
disk_dir='disk'
keys_dir='keys'
network_file="${project_dir}/networks/server.conf"
ova_file=''
ssh_port='22222'
luci_port='8080'
boot_timeout='180'
qemu_pid=''
work_dir=''
user_configuration_output=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ova|--disk-dir|--keys-dir|--network|--ssh-port|--luci-port|--boot-timeout)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
            case "$1" in
                --ova) ova_file="$2" ;;
                --disk-dir) disk_dir="$2" ;;
                --keys-dir) keys_dir="$2" ;;
                --network) network_file="$2" ;;
                --ssh-port) ssh_port="$2" ;;
                --luci-port) luci_port="$2" ;;
                --boot-timeout) boot_timeout="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[[ -n "$ova_file" ]] || { echo 'Error: --ova is required.' >&2; usage >&2; exit 1; }
for value in "$ssh_port" "$luci_port" "$boot_timeout"; do
    [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 )) || {
        echo "Error: expected a positive integer, got: $value" >&2
        exit 1
    }
done
(( 10#$ssh_port <= 65535 && 10#$luci_port <= 65535 )) || {
    echo 'Error: ports must be in the range 1-65535.' >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

stop_qemu() {
    [[ -n "$qemu_pid" ]] || return 0
    if kill -0 "$qemu_pid" 2>/dev/null; then
        echo 'Stopping QEMU...'
        kill -TERM "$qemu_pid"
        for _ in {1..30}; do
            kill -0 "$qemu_pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$qemu_pid" 2>/dev/null; then
            echo 'QEMU did not stop in time; sending SIGKILL.' >&2
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
        wait "$qemu_pid" 2>/dev/null || true
    fi
    qemu_pid=''
}

wait_for_qemu_shutdown() {
    local timeout="$1" qemu_status=0

    for (( elapsed = 0; elapsed < timeout; elapsed++ )); do
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            wait "$qemu_pid" || qemu_status=$?
            qemu_pid=''
            if (( qemu_status != 0 )); then
                echo "Error: QEMU exited with status ${qemu_status} during shutdown." >&2
                return 1
            fi
            return 0
        fi
        sleep 1
    done

    echo "Error: OpenWrt did not shut down within ${timeout}s." >&2
    return 1
}

cleanup() {
    stop_qemu
    [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM

for command in awk qemu-img sha256sum ssh tar; do
    require_command "$command"
done

disk_dir="$(realpath -m "$disk_dir")"
keys_dir="$(realpath -m "$keys_dir")"
network_file="$(realpath -m "$network_file")"
ova_file="$(realpath -m "$ova_file")"

[[ -f "$network_file" ]] || { echo "Error: network config does not exist: $network_file" >&2; exit 1; }
mkdir -p "$disk_dir" "$keys_dir"
mkdir -p "$(dirname "$ova_file")"

# Read the canonical image name from the downloader, keeping this orchestrator
# aligned when its VERSION or TARGET variables are updated.
version="$(awk -F"'" '/^readonly VERSION=/{print $2; exit}' "${project_dir}/download-openwrt-efi.sh")"
target="$(awk -F"'" '/^readonly TARGET=/{print $2; exit}' "${project_dir}/download-openwrt-efi.sh")"
[[ -n "$version" && -n "$target" ]] || { echo 'Error: cannot determine image name from downloader.' >&2; exit 1; }
image_stem="openwrt-${version}-${target}-generic-ext4-combined-efi"
raw_image="${disk_dir}/${image_stem}.img"
qcow2_image="${disk_dir}/${image_stem}.qcow2"
key_file="${keys_dir}/openwrt_ed25519"
qemu_log="${disk_dir}/${image_stem}.qemu.log"
# This is a build-owned file.  A fresh image has fresh Dropbear host keys, so
# discard any prior key for this particular build before QEMU is started.
known_hosts_file="${disk_dir}/${image_stem}.known_hosts"
: >"$known_hosts_file"

echo '==> Downloading OpenWrt'
"${project_dir}/download-openwrt-efi.sh" "$disk_dir"

echo '==> Preparing the 512 MiB QCOW2 disk'
"${project_dir}/prepare-image.sh" "$raw_image" "$qcow2_image"

echo '==> Configuring the OpenWrt user and network'
user_configuration_output="$("${project_dir}/configure-user.sh" "$qcow2_image" "$keys_dir")"
"${project_dir}/configure-network.sh" "$qcow2_image" "$network_file"

echo "==> Starting QEMU (log: $qemu_log)"
OPENWRT_NETWORK_CONFIG="$network_file" \
OPENWRT_SSH_PORT="$ssh_port" OPENWRT_LUCI_PORT="$luci_port" \
    setsid "${project_dir}/run-openwrt.sh" "$qcow2_image" \
    </dev/null >"$qemu_log" 2>&1 &
qemu_pid=$!

echo "Waiting up to ${boot_timeout}s for OpenWrt SSH..."
ready=0
for (( elapsed = 0; elapsed < 10#$boot_timeout; elapsed += 2 )); do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo "Error: QEMU stopped during boot. See: $qemu_log" >&2
        exit 1
    fi
    if ssh -i "$key_file" -p "$ssh_port" -o BatchMode=yes \
        -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$known_hosts_file" root@127.0.0.1 true 2>/dev/null; then
        ready=1
        break
    fi
    sleep 2
done
(( ready == 1 )) || { echo "Error: OpenWrt SSH did not become ready. See: $qemu_log" >&2; exit 1; }

echo '==> Preparing Ansible and creating the inventory'
"${project_dir}/configure-ansible.sh"
"${project_dir}/configure-inventory.sh" \
    --inventory "${project_dir}/inventory.ini" \
    --host 127.0.0.1 --port "$ssh_port" --key "$key_file" \
    --known-hosts "$known_hosts_file"

echo '==> Disabling DHCP services on the OpenWrt LAN interface'
"${project_dir}/run-ansible.sh" "${project_dir}/playbooks/disable-lan-dhcp.yml"

echo '==> Disabling LAN-to-WAN forwarding'
"${project_dir}/run-ansible.sh" "${project_dir}/playbooks/disable-lan-to-wan-nat.yml"

echo '==> Installing WireGuard and LuCI support'
"${project_dir}/run-ansible.sh" "${project_dir}/playbooks/install-wireguard.yml"

echo '==> Configuring the WireGuard server'
"${project_dir}/run-ansible.sh" "${project_dir}/playbooks/configure-wireguard-server.yml"

echo '==> Shutting down OpenWrt cleanly'
"${project_dir}/run-ansible.sh" "${project_dir}/playbooks/shutdown-openwrt.yml"
wait_for_qemu_shutdown 60

echo '==> Creating the OVA'
work_dir="$(mktemp -d "${disk_dir}/.ova.XXXXXX")"
vmdk_name="${image_stem}.vmdk"
ovf_name="${image_stem}.ovf"
manifest_name="${image_stem}.mf"
vmdk_path="${work_dir}/${vmdk_name}"
ovf_path="${work_dir}/${ovf_name}"
manifest_path="${work_dir}/${manifest_name}"

qemu-img check "$qcow2_image"
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized "$qcow2_image" "$vmdk_path"

cat >"$ovf_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<ovf:Envelope xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">
  <ovf:References>
    <ovf:File ovf:id="file1" ovf:href="${vmdk_name}" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </ovf:References>
  <ovf:DiskSection>
    <ovf:Info>Virtual disks</ovf:Info>
    <ovf:Disk ovf:diskId="disk1" ovf:fileRef="file1" ovf:capacity="536870912" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </ovf:DiskSection>
  <ovf:NetworkSection>
    <ovf:Info>Logical networks</ovf:Info>
    <ovf:Network ovf:name="WAN"><ovf:Description>WAN adapter</ovf:Description></ovf:Network>
    <ovf:Network ovf:name="LAN"><ovf:Description>LAN adapter</ovf:Description></ovf:Network>
  </ovf:NetworkSection>
  <ovf:VirtualSystem ovf:id="OpenWrt-WireGuard-Server">
    <ovf:Info>OpenWrt WireGuard server appliance</ovf:Info>
    <ovf:Name>OpenWrt WireGuard Server</ovf:Name>
    <ovf:OperatingSystemSection ovf:id="101"><ovf:Info>Other Linux</ovf:Info><ovf:Description>Other Linux</ovf:Description></ovf:OperatingSystemSection>
    <ovf:VirtualHardwareSection>
      <ovf:Info>Virtual hardware</ovf:Info>
      <ovf:System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>OpenWrt WireGuard Server</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType></ovf:System>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>
      <ovf:Item><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>2</rasd:VirtualQuantity><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits></ovf:Item>
      <ovf:Item><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>512</rasd:VirtualQuantity><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits></ovf:Item>
      <ovf:Item><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceType>20</rasd:ResourceType><rasd:ResourceSubType>AHCI</rasd:ResourceSubType><rasd:Address>0</rasd:Address></ovf:Item>
      <ovf:Item><rasd:InstanceID>4</rasd:InstanceID><rasd:ResourceType>17</rasd:ResourceType><rasd:HostResource>ovf:/disk/disk1</rasd:HostResource><rasd:Parent>3</rasd:Parent><rasd:AddressOnParent>0</rasd:AddressOnParent></ovf:Item>
      <ovf:Item><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceType>10</rasd:ResourceType><rasd:ResourceSubType>E1000</rasd:ResourceSubType><rasd:Connection>WAN</rasd:Connection></ovf:Item>
      <ovf:Item><rasd:InstanceID>6</rasd:InstanceID><rasd:ResourceType>10</rasd:ResourceType><rasd:ResourceSubType>E1000</rasd:ResourceSubType><rasd:Connection>LAN</rasd:Connection></ovf:Item>
    </ovf:VirtualHardwareSection>
  </ovf:VirtualSystem>
</ovf:Envelope>
EOF

(cd "$work_dir" && sha256sum "$ovf_name" "$vmdk_name" | while read -r sum file; do
    printf 'SHA256(%s)= %s\n' "$file" "$sum"
done >"$manifest_name")
tar --format=ustar -C "$work_dir" -cf "$ova_file" "$ovf_name" "$vmdk_name" "$manifest_name"

echo
echo 'Build complete.'
echo "QCOW2: $qcow2_image"
echo "OVA:   $ova_file"
echo "QEMU log: $qemu_log"
echo
echo 'OpenWrt access details:'
printf '%s\n' "$user_configuration_output"
