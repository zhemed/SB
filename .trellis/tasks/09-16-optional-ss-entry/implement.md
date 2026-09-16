# implement.md — 执行计划

起点：`87dda54`（v3.0.1，工作树干净）。改动只进 `src/`，`sb.sh` 由 `scripts/build.sh` 生成；
最后一次性推送（推送即发布）。

---

## 阶段 0 · 基线

- [x] `bash scripts/build.sh && bash tests/verify.sh` 先跑一遍确认绿灯
- [x] `shellcheck --version` ≥ 0.10.0（本地版本差会漏掉新规则，上一轮就栽在这）

## 阶段 1 · 渲染层支持"未启用"

1. `src/30-server-config.sh`
   - [x] `ss_entry_enabled`（默认 0）+ 入站片段 + UDP 规则片段
2. `src/20-ports.sh`
   - [x] `insport`：去掉 SS 端口询问与 SS 密钥生成
   - [x] 新增 `choose_ss_port`（回车/1 随机、2 自定义）
   - [x] `ssport` 若不再被使用则删除（避免留死代码）
- 验证：
  - [x] 用真实内核渲染 hy2-only 配置：`check` 通过、真启动、`ss -ltnup` 只有 hy2 的 UDP
  - [x] 渲染配置里不含 `ss-sb`

## 阶段 2 · 客户端产物跟随

1. `src/50-client-output.sh`
   - [x] `result()` 容忍缺失（`ss_enabled`）
   - [x] `sb_client()`：sbox 出站块、clash 条目、两处成员列表条件化
   - [x] `sbshare()`：未启用时不生成/删除 `ss.txt`，聚合只拼 hy2
- 验证：
  - [x] 未启用时生成的 `sbox.json` / `clash.yaml` 用真实内核 `check`（单成员 selector）
  - [x] 已启用时产物与 v3.0.1 一致（对照上一轮的验收配置）

## 阶段 3 · 菜单[8] 可选功能

1. `src/70-management.sh`
   - [x] `change_ports` / `change_credentials` 移除 SS 选项
   - [x] `manage_optional_features` / `manage_ss_entry`
   - [x] `enable_ss_entry` / `disable_ss_entry` / `change_ss_port`
   - [x] 候选构造（先删后插，幂等）+ 状态查询
2. `src/90-main.sh`
   - [x] 菜单文案 `8. 可选功能`，子菜单提示串
   - [x] 安装提示只放行 hy2；SS 的密钥/NTP 警告移到启用动作里
- 验证：
  - [x] 单元测试覆盖候选构造的幂等与形态（真实 jq）
  - [x] 启用/停用后的配置用真实内核 `check` + 真启动

## 阶段 4 · 修复三形态

1. `src/85-repair.sh`
   - [x] `REPAIR_SS_ENABLED` + gate 放宽（ss ≤1、socks ≤1、不同时出现）
   - [x] `render_repair_config` 传 `ss_entry_enabled`
- 验证：
  - [x] `tests/repair.sh`：ss-sb 保留用例、socks 迁移用例（已有）、hy2-only 不补齐用例

## 阶段 5 · 测试与文档

- [x] `tests/verify.sh`：菜单钉死串、`[0-2]`/`[0-4]`、`insport` 不再引用 `ss_password` 的负向断言、SS 集成串按新位置更新
- [x] `tests/unit.sh`：SS 入口候选、`result()` 缺 ss 的路径、hy2-only 渲染断言
- [x] `README.md`：协议表（默认只装 hy2、SS 为可选）、菜单说明
- [x] `.trellis/spec/{shell,runtime,build,tests}/`：菜单归属、受管资产、钉死串、耦合表

## 阶段 6 · 发布

- [x] 四处版本号 → `3.1.0`
- [x] `bash scripts/build.sh && bash tests/verify.sh` 绿（含 shellcheck 0.10.0）
- [x] `bash scripts/check-version-bump.sh`
- [x] 真实内核三件套复验（hy2-only 真启动 / 启用后 SS 真握手 / 中转链路）
- [x] 提交计划给用户确认 → 推送 → 确认 CI 绿

## 复核门

- 阶段 1 结束：确认「未启用」渲染形态无误（这是整个改动的地基）。
- 阶段 3 结束：启用/停用/幂等的真实验证齐备。
- 阶段 6：推送前一次性给出提交计划。

---

## 完成记录

- 门禁：`bash tests/verify.sh` 绿（shellcheck 0.10.0；unit 290、repair 50）。
- 真实内核 1.10.7 复验：hy2-only `check` + 真启动；启用后 `check` + 真启动 + SS 真握手；
  客户端两种形态由 `sb_client` 真实生成并按行校验；中转链路端到端回归通过。
- 版本：`3.1.0`（`VERSION` / `sb_version` / README / 测试钉死四处同步），
  `check-version-bump.sh` 通过。
- 抓到并修掉一个真 bug：片段结尾换行被命令替换吃掉，Clash 出现两个结构性错误（见 design.md §9.3），
  已加回归用例。
