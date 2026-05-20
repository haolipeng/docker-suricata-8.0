#!/usr/bin/env bash
# 在目标机上运行 Suricata 容器，抓包网卡默认 eth1。
set -euo pipefail

SURICATA_IMAGE="${SURICATA_IMAGE:-suricata:8.0.4-arm64-offline}"
CAPTURE_IFACE="${CAPTURE_IFACE:-eth1}"
CONTAINER_NAME="${CONTAINER_NAME:-suricata}"

if ! docker image inspect "${SURICATA_IMAGE}" >/dev/null 2>&1; then
    echo "error: image not found: ${SURICATA_IMAGE}" >&2
    echo "Set SURICATA_IMAGE to your imported tag, e.g. suricata:8.0-arm64" >&2
    docker images suricata 2>/dev/null || true
    exit 1
fi

if ! ip link show "${CAPTURE_IFACE}" >/dev/null 2>&1; then
    echo "warning: interface ${CAPTURE_IFACE} not found on host" >&2
    ip -br link
fi

docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add SYS_NICE \
    --entrypoint /bin/bash \
    "${SURICATA_IMAGE}" \
    -lc "
set -e
for f in /etc/suricata.dist/suricata.yaml /etc/suricata/suricata.yaml; do
    if [ -f \"\$f\" ]; then
        sed -i 's/interface: eth0/interface: ${CAPTURE_IFACE}/g' \"\$f\"
    fi
done
exec /docker-entrypoint.sh -c /etc/suricata/suricata.yaml
"

echo "Started ${CONTAINER_NAME} (image=${SURICATA_IMAGE}, iface=${CAPTURE_IFACE})"
sleep 2
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
