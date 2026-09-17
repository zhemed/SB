# Input Validation & Interactive Prompts

Two distinct jobs live here, and mixing them is the usual source of bugs: **validators** are silent
boolean predicates, **prompt loops** own the user conversation and the error messages.

---

## 1. Validator contract

A validator is a pure predicate:

- takes its value as `$1` (positional, not a global),
- prints **nothing**,
- returns `0` for valid, `1` for invalid.

```bash
# src/20-ports.sh:8-10
valid_uuid(){
  [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}
```

The full family (all in `src/20-ports.sh` unless noted):

| Validator | Rule |
|-----------|------|
| `valid_port` | 1–65535, optional minimum via `$2` (`src/20-ports.sh:2-6`) |
| `valid_uuid` | canonical 8-4-4-4-12 hex UUID |
| `valid_ss_password` | exactly 44 characters: `^[A-Za-z0-9+/]{43}=$`, i.e. 32 raw bytes of padded base64 (`src/20-ports.sh:17-19`) |
| `valid_hostname` | ≤253 chars, ≥2 labels, per-label 1–63, no leading/trailing hyphen |
| `valid_ipv4` | `src/00-bootstrap.sh:98-105`, octets ≤255 via `10#` |
| `valid_ipv6` | `src/00-bootstrap.sh:107-127`, rejects `::1`, `FE80::/10`, `FC00::/7`, double `::` |

`generate_ss_password` (`src/20-ports.sh:21-27`) is the producer for `valid_ss_password`: it asks
`openssl rand -base64 32`, strips the wrapping newline, and re-validates its own output before
printing it, so an unusable key can never leave this function.

Notes that matter:

- Validation is **structural only**. `valid_ipv6` length-limits, excludes link-local and
  unique-local ranges, and requires the right number of groups — it is not a general IPv6 parser.
- A validator never reports *why* a value is bad. That is the prompt loop's job.
- Reuse these instead of inlining a regex at a call site. `tests/verify.sh` and the management flows
  both assume a single source of truth for what "valid" means.

### Predicates that return more than 0/1

Occasionally a non-boolean is genuinely useful — a caller can distinguish "argument is wrong" from
"resource is taken":

```bash
# src/20-ports.sh:43-47
  case "$network" in
    tcp) ss_args=(-H -lnt) ;;
    udp) ss_args=(-H -lnu) ;;
    *) return 2 ;;
  esac
```

Use `2` only for "misuse of this function" and document it at the definition. Do not invent other
codes.

---

## 2. Prompt loop contract

Any input that must be validated gets a **retry loop**: prompt → default → validate → on failure
`red` a specific reason → re-prompt. Never `exit` on invalid input, and never accept the first value
unconditionally.

```bash
# src/20-ports.sh:52-69 (abridged)
  while true; do
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    if ! valid_port "$port" 1; then
      red "端口必须是1-65535之间的整数"
    else
      port=$((10#$port))
    fi
    if valid_port "$port" 1 && port_conflict "$port" "$network"; then
      red "端口 $port/$network 已被占用"
    elif valid_port "$port" 1; then
      break
    fi
    readp "请重新输入端口 (1-65535，留空随机10000-65535): " port
  done
```

Conventions shown here, all of them expected in new input code:

- **Empty input means "choose for me"**, never an error — here the loop substitutes a random
  `shuf -i 10000-65535 -n 1` port and then re-checks it for conflicts.
- The failure message names the **specific** problem (`已被占用`), not "input invalid".
- The retry prompt restates the accepted range and the empty-input behaviour.
- There are currently **no cross-field port constraints** left: Hysteria2 listens on UDP and
  Shadowsocks-2022 on TCP (which is also why the SS-2022 inbound pins `"network": "tcp"`), so they
  cannot collide. `chooseport` therefore takes only the network family; the `$reserved` parameter and
  its retry branch were removed together with the protocol that needed them. Do not reintroduce a
  reserved argument without a real caller.

```bash
choose_ss_port(){
  local choice
  while true; do
    yellow "1：自动生成随机端口 (10000-65535范围内)，回车默认"
    yellow "2：自定义端口"
    readp "请输入【1-2】：" choice || return 1
    case "$choice" in
      ""|1) port=$(random_available_port tcp) || return 1; return 0 ;;
      2) readp "\n设置Shadowsocks-2022端口 (可输入1-65535，留空随机10000-65535)：" port || return 1
         chooseport tcp
         return $? ;;
      *) red "请输入1或2" ;;
    esac
  done
}
```

- The loop writes into a **global** (`port`), which the caller then assigns to a domain global
  (`port_ss`, `port_hy2`). Reset `port=` before each selection so a stale value cannot be reused:

```bash
        port=
        hy2port
```

---

### Value prompts always offer a way out

A prompt that asks for a value which is about to be written into the live config must have an
explicit escape: `输入0取消` in the question, and cancelling prints `已取消，未做任何修改` before
returning. **Empty input is not a cancel** — in the port prompts it means "pick a random free port"
(that is the documented default), so an operator who presses Enter expecting to back out gets a silent
port change instead. That shipped in 3.1.2: `change_ss_port` asked for a port with no cancel key and
rewrote a working listener. Fixed in 3.1.4 for the Shadowsocks-2022 port, the Hysteria2 port and the
upstream fields, with `choose_ss_port` returning a distinct status (2) so `enable_ss_entry` aborts
instead of minting a key and a random port.

### Destructive confirmations

Anything that changes or removes a working listener goes through `confirm_yes`
(`src/00-bootstrap.sh:76-88`), never a bare `readp` plus a string comparison:

```bash
if ! confirm_yes "确认停用 Shadowsocks-2022 入口？[回车/y 确认，n 取消]："; then
  yellow "已取消，未做任何修改"
  readp "按回车返回可选功能..."
  return 0
fi
```

- **Enter confirms** (the prompt asks about the action the operator just chose), `y`/`yes` in any
  case confirms, `n`/`no` and anything unrecognised cancels, and EOF cancels too — a lost terminal
  is never treated as consent.
- The prompt states both outcomes (`[回车/y 确认，n 取消]`) so nobody has to guess.
- **A cancellation is always reported** (`已取消，未做任何修改`) and then it waits for a keypress.
  A bare `return 0` redraws the menu and looks exactly like a broken entry — that shipped as a real
  bug in 3.1.0/3.1.1 (`[[ $confirm == YES ]] || return 0` silently swallowed a lowercase `yes`).
- Typed-word gates are a different, deliberate class: `rebuild_config_in_place` still requires the
  literal `REBUILD`, because that path invalidates every client and is not a yes/no question.

## 3. Menu input

Top-level menu dispatch is a `case` on a validated string, with a catch-all that re-prompts rather
than aborting:

```bash
# src/90-main.sh:118-119
    readp "请输入数字 [0-9]: " Input || exit 0
    case "$Input" in
```

- `readp … || exit 0` treats EOF (Ctrl-D) as "quit", which is the only input path allowed to exit.
- `0|"") exit 0` — Enter also quits the main menu (`src/90-main.sh:166`).
- The catch-all is `*) red "请输入正确数字"; sleep 1 ;;` (`src/90-main.sh:167`).
- Sub-menus use explicit range prompts such as `请选择【0-2】` and
  `请输入【1-2】` (`src/20-ports.sh:102`, `src/70-management.sh:961`);
  `tests/verify.sh:146-149` asserts two of these strings still exist, so keep the prompt text when
  adding options.

---

## 4. Never echo secrets into the transcript

The Cloudflare API Token is read through the ordinary visible `readp` helper:

```bash
# asserted by tests/verify.sh:75-76
  readp "请输入 Cloudflare API Token：" cf_token || return 1
```

This is deliberate (the user must be able to verify what they pasted), and `tests/verify.sh:77-81`
fails the build if a hidden read (`read -s`) or a masked-input message returns. What must never
happen is echoing the token afterwards during status display — `README.md:78` states that no status
page may print the API Token. Read it, use it, store it with `chmod 600`, never print it.

---

## Common mistakes

- Validating with an inline regex instead of extending a `valid_*` function — the same rule then
  diverges between install, management, and repair paths.
- `exit 1` on bad input in a loop that should have re-prompted.
- Making empty input an error, when every existing prompt treats it as "auto-select".
- Forgetting `port=` reset before a second selection, so the previous choice silently wins.
- Printing the API Token in a status/diagnostic block.
