#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage:
  ./link-vendor-for-build.sh <amd64|arm64>

Creates vendor -> vendor-<arch> in the 8.0 build context so Dockerfile COPY /vendor
uses the correct architecture's offline RPM tree.

Run download-offline-deps.sh for that arch first.
EOF
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

ARCH="$1"
case "${ARCH}" in
    amd64|arm64) ;;
    *)
        echo "error: unsupported arch: ${ARCH} (use amd64 or arm64)" >&2
        exit 1
        ;;
esac

VENDOR_ARCH_DIR="${SCRIPT_DIR}/vendor-${ARCH}"
LINK_PATH="${SCRIPT_DIR}/vendor"

if [[ ! -d "${VENDOR_ARCH_DIR}/rpms/builder" ]]; then
    echo "error: missing ${VENDOR_ARCH_DIR}/rpms/builder" >&2
    echo "Run: ./download-offline-deps.sh --arch ${ARCH} --clean" >&2
    exit 1
fi

ln -sfn "vendor-${ARCH}" "${LINK_PATH}"
echo "Linked ${LINK_PATH} -> vendor-${ARCH}"
