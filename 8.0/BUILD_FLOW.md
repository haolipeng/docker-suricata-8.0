# 8.0 Docker 构建流程说明

本文档按「入口脚本 → Dockerfile → 离线依赖 → 运行时入口」说明 `8.0` 目录的镜像构建流程。

[`Dockerfile.amd64`](Dockerfile.amd64) 与 [`Dockerfile.arm64`](Dockerfile.arm64) 采用同一套默认策略（精简依赖、阿里云镜像、离线 `vendor`）；**仅 Hyperscan** 在 x86_64 上额外安装。下文未特别说明时，两架构行为一致。

## 1. 构建入口

### 1.1 批量构建：`../build.sh`

上一级目录的 [`build.sh`](../build.sh) 会：

1. 读取本目录 [`VERSION`](VERSION)（当前为 `8.0.4`）。
2. 对 `amd64` / `arm64` 循环调用 `Dockerfile.${arch}`。
3. 传入构建参数：`VERSION`、`CORES`（`nproc`）、`CONFIGURE_ARGS`、`--platform linux/${arch}`。
4. 可选构建 **profiling** 变体（额外 `CONFIGURE_ARGS="--enable-profiling --enable-profiling-locks"`）。
5. 可选 push 与 multi-arch manifest。

`build.sh` **不会**自动设置 `OFFLINE=1` 或代理；需要时自行在 `docker build` 中加 `--build-arg`。

### 1.2 单独构建（推荐显式参数）

```bash
cd /path/to/docker-suricata/8.0

# 在线（默认）
docker build \
  --progress=plain \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION) \
  .

# 离线（见 §6：分架构下载 + link-vendor-for-build）
./download-offline-deps.sh --arch amd64 --clean
./link-vendor-for-build.sh amd64
./prepare-local-master-src.sh /home/work/iot-sentinel   # 仅 VERSION=master 时需要
docker build \
  --progress=plain \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION)-offline \
  .

# 离线 arm64（先 link 到 vendor-arm64，并指定 platform）
./download-offline-deps.sh --arch arm64 --clean
./link-vendor-for-build.sh arm64
docker build \
  --progress=plain \
  --platform linux/arm64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.arm64 \
  -t suricata:$(cat VERSION)-arm64-offline \
  .

# 需要代理时（构建期传入，会写入 ENV）
docker build \
  --build-arg HTTP_PROXY=http://host:port \
  --build-arg HTTPS_PROXY=http://host:port \
  --build-arg NO_PROXY=localhost,127.0.0.1 \
  ...
```

## 2. 构建参数一览

| 参数 | 默认 | 作用 |
|------|------|------|
| `OFFLINE` | `0` | `1` 时禁用在线仓库，从构建上下文 `vendor/rpms/*` 安装 RPM（离线前需 `./link-vendor-for-build.sh <arch>`，见 §6.1.1） |
| `VERSION` | （必填） | Suricata 版本：`8.0.4` 等发行号，或 `master` 开发主线 |
| `CORES` | `2` | `make -j` 并行度 |
| `CONFIGURE_ARGS` | 空 | 追加传给 `./configure` 的选项（profiling 镜像由 `build.sh` 注入） |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | 空 | 构建阶段 `dnf`/`curl`/`git` 使用的代理 |

## 3. 总体结构：双阶段

| 阶段 | 基础镜像 | 作用 |
|------|----------|------|
| `builder` | `almalinux:9` | 装编译依赖、取源码、configure、make、安装到 `/fakeroot` |
| `runner` | `almalinux/9-base:latest` | 只装运行时库，拷贝 `/fakeroot`，配置用户与 entrypoint |

最终镜像不包含 gcc/rust 等工具链，体积更小。

## 4. Builder 阶段（`Dockerfile.amd64` / `Dockerfile.arm64`）

### 4.1 准备：`COPY /vendor` 与仓库策略

构建上下文中的 `vendor/` 会复制到镜像 `/vendor`（路径在 Dockerfile 中写死为 `COPY /vendor`）。

- **在线**（`OFFLINE!=1`）：`vendor/` 可为空目录或不存在（若未做符号链接）。
- **离线**（`OFFLINE=1`）：须先下载 `vendor-<arch>/`，再执行 [`link-vendor-for-build.sh`](link-vendor-for-build.sh) 使 `vendor` 指向该架构目录（见 §6.1.1）。

**在线（`OFFLINE!=1`）— 步骤 `[builder 1/4]`：**

- **不执行** `dnf -y update`（避免全系统升级卡住或过慢）。
- 将 AlmaLinux / EPEL 的 `baseurl` 改为阿里云镜像（`mirrors.aliyun.com`）。
- 安装 `epel-release`、`dnf-plugins-core`，启用 `crb`。
- `dnf` 使用 `--setopt=timeout=60 --setopt=retries=10`。
- 打印 `env | grep -i proxy` 便于排查代理。

**离线（`OFFLINE=1`）— 步骤 `[builder 2/4]`：**

- 跳过在线源配置。
- 仅从本地 RPM 仓安装 `ca-certificates`（后续 `curl` 等可能需要）：

```dockerfile
dnf -y install \
  --disablerepo='*' \
  --repofrompath=local-builder,file:///vendor/rpms/builder \
  --setopt=local-builder.gpgcheck=0 \
  ca-certificates
```

`file:///vendor/rpms/builder` 表示 DNF 把该目录当作名为 `local-builder` 的本地仓库（需含 `repodata/`，由 `createrepo_c` 生成）。

### 4.2 编译依赖 — `[builder 3/4]` / `[builder 4/4]`

依赖名集中在变量 `builder_packages`，**在线与离线共用同一份列表**，避免两套 Dockerfile 漂移。

当前 amd64 编译包（节选分类）：

| 类别 | 包 |
|------|-----|
| 构建链 | `autoconf` `automake` `libtool` `make` `pkgconfig` `patch` `diffutils` `which` |
| 编译器 | `gcc` `gcc-c++` `rust` `cargo` `cbindgen` |
| Suricata 核心库 | `jansson-devel` `libyaml-devel` `pcre2-devel` `zlib-devel` `lz4-devel` `libpcap-devel` `libnet-devel` `libcap-ng-devel` `libevent-devel` |
| 其它 | `file-devel` `libprelude-devel` `python3-devel` `python3-yaml` `elfutils-libelf-devel` `jq` `git` |
| x86_64 可选 | `hyperscan-devel`（单独一步安装） |

**已自 amd64 镜像移除**（不再 configure 对应功能）：`dpdk-devel`、`hiredis-devel`、`libbpf-devel`、`libnfnetlink-devel`、`libnetfilter_queue-devel`、`libmaxminddb-devel`、`numactl-devel` 等。

### 4.3 源码获取 — `[builder 5/5]`

由 `VERSION` 与 `OFFLINE` 组合决定，分四条互斥的 `RUN`：

| `VERSION` | `OFFLINE` | 行为 |
|-----------|-----------|------|
| `master` | `1` | 使用构建上下文内的 `local-src/suricata-master`，执行 `./autogen.sh` |
| `master` | `0` | `git clone` OISF/suricata，拉取 suricata-update 的 master tarball，`./autogen.sh` |
| 发行号（如 `8.0.4`） | `1` | 复制并解压 `/vendor/sources/suricata-${VERSION}.tar.gz` |
| 发行号 | `0` | `curl` 下载 `https://www.openinfosecfoundation.org/download/suricata-${VERSION}.tar.gz` |

工作目录：`/src/suricata-${VERSION}`。

- **`VERSION=master`**：GitHub 开发主线，不稳定，需 `autogen.sh`。
- **`VERSION=8.0.4`**（`VERSION` 文件默认值）：官方发布 tarball，稳定发布流程。

### 4.4 `./configure` 与编译

```dockerfile
./configure \
  --prefix=/usr \
  --disable-shared \
  --disable-gccmarch-native \
  ${CONFIGURE_ARGS}
```

**默认不再**传入 `--enable-nfqueue`、`--enable-hiredis`、`--enable-dpdk`、`--enable-ebpf`、`--enable-geoip`、`--enable-profiling-rules`。若需要这些功能，须在 `CONFIGURE_ARGS` 中自行 `--enable-*`，并保证 Dockerfile / 离线脚本里安装了对应 `-devel` 与运行时包。

后续步骤：

1. `make -j "${CORES}"`
2. x86_64：`./src/suricata --build-info | grep Hyperscan | grep yes`
3. `make install install-conf DESTDIR=/fakeroot`
4. `rm -rf /fakeroot/var`（避免 runner 阶段复制 `/var` 出问题）

## 5. Runner 阶段（`Dockerfile.amd64` / `Dockerfile.arm64`）

### 5.1 运行时依赖 — `[runner 1/3]` ~ `[runner 3/3]`

与 builder 类似：在线走阿里云源 + EPEL；离线用 `file:///vendor/rpms/runner`（仓库 ID：`local-runner`）。

`runtime_packages` 与 builder 一样集中维护，当前包括例如：`cronie` `jansson` `libyaml` `libpcap` `libnet` `libevent` `libprelude` `python3` `python3-yaml` `logrotate` `tcpdump` 等；**不含** DPDK、Hiredis、NFQUEUE、libbpf 等已裁剪模块的运行时库。

x86_64 额外安装 `hyperscan`。

安装结束后：

```dockerfile
dnf clean all
find /etc/logrotate.d -type f -not -name suricata -delete
rm -rf /vendor
```

离线包仅构建期需要，最终镜像内不保留 `/vendor`。

### 5.2 拷贝产物与配置

| 步骤 | 说明 |
|------|------|
| `COPY --from=builder /fakeroot /` | 安装 Suricata 二进制与默认配置 |
| `mkdir -p /var/log/suricata ...` | 补全日志、状态目录 |
| `COPY update.yaml` / `suricata.logrotate` | 规则源与日志轮转 |
| `suricata-update update-sources` | **仅在线**（`OFFLINE!=1`） |
| `useradd suricata` + `chown` + `/etc/suricata.dist` | 非 root 运行与首次启动补配置 |
| `VOLUME` | `/var/log/suricata` 等 |
| `suricata --build-info` | 构建期自检 |

## 6. 离线构建

### 6.1 准备依赖：`download-offline-deps.sh`

```bash
# 按架构分别下载（默认写入 vendor-amd64 / vendor-arm64，互不覆盖）
./download-offline-deps.sh --arch amd64 --clean
./download-offline-deps.sh --arch arm64 --clean

# 构建前：把 vendor 指到当前要编的架构
./link-vendor-for-build.sh amd64    # 或 arm64

# 若要构建 VERSION=master
./download-offline-deps.sh --version master --include-master-assets --clean
./prepare-local-master-src.sh /home/work/iot-sentinel
```

脚本会：

1. 用 `docker run --platform linux/<arch> almalinux:9` 在容器内下载 RPM（**脚本内仍会 `dnf update`**，与镜像构建不同）。
2. 默认输出到 `vendor-<arch>/`（如 `vendor-amd64`），**不会**与另一架构混在同一目录。
3. `dnf download --resolve` 到 `vendor-<arch>/rpms/builder` 与 `vendor-<arch>/rpms/runner`。
4. 对每个目录执行 `createrepo_c` 生成 `repodata/`。
5. 下载 `vendor-<arch>/sources/` 下对应 tarball。

`amd64` / `arm64` 的包列表分别与对应 Dockerfile 中 `builder_packages` / `runtime_packages` **对齐**（`hyperscan-devel` / `hyperscan` 仅写在 **amd64** 脚本数组中；arm64 不含 Hyperscan）。

可用 `--output-dir <path>` 覆盖默认目录；未指定时即为 `./vendor-<arch>`。

脚本会透传当前 shell 的 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`（及小写形式）到下载容器。

下载完成后会执行 `normalize_vendor_tree` 修正文件属性。

### 6.1.1 为何使用 `vendor-<arch>` 与 `link-vendor-for-build.sh`

amd64 与 arm64 的 RPM **不能**混在同一目录：[`download-offline-deps.sh`](download-offline-deps.sh) 每次下载前会清空 `rpms/builder` 与 `rpms/runner` 下的 `*.rpm` 并重建 `repodata/`。若共用一个 `vendor/`，后下载的架构会 **覆盖** 先下载的 RPM，导致另一架构离线构建时 `dnf` 报缺包或架构不匹配。

因此默认改为 **按架构分目录**：

| 目录 | 内容 |
|------|------|
| `vendor-amd64/` | 仅 amd64 的 `rpms/*` 与 `sources/*` |
| `vendor-arm64/` | 仅 arm64 的 `rpms/*` 与 `sources/*` |

而 Dockerfile 中路径是固定的：

```dockerfile
COPY /vendor /vendor
```

`docker build` 只会从构建上下文（`8.0/`）下的 **`vendor/`** 拷贝，不会根据 `--platform` 自动改为 `vendor-arm64/`。因此在离线构建前需要让 `vendor` 指向 **当前要编的那一架构** 的目录。

[`link-vendor-for-build.sh`](link-vendor-for-build.sh) 的作用就是在 `8.0/` 下创建符号链接：

```text
vendor  →  vendor-amd64   # ./link-vendor-for-build.sh amd64
vendor  →  vendor-arm64   # ./link-vendor-for-build.sh arm64
```

这样无需修改 Dockerfile，也无需每次 `cp -a vendor-amd64 vendor`（占双倍磁盘）。脚本会检查 `vendor-<arch>/rpms/builder` 是否存在，避免链到空目录。

**不用该脚本时的等价做法：**

```bash
ln -sfn vendor-amd64 vendor    # 或 vendor-arm64
```

**其它可选设计（当前未采用）：**

- 在 `Dockerfile.amd64` / `Dockerfile.arm64` 中分别写 `COPY vendor-amd64` / `COPY vendor-arm64`（可去掉 link 步骤，但两个 Dockerfile 路径不一致）；
- 继续共用单一 `vendor/`（仅适合只维护一种架构的离线包）。

**在线构建**不依赖离线 RPM，一般 **不需要** 执行 `link-vendor-for-build.sh`。

### 6.2 目录结构

```text
vendor-amd64/              # ./download-offline-deps.sh --arch amd64
vendor-arm64/              # ./download-offline-deps.sh --arch arm64
├── rpms/
│   ├── builder/           # 该架构编译 RPM + repodata/
│   └── runner/            # 该架构运行 RPM + repodata/
└── sources/
    ├── suricata-8.0.4.tar.gz
    └── ...

vendor -> vendor-amd64     # ./link-vendor-for-build.sh amd64（构建前）
# 或 vendor -> vendor-arm64

local-src/
└── suricata-master/       # VERSION=master 且 OFFLINE=1 时需要
```

### 6.3 离线构建注意点

- 构建命令必须 `--build-arg OFFLINE=1`。
- 构建前必须对目标架构执行 `./link-vendor-for-build.sh <amd64|arm64>`，保证 `COPY /vendor` 指向正确的 `vendor-<arch>`。
- 不会执行 `suricata-update update-sources`；规则源需自行维护或在线环境初始化后挂载。
- 本地仓必须带 `repodata/`，否则 `--repofrompath` 失败。

## 7. `docker-entrypoint.sh`

容器启动时：

1. 将 `/etc/suricata.dist/*` 中缺失的默认文件复制到 `/etc/suricata`。
2. 若第一个参数不以 `-` 开头，视为用户命令直接 `exec`。
3. 检查 `sys_nice`、`net_admin` capability；不足则警告并以 root 运行 Suricata。
4. 支持 `PUID`/`PGID` 调整 `suricata` 用户。
5. `ENABLE_CRON=yes` 时启动 `crond`。
6. `exec /usr/bin/suricata`（尽量 `--user suricata`）。

## 8. Profiling 变体（`build.sh`）

`build.sh` 在 `VARIANT=profiling` 或 `both` 时会多构建一个 tag（如 `:8.0.4-amd64-profiling`），并传入：

```bash
--build-arg CONFIGURE_ARGS="--enable-profiling --enable-profiling-locks"
```

## 9. amd64 与 arm64 差异

| 项目 | amd64 | arm64 |
|------|-------|-------|
| Dockerfile 默认依赖 / configure | 精简策略 | 与 amd64 相同 |
| 国内镜像、代理、`builder_packages` / `runtime_packages` | 是 | 是 |
| `CARGO_NET_GIT_FETCH_WITH_CLI`（builder） | 是 | 是 |
| Hyperscan（builder / runner） | x86_64 安装 | 不安装 |
| 离线脚本 `BUILDER_PACKAGES` / `RUNNER_PACKAGES` | 含 hyperscan | 不含 hyperscan |

对齐或升级依赖后，请按架构分别重跑 [`download-offline-deps.sh`](download-offline-deps.sh)（例如 `--arch arm64 --clean`）。

## 10. 常见问题

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `dnf` 长时间无输出 | Docker 缓冲日志 | `docker build --progress=plain` |
| 在线装包很慢 | 默认国外源 | 已改阿里云；检查代理 |
| 离线 `repofrompath` 失败 | 无 `repodata/` 或包不全 | 重跑 `download-offline-deps.sh --arch <arch> --clean` |
| 离线装包架构错误 / 缺包 | 未 `link-vendor-for-build` 或 `vendor` 指向错误架构 | 对目标架构执行 `./link-vendor-for-build.sh amd64` 或 `arm64` 后再构建 |
| Hyperscan 检查失败 | 非 x86_64 或包未装上 | 仅在 amd64 需要；arm64 跳过该 `RUN` |
| `master` 构建失败 | 无 GitHub/无离线包 | 在线需网络；离线需 master 两个 tarball |

## 11. 一句话总结

**在 AlmaLinux 9 的 builder 阶段编译 Suricata（支持在线阿里云源或离线 `vendor` RPM 仓），将 `/fakeroot` 与精简后的运行时依赖装入 runner 镜像，由 entrypoint 完成权限与默认配置初始化；默认发行版为 `VERSION` 文件中的发布号（如 `8.0.4`），可选 `master` 开发构建。**
