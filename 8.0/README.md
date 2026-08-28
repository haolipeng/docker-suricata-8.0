# Suricata Docker 8.0 脚本说明

本文档说明项目根目录 `scripts/` 下各脚本的用途和常用示例。除特别说明外，命令都建议在项目根目录执行：

```bash
cd /home/work/docker-suricata/8.0
```

## 构建相关脚本

### `scripts/download-offline-deps.sh`

下载指定架构的离线 RPM 依赖，默认输出到项目根目录下的 `vendor-<arch>/`。首次准备离线 RPM 仓库，或 RPM 依赖发生变化时执行。

```bash
./scripts/download-offline-deps.sh --arch amd64 --clean
./scripts/download-offline-deps.sh --arch arm64 --clean
```

常用参数：

| 参数 | 说明 |
|------|------|
| `--arch <amd64|arm64>` | 目标架构，默认 `amd64` |
| `--output-dir <path>` | 输出目录，默认 `./vendor-<arch>` |
| `--docker <path>` | Docker CLI 路径，默认使用 `$DOCKER` 或 `docker` |
| `--clean` | 下载前删除已有输出目录 |

### `scripts/link-vendor-for-build.sh`

为当前构建架构建立 `vendor` 软链接，使 Dockerfile 复制正确架构的离线 RPM 仓库。离线构建和当前 Dockerfile 的在线构建都需要该链接存在。

```bash
./scripts/link-vendor-for-build.sh amd64
./scripts/link-vendor-for-build.sh arm64
```

执行后效果类似：

```text
vendor -> vendor-amd64
```

或：

```text
vendor -> vendor-arm64
```

### `scripts/vendor-rust-crates.sh`

将 Suricata Rust 依赖提前下载到 `local-src/suricata-master/rust/vendor/`，供 Docker 构建阶段离线编译使用。首次准备 Rust crates，或 Suricata 源码、`Cargo.toml`、`Cargo.lock` 发生变化时执行。

```bash
./scripts/vendor-rust-crates.sh
```

脚本会使用 `rsproxy.cn` 作为 Cargo 源，并将 Cargo 下载缓存放在 `.cargo-vendor-home/`。长期需要保留的是：

```text
local-src/suricata-master/rust/vendor/
```

### `scripts/build-single-layer-image.sh`

生成单层 Suricata 镜像。默认会先基于当前目录的 Dockerfile 构建临时镜像，再通过 `FROM scratch + COPY --from=<source> / /` 生成单层镜像。

从当前 Dockerfile 离线构建并生成单层镜像：

```bash
TARGETARCH=arm64 OFFLINE=1 bash scripts/build-single-layer-image.sh
```

使用已有镜像或镜像 ID 直接生成单层镜像：

```bash
SOURCE_IMAGE=26c006cba08a \
SKIP_BUILD=1 \
OUTPUT_IMAGE=suricata:8.0.4-arm64-single-layer \
bash scripts/build-single-layer-image.sh
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `TARGETARCH` | 目标架构，默认 `arm64`，可选 `arm64` / `amd64` |
| `VERSION` | Suricata 版本，默认读取 `VERSION` 文件 |
| `OUTPUT_IMAGE` | 输出镜像完整引用 |
| `SOURCE_IMAGE` | 已有源镜像或镜像 ID，`SKIP_BUILD=1` 时必填 |
| `SKIP_BUILD` | 设为 `1` 时跳过临时镜像构建 |
| `OFFLINE` | 传给 Dockerfile 的 `OFFLINE` build arg，默认 `1` |
| `CORES` | 编译并发，默认 `nproc` |

## 运行和验证脚本

### `scripts/run-suricata-docker.sh`

启动 Suricata 容器。容器使用宿主机网络命名空间，抓包网卡默认使用 `eth1 eth2`，也可以通过 `CAPTURE_IFACES` 或兼容变量 `CAPTURE_IFACE` 覆盖。

默认网口启动：

```bash
./scripts/run-suricata-docker.sh
```

单网口启动：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES=eth1 ./scripts/run-suricata-docker.sh
```

多网口启动：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2 eth3" ./scripts/run-suricata-docker.sh
```



在10.107.12.8服务器上启动：

```
SURICATA_IMAGE=suricata:8.0.4-arm64-single-layer \
CAPTURE_IFACES=eth3 ./scripts/run-suricata-docker.sh
```



也支持逗号分隔：

```bash
CAPTURE_IFACES=eth1,eth2,eth3 ./scripts/run-suricata-docker.sh
```

默认启动不加载产品规则，入口脚本会使用镜像内预生成的无规则配置
`/etc/suricata.dist/suricata-no-rules.yaml`，并跳过规则目录补齐。需要恢复原有规则加载行为时显式设置：

```bash
SURICATA_LOAD_RULES=yes CAPTURE_IFACES=eth1 ./scripts/run-suricata-docker.sh
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `SURICATA_IMAGE` | 启动使用的镜像，默认 `suricata:8.0.4-arm64-offline` |
| `CAPTURE_IFACES` | 抓包网卡列表，支持空格或逗号分隔，默认 `eth1 eth2` |
| `CAPTURE_IFACE` | 旧版单网口变量，保留兼容 |
| `CONTAINER_NAME` | 容器名，默认 `suricata` |
| `SURICATA_USE_IMAGE_YAML` | 是否用镜像内默认配置覆盖宿主机配置，默认 `no` |
| `SURICATA_LOAD_RULES` | 是否在启动时加载并补齐规则，默认 `no`；设为 `yes` 时使用 `suricata.yaml` 中的 `rule-files` |

### `scripts/stop-suricata-docker.sh`

停止 Suricata 容器。停止前默认等待 30 秒，便于 Suricata 刷完尾部报文和日志。

```bash
./scripts/stop-suricata-docker.sh
```

缩短等待时间并停止指定容器：

```bash
CONTAINER_NAME=suricata-test WAIT_BEFORE_STOP=5 ./scripts/stop-suricata-docker.sh
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `CONTAINER_NAME` | 容器名，默认 `suricata` |
| `WAIT_BEFORE_STOP` | 停止前等待秒数，默认 `30` |

### `scripts/replay-pcaps.sh`

使用 `tcpreplay` 将指定目录下的 `.pcap` / `.pcapng` 文件回放到指定网卡。用于本机验证规则、协议解析和流量处理效果。

```bash
CAPTURE_IFACE=eth1 \
PCAP_DIR=/home/work/pcaps_dataset \
MBPS=5 \
./scripts/replay-pcaps.sh
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `CAPTURE_IFACE` | 回放网卡，必填 |
| `PCAP_DIR` | pcap 目录，默认 `/home/work/pcaps_dataset` |
| `MBPS` | 回放速率，默认 `5` |

### `scripts/suricata-json-cleanup`

清理 Suricata EVE JSON 轮转文件。该脚本主要在镜像内通过 cron 调用，Dockerfile 会复制到容器内 `/usr/local/bin/suricata-json-cleanup`。

默认清理 `/var/log/suricata` 下超过 1 天的 `eve.*.json`，并保留最新一个 JSON 文件。每次成功执行会输出一行清理时间、保留阈值、删除数量和最新保留文件；生产 cron 会写入 `/var/log/suricata/suricata-json-cleanup.log`。

本地手动执行示例：

```bash
SURICATA_LOG_DIR=/var/log/suricata \
SURICATA_JSON_KEEP_DAYS=1 \
./scripts/suricata-json-cleanup
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `SURICATA_LOG_DIR` | 日志目录，默认 `/var/log/suricata` |
| `SURICATA_JSON_KEEP_DAYS` | JSON 保留天数，默认 `1` |
