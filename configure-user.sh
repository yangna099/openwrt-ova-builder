#!/usr/bin/env bash
# Configure OpenWrt's root (LuCI) account in a QCOW2 or raw disk image.

set -euo pipefail

# libguestfs needs writable runtime paths in some WSL environments.
export TMPDIR="${TMPDIR:-/tmp}"
export XDG_RUNTIME_DIR="$TMPDIR"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <openwrt-image> <private-key-output-path-or-directory>" >&2
    exit 1
fi

image="$1"
key_target="$2"
if [[ -d "$key_target" ]]; then
    private_key="${key_target}/openwrt_ed25519"
else
    private_key="$key_target"
fi
public_key="${private_key}.pub"
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

for command in guestfish ssh-keygen openssl awk tr; do
    require_command "$command"
done

if [[ ! -f "$image" ]]; then
    echo "Error: image does not exist: $image" >&2
    exit 1
fi
key_dir="$(dirname "$private_key")"
if [[ ! -d "$key_dir" ]]; then
    echo "Error: key output directory does not exist: $key_dir" >&2
    exit 1
fi

if [[ -e "$private_key" || -e "$public_key" ]]; then
    if [[ -d "$private_key" || -d "$public_key" ]]; then
        echo "Error: SSH key target is a directory: $private_key" >&2
        exit 1
    fi
    echo "Replacing existing SSH key pair: $private_key"
    rm -f -- "$private_key" "$public_key"
fi

echo 'Generating an Ed25519 SSH key pair...'
ssh-keygen -q -t ed25519 -N '' -f "$private_key" -C 'openwrt-root'

# LuCI authenticates against OpenWrt's root account.  Generate a printable
# 16-character password with uppercase, lowercase, numeric, and symbol sets.
while :; do
    candidate="$(openssl rand -base64 48 | tr -d '\n')"
    password="${candidate:0:16}"
    if [[ "$password" =~ [[:upper:]] && "$password" =~ [[:lower:]] \
        && "$password" =~ [[:digit:]] && "$password" =~ [+/=] ]]; then
        break
    fi
done
password_hash="$(openssl passwd -6 -stdin <<<"$password")"

work_dir="$(mktemp -d)"
shadow_file="${work_dir}/shadow"
updated_shadow_file="${work_dir}/shadow.updated"

echo 'Reading the current root password entry...'
guestfish --ro -a "$image" -i download /etc/shadow "$shadow_file"

awk -F: -v OFS=: -v password_hash="$password_hash" '
    $1 == "root" { $2 = password_hash; found = 1 }
    { print }
    END {
        if (!found) {
            print "Error: root user was not found in /etc/shadow." > "/dev/stderr"
            exit 1
        }
    }
' "$shadow_file" >"$updated_shadow_file"

echo 'Writing the LuCI/root password and SSH public key...'
guestfish --rw -a "$image" -i upload "$updated_shadow_file" /etc/shadow
guestfish --rw -a "$image" -i chmod 0600 /etc/shadow
guestfish --rw -a "$image" -i mkdir-p /etc/dropbear
guestfish --rw -a "$image" -i upload "$public_key" /etc/dropbear/authorized_keys
guestfish --rw -a "$image" -i chmod 0600 /etc/dropbear/authorized_keys
guestfish --rw -a "$image" -i sync

echo
echo 'OpenWrt image user configured successfully.'
echo "SSH private key: $private_key"
echo "SSH public key:  $public_key"
echo "LuCI username:   root"
echo "LuCI password:   $password"
