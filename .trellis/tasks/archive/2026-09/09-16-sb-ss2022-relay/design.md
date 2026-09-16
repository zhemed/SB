# design.md — v3.0.0 SS-2022 替换 + 上游/中转

## 1. 实测证据（决定设计的事实，全部用真实内核复现）

验证内核：`/tmp/sbcheck/sing-box-1.10.7-linux-amd64/sing-box`（1.10.7，与 `CORE_VERSION` 一致）。

| # | 断言 | 实测结果 | 影响 |
|---|---|---|---|
| E1 | shadowsocks 入站不写 `network` 时监听什么 | **TCP+UDP 都监听**（`ss -ltnup` 见同端口 tcp+udp 两条） | 443 会被 hy2 的 `443/udp` 占住 → **必须 `"network": "tcp"`** |
| E2 | 上述冲突是启动失败还是降级 | `sing-box check` **通过**（exit 0）；真实 `run` 时 `FATAL … listen udp4 0.0.0.0:443: bind: address already in use`，进程直接退出 | 静态 check 抓不到，**验收必须真启动** |
| E3 | 路由规则 `"network": "tcp,udp"` 是否匹配 | 不匹配（连接穿透）；`["tcp","udp"]` 与 `"tcp"` 匹配 | 兜底规则确实是死规则 → 改用 `route.final` |
| E4 | SS-2022 密钥格式 | 44 字符 base64（32B）✅；24 字符 base64（16B）❌ `bad key`；**43 字符无填充 base64 ❌ `decode psk: illegal base64 data`**；32 字符明文 ❌ | 生成与校验都必须是**带填充的 44 字符 base64** |
| E5 | `net.ipv6.conf.all.disable_ipv6=1` 时 `listen: "::"` | 裸 bind 成功、sing-box 起得来、IPv4 也能连 | 断言「sysctl 关 IPv6 ⇒ `::` 起不来」**不成立**；但运维侧机器已是 IPv4-only 且以 `0.0.0.0` 为准，探测策略取保守值 |

复现 E1/E2：

```bash
cd /tmp/sbcheck && SB=./sing-box-1.10.7-linux-amd64/sing-box
printf '{"inbounds":[{"type":"shadowsocks","tag":"ss-sb","listen":"0.0.0.0","listen_port":18444,
"method":"2022-blake3-aes-256-gcm","password":"%s"}],"outbounds":[{"type":"direct","tag":"direct"}]}' \
  "$(openssl rand -base64 32)" > a.json
$SB check -c a.json && $SB run -c a.json &   # 观察 ss -ltnup：同端口 tcp+udp
```

## 2. 服务端配置形态（改动前 → 改动后）

改动前：`inbounds = [hysteria2(hy2-sb), socks(socks5-sb)]`，
`route.rules = [socks UDP→block, quic/stun→block, {direct, network:"udp,tcp"}(死)]`，无 `final`。

改动后：

```json
{
  "inbounds": [
    { "type": "hysteria2", "tag": "hy2-sb", "listen": "<LISTEN>", "listen_port": <port_hy2>, "...": "..." },
    { "type": "shadowsocks", "tag": "ss-sb", "listen": "<LISTEN>", "listen_port": <port_ss>,
      "network": "tcp", "method": "2022-blake3-aes-256-gcm", "password": "<44 字符 base64>",
      "sniff": true, "sniff_override_destination": true }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "<ipv>" },
    { "type": "block", "tag": "block" }
    /* 配了上游时追加： { "type": "shadowsocks", "tag": "relay", "server": …, "server_port": …,
                          "method": "2022-blake3-aes-256-gcm", "password": … } */
  ],
  "route": {
    "final": "relay | direct",
    "rules": [
      { "inbound": ["ss-sb"], "network": "udp", "outbound": "block" },
      { "protocol": ["quic", "stun"], "outbound": "block" }
    ]
  }
}
```

- `<LISTEN>` = `server_listen_address()`（见 §4），**两个入站共用同一个值**。
- 死规则删除后由 `final` 承担出网兜底；`final` 只在配了上游时变成 `relay`。
- `ss-sb` 的 UDP 阻断规则在 `network: "tcp"` 下是冗余的，**故意保留**：它是 README 与测试里
  「该入口只跑 TCP」的显式契约，也是将来有人给入站加回 UDP 时的防线。
- 渲染方式沿用现有风格：`cat > "$output" <<EOF` 未加引号的 heredoc + 动态作用域局部变量；
  上游出站块用一个预先拼好的 `relay_outbound_suffix` 片段插值（未配置时为空串），
  这样模板仍是单一 heredoc，不需要第二遍 jq 改写。

## 3. 凭据与状态文件

| 项 | 存哪 | 谁生成 | 谁读取 |
|---|---|---|---|
| SS-2022 入站密钥 `ss_password` | 只在 `sb.json`（`ss-sb.password`） | 安装（`insport`）/修复迁移 | 渲染、客户端输出、修复 |
| 上游参数（server/port/password，cipher 固定 `SS_METHOD`） | `$SB_DIR/relay.conf`（600，受管） | 菜单「上游/中转」 | `render_server_config` |

- SS 密钥沿用现有 SOCKS5 口令的既有模式（只存在配置里、修复时反向提取），不新增状态文件。
- 上游单独放状态文件，理由：**渲染必须能无条件重新注入**。若只从旧 `sb.json` 反读，
  修复链路一旦从 `last-good` 或备份恢复就会丢失上游；状态文件是唯一真相，也便于人肉检查。
- 状态文件通过 `atomic_write_private_text` 原子写入（`mktemp $SB_DIR/.managed-write.XXXXXX` → `chmod 600` → `mv -fT`），
  读取用严格解析器：必须是受管普通文件、**恰好三行** `server=` / `port=` / `password=`，逐个校验
  （`relay_server_is_valid` = IPv4/IPv6/域名，`valid_port`，`valid_ss_password`），出现未知键即判定无效。
- **实施时的收敛**：cipher 不做成可选项（固定 `SS_METHOD`）。理由：这一跳两端都是自有 sing-box，
  多一个可配项就多一组「密钥长度随 cipher 变化」的校验分支，而当前没有任何场景需要它。
- 无效状态文件（存在但解析不过）**不阻断渲染**：告警后按直连渲染，节点继续可用——
  把可选能力的损坏升级成整机不可用不划算；写入前已做全部校验，所以损坏只可能来自手工编辑。
- 文件名与权限进入受管资产清单（`spec/runtime/managed-assets.md`）。

## 4. 监听地址探测

```bash
# src/00-bootstrap.sh，与 v6only 同域
server_listen_address(){
  local root=$1 disabled=
  [[ -d $root ]] || { printf '%s\n' 0.0.0.0; return 0; }        # ipv6.disable=1：整棵树不存在
  disabled=$(cat "$root/conf/all/disable_ipv6" 2>/dev/null) || disabled=
  if [[ $disabled == 1 ]]; then printf '%s\n' 0.0.0.0; else printf '%s\n' '::'; fi
}
```

- 判定依据是**主机当前 IPv6 可用性**，不是「`::` 会不会失败」——E5 已证明 sysctl 关 IPv6 后 `::` 仍可用；
  但探测取保守解，与运维侧两台 IPv4-only 机器的既有约定（入站 `0.0.0.0`）一致，也让
  `relay-apply.sh` 里那段「顺手把监听改回 `0.0.0.0`」的补丁可以退休。
- 结果在渲染时算一次、两个入站共用，保证同一份配置里监听地址一致。
- sysctl 根由调用方传入常量 `IPV6_SYSCTL_ROOT="/proc/sys/net/ipv6"`（`render_server_config` 里传）。
  **为什么留这个参数**：这是本次唯一「无条件读宿主内核状态」的函数，需要能不经 root、不改宿主就覆盖
  两个分支；`tests/unit.sh` 因此可以传夹具目录测 `0` / `1` / 目录不存在三种情形。
  `tests/repair.sh` 的夹具不 source `src/00-bootstrap.sh`，那里另有一个返回 `::` 的同名桩。

## 5. 迁移语义（旧安装怎么上来）

沿用 2.0.0 移除 VLESS 时的既有机制，不新增流程：

1. `config_contains_removed_protocol`（`src/85-repair.sh`）扩展：配置里存在
   `type: socks` / `tag: socks5-sb` 入站即视为「携带已移除形态」→ 修复会重写而不是放行。
   （标记名为 `REPAIR_SOCKS_INBOUND`：`tests/verify.sh` 的「退役身份」守卫大小写不敏感地禁用
   `LEGACY_` / `migration` 等字样，命名必须绕开它。）
2. `load_repair_config_values` 兼容读旧形态：**端口**从 `ss-sb` 或 `socks5-sb` 任一取到即可；
   **密钥**只有 `ss-sb` 有，旧形态取不到 → 置空并置 `REPAIR_SOCKS_INBOUND=1`。
3. `try_repair_config_source` 在重写前：密钥缺失则 `generate_ss_password` 生成新密钥，
   label 追加「已把 SOCKS5 入站升级为 Shadowsocks-2022 并重新生成密钥，请更新客户端」。
4. 修复完成后 `refresh_share_files_after_change` 走 `sbshare` 重新生成 `ss.txt` 等文件。

菜单 5（改端口）/ 6（改凭据）在旧形态配置上仍是**严格失败**（jq 选择器找不到 `ss-sb`），
提示走菜单 2 修复——与现状一致，不做静默改写。

## 6. 命名映射（函数/变量）

| 旧 | 新 | 备注 |
|---|---|---|
| `SOCKS_USERNAME` | 删除 | 不再有用户名概念 |
| `port_socks5` | `port_ss` | 20 / 30 / 70 / 85 / 90 全部同步 |
| `socks_password` | `ss_password` | 同上 |
| `valid_socks_password` | `valid_ss_password` | 规则换成 44 字符带填充 base64 |
| `change_socks_password` | `change_ss_password` | `tests/verify.sh` 的 awk 区间锚点必须同步 |
| `ressocks5` | `resss` | 输出 `ss.txt`，SIP002 链接 |
| `SS_METHOD` / `ss-sb` / `relay` | 新增常量 | `00-bootstrap.sh` 常量区 |

`tests/verify.sh:113-114` 用**相邻函数名**做区间锚点抽取 `changeuuid` 函数体，
因此 `change_ss_password` 必须仍是 `changeuuid` 之后的那个函数，且定义风格保持 `name(){` 顶格。

## 7. 受影响文件与理由

| 文件 | 改什么 | 为什么必须改 |
|---|---|---|
| `src/00-bootstrap.sh` | 常量（`SS_METHOD`、tag）、`server_listen_address`、版本号 | 常量与主机探测的唯一归属地 |
| `src/20-ports.sh` | `port_ss`、`generate_ss_password`、`valid_ss_password` | 端口与校验器的唯一归属地 |
| `src/30-server-config.sh` | 入站替换 + `final` + 上游片段 | 配置模板 |
| `src/40-service.sh` | 无需改（`commit_config` 复用） | — |
| `src/50-client-output.sh` | `result` / `resss` / `sbox.json` / `clash.yaml` / `sbshare` | 客户端产物 |
| `src/70-management.sh` | 改端口、改凭据、新增上游菜单 | 用户可见变更入口 |
| `src/85-repair.sh` | 参数提取、迁移、label | 修复是唯一的升级路径 |
| `src/90-main.sh` | 菜单项与提示、装机提示 | 入口 |
| `src/80-lifecycle.sh` | 依赖清单加 `timeout` | 上游可达性探测用它做超时 |
| `tests/{verify,unit,repair}.sh` | 钉死字符串、锚点、夹具、新增用例 | 门禁 |
| `README.md`、`.trellis/spec/**` | 协议/凭据/受管文件/测试锚点描述 | 规范与实现同步 |

## 8. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 配了上游而上游不可达 ⇒ 整机断网（可能连带 SSH 断开） | 提交前用 `timeout 3 bash -c "exec 3<>/dev/tcp/…"` 探测上游端口，不可达需输入 `YES` 才继续；菜单保留「清除上游」一键恢复 |
| SS 入站忘记 `network: "tcp"` ⇒ 与 hy2 抢 443/udp ⇒ 服务起不来，而 `check` 查不出（E2） | 模板钉死 `"network": "tcp"`；验收加**真启动**冒烟；`tests/verify.sh` 钉死该行 |
| 密钥格式不合法 ⇒ 只有真内核能发现 | `valid_ss_password` 精确到 44 字符带填充 base64（E4）；测试覆盖非法样本 |
| 迁移时旧客户端全部失效 | 修复流程明确提示「密钥已重新生成，请更新客户端」；分享文件自动刷新 |
| 改端口/改凭据/修复把上游冲掉（运维侧现在正踩） | 上游存状态文件 + 渲染无条件重注入；加幂等与「改后仍在」用例 |

回滚：`git revert` 到 `2.0.1`；已升级的机器重跑旧版修复即可（配置形态回到 `socks`，但**旧口令不会自动恢复**，
需要重新生成——这是协议替换的固有代价，运维侧知情）。

## 9. 验证方法（与既有纪律一致）

1. **静态门禁**：`bash scripts/build.sh && bash tests/verify.sh`（含新用例）。
2. **真实内核**（本仓库测试套件无法语义校验配置，见 `spec/tests/writing-tests.md` §4）：
   - 用修复/渲染路径生成一份配置，`sing-box check -c` 通过；
   - **真实 `run`**：确认 hy2 与 ss 各自监听，无 `address already in use`（E2 的回归）；
   - **真实握手**：第二个 sing-box 实例用 `shadowsocks` 出站 + `socks` 入站，经它 curl 本地 HTTP 服务，
     证明 SS-2022 密钥与套件在真实协议层可用。
3. 上游分支：渲染出含 `relay` 出站的配置并 `check` 通过（用一台本地假上游即可，不连真实落地机）。
4. 监听地址：在同一台机器上按当前 `disable_ipv6` 值断言渲染结果；关 IPv6 的情形在 netns 内复现。
