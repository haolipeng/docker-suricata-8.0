# arm64 镜像构建步骤

## 环境变量

每个新终端先执行（路径按本机修改）：

```bash
export DOCKER_SURICATA_ROOT=/home/work/docker-suricata
export DOCKER_SURICATA_8="${DOCKER_SURICATA_ROOT}/8.0"
export SURICATA_SRC=/home/work/iot-sentinel
```

| 变量 | 说明 |
|------|------|
| `DOCKER_SURICATA_ROOT` | 工程根目录 |
| `DOCKER_SURICATA_8` | 构建上下文（`docker build` 的工作目录） |
| `SURICATA_SRC` | Suricata 源码目录 |

## 前置准备（在线、离线都需要）

```bash
cd "${DOCKER_SURICATA_8}"

mkdir -p local-src
rm -rf local-src/suricata-master
cp -a "${SURICATA_SRC}" local-src/suricata-master
```

## 离线构建

分两步：**先下载依赖（只需做一次）**，再 **构建镜像**。

### 1. 下载 arm64 离线 RPM（需联网，仅首次或依赖变更时）

```bash
cd "${DOCKER_SURICATA_8}"

./download-offline-deps.sh --arch arm64 --clean
./link-vendor-for-build.sh arm64
```

完成后应有 `vendor` → `vendor-arm64`，且内含 `vendor-arm64/rpms/builder` 与 `vendor-arm64/rpms/runner`。

在 x86 机器上下载 arm64 包时，需已启用 QEMU：

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

### 2. 构建镜像（无需外网）

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh arm64

docker build \
  --network=host \
  --progress=plain \
  --platform linux/arm64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t suricata:$(cat VERSION)-arm64-offline \
  .
```

## 在线构建

需要能访问外网（拉基础镜像、`dnf` 装包）。

```bash
cd "${DOCKER_SURICATA_8}"

docker build \
  --network=host \
  --progress=plain \
  --platform linux/arm64 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t suricata:$(cat VERSION)-arm64 \
  .
```

需要代理时追加（可先 `export HTTP_PROXY=... HTTPS_PROXY=...`）：

```bash
  --build-arg HTTP_PROXY="${HTTP_PROXY}" \
  --build-arg HTTPS_PROXY="${HTTPS_PROXY}" \
  --build-arg NO_PROXY="${NO_PROXY:-localhost,127.0.0.1}" \
```

## 运行镜像（示例）

```bash
cd "${DOCKER_SURICATA_8}"

docker run --rm -it suricata:$(cat VERSION)-arm64-offline suricata --build-info
```

更完整的说明见 [BUILD_FLOW.md](BUILD_FLOW.md).

## 无 veth 内核（定制内核 / 禁用 veth 模块）

默认 `docker build` 会把中间容器挂到 `bridge` 网络，需要内核创建 veth 对。若构建报错 `failed to add the host ... <=> sandbox ... pair interfaces: operation not supported`，请在 **`docker build` 上加 `--network=host`**（上文示例已包含）。运行容器时同样应使用 `--network host`（见 [`run-suricata-docker.sh`](run-suricata-docker.sh)）。
