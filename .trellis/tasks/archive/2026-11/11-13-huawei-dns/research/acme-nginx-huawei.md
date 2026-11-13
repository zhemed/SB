# 研究：acme-nginx 的华为云 DNS-01 实现

来源：<https://github.com/zhemed/acme-nginx>（本地 clone：`/root/acme-nginx`，v0.3.0，acme.sh 3.1.4）。

## 1. 它做了什么

- 从 sb 项目提取证书模块，CLI + 配置文件（`/etc/acme-nginx.conf`），支持
  `DNS_PROVIDER=cloudflare|huaweicloud`。
- 华为云走 **AK/SK**（v0.3.0 起只支持 AK/SK，v0.2.0 的 IAM 用户名/密码不再兼容）。
- 因为官方 acme.sh 3.1.4 自带的 `dns_huaweicloud` 只支持 IAM 用户名/密码
  （`HUAWEICLOUD_Username/Password/DomainName`，见
  <https://github.com/acmesh-official/acme.sh/blob/3.1.4/dnsapi/dns_huaweicloud.sh>），
  acme-nginx 自写了 `dns_huaweicloud_aksk.sh` 插件并注入 acme.sh 的 `dnsapi/`。

## 2. 关键代码位置（acme-nginx v0.3.0）

| 内容 | 位置 |
|---|---|
| 配置模板（含华为云三项） | `src/00-bootstrap.sh` `write_config_template` |
| 配置解析/校验 | `src/00-bootstrap.sh` `load_config` |
| 华为云凭据格式 | AK `^[A-Za-z0-9_-]{16,64}$`；SK `^[A-Za-z0-9+/=_-]{16,128}$`；Region `^[A-Za-z0-9_-]{2,32}$` |
| 凭据存在性判定 | `src/10-acme.sh` `dns_provider_credentials_present`（account.conf 的 `SAVED_HUAWEICLOUD_*`） |
| 插件写入/校验 | `src/10-acme.sh` `write_huawei_aksk_plugin` / `huawei_aksk_plugin_ok`（marker `# acme-nginx-huaweicloud-aksk: v1`，700，`bash -n`） |
| 插件正文 | `src/10-acme.sh` `<<'HWAKSK'` heredoc（161 行） |
| 安装 acme.sh 时按 provider 写插件 | `src/10-acme.sh` `install_official_acme` |
| 签发 | `src/10-acme.sh` `issue_certificate`（`--dns "${plugin%.sh}"` + provider 环境变量） |
| 续期自检 | `src/10-acme.sh` `valid_acme_renewal_identity`（按 provider 查插件） |
| 健康/状态 | `src/10-acme.sh` `dns_provider_credentials_present` 等 |

## 3. 插件逻辑（`dns_huaweicloud_aksk.sh`）

- 签名：华为云 SDK-HMAC-SHA256。`Authorization: SDK-HMAC-SHA256 Access=<AK>, SignedHeaders=content-type;host;x-sdk-date, Signature=<hex>`。
- 端点：`https://dns.<region>.myhuaweicloud.com`（region 必填，决定域名）。
- 请求头：`Content-Type: application/json`、`Host: <endpoint>`、`X-Sdk-Date: <UTC ISO8601>`。
- 流程：
  1. `_hwak_find_zone`：从 `_acme-challenge.<domain>` 逐级去掉最左标签，`GET /v2/zones?type=public&name=<zone>`，
     取 `name == <zone>.` 的 id。
  2. `_hwak_find_recordset`：`GET /v2/recordsets?type=TXT&name=<fulldomain>`。
  3. 无记录 → `POST /v2/zones/<zone>/recordsets` 建 TXT（ttl 300）；
     有记录 → `PUT /v2/zones/<zone>/recordsets/<id>` 追加 TXT（去重）。
  4. `_rm`：删除/更新记录（无记录直接成功）。
- 凭据：`_readaccountconf_mutable` 读取，`_saveaccountconf_mutable` 写回 `SAVED_HUAWEICLOUD_ACCESS_KEY_ID` /
  `SAVED_HUAWEICLOUD_SECRET_ACCESS_KEY` / `SAVED_HUAWEICLOUD_REGION`，续期时 `acme.sh --cron` 自动读取。
- 依赖：`curl`、`openssl`、`jq`、`od`、`awk/sed/sort/tr/mktemp` 等（`od` 用于 HMAC hex 编码；
  sb 现有依赖清单没有 `od`，需要补）。

## 4. 与 sb 的差异（移植时要处理的）

- acme-nginx 是 CLI + 配置文件；sb 是交互菜单 + 备份/恢复点 + 修复体系 → 只移植 provider 层，
  不复制配置文件逻辑。
- acme-nginx 用 `DNS_PROVIDER` 配置项；sb 不新增状态文件，改为从 `account.conf` 推断 provider
  （见 `design.md` §2）。
- acme-nginx 的插件 marker 要改成 sb 自己的 `# sb-huaweicloud-aksk: v1`，便于 repair/门禁校验。
- acme-nginx 有 `STAGING` 开关；sb 不引入（Non-goal N3）。
- acme-nginx 的 reload hook 是 `reload nginx`；sb 的 hook 是 sb 服务重启 + generation 指针，保持不动。

## 5. 参考文档

- acme-nginx README（华为云配置与权限建议）：<https://github.com/zhemed/acme-nginx/blob/main/README.md>
- acme-nginx DEPLOY.md（AK/SK 获取路径、排错）：<https://github.com/zhemed/acme-nginx/blob/main/DEPLOY.md>
