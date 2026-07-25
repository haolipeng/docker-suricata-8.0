# 真实 pcap 定时任务验证

本文档用于验证三件事：

1. 真实 pcap 能生成 `eve*.json`。
2. 容器内 `crond` 能自动清理过期 EVE 文件。
3. 宿主机 `logrotate` 能自动轮转 Suricata 日志。

只在隔离测试网卡或测试 VLAN 上执行，禁止向生产网络回放 pcap。

参考环境 `10.107.12.8`：容器名 `suricata`，镜像 `suricata:8.0.4-arm64-offline`，抓包参数 `-i eth3 -c /etc/suricata/suricata.yaml`，日志挂载到 `/var/log/suricata-docker`，配置挂载到 `/etc/suricata-docker`。本次测试不加载任何规则，因此不以 `alert` 事件作为通过条件；MMS 识别以 EVE `app_proto=iec61850-mms` 为准。该类镜像较精简，容器内可能没有 `ps`、`pgrep`，不要依赖这些命令判断 cron 是否运行；以 cron 配置、容器日志和文件变化作为判定依据。

## 1. 准备变量

```bash
cd /home/work/docker-suricata/8.0

CONTAINER=suricata
CAPTURE_IFACE=eth3
REPLAY_IFACE=eth3
PCAP=/home/work/pcaps_dataset/mms.pcap
LOG_DIR=/var/log/suricata-docker
```

## 2. 检查环境

```bash
docker ps --filter "name=${CONTAINER}"
docker inspect "${CONTAINER}" --format 'Image={{.Config.Image}} Args={{json .Args}} Cap={{json .HostConfig.CapAdd}}'
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
docker logs --tail 80 "${CONTAINER}"
test -f "${PCAP}"
command -v tcpreplay
command -v logrotate
command -v jq
command -v tcpdump
timeout 20 tcpdump -ni "${CAPTURE_IFACE}" tcp port 102 -c 5
```

`tcpdump` 如果长时间抓不到 TCP/102，先确认 `CAPTURE_IFACE` 是否就是测试链路网卡。不要为了通过测试而向未知生产链路回放 pcap。

`suricatasc` 在参考环境的宿主机上不存在，但容器内存在 `/usr/bin/suricatasc`，宿主机 `logrotate` 的 `postrotate` 应通过 `docker exec "${CONTAINER}" suricatasc -c reopen-log-files` 通知 Suricata 重开日志。

## 3. 备份原配置

```bash
TEST_DIR=/tmp/suricata-timer-test
rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}"

docker cp "${CONTAINER}:/usr/local/bin/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.orig"
docker cp "${CONTAINER}:/etc/cron.d/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.cron.orig"
cp -a /etc/suricata-docker/suricata.yaml "${TEST_DIR}/suricata.yaml.orig"
if [ -f /etc/logrotate.d/suricata ]; then
    cp -a /etc/logrotate.d/suricata "${TEST_DIR}/suricata.logrotate.orig"
fi
```

## 4. 临时缩短周期

### 4.1 让 EVE 按分钟切分

先查看当前 EVE 配置位置：

```bash
grep -n 'filename: eve\|rotate-interval\|outputs:' /etc/suricata-docker/suricata.yaml | head -40
```

把 `/etc/suricata-docker/suricata.yaml` 里的 EVE 轮转改成：

```yaml
rotate-interval: minute
```

然后检查并重启。无规则测试时，`suricata -T` 可能因为没有加载任何规则返回非 0；只要输出是 `No rule files match` / `no rules were loaded` 这类无规则信息，而不是 YAML 解析错误，可以继续重启验证：

```bash
docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}" || true
docker restart "${CONTAINER}"
```

### 4.2 让清理任务每分钟跑一次，保留 10 分钟

```bash
docker exec "${CONTAINER}" sh -c 'sed -i \
  "s/KEEP_DAYS=\"\${SURICATA_JSON_KEEP_DAYS:-7}\"/KEEP_MINUTES=\"\${SURICATA_JSON_KEEP_MINUTES:-10}\"/; \
   s/-mtime +\"\$KEEP_DAYS\"/-mmin +\"\$KEEP_MINUTES\"/" \
  /usr/local/bin/suricata-json-cleanup'

docker exec "${CONTAINER}" sh -c \
  "sed -i 's#\*/10 \* \* \* \*#\* \* \* \* \*#' /etc/cron.d/suricata-json-cleanup"

docker exec "${CONTAINER}" cat /usr/local/bin/suricata-json-cleanup
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
```

### 4.3 让宿主机 logrotate 每分钟触发

EVE JSON 的生命周期由容器内 `suricata-json-cleanup` 验证，宿主机 `logrotate` 这里只验证 `*.log`。不要在该临时配置中匹配 `*.json`，否则 `logrotate` 会先把 EVE 文件改名成 `.json.1`，干扰 EVE 清理验证。

```bash
cat >/etc/logrotate.d/suricata-timer-test <<'EOF'
/var/log/suricata-docker/*.log {
    size 1
    missingok
    rotate 3
    nocompress
    sharedscripts
    postrotate
        /usr/bin/docker exec suricata suricatasc -c reopen-log-files >/dev/null
    endscript
}
EOF
```

如果宿主机存在 `/etc/cron.d`，用 cron 每分钟触发：

```bash
cat >/etc/cron.d/suricata-logrotate-timer-test <<'EOF'
* * * * * root /usr/sbin/logrotate -s /var/lib/suricata-timer-test.state /etc/logrotate.d/suricata-timer-test >/dev/null 2>&1
EOF

chmod 644 /etc/cron.d/suricata-logrotate-timer-test
rm -f /var/lib/suricata-timer-test.state
```

参考环境 `10.107.12.8` 的宿主机没有 `/etc/cron.d`，但有 `crond`。这种情况下用受控后台循环代替 cron，记录 PID，恢复阶段必须停止：

```bash
rm -f /tmp/suricata-logrotate-loop.pid /tmp/suricata-logrotate-loop.log
nohup sh -c 'while :; do date; /usr/sbin/logrotate -v -s /var/lib/suricata-timer-test.state /etc/logrotate.d/suricata-timer-test; sleep 60; done' \
  >/tmp/suricata-logrotate-loop.log 2>&1 &
echo $! >/tmp/suricata-logrotate-loop.pid

tail -120 /tmp/suricata-logrotate-loop.log
logrotate -d -s /var/lib/suricata-timer-test.state /etc/logrotate.d/suricata-timer-test
```

## 5. 生成真实日志

```bash
mkdir -p "${TEST_DIR}/saved-logs"
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -exec cp -a {} "${TEST_DIR}/saved-logs/" \;
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -delete
tcpreplay --pps=1 -i "${REPLAY_IFACE}" "${PCAP}"
sleep 120
```

确认生成了真实 EVE JSON：

```bash
EVE_FILE=$(find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -size +0c -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
jq -r '.event_type? // empty' "${EVE_FILE}" | sort | uniq -c
jq -r 'select(.app_proto? == "iec61850-mms") | [.event_type, .app_proto, .src_ip, .src_port, .dest_ip, .dest_port] | @tsv' "${EVE_FILE}"
```

通过条件：至少有一个非空 `eve*.json`。无规则测试时，若 pcap 是 `/home/work/pcaps_dataset/mms.pcap`，通常应看到 `event_type=flow` 且 `app_proto=iec61850-mms`；不要要求出现 `alert` 或 `event_type=iec61850_mms`。

## 6. 观察自动任务

为了验证自动清理，需要存在一个“非最新的过期 EVE 文件”。可从前面保存的真实 EVE 文件复制一个样本，并把 mtime 调旧；之后不要手动执行清理脚本，只观察 cron 是否删除它：

```bash
OLD_EVE_SRC=$(find "${TEST_DIR}/saved-logs" -maxdepth 1 -type f -name 'eve*.json' | head -1 || true)
if [ -n "${OLD_EVE_SRC}" ]; then
    cp "${OLD_EVE_SRC}" "${LOG_DIR}/eve.1999-01-01_00-00-00.json"
    touch -d '20 minutes ago' "${LOG_DIR}/eve.1999-01-01_00-00-00.json"
fi
```

接下来不要手动执行清理脚本或 `logrotate`，只观察 15 分钟：

```bash
for i in $(seq 1 15); do
    date
    find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
    ls -l "${LOG_DIR}"/*.log* "${LOG_DIR}"/*.json* 2>/dev/null || true
    tail -40 /tmp/suricata-logrotate-loop.log 2>/dev/null || true
    sleep 60
done
```

同时可查看容器日志。cron 配置把清理脚本输出重定向到容器 1 号进程 stdout/stderr，因此异常通常会出现在 `docker logs`：

```bash
docker logs --since 20m "${CONTAINER}" | tail -120
docker ps --filter "name=${CONTAINER}"
```

通过条件：

- 容器持续运行，且没有 cron/清理脚本报错。
- 超过 10 分钟的旧 `eve.*.json` 自动删除。
- 最新 `eve.*.json` 保留。
- 宿主机出现 `.1`、`.2` 等轮转文件。
- 轮转后新日志继续写入。
- 容器没有退出。

## 7. 恢复原配置

```bash
docker cp "${TEST_DIR}/suricata-json-cleanup.orig" \
  "${CONTAINER}:/usr/local/bin/suricata-json-cleanup"
docker cp "${TEST_DIR}/suricata-json-cleanup.cron.orig" \
  "${CONTAINER}:/etc/cron.d/suricata-json-cleanup"
docker exec "${CONTAINER}" rm -f /etc/cron.d/zz-sentinel /tmp/cron-sentinel.log /tmp/cleanup-cron.log 2>/dev/null || true

if [ -f /tmp/suricata-logrotate-loop.pid ]; then
    kill "$(cat /tmp/suricata-logrotate-loop.pid)" 2>/dev/null || true
fi
rm -f /tmp/suricata-logrotate-loop.pid
rm -f /tmp/suricata-logrotate-loop.log
rm -f /etc/logrotate.d/suricata-timer-test
rm -f /etc/cron.d/suricata-logrotate-timer-test
rm -f /var/lib/suricata-timer-test.state

cp -a "${TEST_DIR}/suricata.yaml.orig" /etc/suricata-docker/suricata.yaml

docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}" || true
docker restart "${CONTAINER}"
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
docker logs --tail 50 "${CONTAINER}"
```

恢复后再次确认容器参数仍然抓测试网卡：

```bash
docker inspect "${CONTAINER}" --format '{{json .Args}}'
```

## 8. 记录结果

```text
测试时间：
容器镜像：
抓包网卡：
pcap 文件：
真实 eve*.json 数量：
是否出现 IEC61850/MMS 事件：
是否自动删除旧 EVE 文件：
是否自动轮转日志：
轮转后是否继续写入：
是否恢复原配置：
```

## 9. 本次验证结果

| 项目 | 结果 | 证据/备注 |
| --- | --- | --- |
| 测试时间 | 2026-07-25 11:46-11:59 CST | 远端 `10.107.12.8`，root SSH |
| 容器镜像 | 通过 | `suricata:8.0.4-arm64-offline` |
| 容器参数 | 通过 | `["-i","eth3","-c","/etc/suricata/suricata.yaml"]` |
| pcap 文件 | 通过 | `/home/work/pcaps_dataset/mms.pcap` 存在，`tcpreplay --pps=1` 成功发送 22 包 |
| 自然 TCP/102 抓包 | 不作为阻塞 | `timeout 20 tcpdump -ni eth3 tcp port 102 -c 5` 未抓到包；后续 pcap 回放可生成测试流量 |
| 无规则启动 | 通过 | 容器日志出现 `No rule files match` / `no rules were loaded`，但 Suricata 持续运行 |
| 真实 EVE 生成 | 通过 | 生成非空 `eve.2026-07-25_11-50-27.json` |
| IEC61850/MMS 识别 | 通过 | 无规则场景下表现为 `event_type=flow`、`app_proto=iec61850-mms` |
| 容器 cron 清理 | 通过 | 过期样本 `eve.1999-01-01_00-00-00.json` 在下一分钟自动删除；手动执行脚本也返回 0 |
| 宿主机 logrotate 轮转 | 通过 | 临时 `size 1` 配置下生成 `stats.log.1/.2/.3`，`postrotate` 调用容器内 `suricatasc` 成功 |
| 轮转后继续写入 | 通过 | `stats.log` 在 `.1/.2/.3` 之后继续生成新内容 |
| 发现的问题 | 已修文档 | 宿主机无 `/etc/cron.d`；宿主机无 `suricatasc`；`hourly` 不会每分钟轮转；临时 logrotate 匹配 `*.json` 会干扰 EVE 清理；无规则测试不能要求 `alert` 或 `event_type=iec61850_mms` |
| 恢复原配置 | 通过 | 恢复原 cron、原 `suricata.yaml`，删除临时 logrotate/后台循环/sentinel，容器重启后仍抓 `eth3` |
