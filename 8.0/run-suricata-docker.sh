#!/usr/bin/env bash
# 启动 Suricata 容器。CAPTURE_IFACE 必填。
set -euo pipefail

# 可通过环境变量覆盖镜像名和容器名；抓包网卡必须显式指定，避免误抓默认网卡。
SURICATA_IMAGE="${SURICATA_IMAGE:-suricata:8.0.4-offline}"
CAPTURE_IFACE="${CAPTURE_IFACE:-}"
CONTAINER_NAME="${CONTAINER_NAME:-suricata}"

# 启动前先做本地检查，尽早暴露镜像缺失或网卡名错误。
[[ -n "${CAPTURE_IFACE}" ]] || { echo "error: CAPTURE_IFACE required (e.g. CAPTURE_IFACE=eth1)" >&2; exit 1; }
docker image inspect "${SURICATA_IMAGE}" >/dev/null 2>&1 || { echo "error: image not found: ${SURICATA_IMAGE}" >&2; exit 1; }
ip link show "${CAPTURE_IFACE}" >/dev/null 2>&1 || { echo "error: interface not found: ${CAPTURE_IFACE}" >&2; exit 1; }

# 固定使用宿主机目录持久化 Suricata 的日志、规则/状态、运行时文件和配置。
mkdir -p /var/log/suricata-docker /var/lib/suricata-docker /var/run/suricata-docker /etc/suricata-docker

# 若同名容器已存在，先清理旧容器，保证脚本重复执行结果一致。
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# 使用宿主机网络命名空间；NET_RAW/NET_ADMIN 用于抓包，SYS_NICE 用于调度优化。
# Suricata 参数直接传给 entrypoint，避免通过环境变量拼接命令行。
docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SYS_NICE \
    -v /var/log/suricata-docker:/var/log/suricata \
    -v /var/lib/suricata-docker:/var/lib/suricata \
    -v /var/run/suricata-docker:/var/run/suricata \
    -v /etc/suricata-docker:/etc/suricata \
    "${SURICATA_IMAGE}" \
    -i "${CAPTURE_IFACE}" \
    -c /etc/suricata/suricata.yaml

echo "Started ${CONTAINER_NAME} (iface=${CAPTURE_IFACE})"
sleep 2
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
