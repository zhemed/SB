# User Output & Messaging

All user-facing text is **Chinese**. Identifiers, comments, and these specs are English. Message
helpers are defined once in `src/00-bootstrap.sh:60-64` (colour) and `:65-71` (`readp`) and used
everywhere.

---

## 1. The helpers

```bash
# src/00-bootstrap.sh:60-64
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
```

All take exactly **one** argument and colour the whole message. They are wrappers around `echo -e`
and expand escape sequences in the argument — so pass plain text, and do not embed user-controlled
data containing backslashes.

`readp` is the input primitive; see `input-validation.md`.

```bash
# src/00-bootstrap.sh:65-71
readp(){
  if [[ -n ${2-} ]]; then
    IFS= read -r -p "$(yellow "$1")" "$2"
  else
    IFS= read -r -p "$(yellow "$1")"
  fi
}
```

---

## 2. Severity model

Pick the colour by what the user must do, not by how the code feels. Observed distribution:
`red` ×242, `green` ×94, `yellow` ×89, `blue` ×14 (`white` is banner-only).

| Helper | Meaning | Typical use |
|--------|---------|-------------|
| `red` | **Stop.** Refusal, hard error, validation failure. The user must act. | `red "端口 $port/$network 已被占用"` (`src/20-ports.sh:63`) |
| `yellow` | **Careful.** Warning, hint, or a degraded-but-continuing outcome. | `yellow "安全提示：本次只安装 Hysteria2；需要 TCP 备用入口时到菜单[8]启用（SOCKS5，明文，仅限可信链路）"` (`src/90-main.sh:47`) |
| `green` | **Success**, or the name of an action being taken. | `green "证书模式切换成功"` (`src/70-management.sh:65`) |
| `blue` | Neutral informational status. **Rare** — reserve for key confirmations. | `blue "确认的端口：$port"` (`src/20-ports.sh:69`) |
| `white` | Banner framing only. | `src/90-main.sh:89` |

Two rules that follow:

- Never use `red` for a success message, and never `yellow` for a hard failure.
- A failure that is *expected and recovered from* is not a `red`. In `commit_config`, the successful
  rollback path prints `red "已恢复修改前的配置和服务"` because the user's requested change did **not**
  happen — red is about outcome, not about whether the code handled it. Only the unrecoverable
  case escalates to language that demands manual action (`src/40-service.sh:530`).

---

## 3. Messages belong to the layer that owns the decision

Low-level predicates and helpers stay **silent** and just return status. The function that decides
the operation failed prints the message.

```bash
# src/40-service.sh:502-507 — commit_config owns the message
if ! "$SB_BIN" check -c "$candidate" >/dev/null 2>&1; then
  red "新配置未通过 Sing-box v${CORE_VERSION} 检查，已取消修改"
  "$SB_BIN" check -c "$candidate"
  rm -f "$candidate"
  return 1
fi
```

Note the deliberate pattern: the failing validator runs **again without stderr suppression** so the
user sees the underlying reason. Do this whenever the suppressed check is the user's only clue.

Callers then add context rather than duplicating the reason:

```bash
# src/90-main.sh:40 (abridged)
inssbjson || { abort_install_transaction; return 1; }
```

---

## 4. Say what was kept

Every refusal or failure message states the end state, because these operations touch a live
service. Compare:

- Refusal confirms nothing was touched: `red "新配置未通过 Sing-box v${CORE_VERSION} 检查，已取消修改"`.
- Recoverable failure says the old state is back: `red "证书切换失败，原配置未修改或已恢复"` (`src/70-management.sh:52`).
- Unrecoverable failure names the artifact to inspect: `red "自动回滚失败！请立即检查服务；原配置备份保留在 $backup"` (`src/40-service.sh:530`).
- Foreign-asset refusal names the path: `red "检测到不属于本脚本的 $SB_DIR，拒绝覆盖"` (`src/40-service.sh:160`).

An agent adding a new failure path must include the same information: what failed, what state the
system is in now, and what the user should do.

### A success that changes a client-facing value must print the new value

"修改成功" alone is not a finished success message when the thing that changed is what a **client**
has to be configured with. Changing a port/key/cipher has to end by showing the resulting share link
and the server-side key, otherwise the operator is left asking "where is my link?" — which is exactly
what the 3.1.0 enable flow did (it printed only the port; the link existed in the share file and
menu [3] but nobody was told). `print_socks_entry_share` (`src/50-client-output.sh`) is that ending
for the optional SOCKS5 entry: the link, the file it was written to, menu [3] for the QR code, and
the username/password — followed by the plaintext warning. When the share file is missing it says so and points at menu [3] instead of silently
showing nothing.

---

## 5. Section framing and layout

Long flows print a section header in the established shape — a `red` rule, a `green` title, then
`yellow`/`blue` detail lines:

```bash
# src/20-ports.sh:97-100
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "三、设置各协议端口"
  yellow "1：自动生成随机端口 (10000-65535范围内)，回车默认。请确保VPS后台已开放所有端口"
  yellow "2：自定义每个协议端口。请确保VPS后台已开放指定的端口"
```

- The rule is a run of `~` (about 84 characters), always `red`, always full width.
- Section titles are numbered with Chinese numerals: `三、设置各协议端口` (`src/20-ports.sh:98`).
- The ~84-character `~` rule is used as a visual delimiter, not as a separator between every
  message; do not introduce a new ruler width.

### Pacing

Flows that change state pause before returning to the menu:

```bash
# src/70-management.sh — 21 occurrences
  readp "按回车返回主菜单..."
```

`tests/verify.sh:150-151` asserts at least five `按回车返回主菜单...` occurrences exist, so removing
them from modification flows fails the gate. Use it at the end of any management action. When the
output must be read before the pause, prefer a short `sleep`:

```bash
# src/20-ports.sh:69
  blue "确认的端口：$port" && sleep 2
```

---

## 6. Non-interactive modules stay quiet

`src/60-cron.sh` runs both interactively and inside the generated cron runner, so it uses **only
`red`** (eight occurrences) plus a single `yellow` progress note — never `green`, `blue`, or `readp`
(zero occurrences of each). Keep it that way: a cron job's stdout is discarded
(`> /dev/null 2>&1` in the entry), and an interactive prompt there would hang forever.

---

## Common mistakes

- Printing with `printf` for a status change — use the colour helpers so the severity is visible.
- Emitting `red` from a validator; it must be silent for reuse in retry loops.
- Adding a `green` success line to `src/60-cron.sh`.
- A failure message that only says "失败" without stating the current state or where the backup is.
- Suppressing stderr on the check whose output is the user's only diagnostic.
