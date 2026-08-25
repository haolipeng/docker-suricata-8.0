# Suricata Docker 客户环境验证手册

本文档用于在客户环境验证已构建好的 Suricata Docker 镜像。验证方式为：容器使用宿主机网络命名空间，直接抓取宿主机物理网卡上的真实流量。

容器统一使用 [`run-suricata-docker.sh`](run-suricata-docker.sh) 启动；镜像名通过 `SURICATA_IMAGE` 指定，抓包网卡通过 `CAPTURE_IFACES` 指定，可传一个或多个网口。

> veth pair 本机回放测试不属于客户现场主流程，已单独整理到 [`VETH_PAIR_VERIFY.md`](VETH_PAIR_VERIFY.md)。

## 1. 前置条件

进入部署目录：

```bash
cd /home/work/docker-suricata/8.0
```

确认 Docker 可用：

```bash
docker version
```

确认镜像存在。按实际交付架构选择镜像标签：

```bash
docker image ls | grep suricata
docker image inspect suricata:8.0.4-amd64-offline >/dev/null
# 或：
docker image inspect suricata:8.0.4-arm64-offline >/dev/null
```

确认宿主机已安装常用排查工具：

```bash
command -v ip
command -v tcpdump
command -v jq
```

`jq` 只用于解析 EVE JSON。如果客户环境没有 `jq`，可以先用 `grep` 或把日志文件拷贝到有 `jq` 的机器上分析。

## 2. 选择物理抓包网卡

列出宿主机网卡：

```bash
ip -br link
ip -br addr
```

选择承载 IEC61850/MMS 流量的物理网卡，例如 `eth1`、`eno1`、`ens33`、`enp3s0`。如果客户现场有 2-3 个镜像口或 TAP 口需要同时监听，逐个确认后都加入抓包网卡列表。不要选择 `lo`、`docker0`、`br-*`、`veth*` 这类本机虚拟接口作为客户现场主验证接口。

用 `tcpdump` 在宿主机上确认该网卡能看到目标流量。MMS 默认端口为 TCP/102：

```bash
CAPTURE_IFACES=eth1
for iface in ${CAPTURE_IFACES//,/ }; do
  tcpdump -ni "${iface}" tcp port 102 -c 10
done
```

如果长时间抓不到 TCP/102，先确认该网口是否真的接入了承载 MMS 业务的镜像口、TAP 或测试链路。若网口本身没有接入 TCP/102/MMS 流量，自然抓包无流量是链路条件问题，不代表 Suricata 容器或协议解析失败；这种情况下只能通过真实 pcap 回放验证解析能力，不能证明当前物理链路存在 MMS 流量。

如果客户现场流量不是 TCP/102，先用更宽的条件确认网卡确实有业务流量：

```bash
for iface in ${CAPTURE_IFACES//,/ }; do
  tcpdump -ni "${iface}" -c 20
done
```

多网口场景逐个确认：

```bash
for iface in eth1 eth2 eth3; do
  tcpdump -ni "${iface}" tcp port 102 -c 10
done
```

## 3. 启动 Suricata 容器

启动脚本要求显式指定 `CAPTURE_IFACES`，避免误抓默认网卡。

amd64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES=eth1 \
./run-suricata-docker.sh
```

arm64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-offline \
CAPTURE_IFACES=eth1 \
./run-suricata-docker.sh
```

多网口示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2 eth3" \
./run-suricata-docker.sh
```

也可以使用逗号分隔：

```bash
CAPTURE_IFACES=eth1,eth2,eth3 ./run-suricata-docker.sh
```

脚本会展开为 Suricata 参数 `-i eth1 -i eth2 -i eth3`。这种方式适合多个网口统一分析、统一输出到同一套 EVE 日志的场景。如果客户要求按网口拆分日志或单独启停，建议启动多个容器，并为每个容器使用不同的 `CONTAINER_NAME`、日志目录和运行目录。

如需避免覆盖已有同名容器，可指定临时容器名：

```bash
CONTAINER_NAME=suricata-test \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2" \
./run-suricata-docker.sh
```

注意：默认容器名是 `suricata`。脚本会先执行 `docker rm -f "${CONTAINER_NAME}"`，再创建新容器。因此客户现场复测前应确认允许替换同名容器。

## 4. 配置文件与持久化目录

容器挂载以下宿主机目录：

| 宿主机路径 | 容器路径 | 用途 |
|------------|----------|------|
| `/usr/share/suricata-docker/rules` | `/usr/share/suricata/rules` | 产品规则（可现场修改；首次从镜像 `rules.dist` 填充） |
| `/usr/share/suricata/iprep`（镜像内） | 同路径 | 随镜像发布的 IP Reputation 类别定义 |
| `/etc/suricata-docker` | `/etc/suricata` | `suricata.yaml` 和客户 SSH 白名单 |
| `/var/log/suricata-docker` | `/var/log/suricata` | `eve.json`、`fast.log`、`stats.log`、`suricata.log` |
| `/var/lib/suricata-docker` | `/var/lib/suricata` | 运行状态和缓存（不存放产品规则） |
| `/var/run/suricata-docker` | `/var/run/suricata` | Unix command socket |

默认 `SURICATA_USE_IMAGE_YAML=no`：

- 首次启动时，如果宿主机没有 `/etc/suricata-docker/suricata.yaml`，entrypoint 会从镜像内 `/etc/suricata.dist` 复制一份默认配置。
- 首次启动或 `iprep` 目录内文件缺失时，会创建 `/etc/suricata-docker/iprep/ssh-allow.list`；已有白名单永不覆盖。
- 默认配置会在 EVE `filename: eve.%Y-%m-%d_%H-%M-%S.json` 后启用 `rotate-interval: 2h`，即 Suricata 每 2 小时切分一次 `eve.*.json`。
- 如果宿主机已有旧的 `/etc/suricata-docker/suricata.yaml` 且 EVE 配置块缺少 `rotate-interval`，entrypoint 默认会补入 `rotate-interval: 2h`。如需关闭该兜底行为，可设置 `SURICATA_ENSURE_EVE_ROTATE_INTERVAL=no`。
- 日常修改配置时，编辑宿主机文件后重启容器即可：

```bash
vi /etc/suricata-docker/suricata.yaml
docker restart suricata
```

客户现场如果习惯进入容器内修改配置，也可以这样操作。容器内的 `/etc/suricata/suricata.yaml` 实际对应宿主机的 `/etc/suricata-docker/suricata.yaml`，修改会持久化到宿主机挂载目录。

```bash
docker exec -it suricata /bin/bash
vi /etc/suricata/suricata.yaml
exit
```

如果镜像内没有 `vi`，可改用 `sed`、`cat` 等命令，或回到宿主机直接编辑 `/etc/suricata-docker/suricata.yaml`。

重启前建议先做配置检查。`eth1` 替换为实际抓包网卡，多网口时追加多个 `-i`：

```bash
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml -i eth1
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml -i eth1 -i eth2 -i eth3
```

配置检查通过后，在宿主机重启容器让配置生效：

```bash
docker restart suricata
docker logs --tail 80 suricata
```

不要在容器内修改 `/etc/suricata.dist/suricata.yaml`。该目录是镜像内默认配置备份，不是 Suricata 运行时读取的配置路径。

### 4.1 产品规则热更新与 SSH 白名单

产品规则挂在宿主机 `/usr/share/suricata-docker/rules`，对应容器内 `/usr/share/suricata/rules`。`run-suricata-docker.sh` 会 `docker rm -f` 再建容器，但规则在宿主机上，不会随容器一起丢掉。

默认 `SURICATA_USE_IMAGE_RULES=no`：

- 首次启动时，宿主机缺哪个规则文件，entrypoint 就从镜像内 `/usr/share/suricata/rules.dist` 复制哪个。
- 已有规则文件永不覆盖，现场改动会保留。
- 新镜像里新增的规则文件，下次启动会补到宿主机；已改过的同名文件仍以现场为准。

现场改已有 `.rules` 文件后，用 `USR2` 热加载，不必重启容器：

```bash
vi /usr/share/suricata-docker/rules/mms-critical-object.rules
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml
docker kill --signal USR2 suricata
docker logs --tail 80 suricata
```

也可以 `docker exec` 编辑容器内 `/usr/share/suricata/rules/`，改动同样写到宿主机挂载目录。若现场使用 unix command socket，可改执行 `suricatasc -c reload-rules`。

新增一个 yaml 里尚未列出的规则文件时，还要改 `/etc/suricata-docker/suricata.yaml` 的 `rule-files:`。这是改配置，Suricata 不会随 `USR2` 重读 yaml，需要 `docker restart suricata`。

若要把现场规则恢复成镜像默认：

```bash
SURICATA_USE_IMAGE_RULES=yes \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2" \
./run-suricata-docker.sh
```

不要修改镜像内 `/usr/share/suricata/rules.dist`。那是填充用的备份，不是运行时读取路径。

客户 SSH 白名单仍只维护：

```text
/etc/suricata-docker/iprep/ssh-allow.list
```

每行格式为 `<IPv4|IPv6|CIDR>,1,<1-127 分值>`，例如：

```text
10.1.1.50,1,127
10.2.0.0/16,1,127
```

白名单随规则重载重新读取；`/usr/share/suricata/iprep/categories.txt` 的类别定义变更必须通过新镜像发布并重启容器。

如需用镜像内默认配置覆盖宿主机配置：

```bash
SURICATA_USE_IMAGE_YAML=yes \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACES="eth1 eth2" \
./run-suricata-docker.sh
```

## 5. 启动后检查

确认容器运行：

```bash
docker ps --filter name=suricata
```

确认 Suricata 引擎启动：

```bash
docker logs --tail 80 suricata
```

期望看到：

```text
Engine started.
```

确认容器抓包参数：

```bash
docker inspect suricata --format '{{json .Config.Image}} {{json .Args}}'
```

期望 `Args` 中包含：

```text
-i eth1 -c /etc/suricata/suricata.yaml
```

多网口时应包含：

```text
-i eth1 -i eth2 -i eth3 -c /etc/suricata/suricata.yaml
```

确认 capability：

```bash
docker inspect suricata --format '{{json .HostConfig.CapAdd}}'
```

期望包含 `NET_ADMIN`、`NET_RAW`、`SYS_NICE`。不同 Docker 版本可能显示为带 `CAP_` 前缀的形式，例如：

```json
["CAP_NET_ADMIN","CAP_NET_RAW","CAP_SYS_NICE"]
```

确认日志文件开始生成：

```bash
ls -lh /var/log/suricata-docker
tail -f /var/log/suricata-docker/suricata.log
```

确认容器内 JSON 清理 cron 已启动：

```bash
docker exec suricata ps -ef | grep crond
docker exec suricata ls -l /usr/local/bin/suricata-json-cleanup /etc/cron.d/suricata-json-cleanup
```

## 6. 清理旧日志

正式验证前建议清理旧日志，避免历史事件影响统计：

```bash
rm -f /var/log/suricata-docker/eve*.json \
      /var/log/suricata-docker/fast.log \
      /var/log/suricata-docker/stats.log \
      /var/log/suricata-docker/suricata.log

docker restart suricata
```

重启后再次确认：

```bash
docker logs --tail 50 suricata
```

看到 `Engine started.` 后再开始业务验证。

## 7. 验证 IEC61850/MMS 解析

确认 EVE 输出启用了 `iec61850_mms`：

```bash
grep -n 'iec61850_mms' /etc/suricata-docker/suricata.yaml
```

让客户现场产生或等待一段 TCP/102 MMS 业务流量。前提是指定的抓包网口已接入实际承载 MMS 的链路；如果某个网口没有接入 TCP/102/MMS 流量，本节的自然流量验证应记录为“该链路无 MMS 流量”，不要误判为 Suricata 解析失败。

然后定位最新非空 EVE 文件：

```bash
EVE_FILE=$(find /var/log/suricata-docker -maxdepth 1 -type f -name 'eve*.json' -size +0c -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
echo "${EVE_FILE}"
```

统计事件类型：

```bash
jq -r '.event_type? // empty' "${EVE_FILE}" | sort | uniq -c
```

期望能看到：

```text
iec61850_mms
```

事件名是 `iec61850_mms`，不是 `iec61850`。

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

检查 TCP/102 flow 识别结果：

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

`flow` 记录可能在流结束、超时或 Suricata 停止时才稳定刷出。如果刚产生流量后没有看到 flow，可等待一段时间，或在允许的维护窗口停止容器后再查。

## 8. 日志轮转

仓库内模板见 [`suricata.logrotate`](suricata.logrotate)。容器内日志目录是 `/var/log/suricata`，宿主机 logrotate 应配置挂载后的路径 `/var/log/suricata-docker`。EVE JSON 文件由 Suricata 的 `filename` / `rotate-interval` 配置生成，并由容器内清理脚本清理；宿主机 logrotate 不应匹配 `eve*.json`，避免破坏宿主机侧读取方约定的文件名格式。

示例 `/etc/logrotate.d/suricata`：

```text
/var/log/suricata-docker/*.log {
    daily
    missingok
    rotate 3
    nocompress
    sharedscripts
    postrotate
        export SURICATA_SOCKET=/var/run/suricata-docker/suricata-command.socket
        suricatasc -c reopen-log-files
    endscript
}
```

安装后可干跑检查：

```bash
logrotate -d /etc/logrotate.d/suricata
```

## 9. 停止容器

推荐使用 [`stop-suricata-docker.sh`](stop-suricata-docker.sh)。脚本在 `docker stop` 前默认等待 30 秒，便于刷完尾部报文：

```bash
./stop-suricata-docker.sh
```

仅停止、不删除容器：

```bash
docker stop suricata
```

停止并删除容器：

```bash
docker rm -f suricata
```

如果启动时指定了 `CONTAINER_NAME=suricata-test`，停止时也应使用对应容器名：

```bash
CONTAINER_NAME=suricata-test ./stop-suricata-docker.sh
```

## 10. 常见问题

### 10.1 启动时报网卡不存在

现象：

```text
error: interface not found: eth1
```

处理：

```bash
ip -br link
```

确认客户现场实际物理网卡名，并重新设置 `CAPTURE_IFACES`。

### 10.2 旧规则路径配置被拒绝

若挂载目录保留了旧配置，entrypoint 会明确拒绝启动：

```text
ERROR: the active Suricata configuration still loads suricata.rules.
```

删除活动的 `suricata.rules` 加载项，并将 `default-rule-path` 改为 `/usr/share/suricata/rules`。注释中的旧路径不会触发检查。

### 10.3 有 flow 但没有 `iec61850_mms`

优先检查：

```bash
docker inspect suricata --format '{{json .Args}}'
grep -n 'iec61850_mms' /etc/suricata-docker/suricata.yaml
for iface in ${CAPTURE_IFACES//,/ }; do
  tcpdump -ni "${iface}" tcp port 102 -c 10
done
jq -c 'select(.event_type == "flow" and ((.dest_port == 102) or (.src_port == 102)))' "${EVE_FILE}"
```

多网口时逐个抓包确认：

```bash
for iface in eth1 eth2 eth3; do
  tcpdump -ni "${iface}" tcp port 102 -c 10
done
```

常见原因：

| 原因 | 检查点 |
|------|--------|
| 抓错网卡 | `docker inspect` 中 `-i` 是否为客户物理网卡 |
| 抓包网口本身未接入 MMS/TCP/102 流量 | 宿主机逐个网口执行 `tcpdump -ni "$iface" tcp port 102` 是否能看到包；交换机镜像/TAP 是否把 MMS 流量送到该口 |
| 客户现场暂时没有 MMS 流量 | 业务侧是否正在产生 MMS；可等待业务窗口或使用真实 pcap 回放验证解析能力 |
| 报文不完整或只看到单向流量 | flow 中 `pkts_toserver`、`pkts_toclient` 是否都有计数 |
| 配置未启用 EVE 类型 | `suricata.yaml` 中是否包含 `iec61850_mms` |

### 10.4 `event_type == "iec61850"` 没有输出

这是正常现象。当前实现的事件名为：

```text
iec61850_mms
```

### 10.5 EVE 文件名不是 `eve.json`

如果配置了按时间切分，文件名可能类似：

```text
eve.2026-07-24_23-29-46.json
```

验证时应使用“最新非空 EVE 文件”的查找命令，而不是固定读取 `/var/log/suricata-docker/eve.json`。
