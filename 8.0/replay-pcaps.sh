#!/usr/bin/env bash
# CAPTURE_IFACE=eth1 ./replay-pcaps.sh  （可选 PCAP_DIR MBPS，默认 100）
set -euo pipefail

PCAP_DIR="${PCAP_DIR:-/home/work/pcaps_dataset}"
CAPTURE_IFACE="${CAPTURE_IFACE:-}"
MBPS="${MBPS:-100}"

check_env() {
    [[ -n "${CAPTURE_IFACE}" ]] || { echo "error: CAPTURE_IFACE required" >&2; exit 1; }
    command -v tcpreplay >/dev/null || { echo "error: tcpreplay not found" >&2; exit 1; }
    [[ -d "${PCAP_DIR}" ]] || { echo "error: ${PCAP_DIR} not found" >&2; exit 1; }
    ip link show "${CAPTURE_IFACE}" >/dev/null 2>&1 || { echo "error: ${CAPTURE_IFACE} not found" >&2; exit 1; }
}

check_env

mapfile -t pcaps < <(
    find "${PCAP_DIR}" \( -path '*/.git/*' -o -path '*/.git' \) -prune -o \
        \( -iname '*.pcap' -o -iname '*.pcapng' \) -type f -print | sort
)

echo "replay ${#pcaps[@]} pcaps -> ${CAPTURE_IFACE} (mbps=${MBPS})"
failed=0
for f in "${pcaps[@]}"; do
    echo "=== ${f} ==="
    tcpreplay --intf1="${CAPTURE_IFACE}" --mbps="${MBPS}" "${f}" || ((failed++)) || true
done

echo "done failed=${failed}"
exit "${failed}"
