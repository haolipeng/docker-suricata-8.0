# 10.107.12.8 Suricata 抓包与 PCAP 回放测试方案

本文档记录在 `10.107.12.8` 服务器上启动 Suricata Docker，并将 `/home/work/pcaps_dataset` 下所有 `pcap/pcapng` 数据包每小时回放到 `eth3` 的测试方案。

## 1. 测试目标

- 在 `10.107.12.8` 上使用 `suricata:8.0.4-arm64-single-layer` 镜像启动 Suricata。
- Suricata 监听宿主机 `eth3` 网口。
- 周期性回放 `/home/work/pcaps_dataset` 目录及其子目录下的所有 `*.pcap`、`*.pcapng` 文件。
- 回放目标网口为 `eth3`。
- 回放周期为每 1 小时执行一轮。

## 2. 服务器与路径

| 项目 | 值 |
| --- | --- |
| 服务器 | `10.107.12.8` |
| Suricata 项目目录 | `/home/work/docker-suricata/8.0` |
| Suricata 启动脚本 | `/home/work/docker-suricata/8.0/scripts/run-suricata-docker.sh` |
| PCAP 数据目录 | `/home/work/pcaps_dataset` |
| PCAP 回放脚本 | `/home/work/pcaps_dataset/replay-pcaps.sh` |
| 回放网口 | `eth3` |
| 回放速率 | `5 Mbps` |
| 回放周期 | `3600` 秒 |

## 3. 启动 Suricata Docker

进入 Suricata 项目目录：

```bash
cd /home/work/docker-suricata/8.0
```

执行启动命令：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-single-layer \
CAPTURE_IFACES=eth3 \
./scripts/run-suricata-docker.sh
```

启动后确认容器状态：

```bash
docker ps --filter name=suricata --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker logs --tail 30 suricata
```

预期结果：

- 容器名为 `suricata`。
- 镜像为 `suricata:8.0.4-arm64-single-layer`。
- 容器状态为 `Up`。
- 日志中能看到 Suricata 8.0.4 引擎启动成功。

## 4. PCAP 回放脚本行为

`/home/work/pcaps_dataset/replay-pcaps.sh` 已调整为常驻脚本。

脚本行为：

- 启动后立即执行一轮回放。
- 每轮回放前重新扫描 `/home/work/pcaps_dataset`，因此运行期间新增的 `pcap/pcapng` 文件会在下一轮自动加入。
- 跳过 `.git` 目录。
- 按路径排序后依次回放。
- 每轮结束后等待 `REPLAY_INTERVAL_SECONDS` 秒，默认 `3600` 秒。
- 支持 `RUN_ONCE=1` 临时执行单轮测试。

关键环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CAPTURE_IFACE` | 空 | 必填，回放网口。本测试使用 `eth3` |
| `PCAP_DIR` | `/home/work/pcaps_dataset` | PCAP 数据目录 |
| `MBPS` | `5` | tcpreplay 回放速率 |
| `REPLAY_INTERVAL_SECONDS` | `3600` | 每轮回放后的等待时间 |
| `RUN_ONCE` | `0` | 设为 `1` 时只回放一轮后退出 |
| `LOG_FILE` | 空 | 设置后脚本将 stdout/stderr 写入该日志文件 |

单轮测试命令：

```bash
CAPTURE_IFACE=eth3 \
PCAP_DIR=/home/work/pcaps_dataset \
MBPS=5 \
RUN_ONCE=1 \
/home/work/pcaps_dataset/replay-pcaps.sh
```

## 5. 常驻回放服务

当前不使用 `crond`，也不使用 `systemd timer`。

采用方式：

- `replay-pcaps.sh` 自己作为常驻进程循环执行。
- systemd 只作为普通 service 负责：
  - 开机自启
  - 进程异常退出后自动重启
  - 统一查看状态

service 文件：

```text
/etc/systemd/system/pcaps-replay.service
```

service 内容：

```ini
[Unit]
Description=Replay pcaps dataset to eth3 continuously
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
Environment=CAPTURE_IFACE=eth3
Environment=PCAP_DIR=/home/work/pcaps_dataset
Environment=MBPS=5
Environment=REPLAY_INTERVAL_SECONDS=3600
Environment=LOG_FILE=/var/log/pcaps-replay-service.log
WorkingDirectory=/home/work/pcaps_dataset
ExecStart=/home/work/pcaps_dataset/replay-pcaps.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

启用并启动服务：

```bash
systemctl daemon-reload
systemctl enable --now pcaps-replay.service
```

## 6. 验证方法

### 6.1 查看服务状态

```bash
systemctl status pcaps-replay.service --no-pager -l
```

正常运行时可能看到两类状态：

- 正在回放时，进程中会出现 `tcpreplay --intf1=eth3`。
- 一轮结束后，进程会进入 `sleep 3600`。

### 6.2 查看回放日志

```bash
tail -f /var/log/pcaps-replay-service.log
```

一轮成功结束时，日志应包含类似内容：

```text
done failed=0
===== 2026-08-26 17:21:10 replay round end rc=0 =====
sleep 3600s before next replay round
```

### 6.3 查看回放进程

```bash
ps -ef | grep -E '[r]eplay-pcaps.sh|[t]cpreplay --intf1=eth3'
```

### 6.4 查看 Suricata 容器

```bash
docker ps --filter name=suricata --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker logs --tail 30 suricata
```

## 7. 运维命令

重启回放服务：

```bash
systemctl restart pcaps-replay.service
```

停止回放服务：

```bash
systemctl stop pcaps-replay.service
```

禁止开机自启：

```bash
systemctl disable pcaps-replay.service
```

查看服务是否开机自启：

```bash
systemctl is-enabled pcaps-replay.service
```

查看服务是否运行：

```bash
systemctl is-active pcaps-replay.service
```

## 8. 当前验证结果

已在 `10.107.12.8` 上完成验证：

- `suricata` 容器已使用 `suricata:8.0.4-arm64-single-layer` 镜像启动。
- Suricata 监听网口为 `eth3`。
- `/home/work/pcaps_dataset/replay-pcaps.sh` 已能扫描并回放 65 个 `pcap/pcapng` 文件。
- `pcaps-replay.service` 已设置为 `enabled`。
- `pcaps-replay.service` 当前为 `active`。
- 第一轮回放已完成，日志显示 `done failed=0`。
- 第一轮结束后进程进入 `sleep 3600`，表示下一轮将在 1 小时后执行。

## 9. 注意事项

- 本方案不依赖 `crond`。`10.107.12.8` 当前未安装 `cronie/crond`，并且 yum 源访问 `cronie` 包时出现过 `403 Forbidden`。
- 本方案不使用 `systemd timer`。`systemd` 仅用于守护常驻脚本。
- 若修改 `REPLAY_INTERVAL_SECONDS`、`MBPS`、`PCAP_DIR` 等参数，需要修改 `/etc/systemd/system/pcaps-replay.service` 后执行：

```bash
systemctl daemon-reload
systemctl restart pcaps-replay.service
```

- 曾观察到 `/home/work/pcaps_dataset/software_version_test/ssh_traffic.pcap` 回放时出现 `Message too long` 警告，但该轮整体日志最终显示 `done failed=0`。
