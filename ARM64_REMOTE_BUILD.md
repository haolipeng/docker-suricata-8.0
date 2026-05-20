# ARM64 Build Notes

本仓库最终可落地的 `arm64` 构建方案是 `QEMU + buildx`。之前尝试过远程 ARM 节点，但该节点的 Docker 不支持 `bridge / veth / 容器网络`，因此不能作为 `buildx` 节点使用。

## 1. 先决条件

- 本机 Docker 已安装 `buildx` 插件
- 本机可用 `binfmt` / `QEMU`
- `8.0/link-vendor-for-build.sh` 可正常切换 `vendor -> vendor-arm64`
- `8.0/vendor-arm64/` 已准备好

## 2. 安装 `QEMU`

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## 3. 创建 `buildx` builder

```bash
docker buildx create --use --name qemu-builder
docker buildx inspect --bootstrap
```

## 4. 构建 `arm64`

```bash
cd /home/work/docker-suricata/8.0
./link-vendor-for-build.sh arm64
docker buildx build --builder qemu-builder \
  --platform linux/arm64 \
  -f Dockerfile.arm64 \
  -t suricata:8.0-arm64 \
  --load \
  .
```

## 5. 导出离线包

```bash
docker save -o ./dist/suricata-8.0-arm64.tar suricata:8.0-arm64
```

## 6. 已验证的远程节点结论

- `10.107.12.9:6702` 可达
- `secadm` / `root` 登录都曾验证过
- 远端 Docker 已经能设置代理并拉到 `moby/buildkit:buildx-stable-1`
- 但 `buildx bootstrap` 最终失败在 `bridge/veth`，所以该节点不可用
