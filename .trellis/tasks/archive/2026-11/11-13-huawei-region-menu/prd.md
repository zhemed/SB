# 华为云 Region 改为常用区域菜单（默认北京）

## Goal

华为云证书申请时的 Region 输入从"自由文本填 Region ID"改为常用区域菜单（默认北京），
减少用户查 `cn-north-4` 这类 ID 的成本；版本 5.2.0 → 5.2.1。

## Requirements

- R1 显示菜单：`1` 北京 `cn-north-4`（默认）、`2` 上海 `cn-east-3`、`3` 广州 `cn-south-1`、
  `4` 香港 `ap-southeast-1`、`5` 手动输入 Region ID。
- R2 直接回车默认 `cn-north-4`；非法选择（非 1-5）重新提示，不静默接受。
- R3 手动输入仍走 `valid_huaweicloud_region` 校验（`^[A-Za-z0-9_-]{2,32}$`），非法重试。
- R4 选择结果写回现有 `hw_region`，后续 `HUAWEICLOUD_REGION` 环境变量传递、凭据清空逻辑不变。
- R5 测试：单测覆盖默认值、数字选项、手动输入、非法重试；`tests/verify.sh` 的区域提示 pin
  更新为菜单文案；Cloudflare 流程不受影响。
- R6 版本三处同步 5.2.1（`VERSION` / `sb_version` / README），README 说明常用区域菜单与默认值。

## Acceptance Criteria

- [ ] 申请华为云证书时出现区域菜单，回车得到 `cn-north-4`
- [ ] 选 `2`/`3`/`4` 分别得到 `cn-east-3` / `cn-south-1` / `ap-southeast-1`
- [ ] 选 `5` 可手动输入合法 Region ID；非法输入重试
- [ ] `bash scripts/build.sh --check`、`bash tests/verify.sh` 全绿
- [ ] 版本三处为 `5.2.1`；Cloudflare 既有行为与测试不变

## Non-goals

- 不自动探测/猜测用户域名所在区域，不改变 DNS API 端点规则（`dns.<region>.myhuaweicloud.com`）。
- 不引入新的状态文件或配置项。
