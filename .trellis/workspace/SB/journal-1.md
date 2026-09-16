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


## Session 3: v3.1.0：SS-2022 入口改为可选（默认不装），菜单[8] 变可选功能
<!-- trellis-session: v=2 fp=a65f2dd0eca75974 -->

**Date**: 2026-09-16
**Task**: v3.1.0：SS-2022 入口改为可选（默认不装），菜单[8] 变可选功能
**Branch**: `main`

### Summary

新建安装只装 hysteria2（只问 hy2 端口、只生成 UUID）；Shadowsocks-2022 入站改为菜单[8]可选功能里显式启用/停用/改端口/改密钥，客户端产物随入站存在与否变化（停用时删掉遗留 ss.txt，selector 变单成员）；修复保留已有 ss-sb、继续迁移旧 socks5、hy2-only 不补齐；判据不新增状态文件，配置里有没有 ss-sb 就是真相。验证：门禁绿（shellcheck 0.10.0、unit 290、repair 50）+ 真实内核 hy2-only 与启用后两种配置 check+真启动 + SS 真握手 + 客户端两形态按行校验 + 中转链路回归。过程中抓到并修掉一个 check 查不出的真 bug：命令替换吃掉片段结尾换行，导致 Clash 里 udp:false 与下一个代理粘连、分组少一个成员；已加回归用例。

### Git Commits

| Hash | Message |
|------|---------|
| `8d0da3c` | feat(sb): SS-2022 入口改为可选（默认不装），菜单[8] 变为可选功能（v3.1.0） |

### Status

[OK] **Completed**


## Session 4: v3.1.1：修确认提示大小写导致的静默取消
<!-- trellis-session: v=2 fp=100578f399a0891f -->

**Date**: 2026-09-16
**Task**: v3.1.1：修确认提示大小写导致的静默取消
**Branch**: `main`

### Summary

用户实测反馈：在【8】可选功能里停用 SS 入口时输入小写的 yes，菜单只重画一遍、什么都没发生。根因是确认判断写成 [[ $confirm == YES ]] || return 0——大小写敏感且静默返回。新增 confirm_yes（YES/y 不分大小写）并让三处 YES 确认（停用入口、清除上游、上游不可达覆盖）都在取消时打印「已取消，未做任何修改」；prompt 文案写明其他输入即取消。加 6 条 confirm_yes 单测 + 1 条调用层覆盖（非确认输入不提交、不改配置、必须提示）。

### Git Commits

| Hash | Message |
|------|---------|
| `6c7cd41` | fix(sb): 确认提示区分大小写，输入 yes 时静默取消（v3.1.1） |

### Status

[OK] **Completed**


## Session 5: v3.1.2：确认改为回车即确认，并给出显式 n
<!-- trellis-session: v=2 fp=5b5f6f9c1b1d22d5 -->

**Date**: 2026-09-16
**Task**: v3.1.2：确认改为回车即确认，并给出显式 n
**Branch**: `main`

### Summary

确认提示统一成「[回车/y 确认，n 取消]」：回车与 y/yes（不分大小写）确认，n/no 与任何无法识别的输入取消，EOF 也取消；取消仍显式提示。三处确认（停用 SS 入口、清除上游、上游不可达覆盖）同步；REBUILD 整词门禁保持原样（那类操作会打断所有客户端，不适合默认回车）。测试：confirm_yes 8 条覆盖 + 调用层用例（回车确认必须真的删掉入站与 UDP 规则）。规范里把这条约定写进 input-validation.md（含 3.1.0/3.1.1 静默取消的真实 bug 记录）。

### Git Commits

| Hash | Message |
|------|---------|
| `d4f6313` | feat(sb): 确认改为回车即确认，并给出显式 n 选项（v3.1.2） |

### Status

[OK] **Completed**


## Session 6: v3.1.3：启用/改端口/改密钥后显示分享链接与密钥
<!-- trellis-session: v=2 fp=a72c611b84469c67 -->

**Date**: 2026-09-16
**Task**: v3.1.3：启用/改端口/改密钥后显示分享链接与密钥
**Branch**: `main`

### Summary

用户反馈：菜单[8]启用 SS-2022 后没有分享链接、也没有密钥。复现结论：ss.txt 与 ss-sb.password 其实都已生成（菜单[3]可见），但启用流程只打印端口与警告，从未回显结果——是显示缺口而非数据丢失。修复：新增 print_ss_entry_share（打印链接+说明写入 ss.txt+二维码在菜单[3]+服务端 PSK，文件缺失时明确告知去菜单[3]刷新），接到启用/改端口/改密钥三处；顺带修掉 change_ss_password 里过期的「返回凭据菜单」提示。规范补一条：改动客户端可见值的成功必须把新值打出来。新增 enable-flow 沙箱（从 hy2-only 出发走真实 enable_ss_entry+sbshare），断言输出含端口/链接/密钥、ss.txt 已写、链接解出的密钥与配置一致、配置通过真实内核 check。

### Git Commits

| Hash | Message |
|------|---------|
| `a4b0ac6` | fix(sb): 启用/改端口/改密钥后直接给出分享链接与密钥（v3.1.3） |

### Status

[OK] **Completed**
