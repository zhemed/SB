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
| `valid_socks_password` | length 16–128, charset `[A-Za-z0-9._~-]` |
| `valid_reality_key` | exactly 43 chars of `[A-Za-z0-9_-]` |
| `valid_short_id` | exactly 8 hex chars |
| `valid_hostname` | ≤253 chars, ≥2 labels, per-label 1–63, no leading/trailing hyphen |
| `valid_ipv4` | `src/00-bootstrap.sh:96-103`, octets ≤255 via `10#` |
| `valid_ipv6` | `src/00-bootstrap.sh:105-125`, rejects `::1`, `FE80::/10`, `FC00::/7`, double `::` |

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
# src/20-ports.sh:38-45
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
# src/20-ports.sh:50-66 (abridged)
  while true; do
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    if ! valid_port "$port" 1; then
      red "端口必须是1-65535之间的整数"
    else
      port=$((10#$port))
    fi
    if valid_port "$port" 1 && [[ -n $reserved && $port == "$reserved" ]]; then
      red "端口 $port/$network 与已选择的TCP端口冲突"
      port=
    elif valid_port "$port" 1 && port_conflict "$port" "$network"; then
      red "端口 $port/$network 已被占用"
    elif valid_port "$port" 1; then
      break
    fi
    readp "请重新输入端口 (1-65535，留空随机10000-65535): " port
  done
```

Conventions shown here, all of them expected in new input code:

- **Empty input means "choose for me"**, never an error — here it produces a random, conflict-free
  port via `random_available_port`.
- The failure message names the **specific** problem (`已被占用` vs `与已选择的TCP端口冲突`), not
  "input invalid".
- The retry prompt restates the accepted range and the empty-input behaviour.
- Cross-field constraints (SOCKS5 port ≠ VLESS port) are checked here with the `$reserved`
  parameter, not deferred to config validation:

```bash
# src/20-ports.sh:88-92
socksport(){
  readp "\n设置SOCKS5端口 (可输入1-65535，留空随机10000-65535)：" port
  chooseport tcp "$port_vl_re"
  port_socks5=$port
}
```

- The loop writes into a **global** (`port`), which the caller then assigns to a domain global
  (`port_vl_re`, `port_socks5`, `port_hy2`). Reset `port=` before each selection so a stale value
  cannot be reused:

```bash
# src/20-ports.sh:118-123
        port=
        vlport
        port=
        socksport
```

---

## 3. Menu input

Top-level menu dispatch is a `case` on a validated string, with a catch-all that re-prompts rather
than aborting:

```bash
# src/90-main.sh:142-143
    readp "请输入数字 [0-9]: " Input || exit 0
    case "$Input" in
```

- `readp … || exit 0` treats EOF (Ctrl-D) as "quit", which is the only input path allowed to exit.
- `0|"") exit 0` — Enter also quits the main menu (`src/90-main.sh:190`).
- The catch-all is `*) red "请输入正确数字"; sleep 1 ;;` (`src/90-main.sh:191`).
- Sub-menus use explicit range prompts such as `请选择【0-3】` and
  `请输入【1-2】` (`src/20-ports.sh:106`); `tests/verify.sh:108-109` asserts one of these strings
  still exists, so keep the prompt text when adding options.

---

## 4. Never echo secrets into the transcript

The Cloudflare API Token is read through the ordinary visible `readp` helper:

```bash
# asserted by tests/verify.sh:74-75
  readp "请输入 Cloudflare API Token：" cf_token || return 1
```

This is deliberate (the user must be able to verify what they pasted), and `tests/verify.sh:76-80`
fails the build if a hidden read (`read -s`) or a masked-input message returns. What must never
happen is echoing the token afterwards during status display — `README.md:75` states that no status
page may print the API Token. Read it, use it, store it with `chmod 600`, never print it.

---

## Common mistakes

- Validating with an inline regex instead of extending a `valid_*` function — the same rule then
  diverges between install, management, and repair paths.
- `exit 1` on bad input in a loop that should have re-prompted.
- Making empty input an error, when every existing prompt treats it as "auto-select".
- Forgetting `port=` reset before a second selection, so the previous choice silently wins.
- Printing the API Token in a status/diagnostic block.
