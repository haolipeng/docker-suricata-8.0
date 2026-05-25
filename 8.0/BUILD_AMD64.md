# amd64 镜像构建步骤

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

每次执行cp -a命令拷贝最新的项目源代码之前先清除下之前生成的，先执行如下命令

```
make clean
make distclean
```



然后再执行

```bash
cd "${DOCKER_SURICATA_8}"

mkdir -p local-src
rm -rf local-src/suricata-master
cp -a "${SURICATA_SRC}" local-src/suricata-master
```

## 离线构建

分两步：**先下载依赖（只需做一次）**，再 **构建镜像**。

### 1. 下载 amd64 离线 RPM（需联网，仅首次或依赖变更时）

```bash
cd "${DOCKER_SURICATA_8}"

./download-offline-deps.sh --arch amd64 --clean
./link-vendor-for-build.sh amd64
```

完成后应有 `vendor` → `vendor-amd64`，且内含 `vendor-amd64/rpms/builder` 与 `vendor-amd64/rpms/runner`（含 `hyperscan-devel` / `hyperscan`）。

在 x86_64 宿主机上可直接下载 amd64 包，**无需** QEMU/binfmt。若在非 x86_64 机器上构建 amd64 镜像，需自行配置交叉构建环境并加上 `--platform linux/amd64`。

### 2. 构建镜像（无需外网）

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh amd64

docker build \
  --network=host \
  --progress=plain \
  --platform linux/amd64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION)-offline \
  .
```

## 在线构建

需要能访问外网（拉基础镜像、`dnf` 装包）。当前 Dockerfile 会固定复制 `vendor` 目录，因此在线构建前也需要先确保 `vendor` 指向目标架构目录。

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh amd64

docker build \
  --network=host \
  --progress=plain \
  --platform linux/amd64 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION) \
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

docker run --rm -it suricata:$(cat VERSION)-offline suricata --build-info
```

确认 Hyperscan 已启用（仅 amd64）：

```bash
docker run --rm suricata:$(cat VERSION)-offline suricata --build-info | grep -i hyperscan
```

抓包网口在启动时指定，见 [`run-suricata-docker.sh`](run-suricata-docker.sh)（需设置 `CAPTURE_IFACE`）。

arm64 步骤见 [BUILD_ARM64.md](BUILD_ARM64.md)。

## 平台混用修复（arm64 缓存被 amd64 构建误用）

同一台 x86 机器上若先编过 arm64，本机 `almalinux:9` 可能变成 **arm64**，再编 amd64 会出现平台警告或极慢。按顺序执行：

```bash
cd "${DOCKER_SURICATA_8}"

# 1. 确认并拉取 amd64 基础镜像
docker image inspect almalinux:9 --format '{{.Architecture}}'   # 若为 arm64 即需修复
docker pull --platform linux/amd64 almalinux:9
docker pull --platform linux/amd64 almalinux/9-base:latest
docker image inspect almalinux:9 --format '{{.Architecture}}'   # 应变为 amd64

# 2. 离线 RPM 须指向 amd64
./link-vendor-for-build.sh amd64

# 3. 构建（必须带 --platform；Dockerfile.amd64 的 FROM 也已固定 linux/amd64）
./link-vendor-for-build.sh amd64   # 离线时
docker build \
  --network=host \
  --progress=plain \
  --platform linux/amd64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION)-offline \
  .
```

若 `inspect` 仍为 `arm64`，删除 tag 后重拉：

```bash
docker rmi almalinux:9 almalinux/9-base:latest 2>/dev/null || true
docker pull --platform linux/amd64 almalinux:9
docker pull --platform linux/amd64 almalinux/9-base:latest
```

**以后**：amd64 始终 `--platform linux/amd64`；arm64 始终 `--platform linux/arm64`（见 [BUILD_ARM64.md](BUILD_ARM64.md)）。两套最终镜像 tag 已区分（`-arm64` / 无后缀），不会互相覆盖。

## 无 veth 内核（定制内核 / 禁用 veth 模块）

默认 `docker build` 会把中间容器挂到 `bridge` 网络，需要内核创建 veth 对。若构建报错 `failed to add the host ... <=> sandbox ... pair interfaces: operation not supported`，请在 **`docker build` 上加 `--network=host`**（上文示例已包含）。运行容器时同样应使用 `--network host`（见 [`run-suricata-docker.sh`](run-suricata-docker.sh)）。
