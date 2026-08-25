# amd64 镜像构建步骤

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

当前 `vendor-amd64` 是 AlmaLinux `9.7` 版本线，Dockerfile 使用官方多架构 tag（`almalinux:9.7` / `almalinux/9-base:9.7`），由 `--platform` 选择架构。首次构建前可先拉取：

```bash
docker pull --platform linux/amd64 almalinux:9.7
docker pull --platform linux/amd64 almalinux/9-base:9.7
```

可用以下命令确认基础镜像架构正确：

```bash
docker run --rm --platform linux/amd64 almalinux:9.7 uname -m
```

预期输出 `x86_64`。

## 前置准备（程序员手动执行）

> **人工步骤**：以下命令由程序员在构建前自行执行；Agent / 自动化脚本不得代跑（源码路径与清理时机由人决定）。

每次拷贝最新源码前，先在 Suricata 源码目录清理上次构建产物：

```bash
make clean
make distclean
```

然后再执行：

```bash
cd "${DOCKER_SURICATA_8}"

mkdir -p local-src
rm -rf local-src/suricata-master
cp -a /home/work/suricata-8.0.4-study/ local-src/suricata-master
```

## 离线构建

离线构建前需要先准备好两类本地依赖：**离线 RPM 仓库** 和 **离线 Rust crates**。两者都准备完成后，再执行真正的离线镜像构建。

### 1. 准备 amd64 离线 RPM 仓库

如果 `vendor-amd64` 已经准备好，只需要重新建立当前架构的 `vendor` 链接：

```bash
cd "${DOCKER_SURICATA_8}"

./scripts/link-vendor-for-build.sh amd64
```

完成后应有 `vendor` → `vendor-amd64`，且内含 `vendor-amd64/rpms/builder` 与 `vendor-amd64/rpms/runner`（含 `hyperscan-devel` / `hyperscan`）。

如果 `vendor-amd64` 尚未准备好，或 RPM 依赖发生变更，则需要联网下载 RPM 后再建立 `vendor` 链接：

```bash
./scripts/download-offline-deps.sh --arch amd64 --clean
./scripts/link-vendor-for-build.sh amd64
```

### 2. 准备离线 Rust crates

如果 `local-src/suricata-master/rust/vendor/` 已经准备好，可以直接复用。后续 Docker 构建会把该目录放进构建上下文，并强制 Cargo 使用本地 vendor 目录离线编译。

如果该目录尚未准备好，或 Suricata 源码、`Cargo.toml`、`Cargo.lock` 发生变更，则需要联网重新下载 Rust crates：

```bash
cd "${DOCKER_SURICATA_8}"

./scripts/vendor-rust-crates.sh
```

脚本会使用 `rsproxy.cn` 作为 Cargo 国内源，并把下载缓存放在 `.cargo-vendor-home/`。该缓存只用于加速重新 vendor，已从 Docker build context 排除；需要长期复用的是 `local-src/suricata-master/rust/vendor/`。

### 3. 执行离线镜像构建

离线 RPM 仓库必须与基础镜像的 AlmaLinux 小版本一致。当前 `vendor-amd64` 是 AlmaLinux `9.7` 版本线，构建前请确认已按上文拉取 `almalinux:9.7` 与 `almalinux/9-base:9.7`（`--platform linux/amd64`），否则离线 `dnf` 可能因包版本漂移失败。

执行下面命令前，应确认 `vendor` 已指向 `vendor-amd64`，且 `local-src/suricata-master/rust/vendor/` 已存在。

```bash
cd "${DOCKER_SURICATA_8}"

./scripts/link-vendor-for-build.sh amd64

docker build \
  --network=host \
  --platform linux/amd64 \
  --build-arg OFFLINE=1 \
  --build-arg VERSION=$(cat VERSION) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION)-amd64-offline \
  .
```

## 在线构建

需要能访问外网（拉基础镜像、`dnf` 装包）。当前 Dockerfile 会固定复制 `vendor` 目录，因此在线构建前也需要先确保 `vendor` 指向目标架构目录。

```bash
cd "${DOCKER_SURICATA_8}"

./scripts/link-vendor-for-build.sh amd64

docker build \
  --network=host \
  --platform linux/amd64 \
  --build-arg VERSION=$(cat VERSION) \
  --build-arg CORES=$(nproc) \
  -f Dockerfile.amd64 \
  -t suricata:$(cat VERSION)-amd64 \
  .
```

## 构建后自检

```bash
cd "${DOCKER_SURICATA_8}"

IMG="suricata:$(cat VERSION)-amd64-offline"
docker run --rm "${IMG}" suricata --build-info
docker run --rm "${IMG}" suricata --build-info | grep -i hyperscan   # amd64 应能看到 Hyperscan
docker run --rm --entrypoint /bin/bash "${IMG}" -c '
  test -f /usr/share/suricata/iprep/categories.txt
  test -f /etc/suricata.dist/iprep/ssh-allow.list
  for rule in mms-critical-object mms-write-domain mms-control-action mms-obtain-file power-ssh-policy; do
    test -f "/usr/share/suricata/rules/${rule}.rules" || exit 1
    test -f "/usr/share/suricata/rules.dist/${rule}.rules" || exit 1
  done
  suricata -T -c /etc/suricata/suricata.yaml
'
```

镜像内 `/usr/share/suricata/rules.dist` 保存产品规则备份，运行时规则目录可挂到宿主机以便现场修改并 `USR2` 热加载。`/etc/suricata` 存放可持久化配置及 SSH 白名单，`/var/lib/suricata` 仅保留运行状态和缓存。类别定义升级后需重启容器；规则与白名单更新后可发送 `USR2` 或执行规则重载。
