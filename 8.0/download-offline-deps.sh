#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ARCH="amd64"
OUTPUT_DIR=""
DOCKER_BIN="${DOCKER:-docker}"
CLEAN="no"

usage() {
    cat <<'EOF'
Usage:
  ./download-offline-deps.sh [options]

Options:
  --arch <amd64|arm64>       Target architecture. Default: amd64
  --output-dir <path>        Output directory. Default: ./vendor-<arch>
  --docker <path>            Docker CLI binary. Default: $DOCKER or docker
  --clean                    Remove existing output before download
  -h, --help                 Show this help

Examples:
  ./download-offline-deps.sh --arch amd64 --clean
  ./download-offline-deps.sh --arch arm64 --clean
  ./link-vendor-for-build.sh amd64   # before offline docker build
EOF
}

normalize_vendor_tree() {
    local root="$1"
    local tmp=""

    echo "Normalizing downloaded files under: ${root}"

    while IFS= read -r -d '' file; do
        tmp="${file}.codex-tmp"
        cp --preserve=mode,timestamps "${file}" "${tmp}"
        mv -f "${tmp}" "${file}"
    done < <(find "${root}" -type f -print0)
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --docker)
            DOCKER_BIN="$2"
            shift 2
            ;;
        --clean)
            CLEAN="yes"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${SCRIPT_DIR}/vendor-${ARCH}"
fi

case "${ARCH}" in
    amd64)
        PLATFORM="linux/amd64"
        BUILDER_PACKAGES=(
            autoconf
            automake
            cargo
            cbindgen
            diffutils
            patch
            elfutils-libelf-devel
            file
            file-devel
            gcc
            gcc-c++
            git
            jansson-devel
            jq
            libtool
            libyaml-devel
            libnet-devel
            libcap-ng-devel
            libevent-devel
            libpcap-devel
            libprelude-devel
            lz4-devel
            make
            pcre2-devel
            pkgconfig
            python3-devel
            python3-yaml
            rust
            which
            zlib-devel
            hyperscan-devel
            ca-certificates
        )
        RUNNER_PACKAGES=(
            cronie
            elfutils-libelf
            file
            findutils
            iproute
            jansson
            libyaml
            libnet
            libcap-ng
            libevent
            libpcap
            libprelude
            logrotate
            lz4
            net-tools
            pcre2
            procps-ng
            python3
            python3-yaml
            tcpdump
            which
            zlib
            hyperscan
        )
        ;;
    arm64)
        PLATFORM="linux/arm64"
        BUILDER_PACKAGES=(
            autoconf
            automake
            cargo
            cbindgen
            diffutils
            patch
            elfutils-libelf-devel
            file
            file-devel
            gcc
            gcc-c++
            git
            jansson-devel
            jq
            libtool
            libyaml-devel
            libnet-devel
            libcap-ng-devel
            libevent-devel
            libpcap-devel
            libprelude-devel
            lz4-devel
            make
            pcre2-devel
            pkgconfig
            python3-devel
            python3-yaml
            rust
            which
            zlib-devel
            ca-certificates
        )
        RUNNER_PACKAGES=(
            cronie
            elfutils-libelf
            file
            findutils
            iproute
            jansson
            libyaml
            libnet
            libcap-ng
            libevent
            libpcap
            libprelude
            logrotate
            lz4
            net-tools
            pcre2
            procps-ng
            python3
            python3-yaml
            tcpdump
            which
            zlib
        )
        ;;
    *)
        echo "error: unsupported arch: ${ARCH}" >&2
        exit 1
        ;;
esac

if [[ "${CLEAN}" = "yes" ]]; then
    rm -rf "${OUTPUT_DIR}"
fi

mkdir -p "${OUTPUT_DIR}/rpms/builder" "${OUTPUT_DIR}/rpms/runner"

HOST_ARCH=$(uname -m)
if [[ "${ARCH}" = "arm64" && "${HOST_ARCH}" != "aarch64" && "${HOST_ARCH}" != "arm64" ]]; then
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        cat >&2 <<'EOF'
error: arm64 containers require QEMU/binfmt emulation on this host.
       Register qemu-aarch64 first, then rerun the script.
       Example:
         docker run --privileged --rm tonistiigi/binfmt --install arm64
EOF
        exit 1
    fi
fi

docker_env_args=()
for var_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [[ -n "${!var_name-}" ]]; then
        docker_env_args+=("-e" "${var_name}=${!var_name}")
    fi
done

builder_packages=$(printf '%s\n' "${BUILDER_PACKAGES[@]}")
runner_packages=$(printf '%s\n' "${RUNNER_PACKAGES[@]}")

echo "Preparing offline RPM assets:"
echo "  arch: ${ARCH}"
echo "  platform: ${PLATFORM}"
echo "  output: ${OUTPUT_DIR}"

"${DOCKER_BIN}" run --rm -i \
    --platform "${PLATFORM}" \
    -v "${OUTPUT_DIR}:/vendor" \
    "${docker_env_args[@]}" \
    almalinux:9 \
    bash -s <<EOF
set -euo pipefail

mkdir -p /vendor/rpms/builder /vendor/rpms/runner

echo "[1/3] Updating container and installing download tools..."
dnf -y update
dnf -y install epel-release dnf-plugins-core 'dnf-command(download)' createrepo_c
dnf config-manager --set-enabled crb

mapfile -t BUILDER_PACKAGES <<'PKGS'
${builder_packages}
PKGS

mapfile -t RUNNER_PACKAGES <<'PKGS'
${runner_packages}
PKGS

cd /vendor/rpms/builder
echo "[2/3] Downloading builder RPMs into /vendor/rpms/builder..."
rm -f ./*.rpm
dnf download --resolve --alldeps "\${BUILDER_PACKAGES[@]}"
createrepo_c .
echo "[2/3] Builder RPMs ready."

cd /vendor/rpms/runner
echo "[3/3] Downloading runner RPMs into /vendor/rpms/runner..."
rm -f ./*.rpm
dnf download --resolve --alldeps "\${RUNNER_PACKAGES[@]}"
createrepo_c .
echo "[3/3] Runner RPMs ready."

echo "[done] Offline RPM assets have been downloaded into /vendor."
EOF

normalize_vendor_tree "${OUTPUT_DIR}"

echo "Offline assets are ready under: ${OUTPUT_DIR}"
