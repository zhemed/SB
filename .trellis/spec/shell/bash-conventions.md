# Bash Conventions

Language-level rules observed across all 11 modules. These are the conventions an agent must match
so new code is indistinguishable from the surrounding 8,000 lines.

Frequency reference (whole of `src/`): `|| return 1` ×451, `2>/dev/null` ×243, `|| true` ×123,
`printf` ×123, `[[ ]]` ×548, single-bracket `[ ]` ×**0**.

---

## 1. Function definitions

All 234 definitions use the same shape — **column 0, no space before the brace**:

```bash
# src/20-ports.sh:2
valid_port(){
```

Nested/indented definitions and `function name {` style do not appear. Keep it exactly `name(){`.

Function names are `lower_snake_case`. Two naming eras coexist and both are acceptable:

- **Descriptive verb-noun** for newer code: `save_last_good_config`, `commit_config`,
  `managed_directory_is_owned`, `register_acme_certificate_deployment`.
- **Short historical names** for core flows: `inssb`, `insport`, `inscertificate`, `v4v6`, `readp`,
  `sbshare`, `changeuuid`, `sbactive`.

Rename toward the descriptive form only when you are already rewriting the function; do not mass
rename, because `tests/verify.sh` extracts function bodies by name
(`tests/verify.sh:113-121`, `206-213`).

---

## 2. No `set -e`, no `set -u`, no `pipefail`

The runtime script never changes shell options. Verified: no `set -e`, `set -u`, `set -o pipefail`,
or `set +…` appears anywhere in `sb.sh`. (The build and test scripts are the opposite — see §6.)

It also never enables `nounset`, so `[[ -n ${VAR:-} ]]` style guards are used at boundaries where a
variable may not have been declared yet:

```bash
# src/90-main.sh:199
if [[ ${REPAIR_TRANSACTION_FINALIZING:-0} -eq 1 ]]; then
```

**Consequence:** every failure must be handled explicitly. A command that fails without a guard
silently continues, and the script will happily proceed with an empty variable. This is why the
codebase is saturated with `|| return 1`.

---

## 3. Error propagation — the three-idiom rule

Choose the idiom by intent, not by habit:

| Idiom | Meaning | Example site |
|-------|---------|--------------|
| `cmd \|\| return 1` | This failure invalidates the operation. Abort and let the caller decide. | `src/00-bootstrap.sh:143` |
| `cmd \|\| true` | Best-effort. The operation continues and the failure is not actionable here. | `src/40-service.sh:389` |
| `if ! cmd; then … fi` | You need to emit a message, clean up, or branch on the failure. | `src/30-server-config.sh:118-122` |

Inside a function whose result is a boolean, **plain `return 1` on the failing branch** — do not
print. Validators and predicates stay silent:

```bash
# src/40-service.sh:2-10
managed_path_is_trusted(){
  local path=$1 expected_owner owner mode
  [[ -e $path && ! -L $path ]] || return 1
  ...
}
```

Returning a tag from a predicate (`red "…"`) instead of a status is the single most likely way to
break the management flows.

---

## 4. Exit codes carry meaning beyond 0/1

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | Failure; state is unchanged or was successfully restored. |
| `2` | **Failure and automatic rollback also failed** — the user must intervene manually. |
| `75` | (embedded cron programs only) `EX_TEMPFAIL`, lock contention — retry later. |

`commit_config` is the reference implementation (`src/40-service.sh:435-472`): it returns `1` after a
successful rollback (`已恢复修改前的配置和服务`) and `2` when the rollback itself failed
(`自动回滚失败！请立即检查服务；原配置备份保留在 $backup`).

Callers must preserve that distinction, and must capture `$?` **immediately** after the condition:

```bash
# src/70-management.sh:44-54
if commit_config "$candidate"; then
  :
else
  commit_status=$?
  if [[ $commit_status -eq 2 ]]; then
    red "证书切换失败且自动回滚失败，请立即检查服务和配置备份"
    return 2
  fi
  red "证书切换失败，原配置未修改或已恢复"
  return 1
fi
```

Collapsing `2` into `1` loses the "manual intervention required" signal that the repair and
management flows depend on.

---

## 5. Quoting, expansions, and argument hygiene

- **Always quote expansions**: `"$candidate"`, `"${arr[@]}"`, `"$SB_DIR/…"`. Unquoted `$var`
  outside `((…))` or a `[[ … ]]` pattern is essentially absent from the codebase.
- **Pass `--` before paths** so a leading-dash name can never be read as a flag:
  `rm -f -- "$candidate"`, `mv -fT -- "$candidate" "$destination"`, `cp -p -- "$source" "$candidate"`.
- **Force base 10 in arithmetic.** Values that look numeric (ports, octets, version components) get
  the `10#` prefix so `08` is not parsed as an invalid octal:
  ```bash
  # src/20-ports.sh:5
    ((10#$value >= minimum && 10#$value <= 65535))
  # src/00-bootstrap.sh:102
      ((10#$octet <= 255)) || return 1
  ```
- **`[[ ]]` only.** Single-bracket `[ ]` never appears (0 occurrences vs 548 `[[ ]]`).
- **Arrays**: declare with `local -a name` or `local -a name=()`; never `declare`/`typeset`.

```bash
# src/00-bootstrap.sh:108
  local -a groups
```

- **Read lines with `mapfile`**, not a `while read` pipeline, when order and completeness matter:
  ```bash
  # src/00-bootstrap.sh:152
    mapfile -t ip_cache < "$cache_file" 2>/dev/null || return 1
  ```

---

## 6. `local` and variable scope

Declare at the top of the function, several per line, with defaults inline:

```bash
# src/70-management.sh:22
  local cert=$1 key=$2 candidate commit_status
# src/00-bootstrap.sh:197
  local sbcore="$CORE_VERSION" sbname temp_dir archive expected_sha256 actual_sha256
```

- Defaults use the `${2:-…}` form: `local value=$1 minimum=${2:-1}` (`src/20-ports.sh:3`).
- Names are lowercase with underscores: `extension option`, `local -a ss_args`.
- Variables that intentionally persist across calls are **not** declared here; they are the globals
  listed in `src/00-bootstrap.sh:41-50`. Anything a function needs to hand to another function goes
  through a global; only truly call-local state uses `local`.

The build and test scripts are the exception to §2 and use strict mode:

```bash
# scripts/build.sh:2
set -Eeuo pipefail
```

Match that when you write in `scripts/` or `tests/`, and match the unset-options style when you
write in `src/`.

---

## 7. Command invocation

- Suppress noise on probes, not on real work: `stat -c '%u' "$path" 2>/dev/null` is expected;
  suppressing stderr on the command whose error the user must see is not.
- Where a diagnostic matters, print it a second time without suppression so the user sees the
  reason (`src/30-server-config.sh:124-127`, `src/40-service.sh:425-430`).
- Prefer `command -v X >/dev/null 2>&1` for capability checks:
  ```bash
  # src/40-service.sh:181
    if command -v apk >/dev/null 2>&1; then
  ```
- Use `$SB_BIN`, `$SB_CONFIG`, … constants rather than re-typing `/etc/sb/...` paths.

---

## 8. Output commands

| Command | When |
|---------|------|
| `printf '%s\n' "$value"` | Writing data or a formatted line. Preferred (123 uses). |
| `red`/`green`/`yellow`/`blue` | Any user-facing message. See `user-output.md`. |
| `echo` (bare) | Blank-line spacing only — 34 of them. |
| `echo -e "…\e[…"` | Only inside the color helpers and the ASCII banner. |

Do not reach for `echo -e` to color a message; call the helper.

---

## Common mistakes

- Writing `if [ … ]` out of habit — the codebase has none; use `[[ … ]]`.
- Adding `set -euo pipefail` to a `src/` module — it changes global behaviour for the whole
  concatenated script and will change control flow in code that relies on unguarded commands.
- Losing the `1` vs `2` distinction from `commit_config`, so the user is told "已恢复" when the
  rollback actually failed.
- Forgetting `10#` on a user-supplied number, so `08` errors out as invalid octal.
- `return 1` without quoting `"$1"` — an argument with spaces silently splits.
