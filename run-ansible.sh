#!/usr/bin/env bash
# Run a project playbook with the Ansible installation in .venv.

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_playbook="${project_dir}/.venv/bin/ansible-playbook"
inventory="${ANSIBLE_INVENTORY:-${project_dir}/inventory.ini}"
ansible_local_tmp="${project_dir}/.ansible/tmp"

usage() {
    cat <<EOF
Usage: $0 [--inventory FILE] <playbook.yml> [ansible-playbook options]

Options:
  --inventory FILE      Inventory file to use (default: ANSIBLE_INVENTORY or inventory.ini)
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inventory)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
            inventory="$2"
            shift 2
            ;;
        --inventory=*)
            inventory="${1#*=}"
            [[ -n "$inventory" ]] || { echo 'Error: --inventory requires a value.' >&2; exit 1; }
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

if [[ ! -x "$ansible_playbook" ]]; then
    echo "Error: Ansible virtual environment not found: ${ansible_playbook}" >&2
    echo "Run ./configure-ansible.sh first." >&2
    exit 1
fi
if [[ ! -f "$inventory" ]]; then
    echo "Error: inventory file does not exist: ${inventory}" >&2
    exit 1
fi

mkdir -p "$ansible_local_tmp"
export ANSIBLE_LOCAL_TEMP="$ansible_local_tmp"
export ANSIBLE_REMOTE_TEMP="/tmp/.ansible"

exec "$ansible_playbook" -i "$inventory" "$@"
