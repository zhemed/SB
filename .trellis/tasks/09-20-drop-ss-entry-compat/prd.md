# prd.md — 5.0.0：彻底移除旧 Shadowsocks-2022 入口的兼容层

## Goal

撤销 4.0.0 的"旧 SS 入口原样保留"兼容路径：不再识别、保留或移除 3.0.0–3.1.4 创建的
Shadowsocks-2022 入口。菜单 [8] 子菜单回到 0–4，新机器上不再出现任何与旧入口相关的条目。

## 背景（决定链）

1. 用户在新机器上看到「5：移除旧的 Shadowsocks-2022 入口」——那里根本没有旧入口。
2. 第一版方案（按状态隐藏第 5 项）被否决：「ss 彻底移除就行了，这个是多此一举」。
3. 用户在二选一里选定**连兼容层一起拆**，并选定 **5.0.0**（破坏性变更）。

## Requirements

- 删除：保留解析/渲染（`preserved_entry_inbound`）、移除流程（`remove_preserved_ss_entry`）、
  客户端 SS 产物（`resss`、sbox/clash 的 ss 片段、`ss_enabled/ss_port/ss_password`）、
  修复保留路径（`REPAIR_PRESERVED_*`）、菜单第 5 项与相关提示。
- 保留：上游/中转的 Shadowsocks-2022（`RELAY_METHOD`、`valid_ss_password`、`relay.conf`、`manage_relay`）。
- 不得静默丢配置：配置里仍有旧 `ss-sb` 入站时，重写前必须打印明确警告（会移除、会断连）。
- 修复流程把"仍带旧 `ss-sb` 入站"的配置视为**含已废弃协议**：重写为标准配置并说明。
- 遗留 `ss.txt` 继续由 `sbshare` 清理，失败要报错，不静默。
- 版本四处同步到 5.0.0（`VERSION`、`src/00-bootstrap.sh`、`README.md`、规范钉死表）。

## Acceptance Criteria

- [ ] 全新安装（hysteria2 only）与启用 SOCKS5 后，真实内核都能 `check` + 真启动；SOCKS5 真实握手通过
- [ ] 带旧 `ss-sb` 入站的配置重写后：旧入口消失、打印警告、服务能起（真实内核验证）
- [ ] 门禁绿：unit / repair / verify 全部通过，shellcheck 0.10.0 无输出
- [ ] 变异验证：把 `resss()` / `preserved_entry_inbound` / 第 5 项塞回 `src/`，门禁必须红
- [ ] `scripts/check-version-bump.sh` 认 4.0.0 → 5.0.0
- [ ] README 升级段说明"旧 SS 入口将不再被保留"；规范里不再有"4.0.0 保留旧入口"的说法

## Notes

- 破坏性变更：仍在跑旧入口的机器，升级后重写配置时入口会被移除。用户已知情并接受。
- 不再提供任何"迁移到 SOCKS5"的自动化：想继续用 TCP 备用入口就手动启用 SOCKS5。
