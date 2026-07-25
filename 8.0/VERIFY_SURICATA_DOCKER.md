# Suricata Docker 客户环境验证手册

本文档用于在客户环境验证已构建好的 Suricata Docker 镜像。验证方式为：容器使用宿主机网络命名空间，直接抓取宿主机物理网卡上的真实流量。

容器统一使用 [`run-suricata-docker.sh`](run-suricata-docker.sh) 启动；镜像名通过 `SURICATA_IMAGE` 指定，抓包网卡通过 `CAPTURE_IFACE` 指定。

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

选择承载 IEC61850/MMS 流量的物理网卡，例如 `eth1`、`eno1`、`ens33`、`enp3s0`。不要选择 `lo`、`docker0`、`br-*`、`veth*` 这类本机虚拟接口作为客户现场主验证接口。

用 `tcpdump` 在宿主机上确认该网卡能看到目标流量。MMS 默认端口为 TCP/102：

```bash
CAPTURE_IFACE=eth1
tcpdump -ni "${CAPTURE_IFACE}" tcp port 102 -c 10
```

如果客户现场流量不是 TCP/102，先用更宽的条件确认网卡确实有业务流量：

```bash
tcpdump -ni "${CAPTURE_IFACE}" -c 20
```

## 3. 启动 Suricata 容器

启动脚本要求显式指定 `CAPTURE_IFACE`，避免误抓默认网卡。

amd64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE=eth1 \
./run-suricata-docker.sh
```

arm64 示例：

```bash
SURICATA_IMAGE=suricata:8.0.4-arm64-offline \
CAPTURE_IFACE=eth1 \
./run-suricata-docker.sh
```

如需避免覆盖已有同名容器，可指定临时容器名：

```bash
CONTAINER_NAME=suricata-test \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE=eth1 \
./run-suricata-docker.sh
```

注意：默认容器名是 `suricata`。脚本会先执行 `docker rm -f "${CONTAINER_NAME}"`，再创建新容器。因此客户现场复测前应确认允许替换同名容器。

## 4. 配置文件与持久化目录

容器挂载以下宿主机目录：

| 宿主机路径 | 容器路径 | 用途 |
|------------|----------|------|
| `/etc/suricata-docker` | `/etc/suricata` | `suricata.yaml` 等配置 |
| `/var/log/suricata-docker` | `/var/log/suricata` | `eve.json`、`fast.log`、`stats.log`、`suricata.log` |
| `/var/lib/suricata-docker` | `/var/lib/suricata` | 规则、状态数据 |
| `/var/run/suricata-docker` | `/var/run/suricata` | Unix command socket |

默认 `SURICATA_USE_IMAGE_YAML=no`：

- 首次启动时，如果宿主机没有 `/etc/suricata-docker/suricata.yaml`，entrypoint 会从镜像内 `/etc/suricata.dist` 复制一份默认配置。
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

重启前建议先做配置检查。`eth1` 替换为实际抓包网卡：

```bash
docker exec suricata suricata -T -c /etc/suricata/suricata.yaml -i eth1
```

配置检查通过后，在宿主机重启容器让配置生效：

```bash
docker restart suricata
docker logs --tail 80 suricata
```

不要在容器内修改 `/etc/suricata.dist/suricata.yaml`。该目录是镜像内默认配置备份，不是 Suricata 运行时读取的配置路径。

如需用镜像内默认配置覆盖宿主机配置：

```bash
SURICATA_USE_IMAGE_YAML=yes \
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE=eth1 \
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

让客户现场产生或等待一段 TCP/102 MMS 业务流量。然后定位最新非空 EVE 文件：

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

仓库内模板见 [`suricata.logrotate`](suricata.logrotate)。容器内日志目录是 `/var/log/suricata`，宿主机 logrotate 应配置挂载后的路径 `/var/log/suricata-docker`。

示例 `/etc/logrotate.d/suricata`：

```text
/var/log/suricata-docker/*.log /var/log/suricata-docker/*.json {
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

确认客户现场实际物理网卡名，并重新设置 `CAPTURE_IFACE`。

### 10.2 没有 alert

如果日志中出现：

```text
W: detect: No rule files match the pattern /var/lib/suricata/rules/suricata.rules
W: detect: 1 rule files specified, but no rules were loaded!
```

说明没有加载检测规则，因此不会产生 alert。这不影响 IEC61850/MMS 协议解析和 `iec61850_mms` EVE 事务日志。

### 10.3 有 flow 但没有 `iec61850_mms`

优先检查：

```bash
docker inspect suricata --format '{{json .Args}}'
grep -n 'iec61850_mms' /etc/suricata-docker/suricata.yaml
tcpdump -ni "${CAPTURE_IFACE}" tcp port 102 -c 10
jq -c 'select(.event_type == "flow" and ((.dest_port == 102) or (.src_port == 102)))' "${EVE_FILE}"
```

常见原因：

| 原因 | 检查点 |
|------|--------|
| 抓错网卡 | `docker inspect` 中 `-i` 是否为客户物理网卡 |
| 客户现场暂时没有 MMS 流量 | 宿主机 `tcpdump -ni "$CAPTURE_IFACE" tcp port 102` 是否能看到包 |
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
