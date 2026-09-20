# implement.md — 执行记录（v4.0.0 已实现）

起点：`22f7c0e`（v3.1.4，工作树干净）。改动只进 `src/`，`sb.sh` 由构建生成；
本地 shellcheck 已升到 0.10.0（与 CI 对齐）。

**执行中改变计划的用户决定**：原计划把旧的 `ss-sb` 入口"迁移"成 SOCKS5 并重生成密码；
用户 2026-09-20 改为**保留原样不动**——不转换、不删除、重写配置时逐字节原样保留，
只在菜单 [8] 第 5 项暴露"移除"让操作者自己决定何时切换。下面阶段 5 按此记录。

## 阶段 1 · 常量与校验（00 / 20）✅

- 恢复 `SOCKS_USERNAME="sb"`、`RELAY_METHOD="2022-blake3-aes-256-gcm"`；删除 `SS_METHOD`
- 新增 `valid_socks_password`（16–128 位 `[A-Za-z0-9._~-]`）、`generate_socks_password`（`openssl rand -hex 24`）
- `choose_ss_port` → `choose_socks_port`（回车=随机、`1` 自定义、`0` 取消返回 2）；`valid_ss_password` 保留给上游与旧入口

## 阶段 2 · 渲染（30）✅

- 可选入站片段改成 `socks`（`users:[{username,password}]`，无 `network` 字段）+ UDP 阻断规则 tag `socks5-sb`
- `preserved_entry_inbound` 把旧 `ss-sb` 入站对象**逐字节**重新发出，并补回它自己的 `ss-sb` UDP 阻断规则
- 验证：两种形态都过真实内核 `check` + 真启动（hy2 独占 `443/udp`，TCP 入口不去抢 UDP）

## 阶段 3 · 客户端产物（50）✅

- `resss` → `ressocks5`（`socks5://sb:<pw>@host:port#socks5-<host>`），`ss.txt` → `socks5.txt`；旧的 `resss`/`ss.txt` 在旧入口存在时继续生成
- `sbox.json` socks 出站、`clash.yaml` `type: socks5`；成员顺序 SOCKS5 →（旧 ss）→ Hysteria2，与 selector 一致，默认节点恒为 `hy2-<host>`
- `print_socks_entry_share` 打印链接 + 用户名/密码；启用、改端口、改密码后都会打印
- 验证：真实内核 `check` 客户端配置（4 种形态）；真实 `curl --socks5-hostname` 握手

## 阶段 4 · 菜单（70）✅

- `socks_entry_is_enabled/port/password`、`socks_entry_candidate_with_inbound/without_inbound`（先删后插、幂等）、启用/停用/改端口/改密码、`remove_preserved_ss_entry`
- 入口收进菜单 `[8] 可选功能`（1 入口管理 / 2 上游中转）；`[5] 更改端口` 只剩 hy2（`请选择【0-1】`），`[6]` 只剩 UUID
- 启用流程打印**明文警示**（不加密、可被识别，仅限可信链路）
- 验证：单元用例（幂等、取消、无变化时配置 sha256 不变）

## 阶段 5 · 修复（85）✅

- 变量按实际职责命名：`REPAIR_SOCKS_ENABLED/PORT/PASSWORD` + `REPAIR_PRESERVED_INBOUND/PORT/KEY`
- 修复门禁允许"≤1 个 socks 入口 + ≤1 个旧 ss 入口"；`config_contains_removed_protocol` 只剩 vless
- 重写时旧 `ss-sb` 入站**原样**带回；从零重建（REBUILD）只生成 hy2，不臆造入口
- 清理：`render_repair_config` 里残留的 `local ss_password=$REPAIR_SS_PASSWORD` 已删除（该变量在 4.0.0 已不存在），`tests/verify.sh` 把 `REPAIR_SS_PASSWORD` 加入退役名单
- 验证：`tests/repair.sh` 51 例，含"原样保留"逐字节比对与"不臆造入口"

## 阶段 6 · 测试与文档 ✅

- `tests/verify.sh` 钉死串反向重写：钉 SOCKS5 集成、禁旧生产者、禁 `REPAIR_SS_*`/`ss_entry_enabled`、节点顺序 = SOCKS5 → 旧 ss → Hysteria2（偏移 + 发射点双重钉）
- `tests/unit.sh` 313 例、`tests/repair.sh` 51 例；关键断言都做过变异验证（去掉保留标记 / 去掉密码 / 顺序反转等）
- README（协议段、菜单、【8】说明、明文警示、版本）、`.trellis/spec/**`（协议、受管文件、钉死串、函数计数 253 → 263）

## 阶段 7 · 发布 ✅

- 四处版本 → `4.0.0`；门禁绿 + `check-version-bump.sh`：3.1.4 → 4.0.0 覆盖 8 处源码变更
- 真实内核三件套：hy2-only 真启动 / 启用后真启动 + **curl --socks5 真实握手 OK** / 旧 SS 入口原样保留后真启动 / 客户端 4 形态真实 `check`
- 提交计划给用户确认 → 推送 → 确认 CI 绿 → 归档 + journal

## 复核门

- 阶段 2 结束：确认未启用的形态没有回归（这是地基）✅
- 阶段 4 结束：启用/停用/幂等的真实验证齐备 ✅
- 阶段 7：推送前一次性给出提交计划 ✅
