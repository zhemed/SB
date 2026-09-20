# design.md — 5.0.0 彻底移除旧 Shadowsocks-2022 入口兼容层

## 背景与决定链

1. 用户在只有 hysteria2 + SOCKS5 的新机器上看到子菜单仍列出「5：移除旧的 Shadowsocks-2022 入口」。
2. 第一版方案（按状态隐藏）被用户否决：「ss 彻底移除就行了，这个是多此一举」。
3. 用户在二选一里明确选了**连兼容层一起拆**，并选 **5.0.0**（破坏性变更）。

保留原样的那次决定（4.0.0，操作者 2026-09-20）就此撤销：本版本不再识别、不再保留、
不再移除旧入口。仍在跑旧入口的机器，升级后一旦重写配置（改端口/凭据、修复）就会丢掉
该入口——这是用户明确接受的代价，所以必须有**明确警告**，不能静默。

## 不动的部分

- **上游/中转那一跳**仍是 Shadowsocks-2022：`RELAY_METHOD`、`valid_ss_password`（44 位 base64）、
  `relay.conf`、`manage_relay`、客户端不出现在这里（中转只在服务端之间）。全部保留。
- Hysteria2 主线、SOCKS5 可选入口、菜单结构、配置格式、受管文件策略都不变。

## 改动清单（按模块）

### src/30-server-config.sh

- 删掉 `preserved_entry_inbound` 分支（原 20-27 行）：不再逐字节重发旧入站，也不再补它的 `ss-sb` UDP 规则。
- 新增警告（放在 relay 警告旁边，同一风格）：`retired_ss_entry_port` 命中时打印
  「当前配置里还有 4.0.0 之前的 Shadowsocks-2022 入口（端口 N），本版本不再保留它」+
  「本次重写会把它移除；仍在用它连接的人会断开」。

### src/50-client-output.sh

- `result()`：删掉 `ss_enabled/ss_port/ss_password` 的探测与其校验分支（不再有旧 SS 客户端产物）。
- 删掉 `resss()`（SS 分享链接/二维码生成器）。
- `sb_client()`：删掉 `ss_*` 片段与 emission（`${ss_outbound_field}`、`${ss_selector_member}`、
  `${ss_clash_proxy}`、`${ss_clash_member}`）；节点顺序变成 SOCKS5 → Hysteria2。
- `sbshare()`：删掉 `ss_tmp` 分支；**保留**对遗留 `ss.txt` 的清理调用（`remove_saved_ss_link`），
  文案改成「本版本已不再生成 ss.txt，但遗留文件无法删除，请手动检查」。
- `remove_saved_ss_link()` 保留：它就是清理遗留 ss.txt 的受管文件清理器。

### src/70-management.sh

- 删掉 `preserved_ss_entry_is_enabled` / `preserved_ss_entry_port` / `preserved_ss_candidate_without_inbound` /
  `remove_preserved_ss_entry` 四个函数。
- 新增 `retired_ss_entry_port()`：读**活配置**里 `ss-sb` 的端口（只读，不写），
  给上面那个警告与菜单提示共用。
- `manage_socks_entry()`：去掉旧入口提示与第 5 项，回到静态 `请选择【0-4】：`，非法输入提示 0–4。
- `manage_optional_features()`：把「旧的 Shadowsocks-2022 入口仍在运行」换成按状态的两行提示：
  配置里仍有旧入口时说明「本版本不再支持它，下次重写会移除，用它的客户端会断开」。
- `change_credentials()` 的提示改成「上游中转的 Shadowsocks-2022 密钥在菜单[8]第2项里管理」
  （4.0.0 起 [8] 管的是上游密钥，原文案容易被读成"入口密钥"）。

### src/85-repair.sh

- 删掉 `REPAIR_PRESERVED_INBOUND/PORT/KEY` 与其提取、校验、注入（`render_repair_config` 少一个 local）。
- `config_contains_removed_protocol` 把 `shadowsocks + tag=ss-sb` 重新计入：
  带旧入口的配置属于"需要重写"，重写后旧入口消失，标签写「并移除已废弃的 inbound」。
- 修复门禁仍然接受"≤1 个 ss-sb"的配置（能读才能重建），但不再把它当需要保留的东西。

### tests/

- `verify.sh`：删掉 `resss()` / `ss.txt` / `preserved_entry_inbound` / `preserved_ss_*` 的正向钉死；
  改成**禁**这些名字回归（函数定义 + 变量名），并把顺序钉成 SOCKS5 → Hysteria2；
  新钉 `请选择【0-4】`、`retired_ss_entry_port()`、警告文案。
- `unit.sh`：删掉 preserved 相关用例与 ss.txt 断言；子菜单用例改成 0–4 且不再 dispatch remove；
  新增「活配置里有旧 ss-sb 时报出提示」与「重写时不再发 ss-sb 入站/UDP 规则」。
- `repair.sh`：夹具去掉旧入站；`preserved_ss_inbound_is_preserved_verbatim` 换成
  `retired_ss_inbound_is_rewritten_away`（旧入口被视为已废弃协议 → 重建后不存在 + 标签说明）。

### 文档

`README.md`（删掉"旧入口保留"段、节点顺序、加 5.0.0 升级警示与版本号）、
`.trellis/spec/**`（version-pins、module-structure、user-output、managed-assets、input-validation、
writing-tests、cross-layer-thinking-guide；函数计数重算）。

### 验证

- 本地门禁（`tests/verify.sh`，含 shellcheck 0.10.0）。
- **真实内核**：新写 `/tmp/sbverify/v5.sh`：① 全新 hy2-only 启动；② 启用 SOCKS5 + 真实
  `curl --socks5-hostname` 握手；③ **带旧 `ss-sb` 入站的配置重写后旧入口消失、并打印警告、
  服务能起**；④ 客户端 4 形态退化成 2 形态真实 `check`。
- 变异验证：把 `resss()`、`preserved_entry_inbound`、旧第 5 项塞回去，门禁必须红。
- `scripts/check-version-bump.sh`：4.0.0 → 5.0.0。

## 风险与对策

| 风险 | 对策 |
|---|---|
| 有人还在用旧入口，升级后悄悄消失 | 重写时打印两行明确警告；菜单 [8] 在配置仍含旧入口时也提示；README 升级段写清 |
| 修复流程把"有旧入口的配置"判成健康而不重写 | `config_contains_removed_protocol` 计入 ss-sb，标签与重写行为可验证 |
| 遗留 ss.txt 变孤儿 | `sbshare` 继续清理它并提示手动检查（失败时报错不静默） |
| 上游中转被误删 | 明确不动：`valid_ss_password`、`RELAY_METHOD`、relay 的钉死串与用例全部保留 |
