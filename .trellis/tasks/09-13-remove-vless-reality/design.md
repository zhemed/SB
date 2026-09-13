# 技术设计：移除 VLESS Reality

## 决策记录（已定）

| 编号 | 决策 | 理由 |
|---|---|---|
| D1 | **方案 A**：`load_repair_config_values` 接受含 `vless` inbound 的旧配置，重写为标准新配置 | 用户选定。且需同时改 `try_repair_config_source` 的短路（见 §D6.6） |
| D2 | Hysteria2 密码**保持 UUID 格式** | 值本身就是随机 UUID；改成自由格式会改变客户端链接格式并迫使所有用户重发配置，零收益 |
| D3 | **删除** `chooseport` 的 `reserved` 形参 | 除 VLESS 外无调用者；仓库既有规范禁止死代码 |
| D4 | 变量名 `uuid` / `REPAIR_UUID` / `changeuuid` **保持不变**，只改用户可见文案 | 值仍是 UUID，名字依旧准确；改名涉及 12+ 处且需同步钉死断言，纯开销 |

## 盘点修正（相对初版设计的三处判断错误）

1. **`src/85-repair.sh:18-24` 的 `jq -e` 门（第 20 行）才是头号硬失败点**，不是 `:31-32` 的
   `jq -er`。它决定「这份配置能否作为修复来源」，并因此决定是否被迫走 REBUILD。
2. **`change_ports()` 第 601 行是 `||` 链的第一环**（`601-603`）。删掉 vless inbound 后它
   必然失败 → 整个函数永久返回「读取当前端口失败」。不是「少一个选项」，是**功能整体不可用**。
3. **`changeuuid()` 是双目标写入**：读 vless uuid（761），同时写 vless uuid 与 hy2 password
   （791-792）并双向校验（795）。需要真正重写，不是改一句提示。

## 目标终态

服务端只含两个 inbound，客户端只含两个 proxy，无任何自动选择分组。

```
安装流程：  依赖 → 内核 → 证书 → 端口(vl/socks/hy2) → 凭据(uuid + socks密码) → 配置 → 服务
                            ↓                                    ↓
                    端口(socks/hy2)                      凭据(uuid + socks密码)
```

UUID 继续保留（Hysteria2 的 `password` 字段用它），但**来源从 VLESS inbound 改为 Hysteria2 inbound**。

---

## D1 服务端配置（`src/30-server-config.sh`）

删除 `render_server_config` 中的整个 `vless` inbound 对象（当前 `:13-40`），保留
`hysteria2`、`socks`、`outbounds`（`direct` 的 `domain_strategy: ${ipv}`）、`route.rules`。

- `route.rules` 不变：SOCKS5 的 UDP 阻断规则、quic/stun 阻断、direct 兜底都保留。
- `outbounds[].domain_strategy` 由 `ipv` 驱动，与 Reality 无关 → **保留**。
- 删除后 `render_server_config` 不再引用 `port_vl_re`/`ym_vl_re`/`private_key`/`short_id`。

**校验限制（必须知情）**：测试套件里的 `MOCKCORE` 的 `check` 只做 `jq -e .`
（`tests/repair.sh` 的桩），**不做 sing-box 语义校验**；本机也没有真实内核。
因此「新配置对 sing-box 1.10.7 合法」这一点**无法在本地验证**。缓解：删除的只是
一个完整的 inbound 对象，其余内容逐字节不变，语义风险低；但仍应在真机安装一次确认。

---

## D2 安装流程（`src/90-main.sh`）

`install_singbox()` 中删除：

- `sing-box generate reality-keypair` 调用与 `private_key`/`public_key` 解析（当前 `:39-51`）
- `short_id` 生成与校验（当前 `:57-62`）
- `atomic_write_private_text "$SB_DIR/public.key" ...`（当前 `:52-56`）
- 相关 `abort_install_transaction` 分支

保留：`v6only`（`ipv`）、`inssb`、`inscertificate`、`insport`、`inssbjson`、`sbservice`、
`save_last_good_config`、快捷方式、`cronsb`、`sbshare`。

---

## D3 端口选择（`src/20-ports.sh`）

- 删除 `vlport()`。
- `socksport()` 的保留参数消失：`chooseport tcp "$port_vl_re"` → `chooseport tcp`。
  随之 `chooseport` 的 `$reserved` 形参**可能整体失去调用者** → 需判断是否一并删除该形参
  （保留则成为死参数，违反仓库「不留死代码」的既有做法）。
- `insport()` 随机分支中只为 VLESS/SOCKS5 冲突而存在的 `while true` 重试循环
  （当前 `:110-113`）删除。
- 菜单提示文案去掉 VLESS 项；端口确认输出去掉 VLESS 行。
- 删除 `valid_reality_key()`、`valid_short_id()`（唯一调用者是被删的修复/安装代码）。

---

## D4 客户端输出（`src/50-client-output.sh`）

### D4.1 `result()` —— 共享 UUID 的来源必须迁移

当前从 VLESS inbound 读 UUID：

```bash
# src/50-client-output.sh:85
uuid=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .users[0].uuid' "$SB_CONFIG" 2>/dev/null) || return 1
```

改为从 Hysteria2 inbound 读：

```
select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password
```

同时删除 `vl_port`、`vl_name`、`public_key`、`short_id` 的读取与校验，以及
`managed_regular_file_is_trusted "$SB_DIR/public.key"`。

### D4.2 分享链接与节点文件

- 删除 `resvless()`（当前 `:134-149`）。
- `sbshare()`：去掉 `vl_tmp` 与 `vl_reality.txt` 的产出，聚合文件 `jhdy.txt` 改为
  `hy2.txt + socks5.txt` 拼接。注意所有 `rm -f` 清理链与 `mv -fT` 链都要同步收敛
  ——这是该函数中最容易漏改的部分（当前 `:527-553` 有 9 处清理链）。

### D4.3 sing-box 客户端配置（`sb_client` heredoc）

- 删除 `vless` outbound 块（当前 `:321-341`）。
- 删除 `auto`（urltest）outbound 块（当前 `:379-389`）。
- `proxy` selector 改为 `["hy2-$hostname", "socks5-$hostname"]`，`default` 改为 `hy2-$hostname`
  （当前 default 是 `auto`，该 tag 即将不存在 → 不改会导致配置悬空引用）。

### D4.4 Clash 客户端配置

- 删除 `- name: 负载均衡`（load-balance）与 `- name: 自动选择`（url-test）分组。
- 删除 `vless-reality-vision-$hostname` proxy 块。
- `🌍选择代理节点` select 的 proxies 收敛为 `[DIRECT, hysteria2-$hostname, socks5-$hostname]`。

---

## D5 管理菜单（`src/70-management.sh`）

| 项 | 处理 |
|---|---|
| `change_vl_sni()` | 整个函数删除；菜单项「5. 更改SNI域名」删除并**重排后续编号** |
| `change_ports()` | 去掉 VLESS 端口选项与 `port_vl_re`；`chooseport tcp "$vl_port"` 的保留约束消失 |
| `change_credentials()` | 保留；成功提示 `VLESS/Hysteria2 UUID（密码）修改成功` 改为只提 Hysteria2 |
| `switch_ip_priority()` | **保留不动**（`ipv` → `direct` 出站的 `domain_strategy`，全局策略） |

菜单重排会连带影响：`tests/verify.sh` 中钉死的菜单项字符串、`readp "请输入数字 [0-9]"`
的提示范围、以及文档里的菜单说明。**编号重排是本次改动中最容易产生下游遗漏的点。**

---

## D6 修复模块（`src/85-repair.sh`）

### D6.1 必需字段读取（会硬失败的耦合点）

```bash
# src/85-repair.sh:31-32
REPAIR_PRIVATE_KEY=$(jq -er '... .tls.reality.private_key ...' "$source") || return 1
REPAIR_SHORT_ID=$(jq -er '... .tls.reality.short_id[0] ...' "$source") || return 1
```

`jq -er` 读不到就失败 → 对只含 hysteria2+socks 的新配置，`load_repair_config_values`
会直接返回 1，**修复功能整体不可用**。这两行连同 `REPAIR_PRIVATE_KEY`/`REPAIR_SHORT_ID`
整条数据流必须删除，并重新定义「节点参数是否齐全」的判据（剩余必需项：uuid、
`socks5` 端口与密码、`hy2` 端口与证书路径、`ipv`）。

### D6.2 整函数删除

`derive_reality_public_key()`、`repair_reality_public_key()`。

### D6.3 重建路径

`rebuild_repair_config` 中生成 Reality 密钥对与 `public.key` 的部分删除
（当前 `:316-321`、`:340`）。重建后仍须写 `REPAIR_NODE_REBUILT=1` 以提示客户端配置需重发。

### D6.4 报告与临时文件清单

- `initialize_repair_report`/`show_repair_report` 中 VLESS 专属字段删除。
- 临时文件清理清单中 `.public.key.*`、`.reality-key.*`（当前 `:439-440`）：
  **建议保留**，用于清理旧安装遗留的临时文件；但需要注释说明这是兼容性清扫而非当前产物。
  （这与上一轮删除 `.sb.json.rollback.*` 的判断标准一致：那条从未有过生产者，
  这两条**曾经**有生产者，属于真实的旧版本残留。）

### D6.5 旧安装的行为定义（R4）

必须显式选择并测试其一：

- **(A) 重建**：检测到 `vless` inbound 的旧配置时，用现有参数重建为标准新配置
  （保留 uuid / socks / hy2 / 证书），并在报告中说明「已移除 VLESS」。
- **(B) 明确拒绝**：拒绝修复并提示手动处理。

推荐 **(A)**，与既有「参数可从现有配置提取则原地重建」的哲学一致，且不给用户制造
必须手工删配置的死局。这需要一条新的判据与一条新断言。

### D6.6 让方案 A 真正生效：必须改短路逻辑（关键）

`try_repair_config_source()`（`:203-207`）在「来源是当前配置、未发生证书回退、
`managed_config_file_is_valid` 通过」时**直接返回，不重新渲染配置**：

```
当前配置正常，节点参数保持不变
```

而 `managed_config_file_is_valid` 只跑 `sing-box check`（`40-service.sh:372-377`），
旧内核仍然认识 `vless` inbound → **一份含 VLESS 的旧配置会被判定为「正常」并原样保留**。
结果是 VLESS 一直残留，直到用户手动改端口/凭据或走一次 REBUILD。

因此方案 A 需要在此短路条件中加一条：**配置仍含 `vless` inbound 时视为「需要重写」**，
强制走渲染路径。否则 D1 的选择不会生效——这是本次最容易「实现了却没效果」的地方。

### D6.7 三处删函数调用点必须同时删

`repair_reality_public_key` 有 **三个**调用点：`:623`、`:646`、`:758`。

`src/` 没有全局 `set -e`/`set -u`（只有 `60:291` 往生成的续期脚本里写 `set -u`），
所以漏掉任何一个，调用会变成**静默的 command not found**，并让 `maintenance_failed=1`
——一次正常的修复会莫名其妙变成黄色告警。

### D6.8 保留项（刻意的兼容，不是遗漏）

- 临时文件清扫中的 `.public.key.*` 与 `.reality-key.*`（`:439-440`）：**保留并加注释**。
  这两个前缀在已发布版本中**确有生产者**（`85-repair.sh:253`、`:285`），旧机器上可能遗留
  未清理的临时文件。这与上一轮删除 `.sb.json.rollback.*` 的判据一致——那条从未有过生产者。
- `managed_install_data_present()` 的 `-s $SB_DIR/public.key`（`40-service.sh:360`）：
  **保留并加注释**。它现在的作用是**识别旧版 Reality 安装**，正是方案 A 需要的信号；
  且脚本本就有「残缺安装可在确认后清理并重新安装」的出口，不会把用户困死。

### D6.9 其它易漏点

- `src/10-acme.sh:4`（`cert_self_signed`）与 `:279`（`cert_acme`）各有一句
  `ym_vl_re=apple.com`。§D1 改动后成为**死赋值**（全树读者只有 `30:29`、`30:33`、`85:60`）
  → 删除。两个函数其余部分与 VLESS 无关。
- `src/40-service.sh`、`80-lifecycle.sh`、`60-cron.sh`、`00-bootstrap.sh` 无 VLESS 逻辑。
- 客户端半部与服务端半部**必须同一个提交落地**：`refresh_share_files_after_change`
  （`70:748-753`）→ `sbshare()` 仍依赖 vless uuid/port/SNI、`public.key`、short_id
  （`50:85-90`、`:530`、`:550`）。分两次提交会让所有 `change_*` 流程的分享文件刷新失效。

---

## D7 测试（详见 implement.md）

高风险项：

- `tests/verify.sh:130` 的 `awk` 以 `- name: 负载均衡` 为起始锚点 → 分组删除后**该断言会
  静默失效或直接失败**，必须改写，不能只删。
- `tests/verify.sh:120-128` 抽取 sing-box `auto` 块并断言无 `socks5-` → 块消失后
  `[[ -n $auto_block ]] || fail` 会失败。应改写为「客户端配置中不存在 urltest /
  load-balance / url-test 分组」这一结构性断言，保持原不变量（SOCKS5 不参与自动测速）
  仍被覆盖。
- `tests/repair.sh` 的 `MOCKCORE` 桩与节点值 fixture 中大量 `port_vl_re`/`ym_vl_re`/
  `private_key`/`short_id` 变量，以及 Reality 公钥重算/修复用例。
- 已验证：**没有任何 `awk` 范围锚点的起止函数会消失**
  （`changeuuid`/`change_socks_password`/`sb_client`/`sbshare`/`inscertificate` 等全部保留），
  这是本次改动的一个有利条件。

---

## D8 文档与规范

- `README.md`：`:30`、`:33`、`:35`（项目结构表）、`:83`、`:84`、`:85`（协议能力声明）。
- `.trellis/spec/`：`shell/index.md` 的函数总数（234）、`guides/cross-layer-thinking-guide.md`
  以 VLESS 端口为示例的数据流、`runtime/managed-assets.md` 的 `$SB_DIR` 产物清单
  （`public.key`、`vl_reality.txt`）、以及其它描述协议集合的位置。

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 无法本地做 sing-box 语义校验 | 删除的是完整 inbound 对象，其余字节不变；真机安装验证一次 |
| 菜单编号重排的下游遗漏 | 全仓库 grep 菜单字符串 + `tests/verify.sh` 钉死值同步 |
| 清理链漏改导致残留临时文件 | 逐条收敛 `sbshare` 的 9 处 `rm -f`/`mv -fT` 链 |
| 测试覆盖静默流失 | 每处删除用例都要给出「等价覆盖在哪」的判断，否则改写 |
| 旧安装升级路径未定义 | D6.5 显式选 (A) 并加断言 |

## 回滚

全部改动在 `src/`，`sb.sh` 由构建器再生。任一步失败可
`git checkout -- src/ tests/ README.md && bash scripts/build.sh` 回到当前可用状态。
