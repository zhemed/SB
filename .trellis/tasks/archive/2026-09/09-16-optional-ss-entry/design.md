# design.md — SS-2022 入口改为可选

## 1. 唯一真相：配置里有没有 `ss-sb`

不为「启用/未启用」建状态文件。判据永远是 `sb.json` 里存在 `type: shadowsocks` 且 `tag: ss-sb`
的入站。派生规则：

| 位置 | 判据 |
|---|---|
| 渲染（30） | 动态作用域变量 `ss_entry_enabled`（1/0），由调用方给出 |
| 客户端产物（50） | `result()` 从配置里读到 `ss-sb` 就 `ss_enabled=1`，读不到就是 0（不再是错误） |
| 菜单（70） | 同 50：`jq -e '[.inbounds[]|select(.tag=="ss-sb")] | length == 1'` |
| 修复（85） | `load_repair_config_values` 设 `REPAIR_SS_ENABLED`：有 `ss-sb` → 1；只有旧 `socks` → 1（迁移）；都没有 → 0 |

`ss_entry_enabled` 默认必须是 **0**：忘传就是"不装"，而不是渲染出一个缺密钥的坏配置。

## 2. 渲染层的条件化

`render_server_config` 里两处变成片段插值（沿用 v3.0.0 里 relay 出站的写法）：

```json
  "inbounds": [
    { hysteria2 … }${ss_inbound_suffix}
  ],
  "route": {
    "final": "${route_final}",
    "rules": [
      ${ss_udp_rule}{ "protocol": ["quic","stun"], "outbound": "block" }
    ]
  }
```

- `ss_entry_enabled=1` 时：`ss_inbound_suffix` = `,\n    { shadowsocks 块 }`，`ss_udp_rule` = `{ inbound:["ss-sb"], network:"udp", outbound:"block" },\n      `。
- `=0` 时两者都为空串，模板其余部分逐字节不变（未启用时的配置与 v3.0.0 的 hy2-only 形态一致）。
- 未启用时 `port_ss` / `ss_password` 允许为空——模板不再引用它们。

**为什么不重新渲染而用 jq 补丁做启用/停用**：渲染需要构造全部动态作用域局部变量（uuid、两个端口、
证书路径、ipv、relay…），而菜单流量改的是"活配置"里的一小部分；既有 `change_ports` /
`change_ss_password` 已经是 jq 补丁 + `commit_config` 的路子，保持一致。

## 3. 菜单结构

```
[5] 更改端口   → 只保留 hysteria2 主端口（SS 端口搬进 [8]）
[6] 协议凭据   → 只保留 Hysteria2 UUID（SS 密钥搬进 [8]）
[8] 可选功能   → 1：Shadowsocks-2022 入口   2：上游/中转   0：返回
[9] 卸载
```

SS 入口子菜单（`manage_ss_entry`）：

| 项 | 行为 | 未启用时 |
|---|---|---|
| 1 启用 | 选端口（回车/1 随机、2 自定义）→ `generate_ss_password` → 候选 = 现有配置 + 入站 + UDP 规则 → `commit_config` → 刷新分享 | 提示「当前已启用（端口 N）」 |
| 2 停用 | 确认后候选 = 现有配置 − 入站 − 该入站规则 → `commit_config` → 刷新分享（顺带删 `ss.txt`） | 提示「当前未启用」 |
| 3 更改端口 | jq 改 `.listen_port`（唯一性校验） | 提示「请先启用」 |
| 4 更改密钥 | 复用现有 `change_ss_password` 主体 | 提示「请先启用」 |

细节：

- **入站 `listen` 从 hy2 入站读**（`jq -r '.inbounds[]|select(.tag=="hy2-sb")|.listen'`），
  保证同一份配置里两个入站一致，而不是重新探测内核状态。
- **启用时的端口选择**与安装时的逻辑一致：`readp` → 空/1 = `random_available_port tcp`，
  2 = 自定义（`chooseport tcp`，占用则重试）。SS 用 TCP，hy2 用 UDP，同号不冲突。
- **幂等**：候选构造先删掉同 tag 的入站/规则再插入，连续执行两次结果一致。
- 启用/停用后 `refresh_share_files_after_change`（内部就是 `sbshare`）。

## 4. 客户端产物

`result()`：

```bash
if ss_password=$(jq -er '.inbounds[] | select(.type=="shadowsocks" and .tag=="ss-sb") | .password' "$SB_CONFIG" 2>/dev/null); then
  ss_enabled=1
  ss_port=$(jq -er '… .listen_port' "$SB_CONFIG") || return 1
  valid_port "$ss_port" && valid_ss_password "$ss_password" || return 1
else
  ss_enabled=0; ss_port=; ss_password=
fi
```

`resss` 仅在 `ss_enabled=1` 时调用；`sb_client` 的两处（sbox 出站块、clash 条目）与两处成员列表
（selector.outbounds、clash proxies）按 `ss_enabled` 条件化；`sbshare` 未启用时
`rm -f "$SB_DIR/ss.txt"`（先过 `managed_regular_file_is_trusted`，删不掉只告警），聚合文件只拼 hy2。

单成员 selector（`outbounds: ["hy2-…"]`）是合法的——发布前用真实内核 `check` 验证一次。

## 5. 修复的三种形态

| 源配置 | 结果 |
|---|---|
| 有 `ss-sb` | 端口/密钥原样保留（现状不变） |
| 只有 `socks5-sb`（≤2.0.1） | 迁移为 `ss-sb` + 重新生成密钥 + label 提示（现状不变） |
| 两者都没有（本版新建） | 保持没有；`render_repair_config` 传 `ss_entry_enabled=0` |

`load_repair_config_values` 的入站 gate 从「恰好一个 ss 或 socks」放宽为「ss ≤1 且 socks ≤1
且两者不同时存在」。

## 6. 受影响文件

| 文件 | 改什么 |
|---|---|
| `src/20-ports.sh` | `insport` 去掉 SS 端口与密钥；新增 `choose_ss_port`（回车/1 随机、2 自定义） |
| `src/30-server-config.sh` | 条件化入站与 UDP 规则片段 |
| `src/50-client-output.sh` | `result` 容忍缺失、`sb_client` 条件化、`sbshare` 清理 `ss.txt` |
| `src/70-management.sh` | `change_ports`/`change_credentials` 只留 hy2；新增 `manage_optional_features`、`manage_ss_entry`、`enable_ss_entry`、`disable_ss_entry`、候选构造函数 |
| `src/85-repair.sh` | `REPAIR_SS_ENABLED`、gate 放宽、`render_repair_config` 传参 |
| `src/90-main.sh` | 菜单文案（[8] 可选功能）、安装提示（只放行 hy2；SS 警告移到启用动作） |
| `tests/*` | 钉死串、新用例、hy2-only 夹具 |
| `README.md`、`.trellis/spec/**` | 协议/菜单/受管文件的描述 |

## 7. 风险

| 风险 | 缓解 |
|---|---|
| 条件化模板写出不合法 JSON（未启用分支） | 真实内核 `check` + 真启动；`tests/unit.sh` 直接断言 hy2-only 渲染结果无 `ss-sb` |
| 停用后 `ss.txt` 残留，用户以为还能用 | `sbshare` 主动删除 + 测试断言 |
| 修复把已有 SS 入口吃掉 | 三种形态各一个 repair 用例（保留/迁移/不补齐） |
| 菜单重排后锚点漂移（`changeuuid` 后的函数） | 沿用 v3.0.0 的处理：区间锚点同步改，`tests/verify.sh` 里保留 `[[ -n $extracted ]]` 守卫 |
| jq 补丁写入重复入站 | 候选构造先删后插 + 幂等用例 |

## 8. 验证方法

1. 门禁：`bash scripts/build.sh && bash tests/verify.sh`（shellcheck ≥ 0.10.0）。
2. 真实内核：hy2-only 配置 `check` + 真启动（无 ss 监听、服务 active）；
   启用后的配置再跑一次 SS 真握手；中转链路端到端（回归）。
3. 形态断言：渲染出的 hy2-only 配置里 `grep -c ss-sb` 为 0；启用后的配置里为 1。
4. 菜单流程用单元测试覆盖候选构造函数（真实 jq，不 mock）与幂等。

---

## 9. 实施记录（与计划的偏差）

1. **`change_ports` / `change_credentials` 只留 hy2**：SS 的端口与密钥整体搬进【8】子菜单，
   避免同一件事两个入口。`tests/verify.sh` 的 `请选择【0-2】` 钉死改为 `【0-1】`。
2. **`sbshare` 的调用顺序保持 SS 在前**：SS 变可选后最自然的写法是先渲染 hy2，但那会打破
   「SS 在前」的既有顺序断言；改成先 `result`、再 SS（若有）、再 hy2，输出顺序与断言都不变。
3. **框架陷阱（本次抓到的真 bug）**：片段用 `fragment=$(printf '…\n')` 构建时，**命令替换会吃掉
   所有结尾换行**，于是 Clash 里出现 `udp: false- name: hysteria2-…`（把下一个代理吞掉）和
   `- ss-testhost    - DIRECT`（分组少一个成员）。JSON 侧因为空白不敏感而照常通过 `check`，
   **只有把真实产物按行/按语义检查才能发现**。修法是每个需要的片段再 `fragment+=$'\n'`，
   并在 `tests/unit.sh` 加一条 `generated client files keep one entry per line` 回归用例
   （用 `/bin/true` 顶替内核，不需要真 sing-box）。
4. **`insport` 的负向断言**：`tests/verify.sh` 用 awk 抽 `insport` 函数体（区间锚点是下一个函数
   `render_server_config`，不是文件里更早出现的 `valid_ipv6`），断言其中不出现
   `ss_password`/`port_ss`/`ss-sb`/`generate_ss_password`——这是「默认不装」的机器可验证表述。
5. **单元测试需要颜色变量**：菜单文案里有 `${yellow}` 这类插值，unit.sh 以前只 mock 了颜色
   *函数*，`set -u` 会因未定义的变量直接炸；补上空的颜色变量导出。
