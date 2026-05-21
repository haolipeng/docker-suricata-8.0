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

## 5. 确认容器 capability

```bash
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
```

期望看到：

```json
["NET_ADMIN","NET_RAW","SYS_NICE"]
```

## 6. 清理旧日志

清理旧日志，避免本次验证结果和历史日志混在一起：

```bash
rm -f /var/log/suricata-docker/eve.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log
```

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

## 9. 慢速回放 MMS 流量

使用 `tcpreplay` 将测试 pcap 回放到启动容器时指定的网卡。建议先用 `--pps=1` 慢速回放，避免虚拟网卡环境下实时抓包不完整。

```bash
tcpreplay --pps=1 -i ens33 /home/work/pcaps_dataset/mms.pcap
```

期望看到：

```text
Successful packets:        22
Failed packets:            0
```

## 10. 查看 IEC61850/MMS 解析记录

事件名是 `iec61850_mms`，不是 `iec61850`。

统计事件类型：

```bash
jq -r '.event_type? // empty' /var/log/suricata-docker/eve.json | sort | uniq -c
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
}' /var/log/suricata-docker/eve.json
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

只停止容器：

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
