# Journal - SB (Part 1)

> AI development session journal
> Started: 2026-09-13

---



## Session 1: 启用 Trellis、重建规范、移除 VLESS Reality、版本与 CI 治理、sing-box 版本调查
<!-- trellis-session: v=2 fp=6c1c7c3420bdc978 -->

**Date**: 2026-09-13
**Task**: 启用 Trellis、重建规范、移除 VLESS Reality、版本与 CI 治理、sing-box 版本调查
**Branch**: `main`

### Summary

从上游拉取仓库后启用 Trellis；用真实规范替换 fullstack 模板占位；移除 VLESS Reality 并升至 2.0.0/2.0.1；修复启动前哨窗口与撕裂目录自锁；修复节点顺序与 Clash 默认项回归；新增版本号守卫并接入 CI；调查 sing-box 1.15 与配置兼容性（仅研究，已归档）。

### Main Changes

- 启用 Trellis 并重建 .trellis/spec/：删除不适用的 backend/frontend 层，按仓库真实职责建 shell/runtime/build/tests 四层共 15 篇规范，全部引用均经行号与引文核验
- 移除 VLESS Reality（e535d97）：改 8 个 src 模块，删 6 个整函数，重接 4 处共享逻辑；旧配置改为自动迁移重写；补 legacy_vless_config_is_migrated 回归并验证其在旧代码上会失败
- 修复启动前哨窗口（24f6748）：陷阱提前安装；ACME 恢复点按路径归属判定，避免在用户未决断时自动消耗；撕裂的受管目录改为可识别接管
- 修复节点顺序与 Clash 默认项（84975fd）：统一 SOCKS5 在前；发现并修复删除自动分组导致 Clash 默认走 DIRECT 的回归；加 4 条断言，含「明文协议不得作默认」
- 治理版本与 CI：升 2.0.0/2.0.1；新增 scripts/check-version-bump.sh 强制「改 src 必升版」；actions/checkout 升 v7 消除 Node 20 弃用告警
- 调查 sing-box 版本兼容性并归档（2835591）：实测三类配置在 5 个内核版本的通过情况，结论见 .trellis/tasks/archive/2026-09/09-13-singbox-version-compat-research/research.md

### Git Commits

| Hash | Message |
|------|---------|
| `d18da36` | docs(trellis): 用真实规范替换 fullstack 模板占位 spec |
| `e535d97` | feat!: 彻底移除 VLESS Reality，仅保留 Hysteria2 与 SOCKS5 |
| `24f6748` | fix: 关闭启动前哨窗口并清理死代码，修复撕裂目录自锁 |
| `84975fd` | fix: 统一节点顺序为 SOCKS5 在前，并修复 Clash 默认走 DIRECT 的回归 |
| `e4cda5d` | release: 版本升至 2.0.1 |
| `53dc801` | feat(ci): 新增强制版本号同步的守卫脚本 |
| `d6d0326` | ci: actions/checkout 由 v4 升至 v7 |
| `710a46e` | docs(spec): 记录「测试套件无法校验配置语义」这一持久限制 |
| `2835591` | chore(task): 归档 sing-box 版本兼容性调查 |

### Testing

- [OK] tests/verify.sh 全绿（含真实 shellcheck；此前本地未装导致 SC2016 连过两个提交才在 CI 暴露，已装并修复）
- [OK] unit.sh 273 项 / repair.sh 48 项通过；新增断言均验证过在改动前会失败
- [OK] CI 连续三次成功；版本守卫已在 CI 实际生效且基准解析正确
- [OK] sing-box 配置兼容性用真实内核二进制验证（填补套件无法校验配置语义的缺口）

### Status

[OK] **Completed**

### Next Steps

- 客户端 sbox.json 自 sing-box 1.13.0 起已不可用（legacy DNS + dns outbound + tun sniff），独立于内核升级，待决策是否单独修复
- 服务端内核升级待 1.15 稳定版后评估；升级与配置迁移必须同时进行（两种形式互不兼容）
- 本轮改动已推到 origin/main


## Session 2: v3.0.0：SOCKS5 入站换 Shadowsocks-2022 + 上游/中转能力
<!-- trellis-session: v=2 fp=28abc5579ebc4c7d -->

**Date**: 2026-09-16
**Task**: v3.0.0：SOCKS5 入站换 Shadowsocks-2022 + 上游/中转能力
**Branch**: `main`

### Summary

把 socks5 入站换成 SS-2022（2022-blake3-aes-256-gcm，44 位 base64 密钥，入站必须 network:tcp 否则与 hy2 抢 443/udp），新增 upstream/relay 能力（/etc/sb/relay.conf 状态文件 + 菜单[8]，每次渲染重新注入、改端口/凭据/修复都不丢），删掉永不匹配的兜底 route 规则改用 route.final，入站监听按主机 IPv6 状态探测（关闭 -> 0.0.0.0）。真实内核 1.10.7 复验：check + 真启动 + SS-2022 真握手 + 中转链路端到端。发布 v3.0.0 后 CI 因 SC2318 变红（本地 shellcheck 0.8.0 不认识该规则），v3.0.1 修复并让门禁打印 ShellCheck 版本。

### Git Commits

| Hash | Message |
|------|---------|
| `c9baa95` | feat(sb): SOCKS5 入站换成 Shadowsocks-2022，并新增上游/中转能力（v3.0.0） |

### Status

[OK] **Completed**
