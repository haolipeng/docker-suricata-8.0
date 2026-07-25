# Suricata Docker veth Pair 本机回放验证

本文档用于实验室或开发环境的本机 pcap 回放验证。客户现场验证应使用 [`VERIFY_SURICATA_DOCKER.md`](VERIFY_SURICATA_DOCKER.md)，直接抓宿主机物理网卡。

veth pair 验证方式为：Suricata 抓 `veth-suri0`，`tcpreplay` 从 `veth-suri1` 回放 pcap。这样不依赖物理网卡，也能避免把测试流量打到生产网络。

## 1. 创建 veth pair

```bash
cd /home/work/docker-suricata/8.0

ip link del veth-suri0 2>/dev/null || true
ip link add veth-suri0 type veth peer name veth-suri1
ip link set veth-suri0 up
ip link set veth-suri1 up
```

`tcpreplay` 直接回放二层报文，veth 两端不需要配置 IP。若需要用 `ping`、`curl`、`nc` 等工具额外生成测试流量，可以再配置一个未被占用的网段：

```bash
ip addr add 192.168.200.1/24 dev veth-suri0
ip addr add 192.168.200.2/24 dev veth-suri1
```

## 2. 启动容器抓 veth

amd64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE=veth-suri0 \
./run-suricata-docker.sh
```

arm64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-offline \
CAPTURE_IFACE=veth-suri0 \
./run-suricata-docker.sh
```

确认启动成功：

```bash
docker logs --tail 80 suricata
```

期望看到：

```text
Engine started.
```

## 3. 清理旧日志

```bash
rm -f /var/log/suricata-docker/eve*.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log

docker restart suricata
```

## 4. 慢速回放 MMS pcap

建议先用 `--pps=1` 慢速回放，避免虚拟网卡环境下实时抓包不完整。

回放前可先用 `tcpdump` 在宿主机确认 veth pair 能看到报文：

```bash
tcpdump -ni veth-suri0 tcp port 102 -c 10
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

## 5. 查看 IEC61850/MMS 解析记录

定位本次最新非空 EVE 文件：

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

查询 TCP/102 flow：

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
  pkts_toclient: .flow.pkts_toclient
}' "${EVE_FILE}"
```

如果刚回放完查不到 flow，可等待一段时间，或停止容器后再查。flow 的 `reason` 可能是 `timeout` 或 `shutdown`，不应作为严格固定值断言。

## 6. 停止并清理

停止容器：

```bash
WAIT_BEFORE_STOP=5 ./stop-suricata-docker.sh
```

清理 veth pair：

```bash
ip link del veth-suri0 2>/dev/null || true
```

确认接口已删除：

```bash
ip link show veth-suri0
ip link show veth-suri1
```

若两条命令都提示设备不存在，说明清理完成。
