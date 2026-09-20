# implement.md — 5.0.0 执行记录

起点 `caae0f6`（v4.0.0 已发布，CI 绿）。改动只进 `src/`，`sb.sh` 由构建生成。

## 决定链（本任务的真实历史）

1. 用户报告：新机器上菜单 [8] 子菜单仍列出「5：移除旧的 Shadowsocks-2022 入口」。
2. 第一版方案（按状态隐藏第 5 项）在提问组件里被否决，用户写明「ss 彻底移除就行了，这个是多此一举」。
3. 二选一确认：**连兼容层一起拆**（不是只删菜单项）。
4. 版本号：用户在 4.1.0 / 5.0.0 中选 **5.0.0**（破坏性变更）。

## 改了什么

### src/30-server-config.sh

- 删掉 `preserved_entry_inbound` 分支（不再重发旧入站，也不再补它的 `ss-sb` UDP 规则）。
- 新增重写前警告：`retired_ss_entry_port` 命中时打印两行（不再支持 + 本次重写会移除、会断连）。

### src/50-client-output.sh

- `result()` 不再探测 `ss_enabled/ss_port/ss_password`；删掉 `resss()`。
- `sb_client()` 删掉 ss 出站/selector 成员/clash 条目与四个 emission 插值点：节点顺序变为 SOCKS5 → Hysteria2。
- `sbshare()` 删掉 `ss_tmp` 分支，保留 `remove_saved_ss_link` 清理遗留 `ss.txt`（文案改为"本版本已不再生成"）。

### src/70-management.sh

- 删掉 `preserved_ss_entry_is_enabled` / `preserved_ss_entry_port` / `preserved_ss_candidate_without_inbound` /
  `remove_preserved_ss_entry`；新增只读探针 `retired_ss_entry_port()`。
- `manage_socks_entry()` 回到静态 `请选择【0-4】：`（第 5 项与旧入口提示删除，非法输入提示 0–4）。
- `manage_optional_features()`：旧入口"仍在运行"提示换成"本版本不再支持、重写会移除"的两行警告。
- `change_credentials()` 提示改为"上游中转的 Shadowsocks-2022 密钥在菜单[8]第2项里管理"。

### src/85-repair.sh

- 删掉 `REPAIR_PRESERVED_*`（声明、提取、校验、注入、重建初始化）。
- `config_contains_removed_protocol` 重新把 `ss-sb` 计入 → 带旧入口的配置会被重写，标签为
  「并移除已废弃的 inbound（VLESS / Shadowsocks-2022 入口）」。

### src/20-ports.sh · src/00-bootstrap.sh · VERSION

- 安装结尾提示从"Shadowsocks-2022 入口默认不安装…"改为"TCP 备用入口（SOCKS5，明文）默认不安装…"
  （旧文案在 4.0.0 已经是错的：菜单 [8] 不能启用 SS 入口）。
- 版本四处同步 `5.0.0`（`VERSION`、`sb_version`、README、规范钉死表）。

## 验证

| 证据 | 结果 |
|---|---|
| `bash tests/verify.sh` | exit 0，unit 315 + repair 52，shellcheck 0.10.0 无输出，`sb.sh` = `748f589…` |
| 真实内核（`/tmp/sbverify/v5.sh`） | hy2-only 真启动；启用 SOCKS5 后 `curl --socks5-hostname` 真实握手 OK；**带旧 `ss-sb` 的配置重写后旧入口消失 + 两行警告 + 服务真启动**；干净配置重写不再报警 |
| 真实内核（`/tmp/sbverify/v5-clients.sh`） | 无入口/启用 SOCKS5 两形态真实 `check`；selector 默认 hy2、顺序 socks5→hy2；clash 分组 hysteria2→socks5→DIRECT；产物里无任何 shadowsocks 痕迹 |
| 变异 E/F/G | 塞回 `resss()` → 静态断言红；塞回 `preserved_entry_inbound` → 静态断言红；塞回菜单第 5 项 → unit 279 红 |
| `scripts/check-version-bump.sh` | 认 4.0.0 → 5.0.0（7 处源码变更） |

## 已知欠债

- `.trellis/spec/tests/harness.md` 里的 `file:line` 指针在本轮测试改写后整体漂移；已在文件顶部加
  「指针而非证据」的说明并更新了三份测试文件的行数。其它规范里指向 `10-acme/40-service/60-cron/90-main`
  的引用未受影响（这些模块本轮没动），指向 `70-management.sh` 的两处已按实际行号修正。
