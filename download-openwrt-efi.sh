#!/usr/bin/env bash
# Download and unpack the OpenWrt 25.12.5 x86-64 EFI disk image.

set -euo pipefail

readonly VERSION='25.12.5'
readonly TARGET='x86-64'
readonly TARGET_PATH='x86/64'
readonly IMAGE="openwrt-${VERSION}-${TARGET}-generic-ext4-combined-efi.img"
readonly ARCHIVE="${IMAGE}.gz"
readonly BASE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET_PATH}"

# Use the first argument as the output directory, or the current directory.
output_dir="${1:-$PWD}"
mkdir -p "$output_dir"

archive_path="${output_dir}/${ARCHIVE}"
image_path="${output_dir}/${IMAGE}"

download() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --output-document="$destination" "$url"
    else
        echo 'Error: install curl or wget first.' >&2
        exit 1
    fi
}

if [[ -e "$image_path" ]]; then
    echo "Replacing existing image: $image_path"
fi
echo "Downloading ${ARCHIVE}..."
download "${BASE_URL}/${ARCHIVE}" "$archive_path"

checksum_file="$(mktemp)"
trap 'rm -f "$checksum_file"' EXIT
echo 'Verifying SHA-256 checksum...'
download "${BASE_URL}/sha256sums" "$checksum_file"

expected_line="$(awk -v file="$ARCHIVE" '$2 == file || $2 == "*" file { print; exit }' "$checksum_file")"
if [[ -z "$expected_line" ]]; then
    echo "Error: ${ARCHIVE} was not found in the official sha256sums file." >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$output_dir" && printf '%s\n' "$expected_line" | sha256sum --check --status -)
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    expected="$(awk '{print $1}' <<<"$expected_line")"
    [[ "$actual" == "$expected" ]]
else
    echo 'Error: install sha256sum or shasum first.' >&2
    exit 1
fi

echo "Extracting ${ARCHIVE}..."
gzip --force --decompress --keep "$archive_path"
echo "Ready: $image_path"
