# 可选入口换回 SOCKS5（SS-2022 → socks，v4.0.0）

## Goal

用户在评估后选择**路径 2**：把菜单【8】里的**可选**入口从 Shadowsocks-2022 换回 **SOCKS5**
（用户名 `sb` + 独立随机密码，TCP-only）。默认仍**不安装**、按需启用。
发布 **v4.0.0**（协议替换 = 破坏性）。

## Requirements

### ① 入站

- `ss-sb`（shadowsocks）→ `socks5-sb`（`type: socks`，`users:[{username,password}]`）。
- SOCKS5 入站在 sing-box 里**天然只监听 TCP**（实测该类型没有 `network` 字段）→ 不会与 hy2 抢 443/udp。
- 保留 `{"inbound":["socks5-sb"],"network":"udp","outbound":"block"}` 这条防御性规则（README/测试里的
  "该入口只跑 TCP" 契约）。
- 默认不装：新建安装仍然只装 hysteria2；启用/停用/改端口/改凭据都在菜单【8】。

### ② 凭据与产物

- 密码：`openssl rand -hex 24`，校验沿用旧的 `valid_socks_password`（16–128，`[A-Za-z0-9._~-]`）。
- 分享链接 `socks5://sb:<pw>@<host>:<port>#socks5-<hostname>`，写入 `$SB_DIR/socks5.txt`；
  停用时删除该文件（与 SS 时期的 ss.txt 处理一致）。
- 客户端产物：`sbox.json` 的 `socks` 出站（`version: "5"`、`network: "tcp"`）、
  `clash.yaml` 的 `type: socks5`（`udp: false`），selector/分组顺序仍是**可选入口在前、hy2 在后**。
- 启用/改端口/改凭据后**必须显示链接与密码**（v3.1.3 的约定，勿丢）。

### ③ 明文这件事必须写清楚（不拦，但要说）

- 启用流程与 README 明确：**该入口不加密**——口令与流量明文，握手特征明显、容易被识别与封锁，
  只应在可信链路上使用；这是当初把它换掉的唯一理由，现在是有意换回来。
- 保留用户名+密码鉴权，**绝不做无鉴权的开放代理**。

### ④ 修复

- `socks5-sb` 形态：端口/用户名/密码原样保留。
- `ss-sb` 形态（v3.0.0–v3.1.4 装的）：视为"已移除协议"，重写为 socks 形态（**重新生成密码**，
  label 里明确提示旧客户端会失效）。
- 两者都没有：保持没有，不自动补。

## Acceptance Criteria

- [ ] 全新安装渲染的配置只有 hysteria2；真实内核 `check` + 真启动通过。
- [ ] 启用后配置含合法 `socks5-sb` 入站与 UDP 阻断规则，服务 active。
- [ ] **真实 SOCKS5 握手**：`curl --socks5-hostname` 经该入口取回目标内容（真实内核 + 真实 curl）。
- [ ] 停用后入站与规则消失、`socks5.txt` 被删除、客户端配置回到只有 hy2。
- [ ] 修复三形态各有用例（socks 保留 / ss 迁移 / 都没有不补）。
- [ ] 版本四处同步 `4.0.0`，`check-version-bump.sh` 通过；门禁与所有沙箱用例绿。
- [ ] README 与 `.trellis/spec/**` 同步（含"为什么又换回来"的记录）。

## Notes

- 评估记录见 `.trellis/tasks/archive/2026-09/09-20-socks5-vs-ss-eval/research.md`。
- 用户已知代价：明文 + 可指纹识别 + 整轮重做。本任务不重复劝阻，只把它写进文档。
