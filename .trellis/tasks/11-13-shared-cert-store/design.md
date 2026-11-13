# 设计：共享证书库（/etc/cert-store）

## 1. 总体模型

```
         ┌──────────── sb（owner 或 consumer）────────────┐
         │  ACME 签发/续期（owner）  或  shared 模式（consumer）│
         └───────────────┬───────────────────────────────┘
                         │ publish（owner）
                 ┌───────▼────────┐
                 │ /etc/cert-store │  原子 generation + current 指针
                 │  <apex>/        │  meta.env 记录 owner / 指纹 / 时间
                 └───────┬────────┘
                         │ adopt（consumer）
         ┌───────────────▼───────────────────────────────┐
         │  acme-nginx（owner 或 consumer）→ nginx 使用库证书 │
         └───────────────────────────────────────────────┘
```

- **owner**：唯一允许签发/续期的工具。首次发布者成为 owner，写进 `meta.env`。
- **consumer**：只领养（把服务配置指向 store 的 current 路径）并 reload 自己，绝不签发。
- 每次签发前都在 store 锁内"再检查一次"（double-check），避免两边同时签发。

## 2. 目录与文件契约

`STORE_ROOT=/etc/cert-store`（root 700，非符号链接）

```
/etc/cert-store/
├── .lock                       # flock：签发/发布/领养/移交互斥
└── <apex>/                     # 例：zrco.cc（小写、合法 hostname）
    ├── current -> generations/gen.<[A-Za-z0-9]+>
    ├── generations/
    │   └── gen.<id>/
    │       ├── fullchain.pem   # 600，常规文件
    │       └── private.key     # 600，常规文件
    └── meta.env                # 600，每键恰好 1 行
```

`meta.env`（`version=1`）：

| 字段 | 约束 |
|---|---|
| `version` | `1` |
| `domain` | 合法 hostname，且等于目录名 |
| `alt` | 逗号分隔的额外 SAN（如 `*.zrco.cc`），可空 |
| `owner` | `sb` / `acme-nginx` / `none` |
| `issuer` | 如 `letsencrypt` |
| `issued_at` / `not_after` / `updated_at` | 1–12 位 epoch |
| `fingerprint` | fullchain 的 sha256，64 hex |
| `updated_by` | `sb` / `acme-nginx` |

校验矩阵（任一不满足即视为不可用）：
目录/文件权限与属主正确；`current` 只指向 `generations/gen.<alnum>`；cert/key 为常规文件且非符号链接；
meta 每个键恰好一行、无未知键；`domain` 与目录名一致；时间戳/指纹格式正确；`fingerprint(fullchain)` 与
meta 一致；证书可解析、未过期、`not_before ≤ now`、SAN 覆盖请求域名集合、公钥与 private.key 匹配。

## 3. 领养（adopt）

输入：请求域名集合（apex + 可选 wildcard，如 `zrco.cc` + `*.zrco.cc`）。

1. 在 store 锁内读取 `<apex>/meta.env` 与证书，跑完整校验矩阵。
2. `meta.domain == apex` 且 `meta.alt` 与请求 wildcard 一致；SAN 覆盖全部请求名。
3. 通过 → 消费者把服务配置指向 `<apex>/current/fullchain.pem` 与 `.../private.key`，reload 自己；
   **不调用 acme.sh**。
4. 不通过且 `meta.owner` 是另一个工具 → 报错（提示让 owner 续期或显式移交），**不允许擅自签发**。
5. 不通过且库为空/owner=none → 允许签发（成为 owner）。

## 4. 发布（publish）

签发方成功部署且自校验通过后，在 store 锁内：

1. 创建 `generations/gen.$(mktemp 后缀)`（700）→ 写 `fullchain.pem`/`private.key`（600）→ `chmod`；
2. `mv` 成正式 generation → 原子切换 `current`（`ln -s` + `mv -Tf`）；
3. 写 `meta.env`（临时文件 → `mv -Tf`，600）：owner=自己、issuer、issued_at/not_after、fingerprint、updated_at/updated_by；
4. 清理非 current 的旧 generation（失败容忍）；
5. 返回后由工具自己的后置钩子 reload 另一个消费者（sb → reload nginx；acme-nginx → restart sb）。

## 5. 续期归属与移交

- 每个工具的续期 runner 在调用 `acme.sh --cron` 前，在 store 锁内检查 `meta.owner`：
  - 等于自己 → 正常续期；续期成功后 publish。
  - 不等于自己 → 记录 `skipped:not-owner` 并退出 0（不报错、不改状态）。
- 移交（显式）：`take-ownership` 操作 = 在锁内确认要接管 → 用本工具签发/强制续期 → 成功后
  publish（meta.owner=自己）。旧 owner 下次续期自动跳过。
- 不允许自动抢夺；owner 工具被卸载时，库证书仍可用，但状态页/健康检查提示"无 owner 续期"。

## 6. sb 侧改造

- 新证书模式 `shared`：
  - `sb.json` 的 hy2 TLS 路径 = store `<apex>/current/fullchain.pem` / `.../private.key`（直接路径）。
  - 不建立 ACME 续期 cron；证书管理显示来源=共享库、owner、SAN、有效期、指纹。
  - 安装/证书管理：检测库中可领养证书（按输入域名或列出），默认建议"使用共享证书"。
  - 作为 owner：保留现有 ACME 流程与回滚，部署成功后追加 publish；cron runner 增加 owner 检查。
  - 健康检查：shared 模式下校验库证书；owner 为其他工具且临近过期时告警。
  - 修复：shared 证书缺失/损坏 → 沿用现有策略回退自签并提示。
- 配置/状态：不新增状态文件；证书模式从 `sb.json` 的证书路径推断；owner 从 store meta 读取。

## 7. acme-nginx 侧改造

- 配置新增：`CERT_SOURCE=own|store`（默认 `own`）、`STORE_DIR=/etc/cert-store`。
- store 模式：
  - `issue`：锁内领养检查 → 可领养则采用（nginx 配置指向 store current 路径）、reload nginx、退出 0；
    不可领养且 owner 允许 → 正常签发 → publish → reload nginx → 执行后置钩子（重启 sb）。
  - `renew`（cron）：owner 检查；非 owner 若库证书变化则 reload nginx；owner 续期后 publish + reload + 后置钩子。
  - `status`：显示库证书、owner、有效期、指纹。
  - `uninstall`：不删除 store。
- 新增后置钩子（发布成功后执行；root 700、信任校验语义同 sb 5.3.0）用于重启 sb。
- nginx 配置模板/文档：store 模式下指向 `/etc/cert-store/<domain>/current/...`。

## 8. 兼容 / 迁移 / 版本

- 默认不启用 store：两工具行为与当前版本一致；旧版本不识别 store 也不会破坏（新增目录）。
- 迁移：已有 sb 证书 → 菜单"发布到共享证书库"（owner=sb）；已有 acme-nginx 证书同理。
- 版本：sb `5.4.0`；acme-nginx `0.4.0`。

## 9. 测试策略

- 契约层：store 读写/校验矩阵（非法 meta、符号链接、权限、指纹不符、SAN 不覆盖、key 不匹配）。
- 发布层：原子性（中断/失败不破坏 current）、旧 generation 清理、并发锁。
- 领养层：owner 不同/相同、域名集合不匹配、过期证书、owner 非自己时拒绝签发。
- 工具层：sb shared 模式与 owner runner；acme-nginx store 模式与 CLI。
- 互操作：每个仓库的单测用"按契约写入的对方产物"模拟另一工具（sb 测试模拟 acme-nginx 发布，
  acme-nginx 测试模拟 sb 发布），断言领养时**零 acme.sh 调用**。
- 真机：49.9 上 sb 已签发 → 发布进库 → 部署 nginx 领养；再演练一次 owner 移交。

## 10. 风险

- 两边同时首次签发：store 锁 + double-check 缓解；极端情况可能产生两张证书（LE 配额足够），
  以最后 publish 的 meta 为准，另一张废弃。
- owner 工具被卸载/停止：库证书仍可服务，但无人续期 → 状态页/健康检查告警。
- 权限/符号链接攻击：所有路径按现有 managed 校验风格严格检查，不跟随符号链接。
