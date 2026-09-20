# implement.md — 执行计划

起点：`22f7c0e`（v3.1.4，工作树干净）。改动只进 `src/`，`sb.sh` 由构建生成；
一次性推送；本地 shellcheck 已升到 0.10.0（与 CI 对齐）。

## 阶段 1 · 常量与校验（20 / 00）

- [ ] 恢复 `SOCKS_USERNAME="sb"`，删除 `SS_METHOD`
- [ ] `valid_socks_password` / `generate_socks_password`；`choose_ss_port` → `choose_socks_port`

## 阶段 2 · 渲染（30）

- [ ] 可选入站片段改成 `socks` + `users`；UDP 阻断规则 tag 改 `socks5-sb`
- 验证：hy2-only 与启用后两种配置都过真实内核 `check` + 真启动

## 阶段 3 · 客户端产物（50）

- [ ] `resss` → `ressocks5`（`socks5://sb:<pw>@host:port`），`ss.txt` → `socks5.txt`
- [ ] `sbox.json` socks 出站、`clash.yaml` `type: socks5`、成员顺序不变
- [ ] `print_ss_entry_share` → `print_socks_entry_share`（链接 + 用户名 + 密码）
- 验证：真实内核 `check` 客户端配置；真实 curl 握手

## 阶段 4 · 菜单（70）

- [ ] `socks_entry_*` 状态查询、启用/停用/改端口/改密码、候选构造（先删后插、幂等）
- [ ] 启用流程打印**明文警示**
- 验证：单元用例（幂等、取消、配置 sha256 不变）

## 阶段 5 · 修复（85）

- [ ] `REPAIR_SOCKS_ENTRY_*`；`ss-sb` 计入"已移除协议"→ 迁移为 socks 并重生成密码
- 验证：三形态用例

## 阶段 6 · 测试与文档

- [ ] `tests/verify.sh` 钉死串整体反向；`tests/unit.sh` 凭据/候选/取消用例；`tests/repair.sh` 夹具
- [ ] README（协议段、菜单、【8】说明、明文警示、版本）
- [ ] `.trellis/spec/**`（协议、受管文件、钉死串、耦合表、函数计数）

## 阶段 7 · 发布

- [ ] 四处版本 → `4.0.0`；门禁 + `check-version-bump.sh` 绿
- [ ] 真实内核三件套：hy2-only 真启动 / 启用后真启动 / **curl --socks5 真实握手** / 中转链路回归
- [ ] 提交计划给用户确认 → 推送 → 确认 CI 绿 → 归档 + journal

## 复核门

- 阶段 2 结束：确认未启用的形态没有回归（这是地基）。
- 阶段 4 结束：启用/停用/幂等的真实验证齐备。
- 阶段 7：推送前一次性给出提交计划。
