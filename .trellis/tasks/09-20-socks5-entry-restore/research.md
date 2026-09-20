# research.md — 反向替换的实机验证（v4.0.0）

内核：`/tmp/sbcheck/sing-box-1.10.7-linux-amd64/sing-box`，下载后核对
`CORE_SHA256_AMD64` 一致（`1951a078…e00fe`）。

## 1. 三种形态（`/tmp/sbverify/v4.sh`，全部真实内核）

| 形态 | 结果 |
|---|---|
| 全新安装（只有 hy2） | `check` 通过、真启动、监听 `udp 18443` |
| 启用 SOCKS5 入口 | `inbounds: [hy2-sb, socks5-sb]`、真启动、**真实 `curl --socks5-hostname sb:<pw>@127.0.0.1:<port>` 取回内容** |
| 旧 SS 入口保留 | `inbounds: [hy2-sb, ss-sb]`，入站 JSON 原样（含 `network: "tcp"`、原端口），它的 UDP 阻断规则也重新生成，真启动通过 |

关键证据（第 2 项）：SOCKS5 的好处之一就是 **curl 自己会说**——不需要额外的客户端进程：

```
curl --socks5-hostname sb:<password>@127.0.0.1:18444 http://127.0.0.1:18080/probe.txt
  -> body=[socks-v4-ok]
```

## 2. 代码层的关键差异（与 3.0.0 那次踩的坑对比）

- **`socks` 入站没有 `network` 字段**（3.0.0 实测过：写 `"network"` 会 `unknown field`），
  它天然只监听 TCP → 不会出现"SS 入站默认双栈、抢 hy2 的 443/udp"那类 FATAL。
  这也是这次反向替换里**唯一比上次简单**的地方：不需要 `network: "tcp"` 这类补丁。
- 旧 SS 入站是**原样 JSON**带进新模板的（`legacy_entry_inbound`），不做任何字段重排。
  它的 UDP 阻断规则由模板按 `ss-sb` tag 重新生成，避免"保留了入站但丢了规则"。

## 3. 明文风险（用户已知并接受，记录在案）

SOCKS5 明文的代价、可被指纹识别的性质、以及为什么不推荐走这条路，写在
`.trellis/tasks/archive/2026-09/09-20-socks5-vs-ss-eval/research.md`。
实现上做了三件事作为兜底：启用流程打印警示、README 协议段写明、保留用户名+密码鉴权
（不做无鉴权开放代理）。

## 4. 复现

```bash
/tmp/sbverify/v4.sh          # 三种形态：渲染 + check + 真启动 + 真实 SOCKS5 握手
```

脚本会从 `sb.sh` 里抽取 `render_server_config` 及其依赖，用真实内核跑三种配置；
`/tmp` 被清理后按本文件重建即可（内核用仓库里钉死的 SHA-256 核对）。
