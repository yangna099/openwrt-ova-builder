#!/usr/bin/env bash
# Create or update an isolated Python virtual environment for Ansible.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --venv DIR              Virtual-environment directory (default: .venv)
  -h, --help              Show this help message

Use ./configure-inventory.sh to create or update an Inventory file.
EOF
}

venv_dir='.venv'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --venv)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a value." >&2; exit 1; }
            venv_dir="$2"
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

require_command python3

if [[ -e "$venv_dir" && ! -d "$venv_dir" ]]; then
    echo "Error: virtual-environment path is not a directory: $venv_dir" >&2
    exit 1
fi

if [[ ! -x "${venv_dir}/bin/python" ]]; then
    echo "Creating virtual environment: ${venv_dir}"
    if ! python3 -m venv "$venv_dir"; then
        echo 'Error: failed to create the virtual environment.' >&2
        echo 'On Debian/Ubuntu, install the python3-venv package first.' >&2
        exit 1
    fi
fi

venv_python="${venv_dir}/bin/python"

echo 'Installing Ansible into the virtual environment...'
"$venv_python" -m pip install --upgrade pip
"$venv_python" -m pip install --upgrade ansible

echo
"$venv_dir/bin/ansible" --version
echo
echo 'Ansible virtual environment is ready.'
echo "Activate it with: source ${venv_dir}/bin/activate"
echo 'Create an Inventory with: ./configure-inventory.sh --host <host> --key <private-key>'
