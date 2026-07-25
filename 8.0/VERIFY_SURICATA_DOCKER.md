# Suricata 容器运行与 IEC61850/MMS 验证

本文档用于验证已构建好的 Suricata 离线镜像。容器启动统一使用 `run-suricata-docker.sh` 脚本；镜像名可通过 `SURICATA_IMAGE` 覆盖，例如 `suricata:8.0.4-amd64-offline` 或 `suricata:8.0.4-arm64-offline`。

## 1. 创建 veth pair 测试接口

进入目录

```
cd /home/work/docker-suricata/8.0
```

本文档默认使用 veth pair 做本机流量回放验证：Suricata 抓 `veth-suri0`，`tcpreplay` 从 `veth-suri1` 回放 pcap。这样不依赖物理网卡，也能避免把测试流量打到生产网络。

```bash
ip link add veth-suri0 type veth peer name veth-suri1
ip link set veth-suri0 up
ip link set veth-suri1 up
```

如果接口已存在，可先清理后重建：

```bash
ip link del veth-suri0 2>/dev/null || true
ip link add veth-suri0 type veth peer name veth-suri1
ip link set veth-suri0 up
ip link set veth-suri1 up
```

`tcpreplay` 直接回放二层报文，veth 两端不需要配置 IP。若需要用 `ping`、`curl`、`nc` 等工具额外生成测试流量，可以再给两端配置一个未被占用的网段，例如：

```bash
ip addr add 192.168.200.1/24 dev veth-suri0
ip addr add 192.168.200.2/24 dev veth-suri1
```

## 2. 启动容器

`CAPTURE_IFACE` 必须设置为宿主机上的抓包接口。使用本文档的 veth pair 方案时，设置为 `veth-suri0`。

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE=veth-suri0 \
./run-suricata-docker.sh
```

如果要验证 arm64 镜像，将 `SURICATA_IMAGE` 改成对应标签：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-offline \
CAPTURE_IFACE=veth-suri0 \
./run-suricata-docker.sh
```

也可以抓宿主机物理网卡，例如 `eth3`、`eno1`、`ens33`，但回放 pcap 时应确认不会影响实际网络：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline CAPTURE_IFACE=eth3 ./run-suricata-docker.sh
```

### 2.1 宿主机配置（suricata.yaml）

容器将 **`/etc/suricata-docker`** 挂载为 **`/etc/suricata`**。默认 **`SURICATA_USE_IMAGE_YAML=no`**：

- **首次启动**：若宿主机尚无 `suricata.yaml`，entrypoint 从镜像内 `/etc/suricata.dist` 复制一份。
- **日常改配置**：编辑宿主机文件后重启容器即可（Suricata 启动时重新读取 `-c` 指定路径）：

```bash
vi /etc/suricata-docker/suricata.yaml
docker restart suricata
```

- **从镜像恢复默认 suricata.yaml**（会覆盖宿主机手改）：

```bash
SURICATA_USE_IMAGE_YAML=yes SURICATA_IMAGE=suricata:8.0.4-amd64-offline CAPTURE_IFACE=veth-suri0 ./run-suricata-docker.sh
# 或手动：docker run --rm --entrypoint cat suricata:TAG /etc/suricata.dist/suricata.yaml > /etc/suricata-docker/suricata.yaml
```

镜像内模板路径 **`/etc/suricata.dist`** 仅作“出厂默认”备份，Suricata 进程不直接读该目录。

## 3. 日志轮转（logrotate）

仓库内模板见 [`suricata.logrotate`](suricata.logrotate)。容器内日志目录是 `/var/log/suricata`，**宿主机 logrotate 应写挂载后的路径** `/var/log/suricata-docker`。

将下面内容保存为 `/etc/logrotate.d/suricata`（或复制本仓库文件后改路径）：

```text
/var/log/suricata-docker/*.log /var/log/suricata-docker/*.json {
    daily
    missingok
    rotate 3
    nocompress
    sharedscripts
    postrotate
        suricatasc -c reopen-log-files
    endscript
}
```

| 配置项 | 含义 |
|--------|------|
| 路径 | 轮转宿主机上的 `*.log`、`*.json`（如 `suricata.log`、`eve.json`、`fast.log`、`stats.log`）。 |
| `daily` | 每天轮转一次（由系统 cron 中的 `logrotate` 触发）。 |
| `missingok` | 日志文件不存在时不报错。 |
| `rotate 3` | 除当前文件外最多保留 3 份历史（如 `eve.json.1` … `.3`）。 |
| `nocompress` | 历史日志不 gzip，省 CPU，占用磁盘略多。 |
| `sharedscripts` | 多个匹配文件在同一次轮转里只执行一次 `postrotate`。 |
| `postrotate` … `suricatasc -c reopen-log-files` | 轮转后通知**正在运行的 Suricata** 重新打开日志；否则进程可能仍写入已改名的旧文件，新文件里没有新日志。 |

**流程简述：** 每天把旧日志改名 → 创建新的空日志 → `suricatasc` 让 Suricata 切换到新文件 → 只保留最近 3 轮。

**注意：**

- `suricatasc` 需能访问 Suricata 的 Unix socket（默认常在 `/var/run/suricata/suricata-command.socket`）。本部署对应宿主机 **`/var/run/suricata-docker/suricata-command.socket`**；若命令在宿主机执行，可设置例如 `export SURICATA_SOCKET=/var/run/suricata-docker/suricata-command.socket`，或在 `postrotate` 里写 `suricatasc -c reopen-log-files` 前 `export` 该变量（以本机 `suricata.yaml` 中 `unix-command` 配置为准）。
- 安装后可用 `logrotate -d /etc/logrotate.d/suricata` 做干跑检查，确认路径与 `postrotate` 无报错。

## 4. 确认容器 capability

```bash
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
```

期望看到：

```json
["NET_ADMIN","NET_RAW","SYS_NICE"]
```

不同 Docker 版本可能显示为带 `CAP_` 前缀的形式，例如：

```json
["CAP_NET_ADMIN","CAP_NET_RAW","CAP_SYS_NICE"]
```

两种输出语义一致，确认包含 `NET_ADMIN`、`NET_RAW`、`SYS_NICE` 三项即可。

## 5. 清理旧日志

清理旧日志，避免本次验证结果和历史日志混在一起：

```bash
rm -f /var/log/suricata-docker/eve*.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log
```

## 6. 确认 EVE JSON 定时切分配置

pcap 测试建议使用较短轮转周期，便于观察新 EVE 文件。确认宿主机挂载配置中存在：

```bash
grep -n 'rotate-interval' /etc/suricata-docker/suricata.yaml
```

期望测试值为：

```yaml
rotate-interval: minute
```

生产环境可改为 `2h` 等更长周期。

## 7. 重启容器

```bash
docker restart suricata
```

## 8. 确认 Suricata 已启动

```bash
docker logs --tail 50 suricata
```

看到以下内容后再继续：

```text
Engine started.
```

同时确认容器内 JSON 清理 cron 已启动：

```bash
docker exec suricata ps -ef | grep crond
docker exec suricata ls -l /usr/local/bin/suricata-json-cleanup /etc/cron.d/suricata-json-cleanup
```

## 9. 慢速回放 MMS 流量

使用 `tcpreplay` 将测试 pcap 回放到 veth pair 的发送端 `veth-suri1`。Suricata 抓包端是 `veth-suri0`，不要把 pcap 回放到同一个接口上。建议先用 `--pps=1` 慢速回放，避免虚拟网卡环境下实时抓包不完整。

回放前可先用 `tcpdump` 在宿主机确认 veth pair 能看到报文：

```bash
tcpdump -ni veth-suri0 -c 10
```

另开一个终端执行：

```bash
tcpreplay --pps=1 -i veth-suri1 /home/work/pcaps_dataset/mms.pcap
```

期望看到：

```text
Successful packets:        22
Failed packets:            0
```

## 10. 查看 IEC61850/MMS 解析记录

事件名是 `iec61850_mms`，不是 `iec61850`。

先定位本次最新的非空 EVE 文件，避免历史轮转日志干扰统计：

```bash
EVE_FILE=$(find /var/log/suricata-docker -maxdepth 1 -type f -name 'eve*.json' -size +0c -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
echo "${EVE_FILE}"
```

统计事件类型：

```bash
jq -r '.event_type? // empty' "${EVE_FILE}" | sort | uniq -c
```

期望看到类似：

```text
8 iec61850_mms
```

查看 IEC61850/MMS 摘要：

```bash
jq -c 'select(.event_type == "iec61850_mms") |
{
  timestamp,
  src_ip,
  src_port,
  dest_ip,
  dest_port,
  pdu_type: .iec61850_mms.pdu_type,
  direction: .iec61850_mms.direction,
  service: .iec61850_mms.service
}' "${EVE_FILE}"
```

如果没有 `iec61850_mms`，检查 TCP/102 是否被完整捕获。flow 记录通常在流结束、超时或 Suricata 停止时刷出；如果刚回放完查不到 flow，可先等待一段时间，或按“停止容器”步骤停止 Suricata 后再查。

```bash
jq -c 'select(.event_type == "flow" and ((.dest_port == 102) or (.src_port == 102))) |
{
  app_proto,
  src_ip,
  src_port,
  dest_ip,
  dest_port,
  state: .flow.state,
  reason: .flow.reason,
  pkts_toserver: .flow.pkts_toserver,
  pkts_toclient: .flow.pkts_toclient,
  exception_policy: .flow.exception_policy
}' "${EVE_FILE}"
```

## 停止容器

推荐使用 [`stop-suricata-docker.sh`](stop-suricata-docker.sh)（`docker stop` 前默认等待 30 秒，便于刷完尾部报文）：

```bash
./stop-suricata-docker.sh
```

仅停止、不删容器：

```bash
docker stop suricata
```

停止并删除容器：

```bash
docker rm -f suricata
```

清理 veth pair：

```bash
ip link del veth-suri0 2>/dev/null || true
```

## 常见现象

`event_type == "iec61850"` 没有输出是正常的，当前实现的事件名为 `iec61850_mms`。

如果日志中出现以下警告：

```text
W: detect: No rule files match the pattern /var/lib/suricata/rules/suricata.rules
W: detect: 1 rule files specified, but no rules were loaded!
```

说明没有加载检测规则，因此不会产生 alert；这不影响 IEC61850/MMS 协议解析和 `iec61850_mms` EVE 事务日志。

如果 `eve.json` 中只有 `flow`，但没有 `iec61850_mms`，优先检查以下几项：

```bash
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
grep -n 'iec61850_mms' /etc/suricata-docker/suricata.yaml
jq -c 'select(.event_type == "flow" and ((.dest_port == 102) or (.src_port == 102)))' /var/log/suricata-docker/eve.json
```
