# Suricata Docker 镜像

本仓库用于构建和运行 Suricata的 Docker 镜像，仓库地址为，当前主要维护Suricata 8.0.4，支持amd64 / arm64在线与离线构建。

## 快速开始

构建完成后，推荐使用 `8.0/` 目录下的脚本启动容器（已配置 host 网络、所需 capabilities 与目录挂载）：

```bash
cd 8.0

# CAPTURE_IFACE 必填，改为本机抓包网卡
export SURICATA_IMAGE="suricata:$(cat VERSION)-arm64-offline"   # 或 -amd64-offline
export CAPTURE_IFACE=eth1

./run-suricata-docker.sh
```

停止容器（停止前默认等待 30 秒，便于刷完尾部报文）：

```bash
./stop-suricata-docker.sh
```

更详细的构建、运行与 IEC61850/MMS 验证步骤见：

- [`8.0/BUILD_AMD64.md`](8.0/BUILD_AMD64.md) — amd64 镜像构建
- [`8.0/BUILD_ARM64.md`](8.0/BUILD_ARM64.md) — arm64 镜像构建
- [`8.0/VERIFY_SURICATA_DOCKER.md`](8.0/VERIFY_SURICATA_DOCKER.md) — 容器运行与功能验证

## 镜像标签

### 上游镜像（Docker Hub）

| 标签 | 说明 |
|------|------|
| `main` | git master 分支最新代码 |
| `latest` | 最新正式发布版（当前为 8.0） |
| `8.0` | 最新 8.0.x 补丁版 |
| `7.0` | 最新 7.0.x 补丁版 |

4.1.5 及更新版本均有对应的具体版本标签。示例：

```bash
docker pull jasonish/suricata:latest
docker pull jasonish/suricata:7.0.11
```

不含 `amd64`、`arm64v8` 等架构后缀的标签为多架构 manifest，Docker 会自动选择合适架构。若需指定架构，可使用带架构后缀的标签，例如：

```bash
docker pull jasonish/suricata:latest-amd64
docker pull jasonish/suricata:6.0.4-arm64v8
```

### 本仓库本地构建标签

在 `8.0/` 目录构建后，典型标签为：

```text
suricata:8.0.4-amd64-offline
suricata:8.0.4-arm64-offline
suricata:8.0.4-amd64          # 在线构建
suricata:8.0.4-arm64
```

具体版本号以 `8.0/VERSION` 为准。

## 备用镜像仓库

除 Docker Hub 外，上游镜像也推送至 quay.io 与 ghcr.io：

```bash
docker pull quay.io/jasonish/suricata:latest
docker pull ghcr.io/jasonish/suricata:latest
```

## 基本用法

Suricata 通常需要在**宿主机网卡**上抓包，而非容器内虚拟网卡，因此应使用 `--network host`（或 `--net=host`）：

```bash
docker run --rm -it --network host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_NICE \
    jasonish/suricata:latest -i <网卡名>
```

若要在宿主机上直接查看日志，可挂载日志目录：

```bash
mkdir -p logs
docker run --rm -it --network host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_NICE \
    -v "$(pwd)/logs:/var/log/suricata" \
    jasonish/suricata:latest -i <网卡名>
```

### 推荐：使用启动脚本

`run-suricata-docker.sh` 将抓包网卡、capabilities、持久化目录等固定为统一模板，避免每次手写 `docker run`。抓包网卡通过环境变量 `CAPTURE_IFACE` 在运行时指定，无需写入 `suricata.yaml`。

脚本会创建并挂载以下宿主机目录：

| 宿主机路径 | 容器路径 | 用途 |
|------------|----------|------|
| `/var/log/suricata-docker` | `/var/log/suricata` | 日志 |
| `/var/lib/suricata-docker` | `/var/lib/suricata` | 规则、Suricata-Update 缓存等 |
| `/var/run/suricata-docker` | `/var/run/suricata` | 运行时文件 |
| `/etc/suricata-docker` | `/etc/suricata` | 配置文件 |

等价的手写 `docker run` 示例：

```bash
CAPTURE_IFACE=eth2
docker run -d \
    --name suricata \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add SYS_NICE \
    -v /var/log/suricata-docker:/var/log/suricata \
    -v /var/lib/suricata-docker:/var/lib/suricata \
    -v /var/run/suricata-docker:/var/run/suricata \
    -v /etc/suricata-docker:/etc/suricata \
    suricata:8.0.4-arm64-offline \
    -i "${CAPTURE_IFACE}" \
    -c /etc/suricata/suricata.yaml
```

参数说明：

- `CAPTURE_IFACE`：运行时指定抓包网卡，不修改 `suricata.yaml`。
- `-d`：后台运行。
- `--name suricata`：固定容器名，便于 `docker logs`、`docker exec` 与重启。
- `--restart unless-stopped`：宿主机或 Docker 重启后自动拉起（手动 stop 除外）。
- `--network host`：共享宿主机网络命名空间，直接监听物理网卡。
- `NET_ADMIN` / `NET_RAW`：抓包与网络管理所需 capability。
- `SYS_NICE`：Suricata 调度与优先级调整。
- `-i` / `-c`：通过 entrypoint 直接传给 Suricata，指定网卡与主配置文件。

## Linux Capabilities

容器在具备相应 capability 时会以非 root 用户（`suricata`）运行。监听网卡并降权需要 `sys_nice`、`net_admin`、`net_raw`；若缺少任一 capability，将回退为 root 运行。

Docker 示例：

```bash
docker run --rm -it --network host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_NICE \
    jasonish/suricata:latest -i eth0
```

Podman 示例（**必须**显式添加 capabilities）：

```bash
sudo podman run --rm -it --network host \
    --cap-add=NET_ADMIN,NET_RAW,SYS_NICE \
    jasonish/suricata:latest -i eth0
```

## 日志

容器将 `/var/log/suricata` 暴露为数据卷。其他容器可通过 `--volumes-from` 共享该目录，例如：

1. 启动 Suricata 并命名：

    ```bash
    docker run -it --network host --name=suricata jasonish/suricata -i enp3s0
    ```

2. 另一容器挂载同一日志卷：

    ```bash
    docker run -it --network host --volumes-from=suricata logstash /bin/bash
    ```

使用 `run-suricata-docker.sh` 时，日志实际位于宿主机 `/var/log/suricata-docker`。

## 日志轮转

### 容器内 logrotate

在容器内执行 logrotate 即可：

```bash
docker exec CONTAINER_ID logrotate /etc/logrotate.d/suricata
```

测试（强制、详细输出）：

```bash
docker exec CONTAINER_ID logrotate -vf /etc/logrotate.d/suricata
```

若需在容器内定时执行，设置 `ENABLE_CRON=yes`，并在 `/etc/cron.*` 下添加可执行脚本（如 `/etc/cron.hourly/suricata`）：

```bash
#!/bin/bash
logrotate /etc/logrotate.d/suricata
```

可通过基于本镜像的 Dockerfile 创建该脚本，或以 bind mount 挂载。

### 宿主机 logrotate（推荐）

使用 `run-suricata-docker.sh` 时，建议在**宿主机**对挂载目录配置 logrotate。模板见 [`8.0/suricata.logrotate`](8.0/suricata.logrotate)，路径应写为 `/var/log/suricata-docker/*.log` 等。详见 [`8.0/VERIFY_SURICATA_DOCKER.md`](8.0/VERIFY_SURICATA_DOCKER.md)。

## 数据卷

容器暴露以下数据卷：

- `/var/log/suricata` — 日志目录
- `/var/lib/suricata` — 规则、Suricata-Update 缓存及运行时数据
- `/etc/suricata` — 配置目录

> 若将 `/etc/suricata` 挂载为空卷，首次启动时会从镜像内默认配置填充。

使用 bind mount 时，可通过 `PUID`、`PGID` 使容器内 `suricata` 用户与宿主机用户 UID/GID 一致：

```bash
docker run -e PUID=$(id -u) -e PGID=$(id -g) ...
```

这样挂载目录的文件属主将与启动容器的宿主机用户一致。

## 配置

最简单的自定义方式是将 `/etc/suricata` bind mount 到宿主机目录；首次运行会自动填充默认配置：

```bash
mkdir -p ./etc
docker run --rm -it -v "$(pwd)/etc:/etc/suricata" jasonish/suricata:latest -V
```

容器退出后，`./etc` 中将包含默认配置文件。

> 首次生成的文件属主可能与宿主机用户不一致，需 `sudo` 编辑或调整权限。设置 `PUID`/`PGID` 可改善此问题。

修改配置后，在后续运行中挂载同一目录即可，例如：

```bash
docker run --rm -it --network host \
    -v "$(pwd)/etc:/etc/suricata" \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_NICE \
    jasonish/suricata:latest -i eth0
```

## 环境变量

| 变量 | 说明 |
|------|------|
| `PUID` / `PGID` | 调整容器内 `suricata` 用户的 UID/GID，便于 bind mount 权限一致 |
| `ENABLE_CRON` | 设为 `yes` 时在容器内启动 `crond`（配合 cron 脚本做 logrotate 等） |
| `SURICATA_IMAGE` | `run-suricata-docker.sh` 使用的镜像名（默认 `suricata:8.0.4-offline`） |
| `CAPTURE_IFACE` | `run-suricata-docker.sh` **必填**，指定抓包网卡 |
| `CONTAINER_NAME` | 容器名（默认 `suricata`） |
| `WAIT_BEFORE_STOP` | `stop-suricata-docker.sh` 停止前等待秒数（默认 `30`） |

Suricata 命令行参数应直接传给容器 entrypoint（如 `-i eth0 -c /etc/suricata/suricata.yaml`），而非通过环境变量拼接。

## Suricata-Update

容器运行中更新规则最方便。一个终端启动 Suricata：

```bash
docker run --name=suricata --rm -it --network host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_NICE \
    jasonish/suricata:latest -i eth0
```

另一个终端执行更新（`-f` 会在完成后通知 Suricata 重载规则）：

```bash
docker exec -it --user suricata suricata suricata-update -f
```

## 树莓派

镜像可在 Raspberry Pi OS 上使用，但因 Raspberry Pi OS 与 Docker 的兼容问题，日志时间戳可能不正确。可选修复：

- 对 Docker 使用 `--privileged`
- 从 backports 升级 `libseccomp2`

## 操作指南

### 初始化配置

对空的 `/etc/suricata` 卷运行一次即可生成默认配置：

```bash
docker run --rm -it -v "$(pwd)/etc:/etc/suricata" jasonish/suricata:latest -V
```

完成后目录中将包含镜像内的默认配置文件。

## 构建镜像

本仓库的 Dockerfile 与脚本面向多架构、离线依赖打包等场景设计。当前版本目录为 `8.0/`，详细步骤见：

- [`8.0/BUILD_AMD64.md`](8.0/BUILD_AMD64.md)
- [`8.0/BUILD_ARM64.md`](8.0/BUILD_ARM64.md)

简要流程：将 Suricata 源码复制到 `8.0/local-src/suricata-master`，按需下载离线 RPM，再执行 `docker build`。

amd64 离线构建示例：

```bash
cd 8.0
./download-offline-deps.sh --arch amd64 --clean
./link-vendor-for-build.sh amd64
docker build \
  --network=host \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t "suricata:$(cat VERSION)-amd64-offline" \
  .
```

arm64 离线构建示例：

```bash
cd 8.0
./download-offline-deps.sh --arch arm64 --clean
./link-vendor-for-build.sh arm64
docker build \
  --network=host \
  --platform linux/arm64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t "suricata:$(cat VERSION)-arm64-offline" \
  .
```

### 在 x86_64 上交叉构建 ARM 镜像

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Arch Linux 可安装 `extra/qemu-user-static-binfmt`。

## 许可证

本仓库中的构建脚本、Dockerfile 及其他文件均采用 MIT 许可证。
