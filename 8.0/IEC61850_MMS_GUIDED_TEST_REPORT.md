# IEC61850 MMS 指南驱动测试报告

测试依据：`local-src/suricata-master/learning/08-testing-verification/IEC61850_MMS_*.md`

## 测试环境

| 项目 | 值 |
|------|----|
| 测试时间 | `2026-07-10 17:39:07 CST +0800` |
| 工作目录 | `/home/work/docker-suricata/8.0` |
| 测试方式 | Docker 镜像内 `/usr/bin/suricata -r <pcap>` 离线解析 |
| 测试镜像 | `suricata:8.0.4-amd64-offline` |
| 镜像架构 | `amd64/linux` |
| 镜像 ID | `sha256:b5ec3dbbea6262d2d3f51839afd805e117a0ed514fd2f08178b76e13aa03cc2d` |
| pcap 数据集 | `/home/work/pcaps_dataset` |
| Suricata 配置 | `/etc/suricata-docker/suricata.yaml` |
| 测试输出目录 | `/tmp/iec61850_mms_guided_test` |
| 机器可执行源码版 Suricata | 不存在：`local-src/suricata-master/src/suricata` 缺失 |

## 总览

| 范围 | 总数 | 通过 | 失败 | 跳过/未执行 |
|------|------|------|------|-------------|
| pcap 离线解析回归 | 33 | 31 | 2 | 0 |
| Rust 单元测试 | 1 | 0 | 0 | 1 |

## suricata.yaml 配置核查

| 检查项 | 结果 | 结论 |
|--------|------|------|
| EVE 输出启用 | `outputs.1.eve-log.enabled = yes` | 正常 |
| EVE 文件名 | `outputs.1.eve-log.filename = eve.%Y-%m-%d_%H-%M-%S.json` | 正常 |
| EVE 类型包含 MMS | `outputs.1.eve-log.types.31 = iec61850_mms` | 正常 |
| App-layer MMS 启用 | `app-layer.protocols.iec61850-mms.enabled = yes` | 正常 |
| MMS 检测端口 | `app-layer.protocols.iec61850-mms.detection-ports.dp = 102` | 正常 |
| 与源码模板关键段落差异 | 对比 `local-src/suricata-master/suricata.yaml` 关键段落无差异 | 正常 |

结论：本轮异常不是由于 `suricata.yaml` 未启用 `iec61850_mms` 或 TCP/102 检测端口配置错误导致。

## pcap 测试明细

| 状态 | 指南范围 | 用例 | MMS 事件 | Anomaly | 备注 |
|------|----------|------|----------|---------|------|
| PASS | Parser | `get_name_list` | 6 | 1 | 指南允许握手阶段 `malformed_data` |
| PASS | Parser | `get_variable_access_attributes` | 6 | 1 | 关键 service 存在 |
| PASS | Parser | `get_named_variable_list_attributes` | 46 | 0 | 关键 service 存在 |
| PASS | Read | `iec61850_read` | 6 | 1 | 符合指南预期 |
| FAIL | Read | `mms_readRequest` | 4 | 1 | 指南预期 `mms_events=2 malformed=0` |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_array` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_bcd` | 4 | 1 | 已知 BCD 限制仍按指南验证 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_binary_time` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_bit_string` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_boolean` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_boolean_array` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_floating_point` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_integer` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_mms_string` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_octet_string` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_structure` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_unsigned` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_utc_time` | 4 | 1 | `read` service 存在 |
| PASS | Read Data CHOICE | `iec61850_mms_read_data_visible_string` | 4 | 1 | `read` service 存在 |
| PASS | Write | `iec61850_write` | 6 | 1 | `write` service 存在 |
| PASS | Write Generated | `write_01_vmd_integer_invoke_only_response` | 6 | 0 | `write` / `unknown` service 存在 |
| PASS | Write Generated | `write_02_domain_boolean_success_response` | 6 | 0 | `write` service 存在 |
| PASS | Write Generated | `write_03_multi_variable_struct_partial_failure` | 6 | 0 | `write` service 存在 |
| PASS | Write Generated | `write_04_variable_list_name_unsigned_success` | 6 | 0 | `write` service 存在 |
| PASS | Write Generated | `write_05_alternate_component_index` | 6 | 0 | `write` service 存在 |
| PASS | Write Generated | `write_06_alternate_range_all_elements` | 6 | 0 | `write` service 存在 |
| PASS | Write Generated | `write_07_unknown_alternate_malformed_failure_response` | 6 | 0 | `write` service 存在 |
| PASS | Firmware Write | `firmware_segmented` | 8 | 0 | `initiate_download_sequence` / `download_segment` / `terminate_download_sequence` 存在 |
| PASS | Firmware Write | `firmware_segmented_multi` | 10 | 0 | 三类固件写入 service 存在 |
| PASS | File Transfer | `file_upload` | 4 | 0 | 符合指南预期 |
| PASS | File Transfer | `file_download` | 10 | 0 | 符合指南预期 |
| FAIL | Mixed Traffic | `client_server_mms_clean` | 789 | 1 | 指南预期 788 |
| PASS | Smoke | `mms` | 8 | 0 | 容器/veth smoke 样本补充验证 |

## 失败项分析

| 用例 | pcap SHA256 | 现象 | 定位结果 | 初步判断 |
|------|-------------|------|----------|----------|
| `mms_readRequest` | `446d322be5ace29b50a4663037a9fb016460bd362db6815209987f2389a3d119` | 当前输出 4 条 `iec61850_mms`、1 条 `malformed_data`；指南预期 2 条、0 malformed | 4 条 MMS 分别为 `pcap_cnt=9 initiate_request`、`pcap_cnt=11 null MMS + malformed_data`、`pcap_cnt=13 read request`、`pcap_cnt=15 conclude_request` | 更像指南预期与当前 pcap/解析器行为不一致，不是配置未启用 |
| `client_server_mms_clean` | `4819e5f35aee3a702a333bb95c91a880c7f0866118f9c1f2f399f53d45b25ac6` | 当前输出 789 条 `iec61850_mms`、1 条 `malformed_data`；指南预期 788 | 多出的异常位置在 `pcap_cnt=781`，EVE 中存在一条 `event_type=iec61850_mms` 且 `iec61850_mms=null`，同时有 `malformed_data` anomaly | pcap 哈希与指南记录一致，建议复核基准是否应排除 null MMS 事务或更新预期计数 |

## Unit Test 指南执行情况

| 指南 | 命令 | 结果 | 原因 |
|------|------|------|------|
| `IEC61850_MMS_Unit_Test_Guide.md` | `cargo test --lib iec61850mms --manifest-path rust/Cargo.toml` | 未执行 | 当前源码目录缺少 `local-src/suricata-master/rust/Cargo.toml`，且 `local-src/suricata-master/src/suricata` 也不存在，说明该源码树不是已配置/已构建状态 |

## 建议

| 优先级 | 建议 | 说明 |
|--------|------|------|
| 高 | 复核 `mms-readRequest.pcap` 指南预期 | 当前样本包含 initiate/conclude 以及 malformed 空事务，指南中的 `mms_events=2 malformed=0` 可能已经过期 |
| 高 | 复核 `client-server-mms-clean.pcap` 冻结基准 | pcap 哈希与指南一致，但当前解析器多输出 `pcap_cnt=781` 的 null MMS 事务；需要决定基准是否排除此类事务 |
| 中 | 对 null MMS 事务建立明确判定规则 | 测试统计可选择“所有 `event_type=iec61850_mms`”或“仅 `.iec61850_mms` 为 object 的事务”，两种口径会影响计数 |
| 中 | 准备源码构建环境后补跑 Unit Test | 需要恢复/生成 `rust/Cargo.toml` 和 `./src/suricata`，再按 Unit Test 指南执行 |

## 结论

| 结论项 | 结果 |
|--------|------|
| 当前容器 Suricata 是否能解析 IEC61850/MMS | 是 |
| 当前 `suricata.yaml` 是否启用 MMS 输出与协议解析 | 是 |
| Read/Write/Firmware/File Transfer 主路径是否可用 | 是 |
| 严格按指南计数是否全部通过 | 否，2 个计数预期不一致 |
| 是否发现配置导致的失败 | 否 |
