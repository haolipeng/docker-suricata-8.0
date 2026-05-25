#!/usr/bin/env bash
# 停止 Suricata 容器。停止前必须等待 30 秒（刷完尾部报文）；可用 WAIT_BEFORE_STOP 覆盖秒数。
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-suricata}"
WAIT_BEFORE_STOP="${WAIT_BEFORE_STOP:-30}"

# 检查WAIT_BEFORE_STOP是否为正整数，如果不是则退出
if ! [[ "${WAIT_BEFORE_STOP}" =~ ^[0-9]+$ ]] || [[ "${WAIT_BEFORE_STOP}" -lt 1 ]]; then
    echo "error: WAIT_BEFORE_STOP must be a positive integer (default: 30, got: ${WAIT_BEFORE_STOP})" >&2
    exit 1
fi

echo "Waiting ${WAIT_BEFORE_STOP}s before stopping ${CONTAINER_NAME}..."
sleep "${WAIT_BEFORE_STOP}"

# 检查suricata容器是否存在，不存在则直接退出
if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container ${CONTAINER_NAME} not found (already stopped?)"
    exit 0
fi

# 停止suricata容器
echo "Stopping ${CONTAINER_NAME}..."
docker stop "${CONTAINER_NAME}" >/dev/null
echo "Stopped ${CONTAINER_NAME}"
