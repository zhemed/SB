# research.md — SS-2022 入口开 UDP 的代价

内核：`/tmp/sbcheck/sing-box-1.10.7-linux-amd64/sing-box`（与 `CORE_VERSION` 一致，
下载后核对 `CORE_SHA256_AMD64` 一致）。

## 1. 实测

| 试的东西 | 结果 |
|---|---|
| SS 入站 `"network": "udp"` | ✅ 语法接受 |
| SS 入站 `"network": ["tcp","udp"]` | ✅ 语法接受 |
| SS 入站 `"multiplex": {"enabled": true}` | ✅ 语法接受 |
| `"network": "udp"` + `multiplex` | ✅ 语法接受 |
| hysteria2 占 18444/udp + SS 同号 `["tcp","udp"]` | `check` **通过**（抓不到冲突）；真启动 **FATAL** `listen udp4 0.0.0.0:18444: bind: address already in use`，进程退出 |

复现命令见本文件末尾。结论一句话：**语法上能不能写是一回事，同号 UDP 端口会不会撞死是另一回事，
而且是 `check` 抓不到、只有真启动才暴露的那一类。**

## 2. 代价清单（落到本仓库的具体位置）

1. **端口与防火墙**：现在是「443/udp=hy2、443/tcp=SS，只放行一个 443」（`src/30-server-config.sh`
   的 `network: "tcp"` 与 README 的协议说明都建立在这条上）。SS 要吃 UDP 只有两条路：
   给 SS 单独一个 UDP 端口（多一个放行项与扫描面），或把 hy2 从 443 挪走（**已导入的客户端全部失效**）。
2. **我们自己的路由规则会拦掉大头**：`{"protocol":["quic","stun"],"outbound":"block"}`
   （`src/30-server-config.sh`）按嗅探协议匹配且**不限入站**。即使 SS 开了 UDP，
   QUIC（今天绝大多数 UDP）与 STUN 仍被挡；要真有用就得先决定放行 QUIC，等于放弃"强制走 TCP"。
3. **不解决它存在的理由**：这条入口的意义是「UDP 被限速/干扰时的 TCP 退路」。
   客户端↔服务器之间若 UDP 被限速，SS-over-UDP 走的是同一条腿，同样被限——
   等于把唯一退路换成第二条同样脆弱的腿。唯一真受益的是"QUIC 被定点干扰而裸 UDP 可用"，
   但受第 2 条限制只能服务非 QUIC 的 UDP，价值面很窄。
4. **客户端要重导**：现在生成 `"network": "tcp"`（`src/50-client-output.sh`）与 clash 的 `udp: false`；
   开 UDP 后 sing-box 客户端要写 `["tcp","udp"]`、mihomo 要 `udp: true`，所有客户端重新导入。
5. **契约与门禁**：TCP-only 写在 README、`.trellis/spec/`（version-pins §5）与 `tests/verify.sh`
   的钉死串里，还有那条 UDP 阻断路由；改动要连测试一起动。另外启用/改端口流程要自己补
   端口冲突校验——原因见第 1 节最后一行。

## 3. 被否决的替代方案

| 方案 | 价格 | 判定 |
|---|---|---|
| SS 开原生 UDP | 新 UDP 端口（或动 hy2 端口）+ 放行 QUIC 的路由决定 + 客户端重导 + 契约/测试改动 | **否决**：收益面窄，代价最大 |
| `udp_over_tcp`（SS 入站开 `multiplex`，客户端走 mux） | mux 队头阻塞、性能不如原生 UDP；客户端要支持 smux；UDP 阻断规则要放行 mux 进来的 UDP | **备选**：不新开端口、不动 hy2，且**正好工作在"UDP 被限速"的场景**——若将来要做，先做这个 |
| 给 hy2 再加一个备用端口 | 同协议同指纹，客户端要重导 | 否决：同一条腿的镜像，不增加故障覆盖 |

## 4. 复现命令

```bash
mkdir -p /tmp/sbcheck && cd /tmp/sbcheck
curl -fsSL -o sb.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-amd64.tar.gz
sha256sum sb.tar.gz   # 必须等于 src/00-bootstrap.sh 里的 CORE_SHA256_AMD64
tar xzf sb.tar.gz && SB=./sing-box-1.10.7-linux-amd64/sing-box
KEY=$(openssl rand -base64 32)
# 语法检查：把 network 换成 "udp" / ["tcp","udp"] 各跑一次 $SB check -c
# 冲突检查：hy2 与 SS 同号端口，$SB check -c 通过但 $SB run -c 立刻 FATAL
```

## 5. 结论

维持 TCP-only（现状）。若第 1 条触发条件成立，先做 `udp_over_tcp`，不要先开原生 UDP。
