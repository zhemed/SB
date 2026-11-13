# 证书签发支持华为云 DNS（AK/SK）

## Goal

把 `zhemed/acme-nginx` v0.3.0 里的华为云 DNS-01 支持（AK/SK 自定义 acme.sh dnsapi 插件）融合进 sb：
新增 DNS provider 抽象，让**签发、续期、健康检查、修复、测试门禁**全链路同时支持 Cloudflare 与华为云；
版本号升到 `5.2.0`，`sb.sh` 重新生成。

## Background

- sb 现在的 ACME 证书签发写死 Cloudflare：`src/10-acme.sh` 只认 `dnsapi/dns_cf.sh`，凭据只认
  `SAVED_CF_Token` / `SAVED_CF_Account_ID`，签发命令固定 `--dns dns_cf`，健康检查/修复/续期自检
  也各自硬编码 Cloudflare。
- `acme-nginx` 是从 sb 证书模块拆出去的同源项目（同为 acme.sh 3.1.4、同一 SHA-256、同构的
  reload hook / generation 指针 / 续期 runner），v0.3.0 起支持 `DNS_PROVIDER=huaweicloud`：
  AK/SK 走 SDK-HMAC-SHA256 签名，自写 161 行的 `dns_huaweicloud_aksk.sh` 注入 acme.sh dnsapi，
  凭据由 acme.sh 存进 `account.conf`，续期由 `acme.sh --cron` 自动读取。
- 官方 acme.sh 3.1.4 自带的 `dns_huaweicloud` 只支持 IAM 用户名/密码，acme-nginx 已弃用。
- 用户明确要求：把 acme-nginx 的华为云证书能力融合到 sb。

## Requirements

- **R1 provider 选择**：申请证书时（首次安装、重新申请、证书管理里更换凭据）可选择 DNS 供应商：
  Cloudflare（Account ID + API Token）或华为云（AK/SK + Region）；回车默认 Cloudflare。
- **R2 华为云凭据输入**：AK、SK、Region 三个字段，使用普通可见 `readp`（与 Cloudflare Token 一致），
  不得 `read -s`、不得回显/记录凭据；格式校验：AK `[A-Za-z0-9_-]{16,64}`，
  SK `[A-Za-z0-9+/=_-]{16,128}`，Region `[A-Za-z0-9_-]{2,32}`（如 `cn-north-4`）。
- **R3 自定义 DNS 插件**：华为云模式下把 `dns_huaweicloud_aksk.sh` 原子写入
  `$ACME_HOME/dnsapi/`（700、非符号链接、marker `# sb-huaweicloud-aksk: v1` 恰好 1 行、`bash -n` 通过）；
  已存在且有效时不重写；安装/修复/续期自检能按需补写。
- **R4 签发**：华为云模式使用 `--dns dns_huaweicloud_aksk`，凭据只经环境变量
  `HUAWEICLOUD_ACCESS_KEY_ID` / `HUAWEICLOUD_SECRET_ACCESS_KEY` / `HUAWEICLOUD_REGION` 传入，
  所有成功/失败/取消路径都清空变量；签发后的部署注册、暂存目录、reload hook、恢复点逻辑不变。
- **R5 续期**：`acme.sh --cron` runner 保持不变（provider 无关）；续期自检与健康检查按 provider 校验
  插件与凭据；缺失插件时在安全前提下自愈（华为云补写插件）。
- **R6 兼容**：现有 Cloudflare 用户零行为变化；provider 通过 acme.sh `account.conf` 的
  `SAVED_CF_*` / `SAVED_HUAWEICLOUD_*` 推断，不新增状态文件、不动备份/恢复点白名单。
- **R7 界面/文案**：证书管理菜单、健康检查错误信息、申请菜单不再硬编码 "Cloudflare" 语义；
  选择器与提示明确列出 Cloudflare / 华为云。
- **R8 文档与版本**：README 说明华为云用法（AK/SK、Region、最小权限、凭据存放位置）；
  `VERSION`、`src/00-bootstrap.sh` 的 `sb_version`、README 版本行同步为 `5.2.0`；
  `bash scripts/build.sh` 生成新 `sb.sh`。

## Non-goals

- N1 不引入官方 acme.sh 的 IAM 用户名/密码 `dns_huaweicloud`（安全性与 acme-nginx 的取舍一致，弃用）。
- N2 不支持导入华为云 SCM 里购买的证书（那是另一个功能）。
- N3 不增加 Let's Encrypt staging 开关（保持 sb 现有生产签发行为）。
- N4 不做"不重新签发就切换 provider"（切换 provider 必然重签，沿用现有 replace 流程）。
- N5 不改动证书部署/回滚架构，不改 reload hook 语义（因此不 bump `ACME_RELOAD_IDENTITY`）。

## Constraints

- C1 只改 `src/`、`tests/`、`README.md`、`VERSION`；`sb.sh` 必须由 `scripts/build.sh` 生成，禁止手改。
- C2 遵守 `scripts/build.sh` 契约：模块顺序/marker、重复函数禁止、运行时模块加载禁止、
  ACME reload hook 唯一 `ACMERELOAD` heredoc 且可被 awk 抽取并通过 `bash -n`。
- C3 所有凭据输入可见；`tests/verify.sh` 现有 "Cloudflare Token 必须可见" 检查不得放宽。
- C4 不新增运行时依赖，除确认 `od`（HMAC hex 编码用）存在：`od` 加入
  `src/80-lifecycle.sh` 的 `core_dependencies_ready` 列表。
- C5 新代码必须 `bash -n` 通过，并通过现有 `tests/unit.sh`、`tests/repair.sh`、`tests/replay.sh`。
- C6 不改现有 Cloudflare 函数名/行为（`cloudflare_acme_credentials_present`、
  `valid_cloudflare_account_id` 等保留），只新增 provider 层。
- C7 版本规则：`VERSION`、`sb_version`、README 三处同步，`scripts/check-version-bump.sh` 必须通过。
- C8 不提交 git（由主会话统一提交）。

## Acceptance Criteria

- [ ] 申请流程可选择 Cloudflare / 华为云；华为云输入 AK/SK/Region 并做格式校验，非法输入被拒绝。
- [ ] 华为云签发命令使用 `--dns dns_huaweicloud_aksk`，凭据只经环境变量传递并在所有路径清空；
      成功后走原有 `register_acme_certificate_deployment` 部署注册。
- [ ] `dns_huaweicloud_aksk.sh` 原子写入、700、marker 唯一、`bash -n` 通过；重复调用幂等；
      repair/续期自检可恢复缺失插件。
- [ ] 续期自检/健康检查按 provider 校验插件与凭据；华为云安装同样能建立 cron + runner；
      Cloudflare 现有单测全部保持通过。
- [ ] `bash scripts/build.sh && bash tests/verify.sh` 全绿；`bash scripts/check-version-bump.sh` 通过。
- [ ] `tests/verify.sh` 新增华为云门禁：可见输入提示、插件 marker、无 `HUAWEICLOUD_PASSWORD` 残留。
- [ ] README 记录华为云用法；版本三处为 `5.2.0`；`sb.sh` 与 `src/` 同步。
- [ ] diff 中不含对 Cloudflare 既有行为的非必要修改；无凭据明文出现在任何输出/日志/测试期望文件。
