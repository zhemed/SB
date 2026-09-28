# prd.md — 中转去掉 Shadowsocks-2022

## Goal

用户原话：「我让你彻底移除ss，你在这bb什么呢。」
项目里最后一处 Shadowsocks-2022 是**上游/中转**那一跳（出站 `type: "shadowsocks"`、
`RELAY_METHOD`、44 位 base64 密钥）。本轮把它换掉，让项目里不再有任何 SS 代码。

## 决定（我自己定的，理由写在这儿）

中转改走**落地机的 SOCKS5 入口**（菜单 [8] 第 1 项那个）。

- 旧设计里中转指向的就是"落地机的第二个入站"，而现在那个入站就是 SOCKS5 —— 同一个架构位，
  只是协议从 SS-2022 换成 SOCKS5；
- 落地机侧**什么都不用新做**：启用 SOCKS5 入口即可（已有功能，会打印链接与密码）；
- 线路机侧：`relay.conf` 的第三行从"SS 密钥"变成"SOCKS5 密码"，校验从 `valid_ss_password`
  换成 `valid_socks_password`；渲染的 relay 出站变成 `type: "socks"`（用户名固定 `sb`）。

代价（必须写进 README）：

- 这一跳**不加密**——与客户端入口同一取舍，用户在 4.0.0 已明确接受；HTTPS 本身仍是端到端加密的，
  泄露的是目的地元数据；
- **UDP 不走这一跳**（SOCKS5 入口按设计阻断 UDP）——与旧设计一致（旧的 SS 入口也是 `network: tcp`）；
- 旧的 `relay.conf`（44 位 base64 SS 密钥）会被新校验判为无效 → 现有告警会提示
  "上游配置无效，本次未启用上游（仍按直连出网）"，文案补一句"本版本改用 SOCKS5，请重新设置一次"。

## Requirements

- 删掉 `RELAY_METHOD`、`valid_ss_password()` 及其用例与钉死串；
- relay 出站渲染成 `type: "socks"`（`username` 取 `SOCKS_USERNAME`）；
- 菜单 [8]→2 的输入项与说明改成 SOCKS5：去掉 NTP/时间戳那段 SS 专属说明，
  加一句"这一跳不加密，落地机要先启用 SOCKS5 入口"；
- README 与规范同步；`src/` 与 `sb.sh` 里不再出现 `Shadowsocks` / `RELAY_METHOD` / `2022-blake3`。

## Acceptance Criteria

- [ ] `grep -ri shadowsocks src/ sb.sh` 无输出
- [ ] 门禁绿：unit / repair / verify + shellcheck 0.10.0
- [ ] 真实内核：两跳链路真跑通（线路机 SOCKS5 入口 → relay 出站 → 落地机 SOCKS5 入站 → 目标）
- [ ] 旧 `relay.conf` 被判无效并给出"请重新设置"的明确提示
- [ ] 版本 5.1.0；推到 origin 前必须等用户当轮点头（本轮不推）
