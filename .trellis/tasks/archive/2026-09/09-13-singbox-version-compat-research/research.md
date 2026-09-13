# sing-box 版本与配置兼容性调查

> **研究记录，非实施任务。** 结论供 1.15 稳定版发布后重启讨论时直接取用。
> 调查日期 2026-09-13，仓库版本 `2.0.1`（`CORE_VERSION="1.10.7"`）。

## 结论摘要

1. 我们钉死的内核 `1.10.7` 已落后约 19 个月（1.14.0 发布于 2026-08-31）。
2. **升级到 1.13+ 不是改版本号，必须同时迁移配置结构**——两种配置形式互不兼容。
3. **我们生成的客户端配置（`sbox.json`）自 1.13.0（2026-02-28）起已不可用**，
   与是否升级内核无关，是已存在半年多的独立问题。
4. 1.15 目前只有 alpha，且其唯一重头优化（TUN 自有 TCP/IP 栈）**对我们服务端零收益**。
5. 无未修复的安全公告。

**决定**：等 1.15 稳定版后**一并决定**所有事项（内核升级、客户端配置修复）。
客户端配置的问题独立存在，不因等待而消失。

> **补充（同日追加，见 §八）**：本次讨论补上了「升级到底买到什么」的量化依据——
> 真正的收益不在 TUN，而在 hysteria2 依赖的 QUIC 传输层。结论未变（仍等 1.15 稳定版），
> 但判断标准从「新版本有什么」改成了「当前有没有症状」。

---

## 一、实测的兼容性矩阵

方法：用真实内核二进制执行 `sing-box check -c`，而非依据文档推断。

| 配置 | 1.10.7（当前） | 1.12.25 | 1.13.21 | 1.14.0 | 1.15.0-alpha.3 |
|---|---|---|---|---|---|
| **服务端** `sb.json` | ✅ | ✅ 告警 | ❌ | ❌ | ❌ |
| **客户端** `sbox.json` | ✅ | ✅ 告警 | ❌ | ❌ | ❌ |
| **服务端**（迁移后） | ❌ | ❌ | ✅ | ✅ | ✅ |

**关键性质：两种配置形式互不兼容。** 没有一份配置能同时跑在 1.10.7 与 1.13+ 上，
所以内核升级与配置迁移必须同一个提交、同时生效。

### 版本时间线

| 版本 | 发布日期 |
|---|---|
| v1.10.7 | 2025-01-14 |
| v1.12.0 | 2025-08-04 |
| v1.13.0 | 2026-02-28 |
| v1.14.0 | 2026-08-31 |
| v1.15.0-alpha.1/2/3 | 2026-09-04 / 09-05 / 09-13 |

---

## 二、服务端配置需要两处迁移

### 1. `inbound.sniff` / `sniff_override_destination`（1.13.0 硬移除）

```
FATAL decode config: inbounds[0]: legacy inbound fields are deprecated in
sing-box 1.11.0 and removed in sing-box 1.13.0
```

影响 `render_server_config` 的 hysteria2 与 socks 两个 inbound。
替换为路由规则 `{"action": "sniff"}`。

### 2. `outbound.domain_strategy`（我们的 `switch_ip_priority` / `ipv` 功能）

1.12 弃用；**1.14.0 起必须设 `ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true`**：

```
FATAL ... set environment variable ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true
```

替换为路由规则 `{"action": "resolve", "strategy": "prefer_ipv4"}`。

### 行为保全版迁移配置（已实测通过 1.13.21 / 1.14.0 / 1.15α3）

```json
"route": {
  "rules": [
    { "action": "sniff" },
    { "action": "resolve", "strategy": "prefer_ipv4" },
    { "inbound": ["socks5-sb"], "network": "udp", "action": "reject" },
    { "protocol": ["quic", "stun"], "action": "reject" },
    { "outbound": "direct", "network": "udp,tcp" }
  ]
}
```

链接本身（`hysteria2://`、`socks5://`）走协议层 URI，不受这些 schema 变化影响。

---

## 三、客户端配置有三处问题（已存在，非升级引入）

| 问题 | 弃用 | 移除 | 替换 |
|---|---|---|---|
| DNS 段旧格式（`address_resolver`、`address: "fakeip"`） | 1.12 | **1.14** | 新 DNS server 格式（`type`/`server`/`domain_resolver`）+ fakeip 段位移到 fakeip server |
| `dns` outbound | 1.11 | **1.13** | 路由规则动作（`hijack-dns`） |
| TUN inbound 的 `sniff` / `sniff_override_destination` | 1.11 | **1.13** | `{"action": "sniff"}` |

实测：逐层剥离这三处后 `check` 通过（exit 0）。

**影响面**：仅影响把 `sbox.json` / `clash.yaml` 喂给 sing-box/Clash 客户端的用户。
使用分享链接（二维码 / `hysteria2://`）的用户不受影响——这也解释了问题为何长期未被注意。

---

## 四、1.15 的范围与评估

到 `alpha.3` 为止的**全部**变更：

| 版本 | 内容 |
|---|---|
| alpha.1 | Android `auto_redirect` 完整实现、endpoint 的 `on_demand` 选项、缓存文件写缓冲 |
| alpha.2 | 仅修复 |
| alpha.3 | **TUN 改用 sing-tun 自有 TCP/IP 栈**；`stack` 选项弃用，1.17.0 移除；1.16.0 起需 `ENABLE_DEPRECATED_TUN_STACK=true` |

### 该优化对我们零收益

- 服务端配置中 `"tun"` 出现 **0 次**（hysteria2 + socks inbound），不在 TUN 链路内。
- **实测确认 `stack` 选项只被 `tun` 接受**，`tproxy` / `redirect` / `mixed` 均报
  `unknown field "stack"`。即：该优化只作用于 TUN 接入路径。

| 客户端模式 | 1.15 栈优化 |
|---|---|
| `tun`、`auto_redirect`（tun 的选项） | 受益 |
| `tproxy`、`redirect`、`mixed` / `socks` / `http` | 无影响 |

**易漏点**：我们的客户端配置**没有设置 `stack` 选项**，所以客户端升到 1.15 会自动用上新栈，
且在 1.16 / 1.17 不会被弃用影响——这一条我们天然向前兼容，无需任何改动。

**区分三类变化的适用范围**：栈实现（仅 TUN）／协议出口改进（所有模式，如 QUIC 栈升级）／
配置 schema 迁移（所有模式，解析阶段即失败）。

---

## 五、其它发现

- **文档与实现不一致**：官方弃用清单称 legacy special outbounds（`block`/`dns`）
  于 1.13.0 移除，但实测 **1.14.0 仍接受 `{"type":"block"}` outbound 与 `outbound:"block"`
  规则，exit 0 且 stderr 为空**。结论：不能照抄文档，必须用真实内核验证。
  （该 outbound 未改动；未来失效时会有明确报错。）
- **安全**：全仓库仅一条历史公告（GHSA-r5hm-mp3j-285g，2023-09，SOCKS inbound 认证缺陷，
  critical），**1.4.5 已修**，远早于 1.10.7。当前无未修公告。

---

## 六、可复现的验证方法（重要）

本次调查用真实内核二进制校验配置，**这填补了规范中记录的验证缺口**
（`spec/tests/writing-tests.md` §4：MOCKCORE 的 `check` 只做 `jq -e .`，
套件无法校验配置语义）。

```bash
# 取内核
curl -sSL --fail --proto '=https' --proto-redir '=https' -o sb.tar.gz \
  "https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-linux-amd64.tar.gz"
tar -xzf sb.tar.gz

# 渲染我们的配置（需要补 SOCKS_USERNAME / socks_password 等全局）
# 然后直接校验
./sing-box-1.14.0-linux-amd64/sing-box check -c <config.json>
```

注意：hysteria2 inbound 需要证书文件存在，否则初始化阶段报
`read certificate: no such file or directory`，会掩盖后续校验错误。
调查中用 `openssl` 生成自签证书并改写配置路径绕过。

调查用的五个版本内核与配置留在 `/tmp/sbcheck/`（约 230M），**`/tmp` 会被清理，
需要时按上述命令重新下载即可**。

---

## 七、若日后重启：建议的优先级

1. **客户端配置修复**——已坏半年多，且不需要升级内核即可独立修复，影响的是已装用户。
2. **服务端内核升级**——收益为 QUIC 栈等；代价是配置迁移 + 事务顺序设计
   （先换内核则旧配置起不来，先换配置则旧内核起不来，修复路径的回滚也需一并设计）。
3. **1.15 本身**——alpha 阶段，且对服务端零收益，等稳定版。
4. **内核升级的触发条件**（见 §八）——不在版本号上，而在是否观察到 hysteria2 侧症状；
   若无症状，继续停在 1.10.7 是合理选择。

## 八、补充：升级的实际收益（hysteria2 / QUIC 侧）

> 起因：确认「客户端使用 tproxy 透明代理」后，需要回答「还有没有必要升级内核」。
> 本节是 §四（1.15 评估）之外的第二层判断，覆盖 1.10.7 → 1.14.0 的整体跨度。

### 8.1 tproxy 让 1.15 的优化彻底无关

实测已确认 `stack` 选项只被 `tun` 接受（§四）。用户侧接入为 tproxy ⇒ 不在 TUN 链路内；
服务端配置 `"tun"` 出现 0 次 ⇒ 同样不在。**两边都不受益。**

### 8.2 真正的收益在 QUIC 传输层

hysteria2 跑在 QUIC 上。从 1.10.7 到 1.14.0，quic-go 共升 **12 个版本**：

```
0.48.0 → 0.48.1 → 0.48.2 → 0.49 → 0.51 → 0.52
       → 0.54 → 0.55 → 0.57.1 → 0.58 → 0.59 → 0.61
```

另有一条服务端 bug 修复：

```
[1.13.0-alpha.26] Fix memory leak in hysteria2
```

**这两项与接入方式无关**——它们作用在协议/出站那一段，tproxy 用户同样受益。
这是升级的真正理由，也是 1.15 的 TUN 优化无法替代的。

### 8.3 判断标准：看症状，不看版本号

| 现状 | 建议 |
|---|---|
| 稳定运行，无内存增长 / 无断流 / 吞吐正常 | 不急。1.10.7 能跑就一直跑 |
| 内存持续增长 / QUIC 连接异常 / 吞吐下降 | 升级信号——这些正是新版修掉的 |
| 要拿传输层改进但不想动配置 | 见 8.4 的中间站 |

### 8.4 中间站：1.12.25（零配置改动）

| 目标 | 配置改动 | quic-go | 内存泄漏修复 |
|---|---|---|---|
| **1.12.25** | **零**（仅 1 条告警，实测 exit 0） | 0.52 | ❌ |
| 1.13.21 / 1.14.0 | 两处迁移（§二，实测过） | 0.59 / 0.61 | ✅ |

1.12.25 是实测能直接吃下现有配置的**最后一个版本**。完整收益需 1.13+，
届时配置迁移必须与内核切换同时进行（两种形式互不兼容，§一）。

### 8.5 待确认项

用户侧「客户端使用 tproxy」意味着**没有使用我们生成的 `sbox.json`**（那份是 TUN 模式）。
这决定了 §三 的客户端配置问题**是否适用**：

- 未使用我们的 `sbox.json` ⇒ 三个问题与之无关，客户端由用户自行维护
- 仍在使用（自行改成 tproxy）⇒ 那份配置在 1.13+ 同样跑不起来，与内核版本无关

重启讨论时需先确认这一点，它直接影响 §七 的优先级排序。

## 参考

- 迁移文档 <https://sing-box.sagernet.org/migration/>
- 弃用清单 <https://sing-box.sagernet.org/deprecated/>
- 变更日志 <https://sing-box.sagernet.org/changelog/>
