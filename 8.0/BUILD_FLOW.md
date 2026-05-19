# 8.0 Docker Build Flow

这份文档按“构建脚本 -> Dockerfile -> 运行时入口”的顺序解释 `8.0` 的 Docker build 流程。

## 1. 入口是谁

真正负责批量构建的是上一级目录的 [`build.sh`](../build.sh)。

- 它先从 [`VERSION`](VERSION) 读取版本号，当前是 `8.0.4`。
- 它分别调用 [`Dockerfile.amd64`](Dockerfile.amd64) 和 [`Dockerfile.arm64`](Dockerfile.arm64)。
- 它会传入：
  - `VERSION`
  - `CORES`
  - `CONFIGURE_ARGS`
  - `--platform linux/amd64` 或 `--platform linux/arm64`

常见单独构建方式是：

```bash
docker build --build-arg VERSION=$(cat VERSION) -f Dockerfile.amd64 .
docker build --build-arg VERSION=$(cat VERSION) -f Dockerfile.arm64 .
```

## 2. Build.sh 在做什么

`build.sh` 的核心逻辑是：

1. 读取版本号和 CPU 核数。
2. 按架构循环构建 `amd64` 和 `arm64`。
3. 分别构建普通版和 profiling 版。
4. 可选 push 镜像。
5. 可选创建 multi-arch manifest。

profiling 版会额外传：

```bash
--build-arg CONFIGURE_ARGS="--enable-profiling --enable-profiling-locks"
```

## 3. Dockerfile 总体结构

两个 Dockerfile 都是双阶段构建：

- `builder` 阶段：下载源码、配置、编译、安装到临时目录。
- `runner` 阶段：只装运行时依赖，把编译产物拷进去。

这样做的目的很直接：最终镜像更小，且不会把编译工具链一并带进去。

## 4. 逐段解释

### 4.1 `FROM almalinux:9 AS builder`

构建阶段基于 AlmaLinux 9。

### 4.2 `dnf update` 和启用仓库

```dockerfile
dnf -y update
dnf -y install epel-release dnf-plugins-core
dnf config-manager --set-enabled crb
```

- `epel-release` 提供额外软件包源。
- `crb` 提供一些构建依赖。

### 4.3 安装编译依赖

这里安装的是 Suricata 编译所需的开发包、编译器、Rust 相关工具和各种库的 `-devel` 包。

重点可以这样理解：

- `autoconf/automake/libtool/make/pkgconfig`：传统 autotools 构建链。
- `gcc/gcc-c++/rust/cargo/cbindgen`：C/C++ 和 Rust 相关编译器。
- `dpdk-devel/hiredis-devel/jansson-devel/...`：Suricata 各功能模块的开发头文件和库。

### 4.4 仅在 `x86_64` 安装 Hyperscan

```dockerfile
if [ "$(arch)" = "x86_64" ]; then dnf -y install hyperscan-devel; fi
```

这表示：

- x86_64 上启用 Hyperscan。
- 其他架构不装，因为通常不可用或不适配。

### 4.5 `ARG VERSION` 和源码获取

`VERSION` 决定拉取哪份 Suricata 源码。

- 如果是 `master`：直接从 GitHub clone 源码，并把 `suricata-update` 也补进来，再跑 `./autogen.sh`。
- 如果是发行版版本号：下载官方 tarball，解压即可。

也就是说，这里同时支持：

- 开发版构建
- 正式版本构建

### 4.6 `WORKDIR /src/suricata-${VERSION}`

后续命令都在源码目录里执行。

### 4.7 `profiling.patch`

```dockerfile
COPY /profiling.patch /tmp/profiling.patch
RUN patch -p1 < /tmp/profiling.patch
```

这个 patch 会把默认配置里的 profiling 关掉：

- 不是删掉 profiling 功能
- 而是避免默认配置一启动就开 profiling

### 4.8 `./configure`

```dockerfile
./configure \
  --prefix=/usr \
  --disable-shared \
  --disable-gccmarch-native \
  --enable-nfqueue \
  --enable-hiredis \
  --enable-geoip \
  --enable-ebpf \
  --enable-dpdk \
  --enable-profiling-rules \
  ${CONFIGURE_ARGS}
```

含义：

- `--prefix=/usr`：安装到标准系统路径。
- `--disable-shared`：更偏向静态/内嵌式交付。
- `--disable-gccmarch-native`：避免生成只适配本机 CPU 的二进制。
- `--enable-*`：打开 Suricata 的相关功能模块。
- `${CONFIGURE_ARGS}`：由外部注入额外参数，常用于 profiling 变体。

### 4.9 `make -j "${CORES}"`

并行编译，`CORES` 默认是 2，实际由 `build.sh` 传入当前机器 CPU 数。

### 4.10 Hyperscan 校验

```dockerfile
./src/suricata --build-info | grep Hyperscan | grep yes
```

这是一个构建后自检：

- 只在 x86_64 上执行
- 确认 Hyperscan 真正被编进去了

### 4.11 安装到 `/fakeroot`

```dockerfile
make install install-conf DESTDIR=/fakeroot
```

意思是先把安装结果“打包”到临时根目录 `/fakeroot`，而不是直接装进当前镜像根文件系统。

这样后面可以把这棵目录树整体复制到运行时镜像。

### 4.12 删除 `/fakeroot/var`

```dockerfile
RUN rm -rf /fakeroot/var
```

这是为了绕过 Docker 挂载/复制 `/var/run` 时的限制，避免后续阶段复制出问题。

## 5. Runner 阶段

### 5.1 `FROM almalinux/9-base:latest AS runner`

运行阶段使用更轻量的基础镜像。

### 5.2 安装运行时依赖

这一段只装运行 Suricata 需要的库和工具，不装编译器。

同样地，x86_64 上会额外装 `hyperscan`。

### 5.3 `COPY --from=builder /fakeroot /`

把编译产物整体拷到最终镜像里。

### 5.4 创建运行目录

```dockerfile
mkdir -p /var/log/suricata /var/run/suricata /var/lib/suricata
```

这些目录有些不会从 builder 阶段完整带过来，所以在 runner 阶段补建。

### 5.5 配置文件和更新源

```dockerfile
COPY /update.yaml /etc/suricata/update.yaml
COPY /suricata.logrotate /etc/logrotate.d/suricata
RUN suricata-update update-sources
```

- `update.yaml`：`suricata-update` 的源配置。
- `suricata.logrotate`：日志轮转配置。
- `update-sources`：把规则源初始化好。

### 5.6 创建 `suricata` 用户

```dockerfile
useradd --system --create-home suricata
```

然后把配置、日志、状态目录改成这个用户可写。

再把 `/etc/suricata` 复制成 `/etc/suricata.dist`，用于容器启动时补默认配置。

### 5.7 `VOLUME`

把配置、日志、运行时目录声明成 volume，方便挂载持久化。

## 6. 离线构建

当前 Dockerfile 已支持 `OFFLINE=1` 模式，但前提是你先把 RPM 仓库和源码包准备到构建上下文里的 [`vendor/`](vendor/README.md)。

推荐直接运行 [`download-offline-deps.sh`](download-offline-deps.sh) 自动下载离线依赖：

```bash
./download-offline-deps.sh --arch amd64 --clean
```

如果要准备 arm64 离线包：

```bash
./download-offline-deps.sh --arch arm64 --clean
```

说明：

- 脚本会通过 `docker run --platform linux/<arch>` 启一个 AlmaLinux 9 容器做下载。
- 如果下载 `arm64` 依赖，你的 Docker 环境需要支持 `linux/arm64` 容器运行，通常意味着宿主机已经配好 `binfmt/qemu`。
- 脚本会透传当前 shell 中的 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY` 及其小写变量。

目录结构：

```text
vendor/
├── rpms/
│   ├── builder/
│   │   ├── *.rpm
│   │   └── repodata/
│   └── runner/
│       ├── *.rpm
│       └── repodata/
└── sources/
    ├── suricata-8.0.4.tar.gz
    ├── suricata-master.tar.gz
    └── suricata-update-master.tar.gz
```

说明：

- `builder` 仓库放编译阶段依赖。
- `runner` 仓库放运行阶段依赖。
- `sources` 放 Suricata 源码包；发布版构建至少需要 `suricata-${VERSION}.tar.gz`。
- `master` 构建额外需要 `suricata-master.tar.gz` 和 `suricata-update-master.tar.gz`。

离线构建命令：

```bash
docker build \
  -f Dockerfile.amd64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -t suricata:$(cat VERSION) .
```

注意：

- 离线模式下不会执行 `dnf update`。
- 离线模式下不会执行 `suricata-update update-sources`，因为这一步也需要联网。
- 你的本地 RPM 目录必须是可被 DNF 识别的仓库，也就是执行过 `createrepo` 或 `createrepo_c` 生成了 `repodata/`。

### 5.8 `docker-entrypoint.sh`

入口脚本负责：

- 补默认配置
- 检查 capability
- 决定是否以 `suricata` 用户运行
- 启动 `suricata`

### 5.9 最后校验

```dockerfile
RUN /usr/bin/suricata --build-info
```

这是最终 sanity check，确保镜像里真的能运行 Suricata。

## 6. `docker-entrypoint.sh` 做什么

启动时它会：

1. 把 `/etc/suricata.dist` 里缺失的默认文件补到 `/etc/suricata`。
2. 如果用户传了非 `-` 开头的参数，就直接执行那个命令。
3. 检查 `sys_nice` 和 `net_admin` capability。
4. 如果 capability 足够，就切到 `suricata` 用户运行。
5. 如果设置了 `ENABLE_CRON=yes`，还会启动 `crond`。
6. 最后 `exec /usr/bin/suricata ...`

## 7. amd64 和 arm64 的差异

### `Dockerfile.arm64`

- 多了 `ENV CARGO_NET_GIT_FETCH_WITH_CLI=true`
- 这通常是为了让 Cargo 用系统 `git` 拉依赖，避免某些环境下的 Rust Git 依赖问题

### `Dockerfile.amd64`

- 没有这个 `ENV`
- 其他流程基本一致

## 8. 一句话总结

这套构建流程本质上就是：

**用 AlmaLinux 9 在 builder 阶段编译 Suricata，再把安装结果和运行时依赖复制到更轻量的 runner 镜像里，最后用 entrypoint 做权限和默认配置初始化。**
