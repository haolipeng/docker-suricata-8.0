# arm64 镜像构建步骤

## 环境变量

每个新终端先执行（路径按本机修改）：

```bash
export DOCKER_SURICATA_ROOT=/home/work/docker-suricata
export DOCKER_SURICATA_8="${DOCKER_SURICATA_ROOT}/8.0"
```

| 变量 | 说明 |
|------|------|
| `DOCKER_SURICATA_ROOT` | 工程根目录 |
| `DOCKER_SURICATA_8` | 构建上下文（`docker build` 的工作目录） |

## AlmaLinux 9.7 基础镜像准备

当前 `vendor-arm64` 是 AlmaLinux `9.7` 版本线，Dockerfile 使用官方多架构 tag（`almalinux:9.7` / `almalinux/9-base:9.7`），由 `--platform` 选择架构。首次构建前可先拉取：

```bash
docker pull --platform linux/arm64 almalinux:9.7
docker pull --platform linux/arm64 almalinux/9-base:9.7
```

可用以下命令确认基础镜像架构正确：

```bash
docker run --rm --platform linux/arm64 almalinux:9.7 uname -m
```

预期输出 `aarch64`。

## 前置准备（程序员手动执行）

> **人工步骤**：以下命令由程序员在构建前自行执行；Agent / 自动化脚本不得代跑（源码路径与清理时机由人决定）。

每次拷贝最新源码前，先在 Suricata 源码目录清理上次构建产物：

```bash
make clean
make distclean
```

然后再执行（将 `/path/to/suricata-src` 换成实际源码路径）：

```bash
cd "${DOCKER_SURICATA_8}"

mkdir -p local-src
rm -rf local-src/suricata-master
cp -a /path/to/suricata-src local-src/suricata-master
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

### 2. 构建镜像（RPM 依赖离线；Cargo crates 未 vendor 时仍可能需要外网）

注意：`OFFLINE=1` 只表示 RPM 依赖从 `vendor-arm64` 安装；如果 Suricata/Rust 构建过程中需要下载 Cargo crates，且 crates 没有 vendor 到构建上下文，构建阶段仍可能访问外网。

离线 RPM 仓库必须与基础镜像的 AlmaLinux 小版本一致。当前 `vendor-arm64` 是 AlmaLinux `9.7` 版本线，构建前请确认已按上文拉取 `almalinux:9.7` 与 `almalinux/9-base:9.7`（`--platform linux/arm64`），否则离线 `dnf` 可能因包版本漂移失败。

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh arm64

docker build \
  --network=host \
  --platform linux/arm64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t suricata:$(cat VERSION)-arm64-offline \
  .
```

## 在线构建

需要能访问外网（拉基础镜像、`dnf` 装包）。runner 阶段会 `COPY vendor/rpms/runner`（约 50MB，装包后删除），因此构建前需 `./link-vendor-for-build.sh arm64` 确保 `vendor` 存在。

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh arm64

docker build \
  --network=host \
  --platform linux/arm64 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t suricata:$(cat VERSION)-arm64 \
  .
```

## 构建后自检

```bash
cd "${DOCKER_SURICATA_8}"

IMG="suricata:$(cat VERSION)-arm64-offline"
docker run --rm "${IMG}" suricata --build-info
```
