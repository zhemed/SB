# sb

`sb` 是面向 Sing-box 1.10.7 的单文件安装与管理脚本。正式发布物仍是根目录的
`sb.sh`，用户不需要下载其他文件；项目源码按职责保存在 `src/`，由构建脚本按固定顺序
拼接生成发布物。

## 使用

VPS专用一键脚本如下：快捷方式： `sb`

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhemed/SB/main/sb.sh)
```

或者

```bash
bash <(curl -Ls https://raw.githubusercontent.com/zhemed/SB/main/sb.sh)
```

脚本支持使用 systemd 的 Ubuntu、Debian、CentOS，以及使用 OpenRC 的 Alpine。脚本不会修改
系统防火墙或云厂商安全组，安装或改端口后需要自行放行界面提示的 TCP/UDP 端口。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `src/00-bootstrap.sh` | 常量、环境检查、网络信息与内核下载 |
| `src/10-acme.sh` | 证书校验、官方 acme.sh 与 DNS API（Cloudflare / 华为云） |
| `src/20-ports.sh` | 输入校验、Hysteria2 UDP 与可选 SOCKS5 TCP 端口选择 |
| `src/30-server-config.sh` | Sing-box 服务端配置模板 |
| `src/40-service.sh` | 托管目录、systemd/OpenRC 与配置提交 |
| `src/50-client-output.sh` | Hysteria2（以及可选的 SOCKS5 / 旧的 Shadowsocks-2022）分享链接与 Sing-box/Clash 客户端配置 |
| `src/60-cron.sh` | ACME 续期与定时任务管理 |
| `src/70-management.sh` | 证书、端口、协议凭据，以及可选功能（SOCKS5 入口、上游/中转、旧 SS 入口的移除） |
| `src/80-lifecycle.sh` | 卸载、快捷命令、依赖与运行态准备 |
| `src/85-repair.sh` | 内核、配置、证书、服务与维护任务的诊断恢复 |
| `src/90-main.sh` | 安装流程、菜单和唯一入口 |
| `scripts/build.sh` | 校验模块并原子生成根目录 `sb.sh` |
| `tests/` | 无需 root 的构建与纯函数回归 |

这些模块是构建片段，不是运行时插件。正式脚本不会 `source` 项目文件，因此仍支持复制
单个 `sb.sh`、离线运行和安装 `/usr/bin/sb` 快捷命令。

## 开发流程

只修改 `src/`，不要直接编辑生成的 `sb.sh`。

```bash
# 生成或更新正式发布物
bash scripts/build.sh

# 检查 sb.sh 是否与源码完全同步，不修改文件
bash scripts/build.sh --check

# 执行构建、语法、ShellCheck（已安装时）和纯函数测试
bash tests/verify.sh

# 检查「改了 src/ 就必须同步改 VERSION」这条发布规则
bash scripts/check-version-bump.sh
```

也可以使用 `make build`、`make check` 和 `make test`。

构建器会拒绝缺失、多余、错序或符号链接模块，以及 BOM、CRLF、NUL、无结尾换行、
重复函数、运行时模块加载和无效 ACME reload hook。候选文件通过全部检查后才会原子替换
`sb.sh`；内容未变化时保留原文件时间戳。

## 固定版本与证书

- 当前项目版本：`5.8.2`。
- Sing-box 固定为 `1.10.7`。
- acme.sh 固定为 `3.1.4`。
- 两个上游下载均限制为 HTTPS，并在执行前核对项目内固定的 SHA-256。
- DNS API 支持 Cloudflare 与华为云（5.2.0 起）。
- Cloudflare 使用 `Account ID + API Token`；API Token 使用普通可见输入，Zone ID 由 acme.sh 自动识别。
- 华为云使用 AK/SK + Region：AK/SK 在控制台「我的凭证」→「访问密钥」创建，
  建议使用只授 DNS 云解析权限的子账号；Region 决定 API 域名 `dns.<region>.myhuaweicloud.com`，
  申请时提供常用区域菜单（北京 `cn-north-4`（默认）/ 上海 `cn-east-3` / 广州 `cn-south-1` /
  香港 `ap-southeast-1`），也可手动输入 Region ID。
  凭据由 acme.sh 保存在仅 root 可读的 `/etc/sb/acme/account.conf`，任何状态页都不会回显。
- 证书管理页会显示当前与备用证书的 SAN、签发机构、生效/到期时间、剩余天数、
  SHA-256 指纹和证书/私钥匹配状态；任何状态页都不会回显 API Token。
- 输入 `example.com` 或 `*.example.com` 都默认申请 `example.com + *.example.com`（单张证书两个 SAN）；
  申请时可输入 `n` 显式只申请单域名。申请时可选 Cloudflare 或华为云，回车默认 Cloudflare。
- ACME 续期由 root crontab 定时执行，并记录最近检查、结果和实际换证时间。证书管理支持
  计划续期检查、强制重签、续期组件修复以及直接更换域名、DNS 供应商或凭据。
- ACME 只写入受管暂存目录；证书与私钥校验通过后，通过 generation 指针一次切换同时生效，
  服务重启失败会恢复旧 generation。旧版普通证书文件会在续期自检时原地迁移。
- 证书更新后，运行中的 sb 服务会通过 reload hook 重启并加载新证书；服务未运行时不会被续期任务强制启动。
- 证书成功切换后可执行可选后置钩子 `/etc/sb/acme_post_reload.sh`，用于让同机第二个服务（如 nginx）
  加载新证书；详见下文「与 nginx 等第二个服务共用同一张证书」。
- 修复、卸载、残缺安装清理、证书操作和自动续期共用 `/run/sb-acme.lock`，避免并发修改出半套状态。
- **默认只安装 Hysteria2**（UUID 作为密码）。安装只询问 hy2 端口，只放行一个 UDP 端口。
- **可选 TCP 入口是 SOCKS5**（固定用户名 `sb` + 独立随机密码），在菜单 [8] 里按需启用：
  启用后会打印 `socks5://` 链接、用户名/密码，并写入 `/etc/sb/socks5.txt`。
  ⚠️ **SOCKS5 不加密**：口令与流量明文，握手特征明显、容易被识别与封锁，只应在可信链路上使用。
  这是 4.0.0 按维护者要求换回来的形态（评估与代价见
  `.trellis/tasks/archive/2026-09/09-20-socks5-vs-ss-eval/research.md`）。它只承载 TCP，UDP 由 Hysteria2 承担。
- **旧 Shadowsocks-2022 入口的支持已在 5.0.0 彻底移除**（4.0.0 时曾保留一个版本作为过渡）：
  脚本不再支持、保留或移除它。**升级前请先切到 SOCKS5**——如果你的节点上还跑着
  3.0.0–3.1.4 建的旧入口，升级后每次改写配置（改端口、改凭据、修复）都会把它移除，
  仍在用它连接的人会立刻断线。改写前会打印明确警告，菜单 [8] 也会先提示。
  想继续要一个 TCP 备用入口，就在菜单 [8] 第 1 项启用 SOCKS5。
- 客户端配置不再生成负载均衡或自动测速分组；节点顺序固定为 SOCKS5 → Hysteria2，
  默认节点始终是加密的 Hysteria2。
- 菜单 [8] 里的「上游/中转」可把本机出网交给一台落地机（这一跳走落地机的 SOCKS5 入口）：
  参数保存在 `/etc/sb/relay.conf`（600，受管文件），每次重写配置都会重新注入，
  改端口、改凭据、修复都不会丢。**上游不可达等于断网**，清除上游即可立即恢复直连。
- 安装与修复已拆分为独立菜单。修复会补齐依赖与固定内核、恢复最后一次可用配置或从现有节点参数重建标准配置、修复证书与服务定义，并检查快捷命令和定时任务；只有关键节点参数完全无法恢复时，才会要求输入 `REBUILD` 原地生成新节点，不会默认删除 `/etc/sb`。
- 核心修复以事务执行并备份原内核、配置和服务定义；启动失败或收到中断信号时优先恢复原可用服务，无法恢复时会保留修复后的节点配置副本并在报告中给出路径。
- 首次安装中断或关键步骤失败时，会自动清理本次安装创建的服务、定时任务、目录和快捷命令。

项目版本记录在 `VERSION`，并由构建器校验其与脚本内显示版本一致。

## 与 nginx 等第二个服务共用同一张证书

sb 只签发/续期一次，证书通过两个稳定路径对外提供（内部是 generation 指针，原子切换）：

- `/etc/sb/acme-cert.pem`：fullchain
- `/etc/sb/acme-private.key`：私钥

同机的 nginx 直接引用这两个路径即可，不需要复制证书；nginx master 以 root 读取，
`/etc/sb` 保持 700 不用放宽。sb 用 UDP 443、nginx 用 TCP 443，可以同机共存：

```nginx
server {
    listen 443 ssl;
    server_name example.com;
    ssl_certificate     /etc/sb/acme-cert.pem;
    ssl_certificate_key /etc/sb/acme-private.key;
}
```

续期后 nginx 需要重新加载证书。创建 `/etc/sb/acme_post_reload.sh`（root 所有、`chmod 700`）：

```bash
#!/bin/bash
nginx -t && systemctl reload nginx
```

- 钩子只在证书**成功切换**后执行；失败只告警（stderr + syslog `sb`），不回滚 sb、不影响下一次续期。
- 钩子必须 root 所有、非符号链接、可执行、组/他人不可写，否则会被忽略并告警。
- 该文件位于 `/etc/sb` 内，卸载 sb 时会一并删除。
- 申请 `*.example.com` 会同时包含 `example.com`（apex 与一级子域共用同一张证书）。
- 若 nginx 以非 root 启动或运行在容器里，需要把证书路径以只读方式挂载/授权给 nginx 进程。

## 共享证书库（sb 与 acme-nginx 共用）

5.4.0 起 sb 支持 `/etc/cert-store` 共享证书库，用于 sb 与 acme-nginx 同机共用同一张证书：

- **谁先签发谁发布**：签发方把证书原子发布进库（`/etc/cert-store/<域名>/current/` +
  `meta.env` 记录 owner、指纹、有效期），另一个工具直接领养，不再重复申请；
  同一域名同一时间只有一个"续期负责人（owner）"。
- **领养**：证书管理菜单选择「使用共享证书库中的证书（领养，不再申请）」；sb 的 Hysteria2
  配置直接指向 `/etc/cert-store/<域名>/current/fullchain.pem` 与 `.../private.key`，
  并且不再建立 sb 自己的 ACME 续期任务。
- **发布**：ACME 模式下选择「发布当前证书到共享证书库」；之后每次续期成功，reload hook
  会自动把新证书原子发布回库（owner=sb）。
- **续期**：只有 `meta.env` 里的 owner 工具会续期；非 owner 的 sb 续期检查会记录 `skipped`
  并跳过，避免两个工具重复签发。
- **owner 交接**：sb 从「自己签发（owner=sb）」切换为领养共享证书后，只把**当前领养域名**
  的 owner 交还为 `none`（库里其他仍由 sb 负责的域名不受影响）并提示「已交还续期责任，
  需另一方或重新签发接管」——本机已不再续期该域名，避免留下名义 owner；启动自检也会对账
  失效的 owner。发布时若库里已有到期更晚的有效证书，会拒绝用更旧的证书覆盖（主脚本与
  reload hook 两道闸）。
- **接管续期**：共享证书模式下，证书管理菜单新增「5：接管续期（重新签发当前域名）」——
  签发前先在共享库锁内把该域名 owner 置为 `none`（记录原 owner），让仍在续期的对方工具在
  接管窗口内自动跳过，避免两边并发续期；取消、失败或中断时恢复原 owner，成功后用显式接管
  参数把 owner 写回 `sb`，并提示自动续期已恢复。主发布函数只在 owner 是 sb/none 时覆盖；
  其他工具持有 owner 时必须走显式接管，避免误覆盖。
- **并发**：reload hook 的 owner 判定与发布都在共享库锁内完成，续期 runner 读取 owner 时也会
  短暂持锁（flock -w 5，读完即放）。**签发前 double-check（B6）**：发起 ACME 签发前先在
  store 锁内 claim——若 owner 是其他"存活"工具则拒绝签发；否则把 owner 置为 sb 占位，
  签发失败/取消时回滚原 owner，成功则保持 owner 由发布流程写回（显式接管可跳过该检查）。
- **meta 损坏**：发布时若域名目录的 `meta.env` 路径存在（常规文件/符号链接/目录）但解析
  失败，主脚本与 reload hook 都直接拒绝覆盖（不会跳过 owner 校验）；签发前 claim 遇到损坏
  meta 也会拒绝并提示修复；runner 在 store 锁获取失败时写 `skipped` 状态并跳过本次
  （fail-closed，无证书指纹时记 `failed` 并以非 0 退出，进程退出码与 state 一致），
  有 logger 时同时记录系统日志。
- **own 模式**：库内存在同域名存活他方 owner 时，本工具 own 模式手动签发也会被 claim 拒绝
  （提示先停用对方续期或使用接管流程）——这是防双签设计，避免两个工具同时向 CA 申请同一域名。
- **健康检查**：证书管理页显示共享证书来源、owner、有效期与校验结果；owner 缺失或证书
  无效会告警。
- 卸载 sb 不会删除 `/etc/cert-store`；如需停用共享证书，在证书管理里切回自签或 ACME 即可。
- acme-nginx 侧的启用方式（`CERT_SOURCE=store`）见该项目 README。

## 发布检查

提交或发布前至少运行：

```bash
bash scripts/build.sh
bash tests/verify.sh
bash scripts/check-version-bump.sh
```

**版本号规则**：推到 `main` 即等于发布（脚本会从 `main` 自助更新），所以任何改动 `src/`
或根目录 `sb.sh` 的提交都必须同时改 `VERSION`，否则两个不同的构建会共用同一个版本号。
`scripts/check-version-bump.sh` 强制这条规则，CI 也会跑。详细流程见
`.trellis/spec/build/version-pins.md`。

CI 使用同一套验证入口。发布时只需要分发根目录生成的 `sb.sh`。
