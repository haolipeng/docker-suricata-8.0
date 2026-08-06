#!/usr/bin/env bash
# 启动 Suricata 容器。CAPTURE_IFACES 必填，可指定一个或多个网口。
set -euo pipefail

# 可通过环境变量覆盖镜像名和容器名；抓包网卡必须显式指定，避免误抓默认网卡。
# CAPTURE_IFACES 支持一个网口、空格分隔的多个网口，或逗号分隔的多个网口。
SURICATA_IMAGE="${SURICATA_IMAGE:-suricata:8.0.4-arm64-offline}"
CAPTURE_IFACES="${CAPTURE_IFACES:-}"
CONTAINER_NAME="${CONTAINER_NAME:-suricata}"

# 启动前先做本地检查，尽早暴露镜像缺失或网卡名错误。
[[ -n "${CAPTURE_IFACES}" ]] || { echo "error: CAPTURE_IFACES required (e.g. CAPTURE_IFACES=eth1 or CAPTURE_IFACES='eth1 eth2')" >&2; exit 1; }
docker image inspect "${SURICATA_IMAGE}" >/dev/null 2>&1 || { echo "error: image not found: ${SURICATA_IMAGE}" >&2; exit 1; }

CAPTURE_IFACES_NORMALIZED="${CAPTURE_IFACES//,/ }"
read -r -a CAPTURE_IFACES_LIST <<< "${CAPTURE_IFACES_NORMALIZED}"
SURICATA_IFACE_ARGS=()
for iface in "${CAPTURE_IFACES_LIST[@]}"; do
    [[ -n "${iface}" ]] || continue
    ip link show "${iface}" >/dev/null 2>&1 || { echo "error: interface not found: ${iface}" >&2; exit 1; }
    SURICATA_IFACE_ARGS+=(-i "${iface}")
done
[[ "${#SURICATA_IFACE_ARGS[@]}" -gt 0 ]] || { echo "error: no valid capture interfaces specified" >&2; exit 1; }

# 固定使用宿主机目录持久化 Suricata 的日志、规则/状态、运行时文件和配置。
# 配置默认以宿主机 /etc/suricata-docker 为准：改 suricata.yaml 后 docker restart 即生效。
# 若要用镜像内默认 suricata.yaml 覆盖宿主机文件，启动前 export SURICATA_USE_IMAGE_YAML=yes
SURICATA_USE_IMAGE_YAML="${SURICATA_USE_IMAGE_YAML:-no}"
mkdir -p /var/log/suricata-docker /var/lib/suricata-docker /var/run/suricata-docker /etc/suricata-docker

# 容器 date / EVE timestamp 与宿主机一致：挂载宿主机时区，并传入 TZ（若可读）。
EXTRA_DOCKER_OPTS=()
if [[ -e /etc/localtime ]]; then
    EXTRA_DOCKER_OPTS+=(-v /etc/localtime:/etc/localtime:ro)
fi
TZ_VALUE="${TZ:-}"
if [[ -z "${TZ_VALUE}" && -r /etc/timezone ]]; then
    TZ_VALUE=$(tr -d '[:space:]' < /etc/timezone)
fi
if [[ -z "${TZ_VALUE}" && -L /etc/localtime ]]; then
    TZ_VALUE=$(readlink -f /etc/localtime)
    TZ_VALUE="${TZ_VALUE#*/usr/share/zoneinfo/}"
fi
if [[ -n "${TZ_VALUE}" ]]; then
    EXTRA_DOCKER_OPTS+=(-e "TZ=${TZ_VALUE}")
fi

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
    ${EXTRA_DOCKER_OPTS[@]+"${EXTRA_DOCKER_OPTS[@]}"} \
    -v /var/log/suricata-docker:/var/log/suricata \
    -v /var/lib/suricata-docker:/var/lib/suricata \
    -v /var/run/suricata-docker:/var/run/suricata \
    -v /etc/suricata-docker:/etc/suricata \
    -e ENABLE_CRON=yes \
    -e "SURICATA_USE_IMAGE_YAML=${SURICATA_USE_IMAGE_YAML}" \
    "${SURICATA_IMAGE}" \
    "${SURICATA_IFACE_ARGS[@]}" \
    -c /etc/suricata/suricata.yaml

echo "Started ${CONTAINER_NAME} (ifaces=${CAPTURE_IFACES_LIST[*]})"
sleep 2
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
