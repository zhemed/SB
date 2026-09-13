# 彻底移除 VLESS Reality 协议

## Goal

从产品中完全移除 VLESS Reality，使脚本只提供 **Hysteria2**（UDP/QUIC，证书）与 **SOCKS5**
（TCP，明文）两种协议。移除后不留下任何悬空引用、死代码或描述不存在功能的文档。

用户已确认的附加范围：**去掉客户端配置里的「负载均衡」与「自动选择」分组**——只剩一个
可用节点时，对单代理做 load-balance/url-test 没有意义。

## Requirements

### R1 协议面收敛

- 服务端配置不再包含 `vless` inbound。
- 不再生成、存储、校验 Reality 密钥对、`short_id` 与 `public.key` 文件。
- 不再产生 `vl_reality.txt` 节点文件与 `vless://` 分享链接。
- 安装流程不再调用 `sing-box generate reality-keypair`。

### R2 共享逻辑必须重接，而不是删除

- **UUID 归属变更**：UUID 目前与 Hysteria2 共用，但其读取来源是 VLESS inbound
  （`src/50-client-output.sh:85`）。移除后必须改为从 Hysteria2 inbound 读取，
  且 `change_credentials` 的成功提示不得再提及 VLESS。
- **端口保留约束消失**：SOCKS5 端口当前以 VLESS 端口为 `$reserved`
  （`src/20-ports.sh:90`）。移除后不得留下指向已删变量的保留逻辑或重试循环。
- **客户端分组重构**：sing-box 的 `auto`（urltest）与 Clash 的 `负载均衡`/`自动选择`
  组删除；`proxy` selector 与 `🌍选择代理节点` select 收敛为 Hysteria2 + SOCKS5 + DIRECT。

### R3 修复模块的判定标准必须重新定义

- `load_repair_config_values` 中把 Reality 私钥/short_id 当**必需字段**的 `jq -er` 读取
  （`src/85-repair.sh:31-32`）必须移除，否则对合法的新配置会硬失败。
- 「节点参数是否可恢复」的判据、`REBUILD` 重建路径（重新生成 Reality 密钥对的部分）
  必须按新协议集重写，而不是留下永不执行的死分支。
- 修复报告字段不得再输出 VLESS 专属项。

### R4 遗留安装的处理

- 已安装 Reality 的旧版本升级/修复时，不得因为配置里存在 `vless` inbound 而崩溃或
  静默产生半套状态。**行为必须明确并在报告中可见**（接受「重写为标准新配置」或
  「明确拒绝并说明」，但必须是刻意的选择，不能是意外）。
- `managed_install_data_present` 对 `public.key` 的检测保留：它仍用于识别旧安装。

### R5 测试覆盖不得静默流失

- `tests/verify.sh` 中所有会失败的字符串钉死必须同步更新。
- 因功能消失而失去意义的用例可以删除，但**每一处删除都要判断等价覆盖是否已在
  Hysteria2 / SOCKS5 上存在**；若不存在，必须改写而不是删除。
- 依赖被删结构的 `awk` 范围抽取（`tests/verify.sh:130` 的 `负载均衡` 锚点）必须一并修正，
  不得留下会静默空过的断言。

### R6 文档与规范必须与新现实一致

- `README.md` 的协议描述、项目结构表、对外能力声明全部更新。
- `.trellis/spec/` 中所有描述 VLESS/Reality 行为、以其为示例、或统计函数数量的位置更新；
  规范描述的产品必须与代码一致。

### R7 已知代价（知情接受）

移除后本脚本**不再提供任何 TCP + TLS 伪装且免证书的协议**：Hysteria2 是 UDP，
SOCKS5 是明文。此代价已向用户说明并接受。

## Constraints

- 只改 `src/`，不直接编辑 `sb.sh`；提交前必须 `bash scripts/build.sh` 重新生成。
- 遵守 `spec/runtime/atomic-writes.md`（candidate → 校验 → `mv -fT`）与
  `spec/shell/bash-conventions.md`（无 `set -e`、显式 `|| return 1`、退出码语义）。
- 移除范围外的行为不得改变：ACME 证书链、SOCKS5 的 UDP 阻断与明文告警、
  自签证书回退、安装/修复事务与信号回滚、`switch_ip_priority`（`ipv` → `domain_strategy`
  是全局出站策略，与 Reality 无关，保留）。
- 不得降低 `tests/verify.sh` 的断言强度：改写后的断言必须仍然能捕捉真实回归。

## Acceptance Criteria

- [x] `grep -riE 'vless|reality|short_id' src/` 只剩 5 处**有注释说明的遗留兼容判据**
      （迁移检测、旧版本临时文件清扫），无协议逻辑
- [x] `sb.sh` 重新生成，`bash scripts/build.sh --check` 通过
- [x] `bash tests/verify.sh` 全绿（verify + unit 273 + repair 48）
- [x] 服务端配置只含 `hysteria2` 与 `socks` inbound
- [x] 客户端配置不含 urltest / load-balance / url-test 分组，且 proxy selector 不再
      `default: "auto"`
- [x] 旧配置迁移有回归测试（`legacy_vless_config_is_migrated`），且**验证过在移除
      短路判据后会失败**（非空断言）
- [x] `tests/repair.sh` 的节点参数判据已覆盖新协议集
- [x] `README.md` 与 `.trellis/spec/` 不再声明脚本提供 VLESS Reality

## Outcome

已完成。27 个文件变更，净删除 712 行（294 增 / 1006 删）。

**产品代码**：8 个 `src/` 模块。删除 6 个整函数 + 3 个 Reality 数据流；
重接 4 处共享逻辑（`result()` 的 UUID 来源、`change_ports` 的 jq 链头、
`changeuuid` 的双目标写入、`load_repair_config_values` 的必需字段门）。

**测试**：`repair.sh` 净减 6 个用例（覆盖评估见 implement.md），
新增 1 个迁移回归；`verify.sh` 的两处自动分组断言改写为「不含任何自动选择分组」
的结构性断言，保住了原不变量。

**关键修正**（见 design.md §盘点修正）：
1. `85-repair.sh:18-24` 的 `jq -e` 门才是头号硬失败点
2. `change_ports():601` 是 `||` 链第一环，不改会让端口管理整体失效
3. `changeuuid()` 是双目标写入，不是改文案
4. 方案 A 必须同时改 `try_repair_config_source` 短路，否则旧配置永远原样保留

**无法本地验证**：测试桩的 `check` 只做 `jq -e .`，本机无真实内核 →
新配置对 sing-box 1.10.7 的语义合法性需真机安装确认。

## Out of Scope

- 新增其他协议（不引入 Trojan/VMess 等替代）
- 改动 Hysteria2 或 SOCKS5 自身的参数模型
- 证书管理（ACME / 自签）的任何行为变更
- 旧版 Reality 用户的数据迁移工具（只要求行为明确且有记录）
