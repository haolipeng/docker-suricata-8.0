# 真实 pcap 与 EVE 轮转清理验证

本文档只保留测试步骤和结果验证方法。默认验证对象：

| 项目 | 默认值 |
|------|--------|
| 容器名 | `suricata` |
| 抓包网卡 | 按当前主机 IP 选择 |
| 回放 pcap | 多个 MMS pcap，至少包含 `/home/work/pcaps_dataset/mms/mms.pcap` |
| 宿主机日志目录 | `/var/log/suricata-docker` |

## 1. 设置变量

```bash
cd /home/work/docker-suricata/8.0

CONTAINER=suricata
CAPTURE_IFACE=eth3
REPLAY_IFACE=eth3
LOG_DIR=/var/log/suricata-docker
TEST_DIR=/tmp/suricata-timer-test
REPLAY_SECONDS=600

PCAP_FILES=(
  /home/work/pcaps_dataset/mms/mms.pcap
  /home/work/pcaps_dataset/mms/client-server-mms.pcap
  /home/work/pcaps_dataset/mms/client-server-mms-clean.pcap
  /home/work/pcaps_dataset/mms/iec61850_full_session.pcap
  /home/work/pcaps_dataset/mms/iec61850_get_name_list.pcap
  /home/work/pcaps_dataset/mms/iec61850_get_variable_access_attributes.pcap
  /home/work/pcaps_dataset/mms/iec61850_read.pcap
  /home/work/pcaps_dataset/mms/iec61850_write.pcap
  /home/work/pcaps_dataset/mms/mms-readRequest.pcap
  /home/work/pcaps_dataset/mms_file_transfer/iec61850_mms_file_download.pcap
  /home/work/pcaps_dataset/mms_file_transfer/iec61850_mms_file_upload.pcap
  /home/work/pcaps_dataset/mms_write/write_01_vmd_integer_invoke_only_response.pcap
  /home/work/pcaps_dataset/mms_write/write_02_domain_boolean_success_response.pcap
  /home/work/pcaps_dataset/mms_write/write_03_multi_variable_struct_partial_failure.pcap
  /home/work/pcaps_dataset/mms_write/write_04_variable_list_name_unsigned_success.pcap
  /home/work/pcaps_dataset/mms_write/write_05_alternate_component_index.pcap
)
```

如果当前主机 IP 是 `10.107.19.201`，则使用 `ens33` 网口：

```bash
CAPTURE_IFACE=ens33
REPLAY_IFACE=ens33
```

如果当前主机 IP 是 `10.107.12.8`，则使用 `eth3` 网口：

```bash
CAPTURE_IFACE=eth3
REPLAY_IFACE=eth3
```

## 2. 检查测试环境

```bash
docker ps --filter "name=${CONTAINER}"
docker inspect "${CONTAINER}" --format 'Image={{.Config.Image}} Args={{json .Args}} Env={{json .Config.Env}}'
docker logs --tail 80 "${CONTAINER}"

docker exec "${CONTAINER}" sed -n '1,80p' /usr/local/bin/suricata-json-cleanup
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup

for pcap in "${PCAP_FILES[@]}"; do
    test -f "${pcap}"
done
command -v tcpreplay
command -v jq
```

验证结果：

- 容器处于运行状态。
- 容器参数包含 `-i ${CAPTURE_IFACE}` 和 `-c /etc/suricata/suricata.yaml`。
- 容器环境变量包含 `ENABLE_CRON=yes`。
- 容器内存在 `/usr/local/bin/suricata-json-cleanup`。
- 容器内存在 `/etc/cron.d/suricata-json-cleanup`。
- 所有 pcap 文件、`tcpreplay`、`jq` 均可用。

## 3. 清理测试环境

为保证每次测试都是干净环境，启动或重建容器前清理上一次测试留下的配置、规则、日志、状态和运行时文件：

```bash
docker rm -f "${CONTAINER}" 2>/dev/null || true

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

清理后重新启动容器，再继续后续步骤。

```bash
SURICATA_IMAGE=suricata:8.0.4-amd64-offline \
CAPTURE_IFACE="${CAPTURE_IFACE}" \
./scripts/run-suricata-docker.sh
```

验证结果：

- 容器重新启动。
- 宿主机配置和规则目录由镜像默认内容重新填充。

## 4. 备份配置

```bash
rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}/saved-logs"

docker cp "${CONTAINER}:/usr/local/bin/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.orig"
docker cp "${CONTAINER}:/etc/cron.d/suricata-json-cleanup" \
  "${TEST_DIR}/suricata-json-cleanup.cron.orig"
cp -a /etc/suricata-docker/suricata.yaml "${TEST_DIR}/suricata.yaml.orig"
```

## 5. 启用临时测试配置

将 EVE JSON 轮转周期临时改成 1 分钟：

```bash
if grep -q 'rotate-interval:' /etc/suricata-docker/suricata.yaml; then
    sed -i 's/rotate-interval:.*/rotate-interval: 1m/' /etc/suricata-docker/suricata.yaml
else
    sed -i '/filename: eve.%Y-%m-%d_%H-%M-%S.json/a\      rotate-interval: 1m' /etc/suricata-docker/suricata.yaml
fi
```

将清理阈值临时改成 2 分钟：

```bash
docker exec "${CONTAINER}" sh -c 'sed -i \
  "s/KEEP_MINUTES=\"\$((KEEP_DAYS \* 1440))\"/KEEP_MINUTES=\"\${SURICATA_JSON_KEEP_MINUTES:-2}\"/" \
  /usr/local/bin/suricata-json-cleanup'
```

将 cron 临时改成每分钟执行：

```bash
docker exec "${CONTAINER}" sh -c \
  "printf '* * * * * root /usr/local/bin/suricata-json-cleanup >> /var/log/suricata/suricata-json-cleanup.log 2>&1\n' > /etc/cron.d/suricata-json-cleanup && chmod 644 /etc/cron.d/suricata-json-cleanup"
```

检查临时配置：

```bash
grep -n 'filename: eve\|rotate-interval' /etc/suricata-docker/suricata.yaml
docker exec "${CONTAINER}" grep -n 'KEEP_MINUTES' /usr/local/bin/suricata-json-cleanup
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
```

重启容器使 EVE 轮转配置生效：

```bash
docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}"
docker restart "${CONTAINER}"
sleep 5
docker logs --tail 50 "${CONTAINER}"
```

验证结果：

- `rotate-interval` 为 `1m`。
- `KEEP_MINUTES` 使用 `SURICATA_JSON_KEEP_MINUTES:-2`。
- cron 表达式为 `* * * * *`。
- 容器重启后日志出现 `Engine started.`。

## 6. 回放 pcap

清空本次测试前的 EVE 文件，避免混入旧数据：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -exec cp -a {} "${TEST_DIR}/saved-logs/" \;
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -delete
```

持续 10 分钟循环回放多个 pcap：

```bash
REPLAY_END=$((SECONDS + REPLAY_SECONDS))

while [ "${SECONDS}" -lt "${REPLAY_END}" ]; do
    for pcap in "${PCAP_FILES[@]}"; do
        [ "${SECONDS}" -lt "${REPLAY_END}" ] || break
        echo "Replay: ${pcap}"
        tcpreplay --pps=5 -i "${REPLAY_IFACE}" "${pcap}"
        sleep 2
    done
done

sleep 30
```

验证结果：

- 持续回放时间达到 `REPLAY_SECONDS`；大 pcap 可能占用较长时间，不要求每个 pcap 都在一次测试中完整回放。
- `tcpreplay` 输出 `Successful packets` 大于 0。
- `Failed packets` 为 0。

## 7. 验证 EVE 和 MMS

检查是否生成非空 EVE：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -size +0c \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
```

统计事件类型：

```bash
for f in "${LOG_DIR}"/eve*.json; do
    [ -e "$f" ] || continue
    echo "FILE=$f"
    jq -r '.event_type? // empty' "$f" | sort | uniq -c
done
```

查找 MMS 识别结果：

```bash
jq -r 'select((.event_type? == "iec61850_mms") or (.app_proto? == "iec61850-mms")) |
  input_filename + "\t" + ([.event_type, (.app_proto // ""), .src_ip, (.src_port|tostring), .dest_ip, (.dest_port|tostring)] | @tsv)' \
  "${LOG_DIR}"/eve*.json
```

验证结果：

- 至少生成一个非空 `eve*.json`。
- 任一 `eve*.json` 中出现 `event_type=iec61850_mms` 或 `app_proto=iec61850-mms`。
- 验证时检查所有本次生成的 `eve*.json`，不要只看最新文件。

## 8. 验证 EVE JSON 轮转

检查是否生成多个按时间命名的 EVE JSON 文件：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve.*.json' -size +0c \
  -printf '%f %s bytes\n' | sort

find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve.*.json' -size +0c | wc -l
```

验证结果：

- 至少生成多个非空 `eve.*.json` 文件，10 分钟测试建议不少于 5 个。
- 文件名符合 `eve.%Y-%m-%d_%H-%M-%S.json` 格式。
- 后一个 EVE 文件的时间晚于前一个 EVE 文件。

## 9. 验证 EVE 自动清理

持续回放 10 分钟后，早期轮转生成的 EVE 文件会自然超过 2 分钟清理阈值。直接观察当前保留的 EVE 文件：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json*' \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | sort
```

检查是否仍有超过 2 分钟的旧 EVE 文件：

```bash
find "${LOG_DIR}" -maxdepth 1 -type f -name 'eve*.json' -mmin +2 \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n'
```

查看容器日志，确认清理任务持续运行：

```bash
cat "${LOG_DIR}/suricata-json-cleanup.log" 2>/dev/null || true
docker logs --since 20m "${CONTAINER}" | tail -120
```

验证结果：

- 持续回放期间 EVE 文件持续轮转生成。
- 测试结束时，超过 2 分钟的旧 `eve*.json` 已被自动清理。
- 最新的 `eve*.json` 仍然保留且非空。
- 当前保留的 EVE 文件数量明显少于 10 分钟内按 1 分钟轮转产生的总文件数。

## 10. 恢复配置

```bash
docker cp "${TEST_DIR}/suricata-json-cleanup.orig" \
  "${CONTAINER}:/usr/local/bin/suricata-json-cleanup"
docker cp "${TEST_DIR}/suricata-json-cleanup.cron.orig" \
  "${CONTAINER}:/etc/cron.d/suricata-json-cleanup"
cp -a "${TEST_DIR}/suricata.yaml.orig" /etc/suricata-docker/suricata.yaml

docker exec "${CONTAINER}" suricata -T -c /etc/suricata/suricata.yaml -i "${CAPTURE_IFACE}" || true
docker restart "${CONTAINER}"
sleep 5
```

检查恢复结果：

```bash
docker exec "${CONTAINER}" cat /etc/cron.d/suricata-json-cleanup
docker exec "${CONTAINER}" grep -n 'KEEP_MINUTES' /usr/local/bin/suricata-json-cleanup
docker ps --filter "name=${CONTAINER}"
docker inspect "${CONTAINER}" --format '{{json .Args}}'
```

验证结果：

- cron 恢复为原始内容。
- `suricata-json-cleanup` 恢复为原始脚本。
- 容器重启后继续运行。
- 容器参数仍包含 `-i ${CAPTURE_IFACE}`。

## 11. 结果记录

| 项目 | 结果 | 证据/备注 |
|------|------|-----------|
| 容器运行状态 | 通过 | 2026-08-25 20:35:48 使用 `suricata:8.0.4-amd64-offline` 启动，参数为 `["-i","ens33","-c","/etc/suricata/suricata.yaml"]`，环境变量包含 `ENABLE_CRON=yes`；恢复后容器仍为 `Up`。 |
| pcap 文件存在 | 通过 | 文档列出的 16 个 pcap 文件均存在；`tcpreplay` 为 `/usr/bin/tcpreplay`，`jq` 为 `/usr/bin/jq`。 |
| pcap 持续回放 | 通过 | 按用户要求将回放速率提高为 `tcpreplay --pps=200`；2026-08-25 20:40:56 至 20:51:01 持续回放约 605 秒。各 pcap 输出 `Successful packets` 均大于 0，`Failed packets` 均为 0。 |
| EVE 生成 | 通过 | 生成非空 EVE 文件，例如 `eve.2026-08-25_20-51-02.json`，大小 27513 bytes；事件类型包含 `flow`、`http`、`stats`。 |
| MMS 识别 | 通过 | `eve.2026-08-25_20-51-02.json` 中匹配到 4 条 `app_proto=iec61850-mms` 记录，例如 `172.20.4.109:60026 -> 172.20.4.94:102`、`10.10.10.1:49152 -> 10.10.10.2:102`、`127.0.0.1:45298 -> 127.0.0.1:102`。 |
| EVE JSON 轮转 | 通过 | 临时配置 `rotate-interval: 1m` 后生成多个按时间命名的轮转文件；清理前可见 `eve.2026-08-25_20-48-51.json`、`eve.2026-08-25_20-50-02.json`、`eve.2026-08-25_20-51-02.json`。 |
| 过期 EVE 自动清理 | 通过 | 清理脚本临时设置 `KEEP_MINUTES="${SURICATA_JSON_KEEP_MINUTES:-2}"`，cron 临时设置为每分钟执行；日志显示 20:45 至 20:53 每分钟持续 `deleted=1`，20:53 后 `find ... -mmin +2` 无输出。 |
| 最新 EVE 保留 | 通过 | 20:53 清理后仍保留非空最新文件：`eve.2026-08-25_20-51-02.json` 27513 bytes、`eve.2026-08-25_20-52-03.json` 20654 bytes、`eve.2026-08-25_20-53-03.json` 2638 bytes。 |
| EVE stats 事件 | 通过 | 本次测试中出现 1 条 `stats` 事件，位于 `eve.2026-08-25_20-51-02.json`；其中 `app_layer.flow.iec61850-mms=6`、`app_layer.tx.iec61850-mms=870`。 |
| 配置恢复 | 通过 | 已恢复原始 cron：`*/10 * * * * root /usr/local/bin/suricata-json-cleanup ...`；`KEEP_MINUTES` 恢复为 `"$((KEEP_DAYS * 1440))"`；`suricata -T` 通过，容器重启后继续运行且参数仍包含 `-i ens33`。 |
