# 共享证书库：sb 与 acme-nginx 证书互通

## Goal

sb（sing-box/Hysteria2）与 acme-nginx（nginx）在同一台机器上共用同一份域名证书：
**谁先签发谁把证书发布到共享证书库，另一个直接领养、不再申请**；同一时间只有一个
"续期负责人（owner）"，避免两边互相覆盖、重复消耗 Let's Encrypt 配额。两个仓库都是我们自己的，
本次一起改造。大改，分阶段实施。

## Requirements

- R1 共享证书库固定路径 `/etc/cert-store`（root 700），按域名组织，原子切换（generation + current 指针），
  文件 600、目录 700、root 所有。
- R2 库内 `meta.env` 记录 `version/domain/alt/owner/issuer/issued_at/not_after/fingerprint/updated_at/updated_by`；
  读取必须逐字段严格校验（同 sb 现有 domain conf 读取风格）。
- R3 领养判定：证书可解析、未过期、not_before ≤ now、SAN 覆盖请求域名集合、公私钥匹配、
  fingerprint 与 meta 一致 → 消费者直接使用，**不签发**。
- R4 发布：签发方部署自校验成功后，在库锁内原子发布新 generation + 更新 meta（owner=自己）。
- R5 续期归属：只有 `meta.owner` 对应的工具可以续期；非 owner 的 cron/runner 在锁内检查后跳过
  （记录 skip，不报错）。首次发布者成为 owner。
- R6 显式移交：提供"取得签发权"操作（先成功签发/强制续期，再改 meta.owner）；不允许自动抢夺。
- R7 并发安全：签发前在 `/etc/cert-store/.lock` 内再检查一次（double-check），避免两边同时签发。
- R8 sb 侧：新增 `shared` 证书模式（配置指向 store current 路径、无 ACME cron、健康检查/证书管理/
  修复/卸载适配）；作为 owner 时保留现有 ACME 流程并在部署成功后追加发布；cron runner 增加 owner 检查。
- R9 acme-nginx 侧：配置新增 `CERT_SOURCE=own|store`（默认 own）与 `STORE_DIR`；store 模式下
  `issue` 先领养、`renew` 按 owner 跳过/续期并发布、`status` 显示库证书、`uninstall` 不删库；
  nginx 配置指向 store current 路径；新增发布后置钩子（用于重启 sb）。
- R10 向后兼容：不启用 store 时两工具行为与当前版本一致；旧版本不识别 store 也不会被破坏。
- R11 迁移：已有 sb 证书可一键发布进库（owner=sb），已有 acme-nginx 证书同理。
- R12 测试：两仓库单测 + 本地沙箱集成测试（模拟两个工具先后签发/领养/移交，断言只签发一次）；
  文档更新；版本 sb 5.4.0、acme-nginx 0.4.0。

## Non-goals

- 不做跨机证书分发（库仅本机；跨机后续用钩子/rsync 扩展）。
- 不把多个域名合并进一张证书（保持两工具现有的"主域 + 可选泛域"模型）。
- 不自动抢 owner、不自动删除另一家状态。

## Acceptance Criteria

- [ ] 契约文档与实现一致：store 布局、meta 字段、校验矩阵有单测覆盖
- [ ] sb 先签发 → 发布进库 → acme-nginx store 模式领养（nginx 使用库证书，未调用签发）
- [ ] acme-nginx 先签发 → 发布进库 → sb shared 模式领养（sb 使用库证书，未调用签发）
- [ ] 非 owner 的续期 runner 跳过；owner 续期后发布并触发双方 reload
- [ ] 显式移交后，旧 owner 跳过、新 owner 续期
- [ ] 两仓库 `build --check` + `tests/verify.sh` 全绿；沙箱集成测试证明"只签发一次"
- [ ] 不启用 store 时两仓库行为不变（现有测试全绿）
