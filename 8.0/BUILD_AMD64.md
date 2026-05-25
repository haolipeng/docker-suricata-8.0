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

### 2. 构建镜像（无需外网）

```bash
cd "${DOCKER_SURICATA_8}"

./link-vendor-for-build.sh amd64

docker build \
  --network=host \
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

### 构建后自检

```bash
cd "${DOCKER_SURICATA_8}"

IMG="suricata:$(cat VERSION)-offline"
docker run --rm "${IMG}" suricata --build-info
docker run --rm "${IMG}" suricata --build-info | grep -i hyperscan   # amd64 应能看到 Hyperscan
```

### 启动抓包服务

正式运行请用 [`run-suricata-docker.sh`](run-suricata-docker.sh)（`--network host`、`NET_RAW`/`NET_ADMIN`、日志与配置目录挂载等已写好）。**`CAPTURE_IFACE` 必填**；镜像名用 `SURICATA_IMAGE` 与构建 tag 对齐：

```bash
cd "${DOCKER_SURICATA_8}"

export SURICATA_IMAGE="suricata:$(cat VERSION)-offline"
export CAPTURE_IFACE=eth1   # 改为本机抓包网卡

./run-suricata-docker.sh
```

停止容器：[`stop-suricata-docker.sh`](stop-suricata-docker.sh)（`docker stop` 前**必须等待 30 秒**，默认 `WAIT_BEFORE_STOP=30`）。



## 无 veth 内核（定制内核 / 禁用 veth 模块）

默认 `docker build` 会把中间容器挂到 `bridge` 网络，需要内核创建 veth 对。若构建报错 `failed to add the host ... <=> sandbox ... pair interfaces: operation not supported`，请在 **`docker build` 上加 `--network=host`**（上文示例已包含）。运行容器时同样应使用 `--network host`（见 [`run-suricata-docker.sh`](run-suricata-docker.sh)）。
