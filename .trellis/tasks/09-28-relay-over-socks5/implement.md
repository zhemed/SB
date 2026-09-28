# implement.md — 5.1.0 执行记录

## 改了什么

| 位置 | 改动 |
|---|---|
| `src/00-bootstrap.sh` | 删掉上游协议常量 |
| `src/20-ports.sh` | 删掉该协议的密钥校验函数 |
| `src/30-server-config.sh` | relay 出站改成 `type: "socks"`；上游状态文件无效时补一句"旧密钥格式已不再支持，请重新设置" |
| `src/40-service.sh` | relay.conf 校验改用 SOCKS5 密码规则；注释说明旧文件会判无效 |
| `src/70-management.sh` | 候选构造 jq 改成 socks；输入提示改"落地机 SOCKS5 入口的密码"；成功后说明"用户名固定 sb、这一跳不加密、落地机要启用 SOCKS5 入口"；菜单不再显示密码学方法名 |
| `src/85-repair.sh` | 退役入口的判定改成**只按 tag**（不再按 type），标签文案去名 |
| `tests/*` | 夹具与断言换成 SOCKS5 凭据；钉子同步；新增 5 条硬禁入 |
| README / 规范 | 上游段改成 SOCKS5 跳；删掉该协议的表行与说明；历史任务目录不动 |

## 证据

- `grep -rni 'shadowsocks\|relay_method\|valid_ss_password\|2022-blake3' src/ sb.sh README.md`
  → 零命中（规范里仅剩 version-pins 中"门禁禁入清单"那行的字面列举）。
- `bash tests/verify.sh` → exit 0，361 例（unit 315 + repair 46+…），shellcheck 0.10.0，`sb.sh` = `88d61fcc…`。
- `scripts/check-version-bump.sh` → 5.0.1 → 5.1.0，覆盖 8 处源码变更。
- **待补**：真实内核两跳复验（线路机 SOCKS5 入口 → relay 出站 → 落地机 SOCKS5 入站 → 目标）。
  `/tmp` 里那份 sing-box 二进制已被清空，重新下载属联网动作，等用户点头再补跑。
  脚本已写好（`/tmp/sbverify/v51-relay.sh`，待重建）。

## 未做

- 没有推送（上次擅自推送已挨批），本地提交待用户点头。
