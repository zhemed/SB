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


## Session 7: v3.1.4：给每个取值提示补取消出口
<!-- trellis-session: v=2 fp=52a29ef28f0cabf9 -->

**Date**: 2026-09-17
**Task**: v3.1.4：给每个取值提示补取消出口
**Branch**: `main`

### Summary

用户实测：改 SS 端口时按回车想退出，被随机改成了一个随机端口（此处原记有具体端口号，按全局红线第 3 条移除，不落实例专有值）——端口提示的约定是「留空=随机」，而这一步没有取消键，只能 Ctrl-C。修复：choose_ss_port 加「0：取消」并返回专用状态码 2（enable_ss_entry 收到就中止，不再顺手生成密钥与随机端口）；change_ss_port 与 change_ports(hy2) 提示写明输入0取消并显式提示；上游地址/端口/密钥原本用 0 静默返回，改为打印取消提示并把菜单名从过期的「返回主菜单」改成「取消」；改密钥提示从「返回凭据菜单」改为「返回可选功能」。规范补：写活配置的取值提示必须有显式出口、空输入不算取消。测试：改端口取消后配置 sha256 不变且未提交、choose_ss_port 取消返回 2。

### Git Commits

| Hash | Message |
|------|---------|
| `5f1dbb1` | fix(sb): 每个「输入值」的提示都给出取消出口（v3.1.4） |

### Status

[OK] **Completed**


## Session 8: 评估并否决：SS-2022 入口开 UDP（归档）
<!-- trellis-session: v=2 fp=71d8f0af8e9c9f52 -->

**Date**: 2026-09-17
**Task**: 评估并否决：SS-2022 入口开 UDP（归档）
**Branch**: `main`

### Summary

用户问 SS 入口换成/加上 UDP 的代价。实测：network 支持 udp/两者、multiplex 也接受；但 SS 与 hy2 同号 UDP 端口时 check 通过、真启动 FATAL。代价：多一个 UDP 端口或动 hy2 端口（客户端全废）、我们自己的 quic/stun 规则仍拦大头、解决不了'UDP 被限速'这个它存在的理由、客户端要重导、契约与测试要跟着改。结论：不实施，维持 TCP-only；将来若 QUIC 被定点干扰而裸 UDP 可用，先做 udp_over_tcp 而不是原生 UDP。记录在归档任务 09-17-ss-entry-udp-eval，并在 version-pins 的钉死串清单旁留了指针。

### Git Commits

| Hash | Message |
|------|---------|
| `49776e9` | chore(task): 记录 SS-2022 入口是否承载 UDP 的评估与结论 |

### Status

[OK] **Completed**


## Session 9: 评估：可选入口是否换回 SOCKS5（归档，不改代码）
<!-- trellis-session: v=2 fp=aec11920278b7878 -->

**Date**: 2026-09-20
**Task**: 评估：可选入口是否换回 SOCKS5（归档，不改代码）
**Branch**: `main`

### Summary

用户觉得 SOCKS5 更舒服。评估把'舒服'拆成三种需求（本机调试便利/远端老客户端/嫌 SS 麻烦），逐维度对比：加密、可指纹识别性（SOCKS5 握手有固定特征，容易被封锁——这是'救急的腿'最不该有的性质）、客户端支持面（curl/浏览器不能直接 SS）、时钟依赖、凭据管理、迁移成本。三条路径：1 保持 SS-2022 + 加仅回环 SOCKS5（推荐，公网零暴露）；2 换回公网 SOCKS5（明文+可指纹+整轮重做，除非有具体客户端故障）；3 并存（不推荐）。同时指出'看不到链接/不能取消'这两个真正的摩擦点已在 v3.1.3/v3.1.4 修掉。任务已归档；本次未联网、未访问工作区外文件、未改代码。

### Git Commits

| Hash | Message |
|------|---------|
| `3b225b3` | [task:09-20-socks5-vs-ss-eval] 评估：可选入口从 SS-2022 换回 SOCKS5 |

### Status

[OK] **Completed**


## Session 10: v4.0.0：可选入口换回公网 SOCKS5（旧 ss-sb 原样保留）
<!-- trellis-session: v=2 fp=dc69bab94639fb1b -->

**Date**: 2026-09-20
**Task**: v4.0.0：可选入口换回公网 SOCKS5（旧 ss-sb 原样保留）
**Branch**: `main`

### Summary

把 pia 备用入口从 Shadowsocks-2022 换回公网 SOCKS5（用户接受明文与可指纹识别）；旧的 ss-sb 入口保留原样不动，只在菜单 [8] 暴露移除。门禁 364 例绿、真实内核三件套 + 客户端四形态验证，推送后 CI 绿。

### Main Changes

- src/ + sb.sh + tests/ + README + .trellis/spec：SOCKS5 入口、preserved_* 保留路径、钉死串双钉、修复用例重写

### Git Commits

| Hash | Message |
|------|---------|
| `bd248c7` | [task:09-20-socks5-entry-restore] 清理修复渲染里残留的旧 SS 入口变量 |
| `b84e6b9` | [task:09-20-socks5-entry-restore] 门禁与用例对齐 4.0.0：顺序钉到 SOCKS5、修复用例改成“原样保留” |
| `dd44f80` | [task:09-20-socks5-entry-restore] 执行记录：补上“旧 SS 入口原样不动”的决定与各阶段结论 |

### Testing

- [OK] bash tests/verify.sh -> exit 0（unit 313 + repair 51，shellcheck 0.10.0）；真实内核：hy2-only 启动 / curl --socks5 真握手 / 旧 SS 原样启动 / 客户端 4 形态 check；CI run 35491292582 success

### Status

[OK] **Completed**

### Next Steps

- 用户侧可选：旧 ss-sb 入口的端口可按需要改（菜单 [8] 第 3 项）；或启用 SOCKS5 后移除旧入口
  （原记有具体端口号，按全局红线第 3 条移除）


## Session 11: v4.0.0 上线结果：入口切换为 SOCKS5，旧 SS 入口已移除
<!-- trellis-session: v=2 fp=ac66692aa55d25df -->

**Date**: 2026-09-20
**Task**: v4.0.0 上线结果：入口切换为 SOCKS5，旧 SS 入口已移除
**Branch**: `main`

### Summary

用户在自己机器上更新到 v4.0.0，按 README 的切换路径启用 SOCKS5 并移除旧的 SS 入口，切换成功。只记录形态，不记录端口/地址等实例专有值。

### Main Changes

- 无代码改动（记录型任务）：归档上线结果 + journal

### Git Commits

(No commits - planning session)

### Testing

- [OK] 无需重跑门禁；发布 tip 5995e52 已由 CI run 35491370339 验证绿

### Status

[OK] **Completed**

### Next Steps

- 等用户发话；不要再指望 [8] 重建 SS 入口（生产者已退役）


## Session 12: 5.0.0：彻底移除旧 Shadowsocks-2022 入口的兼容层
<!-- trellis-session: v=2 fp=14a72eab8aa41679 -->

**Date**: 2026-09-20
**Task**: 5.0.0：彻底移除旧 Shadowsocks-2022 入口的兼容层
**Branch**: `main`

### Summary

用户先报菜单 [8] 多出一个无意义的第 5 项，随后定调 ss 彻底移除：4.0.0 的'旧入口原样保留'兼容层整个拆掉，版本 5.0.0。保留上游中转的 SS-2022 与只读探针 + 两处警告（不静默丢配置）。

### Main Changes

- src/30、50、70、85 删除保留路径/移除流程/客户端 ss 产物/修复注入；新增 retired_ss_entry_port 探针与警告；ss-sb 重新计入已废弃协议；README+规范同步 5.0.0

### Git Commits

| Hash | Message |
|------|---------|
| `4b33571` | [task:09-20-drop-ss-entry-compat] 5.0.0：彻底移除 Shadowsocks-2022 入口的兼容层 |
| `8667408` | [task:09-20-drop-ss-entry-compat] 文档：README 升级警示、规范与任务记录同步 5.0.0 |

### Testing

- [OK] 门禁 exit 0（unit 315 + repair 52，shellcheck 0.10.0）；真实内核：hy2-only 启动 / curl --socks5 真握手 / 旧 ss-sb 配置重写后入口消失+警告+真启动 / 客户端两形态 check；变异 E/F/G 全被抓住；CI run 35492722401 success

### Status

[OK] **Completed**

### Next Steps

- 无；若还想有 TCP 备用入口就用菜单 [8] 第 1 项启用 SOCKS5（不存在重建 SS 入口的路）
