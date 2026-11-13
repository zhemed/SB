# 证书部署后置钩子：与 nginx 等第二个服务共用同一张证书

## Goal

sb 只签发一次证书，同机的第二个消费者（nginx）通过 sb 的稳定证书路径直接使用；
证书切换成功后由 sb 的 reload hook 执行一个可选后置钩子（例如 `nginx -t && systemctl reload nginx`），
让 nginx 自动加载新证书。版本 5.2.1 → 5.3.0。

## Requirements

- R1 reload hook 支持可选后置钩子 `/etc/sb/acme_post_reload.sh`，仅在以下条件全部满足时执行：
  常规文件、非符号链接、可执行、root 所有、组/他人不可写；否则忽略并告警。
- R2 只在**证书成功切换**后执行：初始安装、配置未引用 ACME 证书、无服务单元、服务未运行、
  重启成功等成功路径都要执行；回滚/失败路径不执行。
- R3 后置钩子失败只向 stderr 告警：不回滚证书部署、不改变 reload hook 的退出码（续期仍视为成功）。
- R4 hook identity 升到 `# sb-acme-reload-v3`；`acme_reload_hook_is_current` 与
  `tests/verify.sh` 的锚点/行数断言同步更新。
- R5 README 增加"与 nginx 共用证书"文档：nginx 直接引用 `/etc/sb/acme-cert.pem` 与
  `/etc/sb/acme-private.key`；后置钩子示例；权限要求；同机 UDP/TCP 443 可共存；
  泛域名 `*.example.com` 会同时包含 apex。
- R6 版本三处同步 5.3.0；单测覆盖钩子执行、钩子失败、不可信钩子（非可执行/符号链接/组可写）；
  `bash scripts/build.sh --check`、`bash tests/verify.sh` 全绿。

## Non-goals

- 不执行任何真实证书申请（用户稍后自行申请）。
- 不自动探测 nginx、不修改 nginx 配置、不做跨机证书分发。
- 不改 acme.sh 调用方式、不改证书原子部署/回滚逻辑。

## Acceptance Criteria

- [ ] 存在且可信的 `/etc/sb/acme_post_reload.sh` 在证书成功切换后被执行一次
- [ ] 钩子失败时证书部署保持成功、hook 退出码仍为 0，并输出告警
- [ ] 非可执行/符号链接/组可写的钩子被忽略（不执行）
- [ ] 回滚路径不执行后置钩子
- [ ] hook identity v3、锚点与门禁同步；`tests/verify.sh` 全绿
- [ ] README 有 nginx 共用证书与后置钩子示例；版本三处为 5.3.0
