# 设计：证书签发支持华为云 DNS（AK/SK）

## 1. 总体思路

sb 的证书子系统已经与 provider 无关的部分（安装固定版本 acme.sh、原子部署、reload hook、续期 runner、
恢复点）保持不动；本次只把"DNS 供应商"抽成一层，并移植 acme-nginx 的华为云 AK/SK 插件。

```
issue_acme_certificate
  ├─ 域名输入/规范化（不变）
  ├─ provider 选择：cloudflare | huaweicloud
  ├─ 凭据输入/校验（CF: AccountID+Token；HW: AK+SK+Region）
  ├─ begin_acme_state_backup / reset_acme_state（不变）
  ├─ install_official_acme <provider>   ← 新增参数；HW 安装后写插件
  ├─ write_acme_reload_hook（不变）
  ├─ acme.sh --issue --dns <plugin> ... ← provider 决定插件名与环境变量
  └─ register_acme_certificate_deployment（不变）

续期：acme.sh --cron（不变，凭据由 account.conf 提供）
自检/健康/修复：acme_dns_provider_detected → 校验对应插件 + 凭据
```

## 2. provider 推断（不新增状态文件）

acme.sh 自己会把用过的 DNS 凭据写进 `$ACME_HOME/account.conf`：

- Cloudflare：`SAVED_CF_Token='...'` + `SAVED_CF_Account_ID='...'`
- 华为云：`SAVED_HUAWEICLOUD_ACCESS_KEY_ID='...'` + `SAVED_HUAWEICLOUD_SECRET_ACCESS_KEY='...'`
  + `SAVED_HUAWEICLOUD_REGION='...'`（插件通过 `_saveaccountconf_mutable` 写入）

新增 `acme_dns_provider_detected`：恰好命中一家且凭据完整时输出 `cloudflare` / `huaweicloud`；
两家同时命中、部分命中或都没有则失败。理由：

- 每次签发前 `reset_acme_state` 会整体删除 `$ACME_HOME`，provider 切换不会残留旧凭据；
- 不新增状态文件 → 恢复点白名单（`validate_acme_state_backup` 的 `state_names`）、
  备份/恢复/清理逻辑、单元测试夹具都不用扩大；
- 与现有 `cloudflare_acme_credentials_present` 的判定方式一致（数 account.conf 行数）。

## 3. 插件生命周期

```
install_official_acme <provider>
  ├─ cloudflare：保持原逻辑（tarball 必须含 dnsapi/dns_cf.sh）
  └─ huaweicloud：安装完成后调用 write_huawei_aksk_plugin
write_huawei_aksk_plugin
  ├─ huawei_aksk_plugin_ok() ? return 0        # 幂等
  ├─ 要求 $ACME_HOME/dnsapi 是真目录
  ├─ mktemp 写入 → chmod 700 → mv -fT 原子替换
  └─ huawei_aksk_plugin_ok()                    # 校验失败即失败
huawei_aksk_plugin_ok
  ├─ 常规文件、非符号链接
  ├─ marker `# sb-huaweicloud-aksk: v1` 恰好 1 行
  └─ bash -n 通过
ensure_acme_dns_plugin
  ├─ acme_dns_provider_detected
  ├─ cloudflare：dns_cf.sh 必须存在（tarball 自带）
  └─ huaweicloud：write_huawei_aksk_plugin（缺失/被改坏时补写）
```

调用点：

- `install_official_acme huaweicloud`（签发）
- `setup_acme_renew_cron`（凭据校验后，写 runner 前）
- `repair_acme_certificate_from_storage`（ACME_HOME 信任校验通过后尝试补写）

插件内容逐字移植自 `acme-nginx` v0.3.0（`/root/acme-nginx/src/10-acme.sh` 的
`write_huawei_aksk_plugin` heredoc，161 行），仅改 marker；保留 `_hwak_*` 函数、
`SDK-HMAC-SHA256` 签名、`dns.<region>.myhuaweicloud.com` v2 API、`_readaccountconf_mutable` /
`_saveaccountconf_mutable` / `_err` 的用法。

## 4. 函数契约（新增/变更）

| 函数 | 契约 |
|---|---|
| `valid_dns_provider <p>` | `cloudflare`/`huaweicloud` 为真 |
| `dns_provider_plugin_file <p>` | 输出 `dns_cf.sh` / `dns_huaweicloud_aksk.sh`，未知失败 |
| `dns_provider_label <p>` | 输出 `Cloudflare` / `华为云` |
| `valid_huaweicloud_access_key_id <v>` | 正则校验 |
| `valid_huaweicloud_secret_access_key <v>` | 正则校验 |
| `valid_huaweicloud_region <v>` | 正则校验 |
| `huaweicloud_acme_credentials_present` | account.conf 中三项 SAVED_HUAWEICLOUD_* 各 1 行 |
| `acme_dns_provider_detected` | 输出 provider；歧义/缺失失败 |
| `acme_credentials_present` | 推断成功即凭据完整 |
| `huawei_aksk_plugin_path` | 输出插件绝对路径 |
| `huawei_aksk_plugin_ok` | 见 §3 |
| `write_huawei_aksk_plugin` | 见 §3，幂等 |
| `ensure_acme_dns_plugin` | 按 provider 保证插件可用（HW 可补写） |
| `install_official_acme [provider]` | 默认 cloudflare，保持旧行为；HW 安装后写插件 |
| `valid_acme_renewal_identity` | 改为 provider 感知（插件按 provider 查） |
| `current_acme_state_is_safe_to_keep` | 用 `acme_credentials_present` |
| `issue_acme_certificate`（原 `issue_cloudflare_certificate`） | 参数/返回码不变；新增 provider 与 HW 凭据输入 |
| `apply_new_acme_certificate`（原 `apply_new_cloudflare_certificate`） | 改名，行为不变 |

## 5. 签发流程细节

1. 域名提示（不变，`readp` 失败返回 3）。
2. provider 提示：`请选择 DNS 供应商（1：Cloudflare 2：华为云，回车默认 Cloudflare）：`，
   `readp` 失败返回 3。
3. 凭据提示：
   - Cloudflare：Account ID（32 hex）→ API Token（可见、非空），提示文案保持原文，门禁仍钉住。
   - 华为云：AK → SK → Region，各带一行黄色说明（AK/SK 创建位置、Region 决定 API 域名、
     凭据由 acme.sh 保存在仅 root 可读的 `$ACME_HOME` 配置中）。
4. 备份/清理/安装/部署逻辑与返回码语义完全沿用现有实现（取消=3 且不动现场；失败走
   `discard_acme_state` + `restore_acme_state_backup`）。
5. `issue_args`：`--home ... --config-home ... --issue --server letsencrypt --dns <plugin> --keylength ec-256 -d <primary> [-d <wildcard>]`；
   `plugin` 来自 `dns_provider_plugin_file`，去掉 `.sh` 后缀。
6. 环境变量：
   - CF：`CF_Token`、`CF_Account_ID`，并继续 `CF_Zone_ID='' CF_Key='' CF_Email=''` 屏蔽旁路凭据。
   - HW：`HUAWEICLOUD_ACCESS_KEY_ID`、`HUAWEICLOUD_SECRET_ACCESS_KEY`、`HUAWEICLOUD_REGION`。
7. 成功/失败后立即清空凭据变量（含 `cf_token`/`account_id`/`hw_*`）。
8. 成功提示：`<label> DNS API 证书申请完成`。

## 6. 续期 / 健康 / 修复

- `setup_acme_renew_cron`：`config_uses_acme_certificate` → 取/恢复 identity →
  `acme_credentials_present` → `ensure_acme_dns_plugin` → 写 hook → 迁移部署 → 写 runner → 写 cron。
- `ensure_acme_renew_cron`：把 `cloudflare_acme_credentials_present` 换成 `acme_credentials_present`；
  其余保持"不完整就调 setup 自愈，失败则保留 cron 并报错"。
- `inspect_acme_renewal_health`：
  1. acme.sh/身份文件缺失 → "acme.sh 组件不完整"
  2. `acme_dns_provider_detected` 失败 → "DNS 凭据缺失或无法识别"
  3. 对应插件文件缺失 → "acme.sh DNS 插件不完整"
  4. `acme_credentials_present` 失败 → "DNS 凭据缺失或格式异常"
  5. 后续证书/布局/部署/cron 检查不变。
- `acme_maintenance_components_are_trusted`：provider 感知的插件路径（替代硬编码 `dns_cf.sh`）。
- `repair_acme_certificate_from_storage`：在 ACME_HOME 整体可信时先 `ensure_acme_dns_plugin`，
  再跑维护组件信任检查；失败仍按现有逻辑降级为"证书有效但续期组件待修复"。

## 7. 兼容性 / 失败模式

- 纯 Cloudflare 主机：provider 推断为 cloudflare，所有路径与 5.1.3 等价（函数名变化只影响内部调用与门禁）。
- 华为云主机：签发/续期/修复与 Cloudflare 同构；唯一新增的外部依赖是 `od`（HMAC hex 编码）。
- 失败模式：
  - account.conf 同时含两家凭据 → 拒绝推断（不会猜），健康检查报错，提示人工处理。
  - 插件被删/被改 → `huawei_aksk_plugin_ok` 失败；续期 setup/repair 可补写；补写失败则报错。
  - 插件写入不是原子/权限不对 → 校验失败即失败，不影响已有证书。
- 回滚：本次不改证书部署架构，回滚即 `git revert`；已签发的华为云证书仍可继续用旧版 sb 的
  `acme.sh --cron` 续期（runner 不变，插件文件留在原处）。

## 8. 安全

- AK/SK 仅经环境变量进入 acme.sh，并由 acme.sh 写入 `account.conf`（`$ACME_HOME` 700、文件 600）；
  sb 自身不落盘、不回显、不写日志。
- 插件是 root 可写的受管文件；repair 的 `managed_tree_is_trusted` + `huawei_aksk_plugin_ok`
  （marker + `bash -n`）双重约束。
- 建议文档要求：使用只授 DNS 云解析权限的子账号 AK/SK。
