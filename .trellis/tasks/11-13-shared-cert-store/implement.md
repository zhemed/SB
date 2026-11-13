# 执行计划：共享证书库（分阶段，两仓库）

> 两个仓库：`/root/SB`（Trellis 管理）与 `/root/acme-nginx`（非 Trellis，按其自身 build/verify 约定）。
> 每个阶段结束都要各自 `bash scripts/build.sh --check && bash tests/verify.sh` 全绿后再进入下一阶段。
> 本任务较大，建议按阶段提交：契约/工具层 → sb 侧 → acme-nginx 侧 → 联调文档发布。

## 阶段 0：契约与夹具（两仓库共享同一份文档）

- [ ] 把 `design.md` 的目录/meta/校验矩阵作为唯一契约；在 sb 与 acme-nginx 的测试里各写一套
      契约夹具（合法/非法 meta、合法/过期/不覆盖的证书、key 不匹配、符号链接、权限错误）。
- [ ] 明确证书集合表示：`domain`（apex）+ `alt`（逗号分隔，含 `*.apex` 可选）。
- [ ] 定义 store 锁协议：`/etc/cert-store/.lock`，`flock -w 30`；锁内做 double-check。
- 验收：两仓库无产品代码改动，只有测试夹具/文档；现有门禁保持全绿。

## 阶段 1：sb 侧 store 工具层（不接 UI）

文件：`src/00-bootstrap.sh`、`src/10-acme.sh`（新增 store 相关函数，命名统一 `cert_store_*`）。

- [ ] 常量：`CERT_STORE="/etc/cert-store"`、`CERT_STORE_LOCK`、`CERT_STORE_VERSION=1`。
- [ ] 读取/校验：`cert_store_meta_path`、`cert_store_read_meta`（逐键白名单 + 恰好一次）、
      `cert_store_validate_domain_dir`（权限/属主/current 指针/generation 文件）、
      `cert_store_certificate_state`（解析证书、SAN、有效期、key 匹配、指纹比对）。
- [ ] 领养判定：`cert_store_can_adopt <domain> [wildcard]`（校验矩阵全部通过才 0）。
- [ ] 发布：`cert_store_publish <domain> <cert> <key> <alt>`（锁内 mktemp→写→mv→切 current→写 meta→清理旧代）。
- [ ] owner：`cert_store_owner <domain>`、`cert_store_require_owner <domain> <self>`、
      `cert_store_take_ownership` 的底层原语（写 meta owner）。
- [ ] 单测：契约矩阵、发布原子性（模拟 mv 失败/中断不破坏 current）、并发锁、指纹/SAN/key 校验。
- 验收：`tests/unit.sh` 新增用例全过；`tests/verify.sh` 绿；不启用时行为不变。

## 阶段 2：sb 侧 shared 证书模式 + owner 感知

- [ ] 证书模式推断：`config_uses_shared_certificate`（配置路径位于 store 下）；`CURRENT_CERT_MODE` 增加 `shared`。
- [ ] 安装/证书管理：
  - 证书管理菜单增加"使用共享证书库中的证书（领养）"与"发布当前证书到共享证书库"；
  - 安装证书选择里检测库中可领养证书，默认建议领养；领养后 `render_server_config` 指向 store 路径。
- [ ] owner 流程：sb 作为 owner 走现有 ACME 流程，`register_acme_certificate_deployment` 成功后调用
      `cert_store_publish`；`valid_acme_renewal_identity` 不受影响。
- [ ] 续期 runner：生成脚本里增加"锁内检查 owner==sb，否则写 skipped 并退出 0"；
      `load_acme_renew_state` 增加 `last_result=skipped`（或 `unchanged` + 标记，二选一并更新健康检查/门禁）。
- [ ] 健康检查/修复/卸载：shared 模式显示与校验库证书；库缺失/损坏回退自签并提示；卸载不删 store。
- [ ] 门禁：verify.sh 增加 shared 模式/owner runner/发布钩子的静态 pin；README 增加共享证书库章节。
- [ ] 版本 5.4.0（三处同步）。
- 验收：单测 + verify 绿；模拟 acme-nginx 发布（测试夹具）→ sb 领养且零 acme.sh 调用。

## 阶段 3：acme-nginx 侧 store 模式

文件：`src/00-bootstrap.sh`、`src/10-acme.sh`、`src/60-cron.sh`、`src/90-main.sh`、`nginx/*`、`README.md`。

- [ ] 配置：`CERT_SOURCE=own|store`（默认 own）、`STORE_DIR=/etc/cert-store`；`load_config` 校验。
- [ ] store 工具层：按契约实现读取/校验/领养/发布（与 sb 独立实现，契约一致）。
- [ ] `issue`：锁内领养检查 → 可领养则配置 nginx 指向 store、reload、退出 0（不签发）；
      不可领养且允许 → 签发 → publish → reload nginx → 执行后置钩子（重启 sb）。
- [ ] `renew`：owner 检查（非 owner 只在库证书变化时 reload nginx）；owner 续期后 publish + reload + 后置钩子。
- [ ] 后置钩子：`/etc/acme-nginx/post_reload.sh`（root 700、信任校验、失败只告警）。
- [ ] `status` 显示库证书/owner/指纹；`uninstall` 不删 store；CLI 增加 `take-ownership`（或 `issue --take-ownership`）。
- [ ] 测试：config 解析、领养/发布/owner gating、renew runner、后置钩子；门禁 pin。
- [ ] 版本 0.4.0；README/DEPLOY 文档更新。
- 验收：`bash scripts/build.sh --check && bash tests/verify.sh` 绿；模拟 sb 发布 → acme-nginx 领养零签发。

## 阶段 4：联调、文档、发布

- [ ] 两仓库各自 `build --check` + `tests/verify.sh` + 版本 bump 检查。
- [ ] 49.9 真机联调（需用户临时授权）：sb 已签发 → 发布进库 → 部署 nginx 领养 → 手动触发一次续期
      验证 owner 发布 + 双方 reload；再演练一次 owner 移交。
- [ ] README（两仓库）写清：启用方式、目录契约、owner/移交、迁移、排错、卸载影响。
- [ ] 提交：sb 仓库走 Trellis（commit + archive + journal）；acme-nginx 按自身习惯提交；是否 push 由用户确认。

## 回滚点

- 阶段 1 只加函数与测试：回滚 = revert 该提交。
- 阶段 2/3 都保持默认不启用 store；出问题把 `CERT_SOURCE`/shared 模式切回原模式即可，store 目录可保留。
- 发布进库是新增副本，不改变两工具原有 live 路径与回滚逻辑。
