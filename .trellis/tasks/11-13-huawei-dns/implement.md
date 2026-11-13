# 执行计划：证书签发支持华为云 DNS（AK/SK）

> 先读 `implement.jsonl` 列出的 spec，再读 `prd.md`、`design.md`，然后按本清单执行。
> 参考实现已 clone 在 `/root/acme-nginx`（同源项目，acme.sh 3.1.4）；插件正文来源：
> `/root/acme-nginx/src/10-acme.sh` 的 `write_huawei_aksk_plugin` 里 `<<'HWAKSK'` heredoc。

## 0. 硬约束

- 只允许改：`src/*.sh`、`tests/unit.sh`、`tests/repair.sh`、`tests/verify.sh`、`README.md`、`VERSION`。
  `sb.sh` 只能由 `bash scripts/build.sh` 生成，禁止手改。
- 禁止 `git commit` / `git push`；主会话负责提交。
- 保持 Cloudflare 现有行为；新增函数不得与 `sb.sh` 现有函数重名（`scripts/build.sh` 会拒绝）。
- 所有新 shell 代码 `bash -n` 通过；本项目未安装 shellcheck，但代码风格要与现有一致。
- 凭据提示必须可见 `readp`，禁止 `read -s`；任何路径不得回显/打印 AK/SK/Token。
- 插件 heredoc 定界符用 `HWAKSK`，正文顶格，终止行 `HWAKSK` 顶格；不得出现第二行 `ACMERELOAD`。

## 1. `src/10-acme.sh`

### 1.1 provider 基础函数（放在 `valid_cloudflare_account_id` 附近）

```bash
valid_dns_provider(){ [[ ${1-} == cloudflare || ${1-} == huaweicloud ]]; }
dns_provider_plugin_file(){ case ${1-} in cloudflare) echo dns_cf.sh;; huaweicloud) echo dns_huaweicloud_aksk.sh;; *) return 1;; esac; }
dns_provider_label(){ case ${1-} in cloudflare) echo Cloudflare;; huaweicloud) echo 华为云;; *) return 1;; esac; }
```

### 1.2 华为云凭据校验与 provider 推断

- `valid_huaweicloud_access_key_id`：`^[A-Za-z0-9_-]{16,64}$`
- `valid_huaweicloud_secret_access_key`：`^[A-Za-z0-9+/=_-]{16,128}$`
- `valid_huaweicloud_region`：`^[A-Za-z0-9_-]{2,32}$`
- `huaweicloud_acme_credentials_present`：`$ACME_HOME/account.conf` 是常规文件，且
  `^SAVED_HUAWEICLOUD_ACCESS_KEY_ID='[^']+'$`、`^SAVED_HUAWEICLOUD_SECRET_ACCESS_KEY='[^']+'$`、
  `^SAVED_HUAWEICLOUD_REGION='[^']+'$` 各恰好 1 行。
- `acme_dns_provider_detected`：CF/HW 两家各自"凭据完整"判定，恰好一家为真才输出该 provider；
  两家都为真或都不为真 → 失败。**不要**新增状态文件。
- `acme_credentials_present`：`acme_dns_provider_detected >/dev/null`。
- 保留 `cloudflare_acme_credentials_present` 原实现不动（兼容测试）。

### 1.3 华为云 DNS 插件

- `huawei_aksk_plugin_path` → `$ACME_HOME/dnsapi/dns_huaweicloud_aksk.sh`
- `huawei_aksk_plugin_ok`：常规文件、非符号链接、`grep -Fxc -- '# sb-huaweicloud-aksk: v1'` 恰为 1、
  `bash -n` 通过。
- `write_huawei_aksk_plugin`：已有效则直接返回 0；否则要求 `$ACME_HOME/dnsapi` 是真目录，
  `mktemp "$ACME_HOME/.aksk-plugin.XXXXXX"` → heredoc 写入 → `chmod 700` → `mv -fT` 原子替换 →
  再跑 `huawei_aksk_plugin_ok`。
- 插件正文：逐字复制 `/root/acme-nginx/src/10-acme.sh` 中 `HWAKSK` heredoc（161 行），
  **只把第一行 marker 改成** `# sb-huaweicloud-aksk: v1`；其余（`_hwak_*`、`SDK-HMAC-SHA256`、
  `dns.<region>.myhuaweicloud.com`、`_readaccountconf_mutable` / `_saveaccountconf_mutable` / `_err`）
  保持原样。
- `ensure_acme_dns_plugin`：`acme_dns_provider_detected` → CF 要求 `dnsapi/dns_cf.sh` 存在且非符号链接；
  HW 调 `write_huawei_aksk_plugin`。

### 1.4 `install_official_acme`

- 签名改为 `install_official_acme(){ local provider=${1:-cloudflare} ... }`。
- 版本已匹配的早退路径：
  - CF：`dnsapi/dns_cf.sh` 存在 → return 0（保持原样）；否则走完整安装。
  - HW：`write_huawei_aksk_plugin` 成功 → return 0；否则走完整安装（安装后再写插件）。
- tarball 解压校验：CF 保持"必须含 `dnsapi/dns_cf.sh`"；HW 不要求 tarball 内有自定义插件。
- 安装完成校验：CF 保持检查 `dns_cf.sh`；HW 调 `write_huawei_aksk_plugin` 并以其结果为准。
- 调用点：`issue_acme_certificate` 里改成 `install_official_acme "$provider"`。

### 1.5 续期/安全校验改为 provider 感知

- `valid_acme_renewal_identity`：`provider=$(acme_dns_provider_detected)`；`plugin=$(dns_provider_plugin_file "$provider")`；
  原 `-f $ACME_HOME/dnsapi/dns_cf.sh` 换成 `-f $ACME_HOME/dnsapi/$plugin`。
- `current_acme_state_is_safe_to_keep`：`cloudflare_acme_credentials_present` → `acme_credentials_present`。

### 1.6 签发函数

把 `issue_cloudflare_certificate` 改名 `issue_acme_certificate`（同步所有调用点与测试/门禁）：

- 参数与返回码语义完全不变：`(initial_install, retain_backup, reuse_backup)`；
  `readp` 取消 → 3 且不动现场；失败走 `discard_acme_state` + `restore_acme_state_backup`。
- 流程：域名提示（不变）→ provider 提示 → 凭据提示 → 备份/清理 → `install_official_acme "$provider"`
  → `write_acme_reload_hook` → 构造 issue 参数 → 执行 acme.sh → 写 identity → 部署注册 → 校验 → 清理备份。
- provider 提示（`readp` 失败 return 3）：
  `请选择 DNS 供应商（1：Cloudflare 2：华为云，回车默认 Cloudflare）：`
- 凭据提示：
  - CF 保持现有两段提示与校验（Account ID 32 hex、Token 非空；文案原样）。
  - HW 三段提示（`readp` 失败 return 3）：
    - `请输入华为云 Access Key ID：`
    - `请输入华为云 Secret Access Key：`
    - `请输入华为云 Region（如 cn-north-4）：`
    前置黄色说明（至少包含）：
    - `华为云 AK/SK 在控制台「我的凭证」→「访问密钥」创建，建议使用仅授 DNS 云解析权限的子账号`
    - `Region 决定 API 域名 dns.<region>.myhuaweicloud.com，国内建议 cn-north-4`
    - `AK/SK 将由 acme.sh 保存在仅 root 可读的 $ACME_HOME 配置中，用于自动续期`
- `issue_args`：`--dns "${plugin%.sh}"`（plugin 来自 `dns_provider_plugin_file`）。
- 环境变量：
  - CF：`HOME="$SB_DIR" CF_Token="$cf_token" CF_Account_ID="$account_id" CF_Zone_ID='' CF_Key='' CF_Email=''`
  - HW：`HOME="$SB_DIR" HUAWEICLOUD_ACCESS_KEY_ID="$hw_access_key" HUAWEICLOUD_SECRET_ACCESS_KEY="$hw_secret_key" HUAWEICLOUD_REGION="$hw_region"`
- 成功/失败/取消后清空所有凭据变量。
- 提示：失败 `red "${label} DNS 验证或证书签发失败"`；成功 `green "${label} DNS API 证书申请完成"`。

### 1.7 `inscertificate` 文案

- 已有 ACME 证书时：`3：通过 DNS API 重新申请（Cloudflare / 华为云）`
- 无 ACME 证书时：`2：使用官方 acme.sh + DNS API 申请域名证书（Cloudflare / 华为云）`
- 调用改成 `issue_acme_certificate 1`（仍恰好 2 处，供 verify 门禁计数）。

## 2. `src/60-cron.sh`

- `setup_acme_renew_cron`：`cloudflare_acme_credentials_present` → `acme_credentials_present`；
  在其后、`write_acme_reload_hook` 前加 `ensure_acme_dns_plugin || return 1`。
- `ensure_acme_renew_cron`：同样换成 `acme_credentials_present`，保持"不完整→setup 自愈，
  失败→保留 cron 并报错"的语义。
- runner / cron 行 / marker 一律不动。

## 3. `src/70-management.sh`

- `inspect_acme_renewal_health` 按 design §6 改为 provider 感知，错误文案：
  - `acme.sh 组件不完整` / `DNS 凭据缺失或无法识别` / `acme.sh DNS 插件不完整` / `DNS 凭据缺失或格式异常`
- `apply_new_cloudflare_certificate` → `apply_new_acme_certificate`（同步调用点），内部改调
  `issue_acme_certificate`；成功提示保持"新 ACME 证书已切换并启用自动续期"。
- `replace_active_acme_certificate`：改调 `issue_acme_certificate 0 1 1`；
  成功提示 `ACME 证书与 DNS 凭据更换完成`。
- 菜单文案：
  - acme 分支：`4：更换域名、DNS 供应商或凭据`
  - self_signed 有备用证书：`2：申请新的 ACME 证书（Cloudflare / 华为云）`
  - self_signed 无备用证书：`1：申请 ACME 证书（Cloudflare / 华为云）`
  - 未知模式：`2：申请并切换为 ACME 证书（Cloudflare / 华为云）`

## 4. `src/85-repair.sh`

- `acme_maintenance_components_are_trusted`：provider 推断 + `dnsapi/$(dns_provider_plugin_file)` 信任检查，
  替换硬编码 `dns_cf.sh`；推断失败返回 1。
- `repair_acme_certificate_from_storage`：在 `managed_tree_is_trusted "$ACME_HOME"` 成立时先
  `ensure_acme_dns_plugin 2>/dev/null || true`，再走现有维护组件检查；其余失败降级语义不变。

## 5. `src/80-lifecycle.sh`

- `core_dependencies_ready` 的命令列表加入 `od`（插件 HMAC hex 编码需要；acme-nginx 也要求它）。

## 6. `tests/unit.sh` 新增用例（行为断言，名称可自拟）

1. `valid_dns_provider` 接受两家、拒绝其他/空。
2. `dns_provider_plugin_file` 映射与未知失败；`dns_provider_label` 映射。
3. `valid_huaweicloud_*` 三组合法/非法值。
4. `huaweicloud_acme_credentials_present` 与 `acme_credentials_present`：CF 夹具、HW 夹具均成功，
   account.conf 缺失失败。
5. `acme_dns_provider_detected`：CF→cloudflare；HW→huaweicloud；缺失→失败；两家齐全→失败；HW 缺 region→失败。
6. `write_huawei_aksk_plugin`：生成文件 700、marker 1 行、`bash -n` 通过；二次调用内容不变（幂等）；
   `dnsapi` 缺失时失败；手工破坏 marker 后 `huawei_aksk_plugin_ok` 失败、`write_huawei_aksk_plugin` 修复。
7. `install_official_acme` 早退路径：mock `$ACME_BIN` 输出 `v3.1.4`，CF（dns_cf.sh 在）成功；
   HW（插件缺失）成功且写出插件；非法 provider 失败。
8. `setup_acme_renew_cron` 华为云夹具：HW account.conf + 证书/domain conf + cron mock → 成功并写 cron；
   删除插件后再次 setup → 自愈补写并成功；删除 account.conf → 失败（沿用现有断言风格）。
9. 现有 CF 用例全部保留通过；`cloudflare_acme_credentials_present` 行为不变。

## 7. `tests/repair.sh` 新增用例

1. 构造 HW ACME_HOME 夹具（mock acme.sh、`account.conf`、`dnsapi/dns_huaweicloud_aksk.sh`、
   `certs/example.com_ecc/example.com.conf`，700/600 权限）→ `acme_maintenance_components_are_trusted example.com` 成功。
2. 删除插件 → 失败；`ensure_acme_dns_plugin` 后再次成功。
3. 现有 repair 用例全部保留通过。

## 8. `tests/verify.sh` 门禁更新

- 版本 pin：`sb_version="v5.2.0"`、`VERSION` 内容 `5.2.0`、README 版本行 `当前项目版本：`5.2.0``。
- `issue_cloudflare_certificate` 的 awk 提取与 `issue_cloudflare_certificate 1` 计数改为
  `issue_acme_certificate`（计数仍为 2）。
- 新增华为云 pin（`grep -Fq` 子串即可）：
  - `请选择 DNS 供应商`
  - `readp "请输入华为云 Access Key ID：`
  - `readp "请输入华为云 Secret Access Key：`
  - `readp "请输入华为云 Region（如 cn-north-4）：`
  - `dns_huaweicloud_aksk`
  - `SDK-HMAC-SHA256`
- 新增：`[[ $(grep -Fxc -- '# sb-huaweicloud-aksk: v1' "$ROOT_DIR/sb.sh" || true) -eq 1 ]]`；
  禁止 `HUAWEICLOUD_PASSWORD`；保留现有 "Cloudflare Token 必须可见" 检查。

## 9. 文档与版本

- `README.md`：
  - 项目结构表 `src/10-acme.sh` → `证书校验、官方 acme.sh 与 DNS API（Cloudflare / 华为云）`
  - "固定版本与证书"：说明 DNS API 支持 Cloudflare 与华为云（AK/SK，5.2.0 起）；华为云需要
    AK/SK + Region（如 `cn-north-4`），建议只授 DNS 云解析权限的子账号；凭据由 acme.sh 保存在
    仅 root 可读的 `/etc/sb/acme/account.conf`，状态页不回显；证书管理支持更换域名、DNS 供应商或凭据。
  - 版本行 `当前项目版本：`5.2.0``。
- `VERSION` → `5.2.0`；`src/00-bootstrap.sh` → `sb_version="v5.2.0"`。

## 10. 验证命令（必须全部执行并记录结果）

```bash
bash scripts/build.sh
bash scripts/build.sh --check
bash tests/verify.sh
bash scripts/check-version-bump.sh origin/main
git diff --stat
git status --short
```

补充自查：

```bash
grep -rn 'cloudflare_acme_credentials_present\|issue_cloudflare_certificate\|apply_new_cloudflare' src/ tests/ | grep -v '^Binary' || true
grep -c 'dns_huaweicloud_aksk' sb.sh
grep -n 'HUAWEICLOUD_PASSWORD' sb.sh || true
```

预期：`tests/verify.sh` 打印 `verification passed:`；`check-version-bump` 打印
`5.1.3 -> 5.2.0 covers ...`；`git status` 只有预期文件。

## 11. 完成定义

- 上述命令全绿；Cloudflare 既有单测/修复/回放全部通过。
- `git diff` 不含 `sb.sh` 手改（它由 build 生成）、不含凭据明文、不含无关重构。
- 汇报：改动文件、关键决策、验证输出摘要、遗留风险（本机无法实测华为云 API）。
