# SOCKS5 入站换 Shadowsocks-2022 + 上游/中转能力（v3.0.0）

## Goal

把服务端第二个入站从明文 **SOCKS5** 换成加密的 **Shadowsocks-2022**，补上「线路机 → 落地机」
的中转能力（现在只能手改 `sb.json`），并顺手修掉两处既有 bug。发布 **v3.0.0**。

来源：`/root/vps/.trellis/spec/ops/proposal-sb-ss2022.md`（运维侧建议书）+ 维护者实测复核。
协议与套件由用户拍板：**Shadowsocks 2022（AEAD-2022），cipher `2022-blake3-aes-256-gcm`**。
判据：这一跳是服务器↔服务器、两端都是自有的 sing-box 1.10.7、无客户端兼容约束；现网已在跑。

范围由用户确认为**四项**（① + ② + ③ + ④），一次做完、一次发布。

## Requirements

### ① SOCKS5 入站 → Shadowsocks-2022 入站

- `socks5-sb` 入站整块删除，新增 `ss-sb`（`type: shadowsocks`），沿用原来的 TCP 端口变量（默认 443）。
- cipher 固定 `2022-blake3-aes-256-gcm`；口令为 **44 字符规范 base64**（32 字节密钥）。
- **入站必须 `"network": "tcp"`**：sing-box 的 shadowsocks 入站默认同时监听 TCP+UDP，
  不写就会去 bind `443/udp`，与 hysteria2 冲突（实测 FATAL，见 design.md §2）。
- 保留「该入站只跑 TCP、UDP 走 hysteria2」的既有行为与既有 UDP 阻断路由规则（tag 改为 `ss-sb`）。
- 客户端产物同步：分享链接（SIP002 base64 userinfo 形式）、`sbox.json` 出站、`clash.yaml` 条目、
  `socks5.txt` → `ss.txt`、聚合文件、二维码。
- 旧安装（配置里还是 `socks` 入站）走**修复即迁移**：修复时识别旧形态并重写为新形态，
  重新生成密钥并明确提示「客户端需更新」。

### ② 上游/中转能力

- 新增「上游 = 一台 SS-2022 落地机」的可配置出站（tag `relay`），`route.final` 指向它；未配置时 `final = direct`。
- 参数持久化到受管状态文件（600），**每次渲染配置都重新注入**——菜单改端口/改凭据/修复之后都不丢。
- 菜单新增「上游/中转」入口：查看 / 设置 / 清除，**幂等**。
- 设置时校验参数（地址、端口、cipher、密钥），并在提交前探测上游 TCP 端口可达性。

### ③ 兜底 route 规则从不生效

- 删除死规则 `{"outbound":"direct","network":"udp,tcp"}`（`network` 逗号拼接永不被匹配，已实测）。
- 改为显式 `route.final`，出网不再依赖「无规则命中 → 用第一个出站」。

### ④ 关闭 IPv6 的主机上入站监听地址

- 入站监听地址改为按主机探测：IPv6 可用 → `::`；主机已关 IPv6 → `0.0.0.0`。
- 覆盖两种情况：sysctl `disable_ipv6=1`（`/proc/sys/net/ipv6` 在、值为 1）与内核参数 `ipv6.disable=1`
  （`/proc/sys/net/ipv6` 不存在）。
- 维保纪律：`src/` 有改动 ⇒ 同一次提交升 `VERSION`（`scripts/check-version-bump.sh` 在 CI 拦）。

## Non-Goals（本次明确不做）

- **不**升级内核版本（继续钉 1.10.7），**不**做 1.13+ 的 rule actions 迁移。
- **不**改客户端 `sbox.json` 在 1.13+ 上不可用的问题（已归档的独立问题）。
- **不**用 `destinations[]`（原生的 SS relay 结构）：它只覆盖「客户端从 SS 入口进来」的路径，
  我们的客户端入口是 hy2，这条路径用不上，仍需通用出站 + `route.final`。
- **不**给 SS 入站开 UDP / multiplex：UDP 继续由 hysteria2 承担，SS 是 TCP 备用入口。
- **不**实现 `ss://` 分享链接导入（设置上游用手工四项式输入；密钥可直接粘贴）。
- **不**改 `route.final` 之外的路由语义。

## Acceptance Criteria

- [ ] `bash scripts/build.sh && bash tests/verify.sh` 通过（含 shellcheck 已安装时不跳过）。
- [ ] 真实内核（1.10.7，`/tmp/sbcheck`）对**新渲染的服务端配置** `check` 通过，且能真实启动；
      hysteria2 与 shadowsocks 两个入站同时监听、互不抢端口。
- [ ] 真实客户端出站连通性验证：用第二个 sing-box 实例以 SS-2022 出站连入，握手成功并可访问 HTTP 服务。
- [ ] 密钥生成/校验：44 字符 base64 通过；16 字节 base64、43 字符无填充 base64、明文口令被拒。
- [ ] 配了上游时渲染出的配置含 `relay` 出站与 `route.final: "relay"`；清除上游后回到 `final: "direct"`。
- [ ] 上游设置**幂等**：连续执行两次结果一致；「改端口」「改凭据」「修复」之后上游仍在。
- [ ] 旧形态配置（`socks` 入站）走修复能重建成 `ss-sb` 形态，且 `sb.json.last-good` 等备份语义不变。
- [ ] 关 IPv6 的主机（sysctl `disable_ipv6=1`）渲染出 `0.0.0.0`；双栈主机渲染出 `::`。
- [ ] 版本四处同步为 `3.0.0`（`VERSION` / `sb_version` / README / 测试钉死），`check-version-bump.sh` 通过。
- [ ] README 与 `.trellis/spec/` 四层规范里关于协议、凭据、受管文件、测试锚点的描述同步更新。

## Notes

- 兼容性破坏是**有意**的：升到 v3.0.0 后，用旧 SOCKS5 凭据的客户端会失效——必须走修复迁移并更新客户端。
- 现网 `zzds.de` 的 relay 是运维侧手改的（`/etc/sb/relay-apply.sh` + `relay-189y.env`）；
  本任务只让**脚本**具备这个能力，是否切换由运维侧决定，本任务不动他们的机器。
