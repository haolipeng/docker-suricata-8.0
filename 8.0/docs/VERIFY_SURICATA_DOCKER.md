# Suricata Docker 客户环境验证手册

本文档用于在客户环境验证已构建好的 Suricata Docker 镜像。容器使用宿主机网络命名空间，直接抓取宿主机物理网卡流量。

本机 veth pair 回放测试见 [`VETH_PAIR_VERIFY.md`](VETH_PAIR_VERIFY.md)。

## 1. 前置检查

```bash
cd /home/work/docker-suricata/8.0

docker image ls | grep suricata
command -v ip
command -v jq
```

按交付架构确认镜像存在：

```bash
docker image inspect suricata:8.0.4-amd64-offline >/dev/null
# 或：
docker image inspect suricata:8.0.4-arm64-offline >/dev/null
```

验证结果：

- Suricata 镜像存在。
- 宿主机存在 `ip`、`jq`。

## 2. 清理测试环境

为保证每次测试都是干净环境，启动容器前清理上一次测试留下的配置、规则、日志、状态和运行时文件：

```bash
docker rm -f suricata 2>/dev/null || true

rm -rf /etc/suricata-docker/*
rm -rf /usr/share/suricata-docker/rules/*
rm -rf /var/log/suricata-docker/*
rm -rf /var/lib/suricata-docker/*
rm -rf /var/run/suricata-docker/*
```

清理范围：

| 路径 | 内容 |
|------|------|
| `/etc/suricata-docker` | 运行时配置、SSH 白名单 |
| `/usr/share/suricata-docker/rules` | 运行时产品规则 |
| `/var/log/suricata-docker` | `eve*.json`、`fast.log`、`stats.log`、`suricata.log` |
| `/var/lib/suricata-docker` | Suricata 运行状态和缓存 |
| `/var/run/suricata-docker` | socket、pid 等运行时文件 |

不要删除镜像内的 `/etc/suricata.dist` 或 `/usr/share/suricata/rules.dist`，它们用于容器启动时恢复默认配置和规则。

## 3. 选择抓包网卡

列出宿主机网卡：

```bash
ip -br link
ip -br addr
```

如果机器的 IP 为 `10.107.19.201`，抓包网口为 `ens33` 和 `ens37`：

```bash
CAPTURE_IFACES="ens33 ens37"
```

多网口场景：

```bash
CAPTURE_IFACES="eth1 eth2 eth3"
```

验证结果：

- 使用客户现场实际承载 MMS 流量的物理网卡。
- 不使用 `lo`、`docker0`、`br-*`、`veth*` 这类本机虚拟接口。

## 4. 启动容器

amd64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES=eth1 \
./scripts/run-suricata-docker.sh
```

arm64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-offline \
CAPTURE_IFACES=eth1 \
./scripts/run-suricata-docker.sh
```

多网口示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2 eth3" \
./scripts/run-suricata-docker.sh
```

指定临时容器名：

```bash
CONTAINER_NAME=suricata-test \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2" \
./scripts/run-suricata-docker.sh
```

注意：默认容器名为 `suricata`。脚本会先删除同名旧容器，再创建新容器。

## 5. 启动后检查

```bash
docker ps --filter name=suricata
docker logs --tail 80 suricata
docker inspect suricata --format '{{json .Config.Image}} {{json .Args}}'
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
ls -lh /var/log/suricata-docker
docker exec suricata ps -ef | grep crond
```

验证结果：

- 容器处于运行状态。
- 日志中出现 `Engine started.`。
- `Args` 包含 `-i eth1 -c /etc/suricata/suricata.yaml`；多网口时应包含多个 `-i`。
- capability 包含 `NET_ADMIN`、`NET_RAW`、`SYS_NICE`。
- `/var/log/suricata-docker` 开始生成日志文件。
- 容器内 `crond` 正在运行。

## 6. 配置和规则检查

运行时配置和规则位于宿主机挂载目录：

| 宿主机路径 | 容器路径 | 用途 |
|------------|----------|------|
| `/etc/suricata-docker` | `/etc/suricata` | 配置和 SSH 白名单 |
| `/usr/share/suricata-docker/rules` | `/usr/share/suricata/rules` | 产品规则 |
| `/var/log/suricata-docker` | `/var/log/suricata` | 日志 |
| `/var/lib/suricata-docker` | `/var/lib/suricata` | 运行状态和缓存 |
| `/var/run/suricata-docker` | `/var/run/suricata` | command socket |

配置检查：

```bash
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml -i eth1
```

多网口配置检查：

```bash
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml -i eth1 -i eth2 -i eth3
```

规则热加载：

```bash
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml
docker kill --signal USR2 suricata
docker logs --tail 80 suricata
```

验证结果：

- 配置检查通过。
- 修改已有 `.rules` 文件后，可以通过 `USR2` 热加载。
- 新增规则文件并修改 `rule-files:` 后，需要 `docker restart suricata`。

## 7. 清理旧日志

正式验证前建议清理旧日志，避免历史事件影响统计：

```bash
rm -f /var/log/suricata-docker/eve*.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log

docker restart suricata
docker logs --tail 50 suricata
```

验证结果：

- 容器重启后日志中再次出现 `Engine started.`。
- 后续统计只基于本次验证产生的新日志。

## 8. 回放 MMS pcap

使用 `/home/work/pcaps_dataset/mms.pcap` 回放 MMS 流量。`REPLAY_IFACE` 设置为实际回放网口；如果按本文档在 `10.107.19.201` 上测试，可使用 `ens37`。

```bash
PCAP=/home/work/pcaps_dataset/mms.pcap
REPLAY_IFACE=ens37

test -f "${PCAP}"
tcpreplay --pps=1 -i "${REPLAY_IFACE}" "${PCAP}"
sleep 30
```

验证结果：

- pcap 文件存在。
- `tcpreplay` 输出 `Successful packets` 大于 0。
- `Failed packets` 为 0。

## 9. 验证 MMS 解析

确认 EVE 输出启用了 `iec61850_mms`：

```bash
grep -n 'iec61850_mms' /etc/suricata-docker/suricata.yaml
```

等待客户现场产生 TCP/102 MMS 流量后，定位最新非空 EVE 文件：

```bash
EVE_FILE=$(find /var/log/suricata-docker -maxdepth 1 -type f -name 'eve*.json' -size +0c -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
echo "${EVE_FILE}"
```

统计事件类型：

```bash
jq -r '.event_type? // empty' "${EVE_FILE}" | sort | uniq -c
```

查看 MMS 事件：

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

查看 TCP/102 flow：

```bash
jq -c 'select(.event_type == "flow" and ((.dest_port == 102) or (.src_port == 102))) |
{
  app_proto,
  src_ip,
  src_port,
  dest_ip,
  dest_port,
  state: .flow.state,
  pkts_toserver: .flow.pkts_toserver,
  pkts_toclient: .flow.pkts_toclient
}' "${EVE_FILE}"
```

验证结果：

- EVE 文件存在且非空。
- 事件类型中出现 `iec61850_mms`。
- TCP/102 flow 中 `app_proto` 为 `iec61850-mms`。
- 如果有 flow 但无 MMS 事件，检查是否抓错网卡、是否只有单向流量、配置中是否启用 `iec61850_mms`。

## 10. 结果记录

| 项目 | 结果 | 证据/备注 |
|------|------|-----------|
| 镜像存在 |  |  |
| 抓包网卡确认 |  |  |
| 容器启动 |  |  |
| Suricata 引擎启动 |  |  |
| 配置检查 |  |  |
| pcap 回放 |  |  |
| EVE 生成 |  |  |
| MMS 事件 |  |  |
| TCP/102 flow |  |  |
