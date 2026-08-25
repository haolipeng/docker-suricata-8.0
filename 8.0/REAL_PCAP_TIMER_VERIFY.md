# 真实 pcap 与 EVE 清理验证

本文档用于在 `10.107.12.8` 验证 Suricata 容器的 EVE 生成、MMS 识别和 EVE 自动清理。宿主机 `logrotate` 只作为可选边界验证，不能处理 `eve*.json`。

## 1. 验证范围

必测：

- pcap 回放后，宿主机 `/var/log/suricata-docker` 能看到 `eve*.json`。
- EVE 中能看到 `iec61850_mms` 或 `app_proto=iec61850-mms`。
- 容器内 cron 能删除过期 `eve.*.json`，删除结果同步反映到宿主机目录。

可选：

- 如果宿主机安装了 `logrotate`，验证它只轮转 `*.log`，不改名、不压缩、不删除 `eve*.json`。

本环境已知前提：

- 容器名：`suricata`
- 镜像：`suricata:8.0.4-arm64-offline`
- 抓包网卡：`eth3`
- pcap：`/home/work/pcaps_dataset/mms.pcap`
- 宿主机日志目录：`/var/log/suricata-docker`
- `eth3` 当前未接入 MMS/TCP/102 自然流量；本次 MMS 验证来自 pcap 回放。
- 本次不加载规则，不以 `alert` 作为通过条件。

## 2. 关键约束

- 宿主机消费者读取 `/var/log/suricata-docker/eve*.json`。
- EVE 文件名格式由 `suricata.yaml` 的 EVE `filename` 决定，例如 `eve.%Y-%m-%d_%H-%M-%S.json`。
- Suricata 负责生成/切分 EVE；容器内 `suricata-json-cleanup` 负责清理 EVE。
- 宿主机 `logrotate` 只能处理 `*.log`，禁止匹配 `eve*.json`。

## 3. 设置变量

```bash
cd /home/work/docker-suricata/8.0

CONTAINER=suricata
CAPTURE_IFACE=eth3
REPLAY_IFACE=eth3
PCAP=/home/work/pcaps_dataset/mms.pcap
LOG_DIR=/var/log/suricata-docker
TEST_DIR=/tmp/suricata-timer-test
```

## 4. 检查当前状态

```bash
docker ps --filter "name=${CONTAINER}"
docker inspect "${CONTAINER}" --format 'Image={{.Config.Image}} Args={{json .Args}} Cap={{json .HostConfig.CapAdd}} Env={{json .Config.Env}}'
docker logs --tail 80 "${CONTAINER}"

docker exec "${CONTAINER}" sed -n '1,80p' /usr/local/bin/suricata-json-cleanup
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup

test -f "${PCAP}"
command -v tcpreplay
command -v jq
command -v tcpdump
command -v logrotate >/dev/null 2>&1 && HOST_HAS_LOGROTATE=yes || HOST_HAS_LOGROTATE=no
```

期望结果：

- 容器运行中。
- `Args` 包含 `-i eth3 -c /etc/suricata/suricata.yaml`。
- `Env` 包含 `ENABLE_CRON=yes`。
- 清理脚本默认保留 1 天：`SURICATA_JSON_KEEP_DAYS:-1`。
- cron 文件存在，默认每 10 分钟运行一次。

确认当前网口自然流量状态：

```bash
timeout 20 tcpdump -ni "${CAPTURE_IFACE}" tcp port 102 -c 5 || true
```

期望结果：当前 `eth3` 未接入 MMS/TCP/102 自然流量，抓不到包不作为失败。

## 5. 备份原配置

```bash
rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}/saved-logs"

docker cp "${CONTAINER}:/usr/local/bin/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.orig"
docker cp "${CONTAINER}:/etc/cron.d/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.cron.orig"
cp -a /etc/suricata-docker/suricata.yaml "${TEST_DIR}/suricata.yaml.orig"
```

从此步骤之后，如中途失败，直接执行第 11 节恢复。

## 6. 启用临时测试配置

### 6.1 让 EVE 按分钟切分

查看 EVE 配置位置：

```bash
grep -n 'filename: eve\|rotate-interval\|outputs:' /etc/suricata-docker/suricata.yaml | head -40
```

如果 EVE 配置块中没有 `rotate-interval`，在 `filename: eve.%Y-%m-%d_%H-%M-%S.json` 后添加客户默认值：

```yaml
rotate-interval: 2h
```

可用命令追加：

```bash
if ! awk 'NR>=98 && NR<=130 && /rotate-interval:/ {found=1} END {exit found?0:1}' /etc/suricata-docker/suricata.yaml; then
    sed -i '/filename: eve.%Y-%m-%d_%H-%M-%S.json/a\      rotate-interval: 2h' /etc/suricata-docker/suricata.yaml
fi
```

检查并重启容器：

```bash
docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}"
docker restart "${CONTAINER}"
sleep 5
docker ps --filter "name=${CONTAINER}"
```

配置检查必须成功；产品规则应从 `/usr/share/suricata/rules` 加载，失败时先修复配置再继续。

### 6.2 重启后写临时清理 cron

把清理阈值临时改成 10 分钟：

```bash
docker exec "${CONTAINER}" sh -c 'sed -i \
  "s/KEEP_MINUTES=\"\$((KEEP_DAYS \* 1440))\"/KEEP_MINUTES=\"\${SURICATA_JSON_KEEP_MINUTES:-10}\"/" \
  /usr/local/bin/suricata-json-cleanup'
```

重写 cron 文件为每分钟执行：

```bash
docker exec "${CONTAINER}" sh -c \
  "printf '* * * * * root /usr/local/bin/suricata-json-cleanup >/proc/1/fd/1 2>/proc/1/fd/2\n' > /etc/cron.d/suricata-json-cleanup && chmod 644 /etc/cron.d/suricata-json-cleanup"

docker exec "${CONTAINER}" sed -n '1,80p' /usr/local/bin/suricata-json-cleanup
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
```

注意：临时 cron 必须在容器重启后写入，并用第 9 节的过期 EVE 样本证明它实际执行。

## 7. 回放 pcap 并验证 EVE/MMS

清空本次 EVE 前，先保存已有 EVE 样本用于后续清理测试：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -exec cp -a {} "${TEST_DIR}/saved-logs/" \;
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -delete
```

回放 pcap：

```bash
tcpreplay --pps=1 -i "${REPLAY_IFACE}" "${PCAP}"
sleep 120
```

检查 EVE 文件：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -size +0c -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
```

检查事件类型和 MMS 识别：

```bash
for f in "${LOG_DIR}"/eve*.json; do
    [ -e "$f" ] || continue
    echo "FILE=$f"
    jq -r '.event_type? // empty' "$f" | sort | uniq -c
done

jq -r 'select((.event_type? == "iec61850_mms") or (.app_proto? == "iec61850-mms")) |
  input_filename + "\t" + ([.event_type, (.app_proto // ""), .src_ip, (.src_port|tostring), .dest_ip, (.dest_port|tostring)] | @tsv)' \
  "${LOG_DIR}"/eve*.json
```

通过条件：

- 至少有一个非空 `eve*.json`。
- 本次生成的任一 `eve*.json` 中出现 `iec61850_mms` 或 `app_proto=iec61850-mms`。
- 不只检查最新 EVE 文件，最新文件可能只包含背景流量。

## 8. 验证 EVE 自动清理

放入一个非最新、过期的 EVE 样本：

```bash
OLD_EVE_SRC=$(find "${TEST_DIR}/saved-logs" -maxdepth 1 -type f -name 'eve*.json' | head -1 || true)
if [ -z "${OLD_EVE_SRC}" ]; then
    OLD_EVE_SRC=$(find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' | head -1 || true)
fi

if [ -n "${OLD_EVE_SRC}" ]; then
    cp "${OLD_EVE_SRC}" "${LOG_DIR}/eve.1999-01-01_00-00-00.json"
    touch -d '20 minutes ago' "${LOG_DIR}/eve.1999-01-01_00-00-00.json"
fi
```

观察 75 秒：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json*' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
sleep 75
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json*' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
docker logs --since 20m "${CONTAINER}" | tail -120
```

通过条件：

- `eve.1999-01-01_00-00-00.json` 被容器 cron 自动删除。
- 最新 `eve*.json` 保留。
- 删除在宿主机 `/var/log/suricata-docker` 和容器内 `/var/log/suricata` 同步生效，因为二者是同一个 bind mount。

如果过期样本未删除，重写 cron 文件后再观察一次：

```bash
docker exec "${CONTAINER}" sh -c \
  "printf '* * * * * root /usr/local/bin/suricata-json-cleanup >/proc/1/fd/1 2>/proc/1/fd/2\n' > /etc/cron.d/suricata-json-cleanup && chmod 644 /etc/cron.d/suricata-json-cleanup"
sleep 75
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json*' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
```

## 9. 可选：验证 logrotate 边界

仅当宿主机存在 `logrotate` 时执行：

```bash
if [ "${HOST_HAS_LOGROTATE}" = yes ]; then
cat >/etc/logrotate.d/suricata-timer-test <<'LOGROTATE'
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
LOGROTATE

rm -f /var/lib/suricata-timer-test.state
/usr/sbin/logrotate -v -s /var/lib/suricata-timer-test.state /etc/logrotate.d/suricata-timer-test
fi
```

检查结果：

```bash
ls -l "${LOG_DIR}"/*.log* 2>/dev/null || true
find "${LOG_DIR}" -maxdepth 1 -type f \( -name '*.json.[0-9]*' -o -name '*.json-*' -o -name '*.json.gz' \) -print
```

通过条件：

- 可以生成 `*.log.1`、`*.log.2` 等轮转文件。
- 不允许出现 `.json.1`、`.json.gz` 等 EVE JSON 轮转文件。

## 10. 恢复

无论验证成功还是失败，结束前都执行本节。

```bash
rm -f /etc/logrotate.d/suricata-timer-test
rm -f /var/lib/suricata-timer-test.state

docker cp "${TEST_DIR}/suricata-json-cleanup.orig" \
  "${CONTAINER}:/usr/local/bin/suricata-json-cleanup"
docker cp "${TEST_DIR}/suricata-json-cleanup.cron.orig" \
  "${CONTAINER}:/etc/cron.d/suricata-json-cleanup"
docker exec "${CONTAINER}" rm -f /etc/cron.d/zz-cron-check /tmp/cron-check.log /tmp/cleanup-final.log 2>/dev/null || true

cp -a "${TEST_DIR}/suricata.yaml.orig" /etc/suricata-docker/suricata.yaml

docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}" || true
docker restart "${CONTAINER}"
sleep 5

docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
grep -n 'filename: eve\|rotate-interval' /etc/suricata-docker/suricata.yaml | head -20
docker ps --filter "name=${CONTAINER}"
docker inspect "${CONTAINER}" --format '{{json .Args}}'
```

恢复后建议重写一次生产 cron 文件，内容不变，用于确保 crond 重新加载：

```bash
docker exec "${CONTAINER}" sh -c \
  "printf '*/10 * * * * root /usr/local/bin/suricata-json-cleanup >/proc/1/fd/1 2>/proc/1/fd/2\n' > /etc/cron.d/suricata-json-cleanup && chmod 644 /etc/cron.d/suricata-json-cleanup"
```

## 11. 结果记录

| 项目 | 结果 | 证据/备注 |
| --- | --- | --- |
| 测试时间 |  |  |
| 容器镜像 |  |  |
| 容器参数 |  |  |
| 清理阈值 |  | 默认 1 天，测试临时改为 10 分钟 |
| 自然 TCP/102 |  | `eth3` 当前未接入 MMS/TCP/102，自然无包不阻塞 |
| pcap 回放 |  |  |
| EVE 生成 |  |  |
| MMS 识别 |  |  |
| EVE 自动清理 |  |  |
| logrotate 边界 |  | 只允许处理 `*.log` |
| 恢复 |  |  |

## 12. 最近一次测试结果

| 项目 | 结果 | 证据/备注 |
| --- | --- | --- |
| 测试时间 | 2026-07-25 12:58-13:09 CST | 远端 `10.107.12.8` |
| 容器镜像 | 通过 | `suricata:8.0.4-arm64-offline` |
| 容器参数 | 通过 | `["-i","eth3","-c","/etc/suricata/suricata.yaml"]` |
| 清理阈值 | 通过 | 默认 `SURICATA_JSON_KEEP_DAYS:-1`，按 `1440` 分钟计算 |
| crond 执行能力 | 通过 | sentinel cron 在下一分钟写入 |
| 自然 TCP/102 | 不作为阻塞 | `eth3` 当前未接入 MMS/TCP/102 自然流量；本次 MMS 识别来自 pcap 回放 |
| pcap 回放 | 通过 | `/home/work/pcaps_dataset/mms.pcap`，`tcpreplay --pps=1` 成功发送 22 包 |
| EVE 生成 | 通过 | 生成 3 个非空 `eve*.json` |
| MMS 识别 | 通过 | 出现 `iec61850_mms` 事件和 `app_proto=iec61850-mms` flow |
| logrotate 边界 | 通过 | 只轮转 `*.log`，未产生 `.json.1`、`.json.gz` |
| EVE 自动清理 | 通过但需注意 | 重启前写入的临时 cron 未触发；重写 cron 文件后，过期 EVE 在下一分钟删除 |
| 恢复 | 通过 | 恢复原 `suricata.yaml`、清理脚本、cron，删除临时 logrotate，容器继续抓 `eth3` |

## 13. 已知问题与注意事项

- `eth3` 当前未接入 MMS/TCP/102 自然流量；自然抓包无包是链路条件，不代表 Suricata 失败。
- 临时修改 cron 后必须用过期 EVE 样本验证实际执行；必要时重写 `/etc/cron.d/suricata-json-cleanup`。
- MMS 校验要查本次生成的所有 `eve*.json`，不要只看最新文件。
- 宿主机 logrotate 不允许匹配 `eve*.json`，否则会破坏宿主机消费者的文件名约定。
- 宿主机没有 `logrotate` 时，跳过 logrotate 验证，不影响 EVE 生成和容器清理结论。
