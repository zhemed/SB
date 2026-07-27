# sb

`sb` 是面向 Sing-box 1.10.7 的单文件安装与管理脚本。正式发布物仍是根目录的
`sb.sh`，用户不需要下载其他文件；项目源码按职责保存在 `src/`，由构建脚本按固定顺序
拼接生成发布物。

## 使用

```bash
sudo bash sb.sh

# 安装完成后
sudo sb
```

脚本支持使用 systemd 的 Ubuntu、Debian、CentOS，以及使用 OpenRC 的 Alpine。脚本不会修改
系统防火墙或云厂商安全组，安装或改端口后需要自行放行界面提示的 TCP/UDP 端口。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `src/00-bootstrap.sh` | 常量、环境检查、网络信息与内核下载 |
| `src/10-acme.sh` | 证书校验、官方 acme.sh 与 Cloudflare DNS API |
| `src/20-ports.sh` | 输入校验、VLESS/SOCKS5 TCP 与 Hysteria2 UDP 端口选择 |
| `src/30-server-config.sh` | Sing-box 服务端配置模板 |
| `src/40-service.sh` | 托管目录、systemd/OpenRC 与配置提交 |
| `src/50-client-output.sh` | VLESS、Hysteria2、SOCKS5 分享链接及 Sing-box/Clash 客户端配置 |
| `src/60-cron.sh` | ACME 续期与定时任务管理 |
| `src/70-management.sh` | 证书、SNI、端口与协议凭据修改 |
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
```

也可以使用 `make build`、`make check` 和 `make test`。

构建器会拒绝缺失、多余、错序或符号链接模块，以及 BOM、CRLF、NUL、无结尾换行、
重复函数、运行时模块加载和无效 ACME reload hook。候选文件通过全部检查后才会原子替换
`sb.sh`；内容未变化时保留原文件时间戳。

## 固定版本与证书

- 当前项目版本：`1.9.0`。
- Sing-box 固定为 `1.10.7`。
- acme.sh 固定为 `3.1.4`。
- 两个上游下载均限制为 HTTPS，并在执行前核对项目内固定的 SHA-256。
- DNS API 默认使用 Cloudflare `Account ID + API Token`。
- API Token 使用普通可见输入，Zone ID 由 acme.sh 自动识别。
- 证书管理页会显示当前与备用证书的 SAN、签发机构、生效/到期时间、剩余天数、
  SHA-256 指纹和证书/私钥匹配状态；任何状态页都不会回显 API Token。
- 单域名与 `*.example.com` 泛域名输入会自动选择对应申请参数。
- ACME 续期由 root crontab 定时执行，并记录最近检查、结果和实际换证时间。证书管理支持
  计划续期检查、强制重签、续期组件修复以及直接更换域名、Account ID 或 Token。
- ACME 只写入受管暂存目录；证书与私钥校验通过后，通过 generation 指针一次切换同时生效，
  服务重启失败会恢复旧 generation。旧版普通证书文件会在续期自检时原地迁移。
- 证书更新后，运行中的 sb 服务会通过 reload hook 重启并加载新证书；服务未运行时不会被续期任务强制启动。
- 修复、卸载、残缺安装清理、证书操作和自动续期共用 `/run/sb-acme.lock`，避免并发修改出半套状态。
- 服务端同时提供 VLESS Reality、Hysteria2 与 SOCKS5。
- VLESS 与 Hysteria2 共用 UUID；SOCKS5 使用固定用户名 `sb` 和独立随机密码。
- SOCKS5 仅允许 TCP，不参与自动测速或负载均衡；它本身不加密，只应在可信链路中使用。
- 安装与修复已拆分为独立菜单。修复会补齐依赖与固定内核、恢复最后一次可用配置或从现有节点参数重建标准配置、修复证书与服务定义，并检查快捷命令和定时任务；只有关键节点参数完全无法恢复时，才会要求输入 `REBUILD` 原地生成新节点，不会默认删除 `/etc/sb`。
- 核心修复以事务执行并备份原内核、配置和服务定义；启动失败或收到中断信号时优先恢复原可用服务，无法恢复时会保留修复后的节点配置副本并在报告中给出路径。
- 首次安装中断或关键步骤失败时，会自动清理本次安装创建的服务、定时任务、目录和快捷命令。

项目版本记录在 `VERSION`，并由构建器校验其与脚本内显示版本一致。

## 发布检查

提交或发布前至少运行：

```bash
bash scripts/build.sh
bash tests/verify.sh
```

CI 使用同一套验证入口。发布时只需要分发根目录生成的 `sb.sh`。
