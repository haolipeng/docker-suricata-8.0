# Suricata veth pair 流量处理能力测试报告

测试依据：[VERIFY_SURICATA_DOCKER.md](VERIFY_SURICATA_DOCKER.md)

## 测试环境

| 项目 | 值 |
|------|----|
| 测试时间 | 2026-07-10 17:29:30 CST +0800 |
| 工作目录 | `/home/work/docker-suricata/8.0` |
| 测试镜像 | `suricata:8.0.4-amd64-offline` |
| 镜像架构 | `amd64/linux` |
| 镜像 ID | `sha256:b5ec3dbbea6262d2d3f51839afd805e117a0ed514fd2f08178b76e13aa03cc2d` |
| Suricata 版本 | `8.0.4 RELEASE` |
| 抓包接口 | `veth-suri0` |
| 回放接口 | `veth-suri1` |
| 测试 pcap | `/home/work/pcaps_dataset/mms.pcap` |
| 回放速率 | `tcpreplay --pps=1` |
| EVE 文件 | `/var/log/suricata-docker/eve.2026-07-10_17-27-10.json` |

## 执行结果

| 测试项 | 命令/检查点 | 期望结果 | 实际结果 | 结论 |
|--------|-------------|----------|----------|------|
| 创建 veth pair | `ip link add veth-suri0 type veth peer name veth-suri1` | 两个接口创建成功并 `UP` | `veth-suri0`、`veth-suri1` 均为 `UP` | 通过 |
| 启动容器 | `SURICATA_IMAGE=suricata:8.0.4-amd64-offline CAPTURE_IFACE=veth-suri0 ./run-suricata-docker.sh` | 容器启动，Suricata 引擎启动 | 日志出现 `Engine started.` | 通过 |
| capability | `docker inspect suricata --format '{{json .HostConfig.CapAdd}}'` | 包含 `NET_ADMIN`、`NET_RAW`、`SYS_NICE` | 实际为 `["CAP_NET_ADMIN","CAP_NET_RAW","CAP_SYS_NICE"]` | 通过，输出格式与文档略有差异 |
| veth 抓包验证 | `tcpdump -ni veth-suri0 -c 10` | 能看到回放流量 | 捕获到 TCP/102 MMS 报文 | 通过 |
| pcap 回放 | `tcpreplay --pps=1 -i veth-suri1 /home/work/pcaps_dataset/mms.pcap` | `Successful packets: 22`，`Failed packets: 0` | 成功 22，失败 0，截断 0 | 通过 |
| EVE 事件统计 | `jq -r '.event_type? // empty' <本次 EVE>` | 出现 `iec61850_mms` | `8 iec61850_mms`，`6 flow` | 通过 |
| TCP/102 flow | 查询 `src_port == 102` 或 `dest_port == 102` 的 flow | 识别为 MMS 协议 | `app_proto=iec61850-mms`，状态 `closed` | 通过 |
| 容器停止刷日志 | `WAIT_BEFORE_STOP=5 ./stop-suricata-docker.sh` | 容器正常停止并刷出尾部日志 | 容器 `Exited (0)`；停止后出现 TCP/102 flow | 通过 |
| 清理 veth pair | `ip link del veth-suri0` | 测试接口删除 | `veth-suri0`、`veth-suri1` 均不存在 | 通过 |

## 协议解析明细

| 序号 | 时间戳 | 源 | 目的 | PDU 类型 | 方向 | Service |
|------|--------|----|------|----------|------|---------|
| 1 | `2026-07-10T17:27:48.795254+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `initiate_request` | `request` | `null` |
| 2 | `2026-07-10T17:27:49.795252+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `initiate_response` | `response` | `null` |
| 3 | `2026-07-10T17:27:51.795252+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `confirmed_request` | `request` | `get_variable_access_attributes` |
| 4 | `2026-07-10T17:27:53.795252+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `confirmed_error` | `response` | `null` |
| 5 | `2026-07-10T17:27:54.795253+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `confirmed_request` | `request` | `read` |
| 6 | `2026-07-10T17:27:55.795255+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `confirmed_response` | `response` | `read` |
| 7 | `2026-07-10T17:27:56.795256+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `conclude_request` | `request` | `null` |
| 8 | `2026-07-10T17:27:57.795253+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `conclude_response` | `response` | `null` |

## Flow 结果

| 字段 | 值 |
|------|----|
| `app_proto` | `iec61850-mms` |
| 源 | `172.16.0.101:1345` |
| 目的 | `172.16.202.5:102` |
| 状态 | `closed` |
| 结束原因 | `timeout` |
| `pkts_toserver` | `11` |
| `pkts_toclient` | `11` |
| `bytes_toserver` | `1000` |
| `bytes_toclient` | `907` |
| 总字节 | `1907` |

## 文档问题记录

| 问题 | 实际表现 | 建议 |
|------|----------|------|
| capability 期望值格式不完全一致 | 文档期望 `["NET_ADMIN","NET_RAW","SYS_NICE"]`，Docker 实际输出 `["CAP_NET_ADMIN","CAP_NET_RAW","CAP_SYS_NICE"]` | 文档中补充不同 Docker 版本可能带 `CAP_` 前缀，二者语义一致 |
| 清理旧日志命令未覆盖轮转后的 EVE 文件 | 文档只删除 `eve.json`，但本机实际 EVE 文件为 `eve.2026-07-10_17-27-10.json`，历史 `eve*.json` 会干扰统计 | 清理命令建议改为删除 `/var/log/suricata-docker/eve*.json`，或统计时只选择本次最新非空 EVE 文件 |
| flow 记录需要停止或等待后才稳定出现 | 回放后立即查询已有 `iec61850_mms`，但 TCP/102 flow 在停止容器刷日志后才出现 | 文档可在 flow 检查前增加“等待 flow 超时或停止容器刷日志”的提示 |

## 结论

| 结论项 | 结果 |
|--------|------|
| veth pair 方式是否可用于 Suricata 容器流量测试 | 可行 |
| Suricata 是否捕获到 TCP/102 流量 | 是 |
| Suricata 是否识别 IEC61850/MMS 协议 | 是，`app_proto=iec61850-mms` |
| 是否生成 IEC61850/MMS EVE 事务日志 | 是，共 8 条 `iec61850_mms` |
| 本次流量处理能力验证 | 通过 |

## 2026-07-24 复测记录

测试依据：[VERIFY_SURICATA_DOCKER.md](VERIFY_SURICATA_DOCKER.md)

### 测试环境

| 项目 | 值 |
|------|----|
| 测试时间 | `2026-07-24 23:31:38 CST +0800` |
| 工作目录 | `/home/work/docker-suricata/8.0` |
| 测试镜像 | `suricata:8.0.4-amd64-offline` |
| 镜像架构 | `amd64/linux` |
| 镜像 ID | `sha256:b5ec3dbbea6262d2d3f51839afd805e117a0ed514fd2f08178b76e13aa03cc2d` |
| Suricata 版本 | `8.0.4 RELEASE` |
| 抓包接口 | `veth-suri0` |
| 回放接口 | `veth-suri1` |
| 测试 pcap | `/home/work/pcaps_dataset/mms.pcap` |
| 回放速率 | `tcpreplay --pps=1` |
| EVE 文件 | `/var/log/suricata-docker/eve.2026-07-24_23-29-46.json` |

### 执行过程

| 测试项 | 命令/检查点 | 期望结果 | 实际结果 | 结论 |
|--------|-------------|----------|----------|------|
| 初始容器状态核查 | `docker inspect suricata --format '{{json .Config.Image}} {{json .Args}} {{json .HostConfig.CapAdd}}'` | 确认现有容器是否可直接用于 veth 测试 | 现有容器镜像为 `suricata:8.0.4-amd64-offline`，但参数为 `-i eno3 -c /etc/suricata/suricata.yaml` | 需重建为 veth 测试容器 |
| 创建 veth pair | `ip link del veth-suri0 2>/dev/null || true` 后执行 `ip link add veth-suri0 type veth peer name veth-suri1`，并分别 `ip link set ... up` | 两个接口创建成功并 `UP` | `veth-suri0`、`veth-suri1` 创建并启用成功 | 通过 |
| 清理旧日志 | 删除 `/var/log/suricata-docker/eve*.json`、`fast.log`、`stats.log`、`suricata.log` | 本次统计不受历史日志干扰 | 清理成功 | 通过 |
| 启动容器 | `SURICATA_IMAGE=suricata:8.0.4-amd64-offline CAPTURE_IFACE=veth-suri0 ./run-suricata-docker.sh` | 容器启动，Suricata 引擎启动 | 启动脚本删除旧 `suricata` 容器并新建容器；日志出现 `Engine started.` | 通过 |
| capability | `docker inspect suricata --format '{{json .HostConfig.CapAdd}}'` | 包含 `NET_ADMIN`、`NET_RAW`、`SYS_NICE` | `['CAP_NET_ADMIN','CAP_NET_RAW','CAP_SYS_NICE']` | 通过 |
| veth 抓包验证 | `tcpdump -ni veth-suri0 -c 10` | 能看到回放流量 | 捕获到 TCP/102 MMS 报文；同时夹杂 2 条 IPv6 mDNS 背景流量 | 通过，有环境噪声 |
| pcap 回放 | `tcpreplay --pps=1 -i veth-suri1 /home/work/pcaps_dataset/mms.pcap` | `Successful packets: 22`，`Failed packets: 0` | 成功 22，失败 0，截断 0，重试 0 | 通过 |
| EVE 文件定位 | `find /var/log/suricata-docker -maxdepth 1 -type f -name 'eve*.json' -size +0c ...` | 定位本次最新非空 EVE 文件 | `/var/log/suricata-docker/eve.2026-07-24_23-29-46.json` | 通过 |
| EVE 事件统计 | `jq -r '.event_type? // empty' "$EVE_FILE" | sort | uniq -c` | 出现 `iec61850_mms` | `8 iec61850_mms`，`2 flow` | 通过 |
| IEC61850/MMS 摘要 | 查询 `event_type == "iec61850_mms"` | 输出 MMS 事务摘要 | 8 条 MMS 事务，包含 `initiate_request`、`initiate_response`、`confirmed_request/get_variable_access_attributes`、`confirmed_error`、`confirmed_request/read`、`confirmed_response/read`、`conclude_request`、`conclude_response` | 通过 |
| 停止容器刷日志 | `WAIT_BEFORE_STOP=5 ./stop-suricata-docker.sh` | 容器正常停止并刷出 flow | 容器正常停止 | 通过 |
| TCP/102 flow | 查询 `src_port == 102` 或 `dest_port == 102` 的 flow | 识别为 MMS 协议 | `app_proto=iec61850-mms`，`state=closed`，`reason=shutdown`，`pkts_toserver=11`，`pkts_toclient=11` | 通过 |

### 事件统计

```text
      2 flow
      8 iec61850_mms
```

### 协议解析明细

| 序号 | 时间戳 | 源 | 目的 | PDU 类型 | 方向 | Service |
|------|--------|----|------|----------|------|---------|
| 1 | `2026-07-24T23:30:22.574252+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `initiate_request` | `request` | `null` |
| 2 | `2026-07-24T23:30:23.574251+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `initiate_response` | `response` | `null` |
| 3 | `2026-07-24T23:30:25.574250+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `confirmed_request` | `request` | `get_variable_access_attributes` |
| 4 | `2026-07-24T23:30:27.574252+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `confirmed_error` | `response` | `null` |
| 5 | `2026-07-24T23:30:28.574253+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `confirmed_request` | `request` | `read` |
| 6 | `2026-07-24T23:30:29.574251+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `confirmed_response` | `response` | `read` |
| 7 | `2026-07-24T23:30:30.574250+0800` | `172.16.202.5:102` | `172.16.0.101:1345` | `conclude_request` | `request` | `null` |
| 8 | `2026-07-24T23:30:31.574250+0800` | `172.16.0.101:1345` | `172.16.202.5:102` | `conclude_response` | `response` | `null` |

### Flow 结果

| 字段 | 值 |
|------|----|
| `app_proto` | `iec61850-mms` |
| 源 | `172.16.0.101:1345` |
| 目的 | `172.16.202.5:102` |
| 状态 | `closed` |
| 结束原因 | `shutdown` |
| `pkts_toserver` | `11` |
| `pkts_toclient` | `11` |
| `bytes_toserver` | `1000` |
| `bytes_toclient` | `907` |

### 本轮问题记录

| 问题 | 实际表现 | 影响 | 建议 |
|------|----------|------|------|
| 测试前已有同名 `suricata` 容器在抓物理网卡 | 初始容器参数为 `-i eno3`；执行 `run-suricata-docker.sh` 会先 `docker rm -f suricata` 再重建为 `veth-suri0` | 按文档复测会中断现有 `suricata` 容器的原抓包状态 | 复测前明确确认是否允许替换同名容器；或用 `CONTAINER_NAME` 指定临时测试容器名 |
| `tcpdump -ni veth-suri0 -c 10` 可能捕获到非 pcap 测试流量 | 本轮前 10 包中夹杂 2 条 IPv6 mDNS 报文，来自链路本地地址到 `ff02::fb:5353` | 不影响 Suricata MMS 解析结果，但会干扰人工确认“前 10 包均来自 pcap”的判断 | 文档中的 tcpdump 检查可增加过滤条件，例如 `tcpdump -ni veth-suri0 tcp port 102 -c 10` |
| 停止容器后 flow 结束原因与历史报告不同 | 本轮停止后 TCP/102 flow 为 `reason=shutdown`；历史报告曾出现 `reason=timeout` | 不影响协议识别和包计数，但说明 flow `reason` 受停止时机影响，不宜作为严格固定值断言 | 验证时重点断言 `app_proto=iec61850-mms`、`state=closed`、双向包数；`reason` 仅记录不强约束 |

### 复测结论

| 结论项 | 结果 |
|--------|------|
| veth pair 回放方式是否可用 | 可用 |
| pcap 是否完整回放 | 是，成功 22 包、失败 0 |
| Suricata 是否生成 IEC61850/MMS 事务日志 | 是，共 8 条 `iec61850_mms` |
| Suricata 是否识别 TCP/102 为 IEC61850/MMS | 是，`app_proto=iec61850-mms` |
| 本轮 VERIFY_SURICATA_DOCKER.md pcap 测试是否通过 | 通过 |
