# research.md — 真实内核实测记录（v3.0.0 依据）

内核：`/tmp/sbcheck/sing-box-1.10.7-linux-amd64/sing-box`（1.10.7，与 `CORE_VERSION` 一致）。
下载方式见已归档任务 `.trellis/tasks/archive/2026-09/09-13-singbox-version-compat-research/research.md` §6。

本文件记录**决定设计**的实测结论，以及可复现的命令。所有结论都不是文档推断。

---

## 1. shadowsocks 入站的默认监听面（决定 `network: "tcp"` 必写）

```bash
cd /tmp/sbcheck && SB=./sing-box-1.10.7-linux-amd64/sing-box
KEY=$(openssl rand -base64 32)
cat > a.json <<EOF
{"log":{"level":"info"},
 "inbounds":[{"type":"shadowsocks","tag":"ss-sb","listen":"0.0.0.0","listen_port":18443,
              "method":"2022-blake3-aes-256-gcm","password":"$KEY"}],
 "outbounds":[{"type":"direct","tag":"direct"}]}
EOF
$SB run -c a.json &   # 观察 ss -ltnup
```

结果：**同一端口同时监听 TCP 与 UDP**（`ss -ltnup` 两条，日志两行
`tcp server started` / `udp server started`）。

因此若照抄「省略 network 用默认」，443 上会与 hysteria2 的 `443/udp` 抢端口。

## 2. 抢端口的后果：`check` 查不出，真启动才 FATAL

配置 = hysteria2(`18444/udp`) + shadowsocks(`18444`，无 `network`)：

| 检查 | 结果 |
|---|---|
| `sing-box check -c` | **exit 0，通过**（静态检查不做端口冲突检测） |
| `sing-box run -c` | `FATAL start service: initialize inbound/shadowsocks[ss-sb]: listen udp4 0.0.0.0:18444: bind: address already in use`，进程退出 |

加上 `"network": "tcp"` 后同一配置正常启动：`udp 18444`（hy2）+ `tcp 18444`（ss）。

> 这条同时说明：本仓库测试套件的 `MOCKCORE`（`check` = `jq -e .`）与真实 `check` 都**不能**替代
> 一次真启动。发布前必须真启动一次（本次已做）。

## 3. 路由规则里的 `network` 是逗号字符串还是数组

运行时（socks 入站 + 规则阻断 + 真实发包，见前一任务的记录）：

| 写法 | 结果 |
|---|---|
| `"network": "tcp,udp"` | **不匹配**（连接穿透） |
| `"network": ["tcp","udp"]` | 匹配 |
| `"network": "tcp"` | 匹配 |

入站字段上写 `"network": "tcp,udp"` 则直接 FATAL `unknown network: tcp,udp`。
→ 模板里那条 `{"outbound":"direct","network":"udp,tcp"}` 属于永远不生效的死规则，已删除并用 `route.final` 替代。

## 4. SS-2022 密钥格式

用 `2022-blake3-aes-256-gcm` 入站逐条试：

| 密钥 | 结果 |
|---|---|
| `openssl rand -base64 32`（44 字符，带 `=`） | ✅ |
| 24 字符 base64（16 字节） | ❌ `parse inbound[0]: bad key` |
| 48 字符 hex | ✅（sing-box 接受，但客户端实现宽严不一） |
| 43 字符无填充 base64 | ❌ `decode psk: illegal base64 data at input byte 40` |
| 32 字符明文 | ❌ `bad key` |

→ 生成与校验都钉死**带填充的 44 字符标准 base64**（`valid_ss_password`），与客户端互操作面一致。

## 5. `listen: "::"` 在关闭 IPv6 的主机上的真实行为

`unshare -n` 独立网络命名空间内（不影响宿主）：

| 测试 | 结果 |
|---|---|
| `net.ipv6.conf.all.disable_ipv6=1` 后裸 `bind "::"` | 成功 |
| 同上，sing-box `socks listen ::` | 正常运行 |
| 同上，sing-box `hysteria2 listen ::` | 正常运行 |
| 从 IPv4 连 `::` 上的服务 | 可连接 |

→ 运维侧「sysctl 关 IPv6 会让 `::` 起不来」的因果**不成立**；只有内核参数 `ipv6.disable=1`
（AF_INET6 整个不可用）才会失败。但运维侧两台机器已是 IPv4-only 并以 `0.0.0.0` 为约定，
所以实现取保守解：探测 + 关闭时用 `0.0.0.0`。生产端已实测（netns）：

```
默认: ::
sysctl -w net.ipv6.conf.all.disable_ipv6=1 后: 0.0.0.0
```

`server_listen_address` 的分支另由 `tests/unit.sh` 用夹具 sysctl 树覆盖三种情形
（`0` / `1` / 目录不存在），无需 root。

## 6. 协议层端到端（不是 check，而是真握手）

`/tmp/sbverify/handshake.sh`：用**产品自己渲染的**服务端配置起服务，
第二个 sing-box 实例以 `shadowsocks` 出站 + `socks` 入站接入，再 curl 本地 HTTP 服务：

```
--- server alive: yes ---
--- client alive: yes ---
curl exit=0 body=[ss-2022-tunnel-ok]
HANDSHAKE OK
```

## 7. 中转链路端到端

`/tmp/sbverify/relay-chain.sh`：客户端 → 本机节点（配置由 `render_server_config` 生成，
`relay.conf` 指向上游）→ 上游 SS-2022（模拟落地机，只有 direct 出站）→ HTTP 目标。

```
curl exit=0 body=[relay-chain-ok]
upstream inbound connections: 2 ; local relay outbound lines: 1
RELAY CHAIN OK
```

上游日志里出现 `inbound/shadowsocks[ss-in]: inbound connection`、本机日志里出现
`outbound/shadowsocks[relay]`，即流量确实经过落地机。

## 8. 复现方式汇总

```bash
# 门禁（不需要 root，不需要真内核）
cd /root/SB && bash scripts/build.sh && bash tests/verify.sh

# 真实内核三件套（需要 /tmp/sbverify 的脚本与 /tmp/sbcheck 的内核）
/tmp/sbverify/harness.sh            # 渲染 + check + 真启动 + 监听断言
/tmp/sbverify/harness.sh --relay    # 同上，且配置里含 relay 出站与 final=relay
/tmp/sbverify/handshake.sh          # SS-2022 真握手
/tmp/sbverify/relay-chain.sh        # 中转链路端到端
```

`/tmp` 会被清理；重建方法：下载 1.10.7 内核与自签证书后，脚本会自行抽取 `sb.sh` 里的
`server_listen_address` / `render_server_config` / relay 系列 / `valid_*` 函数并调用。
