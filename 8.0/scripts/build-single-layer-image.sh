#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  bash scripts/build-single-layer-image.sh
  SOURCE_IMAGE=26c006cba08a SKIP_BUILD=1 bash scripts/build-single-layer-image.sh

说明:
  - 默认先按当前目录 Dockerfile 构建 Suricata 临时镜像，再生成单层镜像。
  - 也可通过 SOURCE_IMAGE 指定已有镜像或镜像 ID，配合 SKIP_BUILD=1 直接压成单层。
  - 单层生成使用 FROM scratch + COPY --from=<source> / /，避免 docker export/import 丢失 VOLUME 目录内容。

环境变量:
  TARGETARCH          目标架构，默认 arm64，可选 arm64/amd64
  VERSION             Suricata 版本，默认读取项目根目录的 VERSION
  IMAGE_NAME          镜像名，默认 suricata
  IMAGE_TAG           输出 tag，默认 ${VERSION}-${TARGETARCH}-single-layer
  OUTPUT_IMAGE        输出镜像完整引用，默认 ${IMAGE_NAME}:${IMAGE_TAG}
  SOURCE_IMAGE        已有源镜像或镜像 ID；设置 SKIP_BUILD=1 时必填
  TMP_IMAGE           构建出的临时镜像名，默认 ${IMAGE_NAME}:tmp-${VERSION}-${TARGETARCH}
  DOCKERFILE          Dockerfile 路径，默认 Dockerfile.${TARGETARCH}
  OFFLINE             传给 Dockerfile 的 OFFLINE build arg，默认 1
  CORES               编译并发，默认 nproc
  BUILD_NETWORK_MODE  docker build 网络模式，默认 host
  SKIP_BUILD          设为 1 时跳过构建，直接使用 SOURCE_IMAGE
  SKIP_PUSH           设为 1 时跳过 push，默认 1
  KEEP_TMP_IMAGES     设为 1 时保留中间镜像，默认 0

示例:
  # 在 10.107.12.8 上用已有镜像 ID 验证：
  SOURCE_IMAGE=26c006cba08a \
  SKIP_BUILD=1 \
  OUTPUT_IMAGE=suricata:8.0.4-arm64-single-layer \
  bash scripts/build-single-layer-image.sh

  # 从当前 Dockerfile 离线构建并生成单层镜像：
  TARGETARCH=arm64 OFFLINE=1 bash scripts/build-single-layer-image.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "请直接执行脚本，不要 source: bash scripts/build-single-layer-image.sh" >&2
  return 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1" >&2
    exit 1
  fi
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

need_cmd docker
need_cmd awk
need_cmd mktemp
need_cmd nproc

TARGETARCH="${TARGETARCH:-arm64}"
VERSION="${VERSION:-$(cat VERSION)}"
IMAGE_NAME="${IMAGE_NAME:-suricata}"
IMAGE_TAG="${IMAGE_TAG:-${VERSION}-${TARGETARCH}-single-layer}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${IMAGE_NAME}:${IMAGE_TAG}}"
SOURCE_IMAGE="${SOURCE_IMAGE:-}"
TMP_IMAGE="${TMP_IMAGE:-${IMAGE_NAME}:tmp-${VERSION}-${TARGETARCH}}"
DOCKERFILE="${DOCKERFILE:-Dockerfile.${TARGETARCH}}"
OFFLINE="${OFFLINE:-1}"
CORES="${CORES:-$(nproc)}"
BUILD_NETWORK_MODE="${BUILD_NETWORK_MODE:-host}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_PUSH="${SKIP_PUSH:-1}"
KEEP_TMP_IMAGES="${KEEP_TMP_IMAGES:-0}"
PLATFORM="linux/${TARGETARCH}"

case "${TARGETARCH}" in
  arm64 | amd64) ;;
  *)
    echo "不支持的 TARGETARCH: ${TARGETARCH}，可选 arm64/amd64" >&2
    exit 1
    ;;
esac

if [[ "${SKIP_BUILD}" == "1" && -z "${SOURCE_IMAGE}" ]]; then
  echo "SKIP_BUILD=1 时必须设置 SOURCE_IMAGE，例如 SOURCE_IMAGE=26c006cba08a" >&2
  exit 1
fi

if [[ "${SKIP_BUILD}" != "1" && ! -f "${DOCKERFILE}" ]]; then
  echo "找不到 Dockerfile: ${DOCKERFILE}" >&2
  exit 1
fi

FLATTEN_SOURCE_TAG="${IMAGE_NAME}:flatten-source-${VERSION}-${TARGETARCH}-$$"
FLATTEN_DOCKERFILE=""

cleanup() {
  if [[ -n "${FLATTEN_DOCKERFILE}" && -f "${FLATTEN_DOCKERFILE}" ]]; then
    rm -f "${FLATTEN_DOCKERFILE}"
  fi
  if [[ "${KEEP_TMP_IMAGES}" == "1" ]]; then
    return
  fi
  docker image rm -f "${FLATTEN_SOURCE_TAG}" >/dev/null 2>&1 || true
  if [[ "${SKIP_BUILD}" != "1" ]]; then
    docker image rm -f "${TMP_IMAGE}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

build_source_image() {
  log "构建 Suricata 临时镜像: ${TMP_IMAGE}"
  docker build \
    --network="${BUILD_NETWORK_MODE}" \
    --platform="${PLATFORM}" \
    --build-arg "OFFLINE=${OFFLINE}" \
    --build-arg "VERSION=${VERSION}" \
    --build-arg "CORES=${CORES}" \
    -f "${DOCKERFILE}" \
    -t "${TMP_IMAGE}" \
    .
}

write_flatten_dockerfile() {
  FLATTEN_DOCKERFILE="$(mktemp "${TMPDIR:-/tmp}/suricata-single-layer.XXXXXX.Dockerfile")"
  cat >"${FLATTEN_DOCKERFILE}" <<'EOF'
ARG SOURCE_REF=almalinux:9.7
FROM ${SOURCE_REF} AS source
FROM scratch
COPY --from=source / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VOLUME ["/var/log/suricata", "/var/lib/suricata", "/var/run/suricata", "/etc/suricata"]
ENTRYPOINT ["/docker-entrypoint.sh"]
EOF
}

flatten_image() {
  local source_ref="$1"

  docker image inspect "${source_ref}" >/dev/null

  # Dockerfile COPY --from 对裸 image id 支持不稳定，统一打一个临时 tag。
  docker tag "${source_ref}" "${FLATTEN_SOURCE_TAG}"
  write_flatten_dockerfile

  log "生成单层镜像: ${source_ref} -> ${OUTPUT_IMAGE}"
  docker build \
    --platform="${PLATFORM}" \
    --build-arg "SOURCE_REF=${FLATTEN_SOURCE_TAG}" \
    -f "${FLATTEN_DOCKERFILE}" \
    -t "${OUTPUT_IMAGE}" \
    "${ROOT_DIR}"
}

verify_platform() {
  local image_ref="$1"
  local arch
  arch="$(docker image inspect "${image_ref}" --format '{{.Architecture}}')"
  if [[ "${arch}" != "${TARGETARCH}" ]]; then
    echo "镜像架构不匹配: ${image_ref} -> ${arch}, 期望 ${TARGETARCH}" >&2
    exit 1
  fi
}

verify_single_layer() {
  local image_ref="$1"
  local layers
  layers="$(docker image inspect "${image_ref}" --format '{{len .RootFS.Layers}}')"
  if [[ "${layers}" != "1" ]]; then
    echo "镜像不是单层: ${image_ref}, layers=${layers}" >&2
    docker history "${image_ref}" --no-trunc
    exit 1
  fi
}

verify_runtime_metadata() {
  local image_ref="$1"
  local entrypoint
  entrypoint="$(docker image inspect "${image_ref}" --format '{{json .Config.Entrypoint}}')"
  if [[ "${entrypoint}" != '["/docker-entrypoint.sh"]' ]]; then
    echo "ENTRYPOINT 不符合预期: ${entrypoint}" >&2
    exit 1
  fi
}

log "构建参数:"
log "  PLATFORM=${PLATFORM}"
log "  VERSION=${VERSION}"
log "  DOCKERFILE=${DOCKERFILE}"
log "  OFFLINE=${OFFLINE}"
log "  CORES=${CORES}"
log "  SKIP_BUILD=${SKIP_BUILD}"
log "  SOURCE_IMAGE=${SOURCE_IMAGE:-<build ${TMP_IMAGE}>}"
log "  OUTPUT_IMAGE=${OUTPUT_IMAGE}"

if [[ "${SKIP_BUILD}" == "1" ]]; then
  flatten_image "${SOURCE_IMAGE}"
else
  build_source_image
  flatten_image "${TMP_IMAGE}"
fi

verify_platform "${OUTPUT_IMAGE}"
verify_single_layer "${OUTPUT_IMAGE}"
verify_runtime_metadata "${OUTPUT_IMAGE}"

if [[ "${SKIP_PUSH}" != "1" ]]; then
  log "推送镜像: ${OUTPUT_IMAGE}"
  docker push "${OUTPUT_IMAGE}"
else
  log "按要求跳过 push"
fi

log "完成: ${OUTPUT_IMAGE}"
