# implement.md — 执行计划

执行前状态：`34f2676`（v2.0.1），工作树干净。所有改动在 `main` 上做，**最后一次性推送**（推送即发布）。

约定：
- 只改 `src/`，然后 `bash scripts/build.sh` 重新生成 `sb.sh`；**永不手改 `sb.sh`**。
- 每个阶段结束跑 `bash scripts/build.sh && bash tests/verify.sh`（测试更新未完成前，允许门禁红，
  但要记录红在哪一条，不允许「跳过不看」）。
- 版本号改动放最后一步统一做（4 处同步 + `check-version-bump.sh`）。

---

## 阶段 0 · 开工前

- [x] 真实内核证据齐备（design.md §1，`/tmp/sbcheck/sing-box-1.10.7-linux-amd64`）
- [x] `git status --porcelain` 干净；`VERSION` = `2.0.1`

## 阶段 1 · 服务端基线（③ 死规则 + ④ 监听地址）

最小、零耦合的两项先做，做完即可单独验证。

1. `src/00-bootstrap.sh`
   - [x] 加 `server_listen_address()`（design.md §4）
2. `src/30-server-config.sh`
   - [x] 两个入站 `listen` 改用 `$(server_listen_address)`
   - [x] 删死规则，加 `"final": "direct"`
- 验证：`bash scripts/build.sh && bash tests/verify.sh`；
  真实内核 `check` 通过；用 netns 复现 `disable_ipv6=1` 时渲染出 `0.0.0.0`
- 回滚点：`git stash` / `git checkout -- src`

## 阶段 2 · SS-2022 入站替换（①）

1. `src/00-bootstrap.sh`
   - [x] 删 `SOCKS_USERNAME`，加 `SS_METHOD="2022-blake3-aes-256-gcm"`（+ tag 常量若有需要）
2. `src/20-ports.sh`
   - [x] `port_socks5` → `port_ss`；提示文案改「Shadowsocks」；凭据生成段改用 `generate_ss_password`
   - [x] `valid_socks_password` → `valid_ss_password`（44 字符带填充 base64）
3. `src/30-server-config.sh`
   - [x] socks 入站整块换 shadowsocks 入站（`network: "tcp"` 必写）
   - [x] 路由规则 tag 改 `ss-sb`
4. `src/50-client-output.sh`
   - [x] `result()` 读 `ss-sb` 的 port/password 并校验
   - [x] `ressocks5` → `resss`（SIP002 base64 userinfo 链接、`ss.txt`、二维码文案）
   - [x] `sbox.json` 出站换 shadowsocks（`network: "tcp"`），selector 成员改 `ss-$hostname`
   - [x] `clash.yaml` 条目换 `type: ss` + `cipher`，分组顺序 `[hysteria2, ss, DIRECT]`
   - [x] `sbshare` 的临时文件/产物名 `socks5.txt` → `ss.txt`
5. `src/70-management.sh`
   - [x] 改端口、改凭据两处的 jq 选择器与文案；`change_socks_password` → `change_ss_password`
6. `src/85-repair.sh`
   - [x] `load_repair_config_values` 改读 `ss-sb`（端口兼容旧 `socks5-sb`），密钥缺失标记
   - [x] `config_contains_removed_protocol` 把 `socks`/`socks5-sb` 计入
   - [x] `try_repair_config_source` 迁移分支 + label
   - [x] `render_repair_config` 的局部变量改名
7. `src/90-main.sh`
   - [x] 装机提示（SOCKS5 安全提示 → SS-2022 提示：密钥不可推导、NTP 前提）
   - [x] 防火墙提示端口变量
- 验证：
  - [x] 真实内核渲染配置 `check` + **真启动**（E2 回归：不得抢 443/udp）
  - [x] 真握手：第二个 sing-box 用 SS 出站连入并 curl 通
  - [x] `tests/verify.sh` 的 SOCKS5 钉死串全部替换为新语义钉死串

## 阶段 3 · 上游/中转（②）

1. `src/00-bootstrap.sh`
   - [x] `relay.conf` 路径常量
2. 新函数（放 `src/40-service.sh`，属受管目录写入域；渲染读取放 `src/30-server-config.sh` 调用点）
   - [x] `load_relay_settings()` / `save_relay_settings()` / `relay_settings_present()`
   - [x] 严格解析 + 校验（`valid_ss_password` / `valid_port` / cipher 白名单 / 地址）
3. `src/30-server-config.sh`
   - [x] 调 `load_relay_settings`，拼 `relay_outbound_suffix`，`final` 随之切换
4. `src/70-management.sh`
   - [x] 新增 `manage_relay()` 子菜单：查看 / 设置（四项输入 + 可达性探测 + 显式确认）/ 清除
   - [x] 提交走 `commit_config`（check → 备份 → 原子替换 → 重启 → 失败回滚）
5. `src/90-main.sh`
   - [x] 主菜单加 `8. 上游/中转`，卸载顺延为 `9`，提示 `[0-9]`
- 验证：
  - [x] 幂等：连续两次设置，`sb.json` 与 `relay.conf` 不变
  - [x] 「改端口 / 改凭据 / 修复」之后 `relay` 出站与 `final` 仍在
  - [x] 清除上游后 `final` 回到 `direct`，`relay.conf` 删除

## 阶段 4 · 测试与文档

- [x] `tests/verify.sh`：版本、常量、段落钉死串、菜单钉死串、缺失钉死串（`socks5-` 不残留）
- [x] `tests/unit.sh`：SS 密钥校验、`server_listen_address`、relay 状态文件读写/校验
- [x] `tests/repair.sh`：夹具改 `ss-sb`；新增「旧 socks 配置修复迁移」用例
- [x] `README.md`：协议表、凭据说明、中转说明、版本号
- [x] `.trellis/spec/{shell,runtime,build,tests}/`：受管资产、版本钉死、测试锚点、模块归属

## 阶段 5 · 发布

- [x] `VERSION` / `src/00-bootstrap.sh:sb_version` / `README.md` / `tests/verify.sh` 四处 → `3.0.0`
- [x] `bash scripts/build.sh && bash tests/verify.sh` 绿
- [x] `bash scripts/check-version-bump.sh`（对着 `origin/main`）通过
- [x] 真实内核复验（阶段 2 的三项）
- [x] 提交计划一次性给出，等用户确认后再 `git push`
- [x] 推送后确认 CI 绿（`checkout@v7` + 版本门禁 + `verify.sh` 三步）

## 复核门（Review Gate）

- 阶段 1 结束：只影响监听地址与 `route.final`，可以单独发布 → 需要用户确认是否继续阶段 2。
- 阶段 2/3 结束：`sing-box check` + 真启动 + 真握手三项证据齐备才继续。
- 阶段 5：推送前把提交计划（含改动文件与提交信息）一次性给用户确认。

---

## 实施记录（与计划的偏差）

1. **`relay.conf` 收敛为三行**（`server=` / `port=` / `password=`）：cipher 固定为 `SS_METHOD`，
   不做成可配项——多一个可配项就多一组「密钥长度随 cipher 变化」的校验分支，当前没有场景需要。
2. **监听地址探测留了一个参数**：`server_listen_address "$IPV6_SYSCTL_ROOT"`。这是唯一「无条件读宿主
   内核状态」的函数，需要能不经 root/不改宿主就覆盖两个分支；`tests/unit.sh` 用夹具目录测三种情形。
3. **修复标记命名为 `REPAIR_SOCKS_INBOUND`**：`tests/verify.sh` 的退役身份守卫大小写不敏感地禁用
   `LEGACY_` / `migration` 字样。
4. **依赖清单新增 `timeout`**（`src/80-lifecycle.sh`）：上游可达性探测需要超时。
5. **测试规模**：`tests/unit.sh` 273 → 279（SS 密钥 11 条 + 监听地址 3 条），
   `tests/repair.sh` 48 → 49（新增 `pre_v3_socks_config_is_migrated`）。
6. **真实内核证据**写入 [research.md](./research.md)：`check` + 真启动 + SS-2022 真握手 + 中转链路端到端。
7. 阶段 5 的「推送前给提交计划」尚未执行，等用户确认；`check-version-bump.sh` 已通过
   （`2.0.1 -> 3.0.0 covers 10 source change(s) against 34f2676`）。
