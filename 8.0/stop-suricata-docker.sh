#!/usr/bin/env bash
# 停止 Suricata 容器。可选 WAIT_BEFORE_STOP 在停止前等待（秒），便于刷完尾部报文。
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-suricata}"
WAIT_BEFORE_STOP="${WAIT_BEFORE_STOP:-0}"

if ! [[ "${WAIT_BEFORE_STOP}" =~ ^[0-9]+$ ]]; then
    echo "error: WAIT_BEFORE_STOP must be a non-negative integer (got: ${WAIT_BEFORE_STOP})" >&2
    exit 1
fi

if [[ "${WAIT_BEFORE_STOP}" -gt 0 ]]; then
    echo "Waiting ${WAIT_BEFORE_STOP}s before stopping ${CONTAINER_NAME}..."
    sleep "${WAIT_BEFORE_STOP}"
fi

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Container ${CONTAINER_NAME} not found (already stopped?)"
    exit 0
fi

echo "Stopping ${CONTAINER_NAME}..."
docker stop "${CONTAINER_NAME}" >/dev/null
echo "Stopped ${CONTAINER_NAME}"
