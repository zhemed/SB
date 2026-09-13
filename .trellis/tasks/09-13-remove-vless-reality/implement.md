# 执行计划

## 原则

- **一次性完成，不允许中间态可提交**。客户端半部与服务端半部互相依赖（见 design §D6.9），
  必须同一个提交落地。
- 顺序按「先删叶、后改根」：先删除无人依赖的函数，再改被依赖的共享逻辑，最后同步测试与文档。
- 每完成一个模块立即 `bash -n`，全部完成后 `scripts/build.sh` + `tests/verify.sh`。

## 步骤

### 阶段 1：纯删除（无依赖风险）

1. `src/20-ports.sh` — 删 `valid_reality_key()`、`valid_short_id()`、`vlport()`；
   删 `chooseport` 的 `reserved` 形参与 57-59 分支（D3）；修 `insport` 的随机分支、
   自定义分支、确认输出、凭据文案。
2. `src/30-server-config.sh` — 删 `render_server_config` 的 vless inbound（14-40），
   注意 JSON 逗号使 hy2 成为 `inbounds[0]`。
3. `src/10-acme.sh` — 删 `:4`、`:279` 的 `ym_vl_re=apple.com` 死赋值。
4. `src/85-repair.sh` — 删 `derive_reality_public_key()`、`repair_reality_public_key()`
   及其**全部三个**调用点（`:623`、`:646`、`:758`）。

### 阶段 2：共享逻辑重接（核心风险）

5. `src/90-main.sh` — 删 `install_singbox` 的 38-62 Reality 块与 local 列表；
   改 73 行放行提示；删菜单 135 行并按方案 (a) 重排编号、改 `[0-9]`→`[0-8]`、
   `case 4|5|6|7|8`→`4|5|6|7`、删 `5) change_vl_sni ;;`。
6. `src/70-management.sh` — 删 `change_vl_sni()`（533-592）；
   修 `change_ports()`（**必须删 601 这环 `||` 链**、选项重排、`chooseport` 调用）；
   重写 `changeuuid()` 为 Hysteria2 单目标；改 `change_credentials` 文案。
7. `src/50-client-output.sh` — `result()` 的 UUID 改读 hy2 password 并删 VLESS 校验；
   删 `resvless()`；`sbshare()` 收敛 9 处清理链并去掉 `vl_reality.txt`；
   sing-box 删 vless outbound + auto 组并修 `proxy` selector 的 `default`；
   Clash 删两个分组与 vless proxy。
8. `src/85-repair.sh` — `load_repair_config_values` 删 vless 必需门（18-24）；
   `render_repair_config` 收敛动态作用域输入；`rebuild_config_in_place` 删 Reality 块；
   `repair_managed_permissions` 去掉 public.key；报告字段与初始化；
   **`try_repair_config_source` 增加「仍含 vless → 需重写」判据（design §D6.6）**。

### 阶段 3：测试同步

9. `tests/verify.sh` — 更新 84-89 的成功提示钉死；62-65 的菜单钉死（`9. 卸载` 等）；
   108 的 `请选择【0-3】`；**改写 120-134 的两个自动分组断言为「客户端配置不存在任何
   urltest/load-balance/url-test 分组」的结构性断言**（不得删除，否则原不变量失去覆盖）。
10. `tests/unit.sh` / `tests/repair.sh` — 清理 Reality 用例与 fixture 变量；
    逐条判断等价覆盖是否已存在于 Hysteria2/SOCKS5，不存在则改写而非删除。
11. `scripts/build.sh` 重新生成 `sb.sh`。

### 阶段 4：文档与规范

12. `README.md` — `:30`、`:33`、`:35`、`:83`、`:84`、`:85`。
13. `.trellis/spec/` — `shell/index.md` 函数总数、`guides/cross-layer-thinking-guide.md`
    的 VLESS 端口示例、`runtime/managed-assets.md` 的产物清单，及其它描述协议集合处。

## 验证

```bash
bash scripts/build.sh
bash scripts/build.sh --check
bash tests/verify.sh
grep -riE 'vless|reality|short_id|public_key' src/    # 只应剩 D6.8 的兼容项
```

新增/改写的断言必须**验证过在改动前会失败**（沿用上一轮做法：临时 `git checkout -- src/`
跑一次，再逐文件哈希比对恢复）。

## 已知无法本地验证

`MOCKCORE` 的 `check` 只做 `jq -e .`，本机无真实内核 → **新配置对 sing-box 1.10.7 的语义
合法性无法在本地证明**。缓解：删除的只是一个完整 inbound 对象，其余字节不变。
需在真机安装一次确认。

## 回滚点

全部改动在 `src/ tests/ README.md .trellis/spec/`。任一步失败：
`git checkout -- src/ tests/ README.md && bash scripts/build.sh`。
