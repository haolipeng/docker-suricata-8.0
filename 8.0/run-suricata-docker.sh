#!/usr/bin/env bash
# 启动 Suricata 容器。CAPTURE_IFACE 必填。数据目录见 SURICATA_DATA_ROOT（默认 /opt/suricata-docker）。
set -euo pipefail

SURICATA_IMAGE="${SURICATA_IMAGE:-suricata:8.0.4-arm64-offline}"
CAPTURE_IFACE="${CAPTURE_IFACE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-suricata}"
SURICATA_DATA_ROOT="${SURICATA_DATA_ROOT:-/opt/suricata-docker}"

[[ -n "${CAPTURE_IFACE}" ]] || { echo "error: CAPTURE_IFACE required (e.g. CAPTURE_IFACE=eth1)" >&2; exit 1; }
docker image inspect "${SURICATA_IMAGE}" >/dev/null 2>&1 || { echo "error: image not found: ${SURICATA_IMAGE}" >&2; exit 1; }
ip link show "${CAPTURE_IFACE}" >/dev/null 2>&1 || { echo "error: interface not found: ${CAPTURE_IFACE}" >&2; exit 1; }

mkdir -p "${SURICATA_DATA_ROOT}"/{log,lib,run,etc}
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add SYS_NICE \
    -v "${SURICATA_DATA_ROOT}/log:/var/log/suricata" \
    -v "${SURICATA_DATA_ROOT}/lib:/var/lib/suricata" \
    -v "${SURICATA_DATA_ROOT}/run:/var/run/suricata" \
    -v "${SURICATA_DATA_ROOT}/etc:/etc/suricata" \
    "${SURICATA_IMAGE}" \
    -i "${CAPTURE_IFACE}" \
    -c /etc/suricata/suricata.yaml

echo "Started ${CONTAINER_NAME} (iface=${CAPTURE_IFACE}, data=${SURICATA_DATA_ROOT})"
sleep 2
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
