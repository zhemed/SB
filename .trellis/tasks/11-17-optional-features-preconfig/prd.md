# 待办：菜单[8] 可选功能的“预配置”能力

## Goal

让“没装也能用选项 8”有实际意义：允许用户在**安装前**预配置上游/中转与 SOCKS5 入口意愿，
安装时自动应用并明确提示；同时不破坏现有“改 `sb.json` 必须重启服务验证”的安全模型。

## Background（2026-11-17 调查结论）

- 菜单 4–8 由 `is_installed` 硬门禁（`src/90-main.sh:146-158`），`is_installed` 要求
  `/etc/sb/.sb-managed` + 属于 sb 的服务单元 + `/etc/sb/sing-box` + `/etc/sb/sb.json` 四样齐全
  （`src/40-service.sh:408-410`）。该门禁自 v1.6.0 起未变，不是回归。
- 选项 8 的每个写操作都要 `service_must_be_active` + `commit_config`
  （`sing-box check` → 重启服务 → 验证 active，失败回滚，`src/40-service.sh:484-534`），
  因此**完全没装时无法落地任何修改**——这是设计使然，不是 bug。
- 已完成（v5.8.3，方案 A，纯 UX）：未安装时菜单 3–8 标注“（需先安装）”，
  选项 3/4–8 提示“请先用菜单[1]安装，或用菜单[2]修复”，选项 8 单独说明其依赖。
- 仍待办（方案 B）：预配置能力。当前安装流程不询问 SOCKS5/上游，装完才能进选项 8 配置。

## Requirements

- R1 预配置上游/中转：未安装时允许写 `/etc/sb/relay.conf`（root 600，三行
  `server=` / `port=` / `password=`，复用 `relay_server_is_valid` / `valid_port` /
  `valid_socks_password` 校验）；安装时渲染自动注入（`src/30-server-config.sh:22-28` 已支持
  “存在则注入 relay 出站并把 `route.final` 指向 relay”），装完即生效。
- R2 安装流程询问：安装时增加“是否启用 SOCKS5 入口”（可回车跳过）；启用则生成端口与密码，
  通过 `socks_entry_enabled` / `port_socks5` / `socks_password` 渲染进首次配置，
  不再需要装完再进选项 8。
- R3 未安装时的选项 8 入口：未安装但 `/etc/sb` 存在时，选项 8 可进入“预配置”模式——
  只允许写 `relay.conf` 与记录 SOCKS5 意愿，界面明确标注“安装后生效”；
  不得修改 `sb.json`、不得声称“已启用”、不得伪造状态。
- R4 安全边界：预配置只写 `relay.conf`（600）与意愿标记；不改 `commit_config` 的
  “写 `sb.json` 必须服务重启验证”模型；不新增无服务状态下改 `sb.json` 的路径。
- R5 一致性：安装/修复读取预配置并应用，安装报告明确显示“已应用预配置（上游/SOCKS5）”；
  预配置与选项 8 正常配置写同一份状态，避免两套真相。
- R6 测试：单测覆盖 relay.conf 预配置校验/安装注入/SOCKS5 预配置落地/非法值拒绝；
  `tests/verify.sh` 增加相应 pin；不引入新的 `-F/-E` 混用。

## Non-goals

- 不接管/兼容非 sb 安装的外部 sing-box 实例。
- 不做“服务未运行时直接改 `sb.json` 并跳过重启验证”的离线写配置模式。
- 不改变 `is_installed` 判定与 4–8 的实际执行路径（仅新增“未安装时的预配置”分支）。

## Acceptance Criteria

- [ ] 全新机器（未安装）：选项 8 可预配置上游（写 `relay.conf`）并记录 SOCKS5 意愿，界面提示“安装后生效”。
- [ ] 预配置后执行菜单[1]安装：首次渲染的 `sb.json` 含 relay 出站（`route.final=relay`）与
      已启用的 SOCKS5 入站；服务 active；安装报告显示已应用预配置。
- [ ] 未做预配置时，安装与选项 8 行为与当前版本完全一致（向后兼容）。
- [ ] 非法预配置（端口/密码/地址不合法、文件权限异常）被拒绝且不写入半成品。
- [ ] 门禁全绿（`build --check`、`tests/verify.sh`、`check-version-bump`），版本四处同步。

## Notes

- 与选项 8 现状相关的位置：菜单门禁 `src/90-main.sh:146-158`；状态展示与写操作
  `src/70-management.sh:1110-1454`；`commit_config` `src/40-service.sh:484-534`；
  relay 注入 `src/30-server-config.sh:22-28`。
- 优先级 P3：属于体验增强，不阻塞现有功能；等有真实“安装前就要配上游”的需求再做。
