# OpenWrt OVA Builder

## Dependencies for Building an OVA

```bash
sudo apt update
sudo apt install python3-venv python3-pip
sudo apt install qemu-system-x86 qemu-utils qemu-system-gui ovmf libguestfs-tools
sudo chmod 644 /boot/vmlinuz-6.8.0-137-generic
sudo usermod -aG kvm "$USER"
```

## Dependencies for Running Ansible Playbooks

```bash
sudo apt update
sudo apt install python3-venv python3-pip
```

## Build an OVA

Build a WireGuard server appliance:

```bash
./build-openwrt-wireguard-server.sh \
  --ova output/openwrt-wireguard-server.ova \
  --keys-dir server-keys
```

Build a WireGuard client appliance:

```bash
./build-openwrt-wireguard-client.sh \
  --ova output/openwrt-wireguard-client.ova \
  --keys-dir client-keys
```

Build the ZeroTier appliance:

```bash
./build-openwrt-zerotier.sh \
  --ova output/openwrt-zt-pbr.ova \
  --disk-dir disk-zerotier \
  --keys-dir zerotier-keys
```

The imported PVE virtual machine is named `openwrt-zt-pbr`. Its three embedded
NICs are WAN `eth0`, LAN `eth1` at `10.10.11.1/24`, and Ansible management
`eth2`. The `eth2` NIC is preconfigured as DHCP interface `wan_internal` in
the `internal` firewall zone, so it can be used before the post-import
ZeroTier playbook runs. The appliance is configured as IPv4-only.

Build a WireGuard relay appliance. The relay accepts downstream WireGuard
clients and sends their traffic through the upstream tunnel described by the
wg-quick configuration:

```bash
./build-openwrt-wireguard-relay.sh \
  --ova output/openwrt-wireguard-relay.ova \
  --keys-dir relay-keys \
  --wg-quick-config clients/relay-upstream.conf
```

The relay OVA has one physical network adapter. Its `relay` interface uses the
static address `10.8.7.4/20`; it has no LAN or WAN logical interfaces or
firewall zones. IPv4 DHCP, DHCPv6, router advertisements, and NDP proxying are
explicitly disabled on the `relay` interface. Separate `wgserver` and
`wgclient` interfaces provide the downstream and upstream tunnels. The
upstream configuration must be an IPv4 full-tunnel configuration with
`0.0.0.0/0` in `AllowedIPs` and at least one IPv4 DNS server. Like the server
build, the downstream WireGuard address comes from the `wg_address` default in
`playbooks/configure-wireguard-server.yml`.

## Configure the Ansible Environment

### Install Ansible with `configure-ansible.sh`

[`configure-ansible.sh`](configure-ansible.sh) creates an isolated Python
virtual environment and installs or upgrades Ansible in it. This keeps the
project's Ansible installation separate from system Python packages.

Create the default `.venv` environment:

```bash
./configure-ansible.sh
```

The script is safe to run again when the environment already exists. Each run
upgrades `pip` and Ansible to the latest versions available from the configured
Python package index.

Script options:

| Option | Default | Required | Purpose |
| --- | --- | --- | --- |
| `--venv DIR` | `.venv` | No | Selects the virtual-environment directory to create or update. |
| `-h`, `--help` | N/A | No | Displays command usage and exits. |

To create the environment in another directory:

```bash
./configure-ansible.sh --venv .venv-ansible
source .venv-ansible/bin/activate
```

`run-ansible.sh` uses `.venv/bin/ansible-playbook` directly. Use the default
`.venv` location when running playbooks through that wrapper. If a custom
environment is selected, activate it and invoke `ansible-playbook` directly,
or create the default environment as well.

The script requires `python3` and Python virtual-environment support. On
Debian or Ubuntu, install `python3-venv` if environment creation fails. Package
installation also requires access to the configured Python package index.

### Create an Inventory with `configure-inventory.sh`

[`configure-inventory.sh`](configure-inventory.sh) generates an Ansible
inventory for one OpenWrt SSH target. The generated host belongs to the
`openwrt` group, connects as `root`, and sets
`ansible_python_interpreter=none` because these playbooks use raw commands and
do not require Python on OpenWrt.

Create an inventory for an OpenWrt target:

```bash
./configure-inventory.sh --host 10.8.7.3
```

Create an inventory for a local QEMU instance using the default forwarded SSH
port from `run-openwrt.sh`:

```bash
./configure-inventory.sh --port 22222
```

Script options:

| Option | Default | Required | Purpose |
| --- | --- | --- | --- |
| `--inventory FILE` | `inventory.ini` | No | Selects the inventory file to write. Its parent directory must already exist. |
| `--host HOST` | `127.0.0.1` | No | Sets the OpenWrt SSH hostname or IP address. The value cannot be empty. |
| `--port PORT` | `22` | No | Sets the OpenWrt SSH port. Valid values are `1` through `65535`. |
| `--key PATH` | `keys/openwrt_ed25519` | No | Sets the SSH private-key path written to the inventory. |
| `--name NAME` | `router` | No | Sets the Ansible inventory hostname. Letters, digits, underscores, periods, and hyphens are accepted. |
| `--known-hosts FILE` | Uses the user's default SSH `known_hosts` file | No | Uses a dedicated known-hosts file. Its parent directory must already exist; the file is created if necessary. |
| `-h`, `--help` | N/A | No | Displays command usage and exits. |

The inventory file is replaced on every successful invocation. Without
`--known-hosts`, SSH uses the user's default `~/.ssh/known_hosts` file. In both
modes, newly encountered host keys are accepted and recorded automatically.

After creating the inventory, verify connectivity with a harmless raw command:

```bash
.venv/bin/ansible \
  --inventory inventory.ini \
  openwrt \
  --module-name ansible.builtin.raw \
  --args 'uname -a'
```

## Run Ansible Playbooks

The two playbooks documented below create a WireGuard client configuration on
the server and then apply that configuration to a client OpenWrt instance.

`run-ansible.sh` supports the following operating-system environment variable:

| Environment variable | Default | Required | Purpose |
| --- | --- | --- | --- |
| `ANSIBLE_INVENTORY` | `inventory.ini` in the project root | No | Selects the Ansible inventory. The `--inventory` command-line option takes precedence. |

For example, select the inventory through the environment:

```bash
ANSIBLE_INVENTORY=inventory.ini \
  ./run-ansible.sh playbooks/create-wireguard-client.yml
```

The `-e` options in the following examples are Ansible extra variables, not
Bash environment variables. Extra variables passed on the command line
override the defaults defined in a playbook.

### Configure the ZeroTier Network

Point `inventory.ini` at the DHCP address obtained by `eth2`, then run:

```bash
./run-ansible.sh \
  --inventory inventory.ini \
  playbooks/configure-zerotier.yml \
  -e zerotier_network_id="<ZEROTIER_NETWORK_ID>" \
  -e zerotier_exit_ip="<ZEROTIER_EXIT_IP>"
```

`zerotier_network_id` and `zerotier_exit_ip` have no defaults and must be
provided for every run.

The playbook prints the ZeroTier node ID and waits up to 600 seconds for
controller authorization. It requires the selected network to report `OK`,
requires an assigned IPv4 CIDR in `zerotier-cli -j listnetworks`, and verifies
that the same IPv4 is present on the discovered `zt*` interface. If the
controller has assigned IPv4 but the interface has not applied it, the
playbook runs `/etc/init.d/zerotier restart`, waits 13 seconds, and checks the
controller and interface again. Route and firewall configuration is applied
only after all checks succeed. After the OpenWrt network reload, the playbook
verifies the interface IPv4 a second time. The restart delay can be overridden
with `zerotier_restart_delay`.

### Create a WireGuard Client Configuration

[`create-wireguard-client.yml`](playbooks/create-wireguard-client.yml) performs
the following operations on a configured OpenWrt WireGuard server:

1. Selects an unused IPv4 address from the server's WireGuard subnet.
2. Generates the client keys and creates the server-side peer.
3. Writes a client `wg-quick` configuration file on the Ansible controller.

Before running this playbook, the target OpenWrt server must have completed
`install-wireguard.yml` and `configure-wireguard-server.yml`. The inventory
must point to the WireGuard server.

A typical invocation is:

```bash
./run-ansible.sh \
  --inventory inventory.ini \
  playbooks/create-wireguard-client.yml \
  -e wg_client_name=xianzi_lu
```

When creating a client configuration on a relay image, explicitly select its
`relay` logical interface. A relay has no `lan` interface, so omitting this
option prevents the playbook from discovering the WireGuard endpoint address:

```bash
./run-ansible.sh \
  --inventory inventory.ini \
  playbooks/create-wireguard-client.yml \
  -e wg_client_name=xianzi_lu \
  -e lan_interface=relay
```

This example writes `clients/xianzi_lu.conf`. A client name cannot be created
twice; use a new `wg_client_name` when running the playbook again.

The following example customizes the generated configuration:

```bash
./run-ansible.sh \
  --inventory inventory.ini \
  playbooks/create-wireguard-client.yml \
  -e '{
    "wg_client_name": "branch_router",
    "wg_client_dns": "10.20.0.1",
    "wg_client_allowed_ips": "0.0.0.0/0",
    "wg_client_config_file": "/secure/wireguard/branch_router.conf"
  }'
```

Supported Ansible variables:

| Variable | Default | Required | Purpose |
| --- | --- | --- | --- |
| `wg_interface` | `wgserver` | No | Name of the server's WireGuard UCI interface. It must match the interface configured on the server. |
| `wg_port` | `51820` | No | Server UDP port written to the client configuration. It must match the server's listening port. |
| `wg_client_name` | `client1` | No | Client name used for the server-side peer section and default output filename. It may contain only letters, digits, underscores, and hyphens. Setting it explicitly is recommended. |
| `lan_interface` | `lan` | No | Logical OpenWrt interface from which the playbook discovers the server's WireGuard endpoint address. Set it to `relay` when the target is a relay image. |
| `wg_client_dns` | `10.20.0.1` | No | DNS server written to the client's `[Interface]` section. It cannot be empty and should be reachable through the tunnel. |
| `wg_client_allowed_ips` | `0.0.0.0/0` | No | Value written to `AllowedIPs` in the client's `[Peer]` section. The default enables an IPv4 full tunnel; override it with the required networks for split tunneling. |
| `wg_client_config_file` | `clients/<wg_client_name>.conf` | No | Output path on the Ansible controller. The default path is under the project root; an absolute path may also be supplied. |

The playbook discovers the endpoint address and allocates the client tunnel
address automatically. Neither value needs to be supplied.

### Configure a WireGuard Client Gateway

[`configure-wireguard-client.yml`](playbooks/configure-wireguard-client.yml)
reads a local `wg-quick` configuration file and configures the target OpenWrt
instance as an IPv4 full-tunnel client gateway. It configures WireGuard, DNS,
and LAN policy routing, permits LAN-to-WireGuard forwarding, and removes
LAN-to-WAN forwarding to prevent traffic leaks.

The inventory must point to the client OpenWrt instance, and that device must
have completed `install-wireguard.yml`.

Apply the configuration generated in the previous section:

```bash
./run-ansible.sh \
  --inventory inventory.ini \
  playbooks/configure-wireguard-client.yml \
  -e wg_quick_config_file=clients/xianzi_lu.conf
```

`wg_quick_config_file` is the only variable that must be supplied explicitly.
A relative path is resolved from the project root, not from the `playbooks/`
directory. Absolute paths and paths beginning with `~` are also supported.

The following example customizes the OpenWrt UCI names:

```bash
./run-ansible.sh \
  --inventory inventory-client.ini \
  playbooks/configure-wireguard-client.yml \
  -e '{
    "wg_quick_config_file": "clients/xianzi_lu.conf",
    "wg_interface": "wgclient",
    "wg_peer": "wgclient_peer",
    "wg_firewall_zone": "wireguard",
    "lan_interface": "lan",
    "lan_firewall_zone": "lan",
    "wan_firewall_zone": "wan"
  }'
```

Supported Ansible variables:

| Variable | Default | Required | Purpose |
| --- | --- | --- | --- |
| `wg_quick_config_file` | None | **Yes** | Path to the client `wg-quick` configuration file on the Ansible controller. |
| `wg_interface` | `wgclient` | No | WireGuard UCI interface name created on the client OpenWrt instance. |
| `wg_peer` | `wgclient_peer` | No | WireGuard peer UCI section name created on the client OpenWrt instance. |
| `wg_firewall_zone` | `wireguard` | No | Firewall zone name and UCI section name used for the WireGuard interface. |
| `lan_interface` | `lan` | No | Logical OpenWrt interface that receives client-device traffic and is used for policy routing. |
| `lan_firewall_zone` | `lan` | No | Name of the LAN firewall zone. |
| `wan_firewall_zone` | `wan` | No | Name of the WAN firewall zone, used when finding and removing LAN-to-WAN forwarding sections. |
| `lan_to_wg_forwarding` | `lan_to_wireguard` | No | UCI section name for LAN-to-WireGuard firewall forwarding. |
| `wg_route_table` | `51820` | No | IPv4 policy-routing table number used for LAN full-tunnel traffic. |
| `wg_lan_route` | `wgclient_lan_default` | No | UCI section name for the LAN default route. |
| `wg_lan_rule` | `wgclient_from_lan` | No | UCI section name for the LAN ingress policy-routing rule. |
| `wg_lan_rule_priority` | `30000` | No | Priority of the LAN policy-routing rule. The DNS rules use the immediately following priorities. |

The input `wg-quick` file must contain:

- `Address`, `PrivateKey`, and `DNS` in the `[Interface]` section.
- `PublicKey`, `Endpoint`, and `AllowedIPs` in the `[Peer]` section.
- `0.0.0.0/0` in `AllowedIPs`, because this playbook configures an IPv4
  full-tunnel gateway.

`MTU` and `PresharedKey` are optional. `PersistentKeepalive` defaults to `25`
when omitted. The configuration contains a private key, so restrict its file
permissions and do not commit it to version control.
