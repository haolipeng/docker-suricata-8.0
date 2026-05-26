# Suricata 容器运行与 IEC61850/MMS 验证

本文档用于验证已构建好的 `suricata:8.0.4-offline` 镜像。容器启动统一使用 `run-suricata-docker.sh` 脚本。

## 1. 进入目录

```bash
cd /home/work/docker-suricata/8.0
```

## 2. 确认脚本包含 NET_RAW

实时抓包需要 `NET_RAW`。先确认脚本中已经包含该 capability：

```bash
grep -n 'NET_RAW' run-suricata-docker.sh
```

期望看到：

```text
--cap-add NET_RAW
```

## 3. 确认镜像存在

```bash
docker image inspect suricata:8.0.4-offline >/dev/null && echo "image ok"
```

## 4. 启动容器

`CAPTURE_IFACE` 必须设置为宿主机上的抓包网卡，例如 `ens33`。

```bash
CAPTURE_IFACE=ens33 ./run-suricata-docker.sh
```

脚本会固定挂载以下宿主机目录：

```text
/var/log/suricata-docker -> /var/log/suricata
/var/lib/suricata-docker -> /var/lib/suricata
/var/run/suricata-docker -> /var/run/suricata
/etc/suricata-docker     -> /etc/suricata
```

## 5. 日志轮转（logrotate）

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

## 6. 确认容器 capability

```bash
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
```

期望看到：

```json
["NET_ADMIN","NET_RAW","SYS_NICE"]
```

## 7. 清理旧日志

清理旧日志，避免本次验证结果和历史日志混在一起：

```bash
rm -f /var/log/suricata-docker/eve.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log
```

## 8. 重启容器

```bash
docker restart suricata
```

## 9. 确认 Suricata 已启动

```bash
docker logs --tail 50 suricata
```

看到以下内容后再继续：

```text
Engine started.
```

## 10. 慢速回放 MMS 流量

使用 `tcpreplay` 将测试 pcap 回放到启动容器时指定的网卡。建议先用 `--pps=1` 慢速回放，避免虚拟网卡环境下实时抓包不完整。

```bash
tcpreplay --pps=1 -i ens33 /home/work/pcaps_dataset/mms.pcap
```

期望看到：

```text
Successful packets:        22
Failed packets:            0
```

## 11. 查看 IEC61850/MMS 解析记录

事件名是 `iec61850_mms`，不是 `iec61850`。

统计事件类型：

```bash
jq -r '.event_type? // empty' /var/log/suricata-docker/eve*.json | sort | uniq -c
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
}' /var/log/suricata-docker/eve*.json
```

如果没有 `iec61850_mms`，检查 TCP/102 是否被完整捕获：

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
}' /var/log/suricata-docker/eve.json
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
