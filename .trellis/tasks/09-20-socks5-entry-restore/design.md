# design.md — 反向替换：SS-2022 → SOCKS5

## 1. 与 v3.0.0/v3.1.0 的关系

v3.0.0 做了 socks → SS-2022，v3.1.0 把入口改成"可选、默认不装"。本任务是**只把协议那一层换回来**，
其余设计全部保留：

| 保留 | 换掉 |
|---|---|
| 菜单【8】可选功能的结构（入口 + 上游/中转） | 入站类型与凭据模型 |
| 默认不装、按需启用 | 客户端产物（链接/出站/分组成员） |
| `print_*_share`（启用后显示链接与凭据） | 分享文件名 `ss.txt` → `socks5.txt` |
| 取消出口、回车即确认等交互约定 | 修复的"已移除协议"识别对象 |
| UDP 阻断规则、TCP-only 契约 | 密码校验/生成函数 |

## 2. 命名映射（反向）

| 现在 | 换回 |
|---|---|
| `SS_METHOD` | 删除；恢复 `SOCKS_USERNAME="sb"` |
| `ss-sb` / `shadowsocks` | `socks5-sb` / `socks` + `users` |
| `valid_ss_password` / `generate_ss_password` | `valid_socks_password`（16–128，`[A-Za-z0-9._~-]`）/ `generate_socks_password`（`openssl rand -hex 24`） |
| `choose_ss_port` | `choose_socks_port`（同样的 0 取消 / 回车随机 / 2 自定义） |
| `ss_entry_is_enabled/port/password` | `socks_entry_*`（密码取 `users[0].password`） |
| `enable_ss_entry` / `disable_ss_entry` / `change_ss_port` / `change_ss_password` | 同名替换为 socks 版本 |
| `print_ss_entry_share` | `print_socks_entry_share` |
| `resss` / `ss.txt` | `ressocks5` / `socks5.txt` |
| `REPAIR_SS_ENABLED` / `REPAIR_SS_PORT` / `REPAIR_SS_PASSWORD` | `REPAIR_SOCKS_ENTRY_*`（沿用旧的 `REPAIR_SOCKS_INBOUND` 语义则拆成"入口存在"与"旧 SS 形态"两个标记） |

## 3. 修复的三形态（与 v3.0.0 对称）

| 源配置 | 处理 |
|---|---|
| 有 `socks5-sb` | 端口/用户名/密码原样提取 |
| 有 `ss-sb`（v3.0.0–v3.1.4） | 视为已移除协议 → 重写为 socks 形态、**重新生成密码**、label 提示旧客户端失效 |
| 都没有 | 保持没有 |

`config_contains_removed_protocol` 的识别对象从 `socks5-sb` 改成 `ss-sb`（vless 照旧）。

## 4. 真实 SOCKS5 握手验证（这次比上次好验）

SOCKS5 的优点之一就是**curl 自己会说**：

```bash
$SB run -c server.json &            # 服务端：hy2 + socks5-sb
curl --socks5-hostname 127.0.0.1:<port> http://127.0.0.1:18080/probe.txt
```

不需要第二个 sing-box 客户端进程（SS 时期需要）。这条会作为发布前的硬证据。

## 5. 明文风险的处理方式

用户已明确选择换回，设计上不做阻拦，但**必须**：

1. 启用流程打印警示（明文 + 可被指纹识别 + 只在可信链路用）；
2. README 的协议段写清楚这一条是**有意为之**，并指向本次评估记录；
3. 保留用户名+密码（不做无鉴权开放代理）；
4. 分享文件与配置仍是 600/700（凭据不裸奔到文件系统其它用户）。

## 6. 受影响文件

`src/20-ports.sh`、`src/30-server-config.sh`、`src/50-client-output.sh`、`src/70-management.sh`、
`src/85-repair.sh`、`src/90-main.sh`、`src/00-bootstrap.sh`；`tests/{verify,unit,repair}.sh`；
`README.md`；`.trellis/spec/{shell,runtime,build,tests}/`。
