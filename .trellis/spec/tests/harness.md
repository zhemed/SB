# Test Harness

Sources: `tests/verify.sh` (246 lines), `tests/unit.sh` (1623), `tests/repair.sh` (747).

---

## 1. Output protocol (TAP)

`verify.sh` is assertion-only and fail-fast with its own `fail()`:

```bash
# tests/verify.sh:15-17
fail(){
  printf 'verify: %s\n' "$1" >&2
  exit 1
}
```

`unit.sh` and `repair.sh` emit TAP. Progress only through `pass` / `skip`; failure prints
`not ok` on **stderr** and exits immediately:

```bash
# tests/unit.sh:22-29
pass(){
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$passed" "$1"
}

fail(){
  printf 'not ok %d - %s\n' "$((passed + 1))" "$1" >&2
  exit 1
}
```

- The counter increments **only on success**, so `passed + 1` is the correct number for the failing
  test. This off-by-one is deliberate.
- **Never hardcode the plan.** `1..N` is emitted as the last line, derived from the counter:
  ```bash
  # tests/unit.sh:1623
  printf '1..%d\n' "$passed"
  ```
  Adding a test requires no count edit.
- Cases are declared through wrappers so `set -e` cannot abort the runner silently:
  ```bash
  # tests/unit.sh:32-42
  expect_success(){
    local name=$1
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
  }

  expect_failure(){
    local name=$1
    shift
    if "$@"; then fail "$name"; else pass "$name"; fi
  }
  ```
  Extra arguments are forwarded, which is how parameterised cases work — e.g. the three signal tests
  pass `INT` / `TERM` / `HUP` (`tests/repair.sh:670-675`).

### Always test the negative half too

An `expect_failure` proves only that the operation refused. Give the accompanying "nothing was
damaged" claim its own named assertion:

```bash
# tests/unit.sh:525-528
expect_failure "ACME cron setup rejects an inactive daemon" setup_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "inactive daemon changed existing cron"
pass "inactive daemon preserves existing cron"
```

The standard tools for this are a sha256 before/after (`tests/unit.sh:523`), `cmp -s --` for byte
identity (`tests/repair.sh:411-412`), and a `compgen -G` sweep for leftover temp files
(`tests/unit.sh:229-232`).

### Platform-gated cases must still emit a line

`repair.sh` has `skip` (`tests/repair.sh:15`). `unit.sh` keeps the plan platform-invariant by
emitting paired placeholder passes inside the `else` branch (`tests/unit.sh:827-831`). Either way,
the plan line's count never depends on the platform.

### Keep product output out of the TAP stream

```bash
# tests/unit.sh:219-221
write_acme_identity_quiet(){
  write_acme_identity "$@" 2>/dev/null
```

Also `tests/repair.sh:221` (`repair_singbox >/dev/null 2>&1`) and `tests/unit.sh:1589`
(`( uninstall >/dev/null )`).

---

## 2. Sandboxing — no root, no host writes

Every test file starts the same way:

```bash
# tests/unit.sh:6-9
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
readonly ROOT_DIR TEMP_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT
```

Then **every production absolute path is re-pointed under `$TEMP_DIR`** before the first writing
test:

```bash
# tests/unit.sh:185-190
STATE_DIR="$TEMP_DIR/state"
export SB_DIR="$STATE_DIR/sb"
export SB_CONFIG="$SB_DIR/sb.json"
```

covered set: `SB_DIR`, `SB_CONFIG`, `SB_LAST_GOOD`, `SB_BIN`, `SB_MANAGED_MARKER`, `SHORTCUT`,
`SYSTEMD_UNIT`, `OPENRC_UNIT`, all `ACME_*`, `ACME_LOCK`. See `tests/unit.sh:66-76`, `185-190`,
`1324-1326`, `1433-1438`; `tests/repair.sh:448-471`.

There is **no `sudo` anywhere in `tests/`**. The only literal real-world paths are fixture *text*
(the marker file content at `tests/repair.sh:262`) and the deliberate `/etc/sb` → sandbox rewrite at
`tests/unit.sh:885`.

Complex cases get their own sub-directory and re-declare paths inside a subshell
(`tests/repair.sh:37-41`, `353-370`; `tests/unit.sh:1599-1602`).

Fixtures are built locally with `openssl` / `jq` into `$TEMP_DIR` — the suite never reaches the
network (`tests/unit.sh:347-351`, `430-433`; `tests/repair.sh:567-572`).

Case functions must leave shared fixtures usable: restore or remove what they perturb
(`tests/repair.sh:70-71`; `tests/unit.sh:233-234`).

---

## 3. Loading product code

**Source only definition-only modules**, each with a `shellcheck source=/dev/null` pragma:

```bash
# tests/unit.sh:44-46
# Production concatenates these files. Tests may source definition-only modules.
# shellcheck source=/dev/null
source "$ROOT_DIR/src/20-ports.sh"
```

`unit.sh` sources `20`, `10`, `60`, `80`, `70`; `repair.sh` sources `10`, `20`, `30`, `40`, `50`, `85`.
Order is arbitrary precisely because those modules contain function definitions only — the rule from
`spec/shell/module-structure.md` §2.

**Never source `src/00-bootstrap.sh` or `src/90-main.sh`** — they execute top-level code. Extract the
one function you need and source the extraction inside a subshell:

```bash
# tests/repair.sh:322-325 (abridged)
awk '
  /^handle_install_interrupt\(\)\{/ { inside=1 }
  ...
' "$ROOT_DIR/src/90-main.sh" > "$handler_file" || return 1
```

**Guard every extraction:**
```bash
# tests/verify.sh:115
[[ -n $uuid_function ]] || fail "cannot extract UUID management function"
```
Without the guard, a failed extraction makes later negative greps pass **vacuously**.

Hand-write bootstrap-only collaborators with a comment explaining why the test supplies them
(`tests/unit.sh:56-62`).

`sb.sh` itself is **never executed** — only `bash -n`, `grep`, and `awk` (`tests/verify.sh:21`).

---

## 4. Mocking

**Function shadowing is the primary mechanism**, not `PATH`:

```bash
# tests/unit.sh:487-489
crontab(){
  case ${1-} in
    -l)
```

Examples: `ss` (`tests/unit.sh:166`), `readp` (`:1247`), `jq` (`:1274`), `commit_config` (`:1316`),
`stat` (`tests/repair.sh:24`). Behaviour is driven by `MOCK_*` knobs.

Hostile conditions are **fabricated**, not created with privileges — e.g. a foreign owner is faked by
a `stat` mock returning `$(id -u) + 1` (`tests/repair.sh:25-27`), and a missing `flock` is simulated by
mocking `command` (`tests/unit.sh:1540-1545`).

**`unset -f` every mock immediately after the case** (`tests/unit.sh:631`, `1119`, `1199`, `1579`).

`PATH` shims are used only for a genuinely absent binary, in a private `test-bin`, with capability
recorded in `TEST_HAS_*`:

```bash
# tests/unit.sh:11-17
TEST_HAS_SYSTEM_FLOCK=1
if ! command -v flock >/dev/null 2>&1; then
  TEST_HAS_SYSTEM_FLOCK=0
  mkdir -p "$TEMP_DIR/test-bin"
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEMP_DIR/test-bin/flock"
  chmod 700 "$TEMP_DIR/test-bin/flock"
  export PATH="$TEMP_DIR/test-bin:$PATH"
fi
```

---

## 5. Signal and rollback testing

Test signals by extracting the **real** handler, installing it in a subshell, and signalling the
subshell:

```bash
# tests/repair.sh:382-383
  trap handle_install_interrupt INT TERM HUP
  kill -s "$signal" "$BASHPID"
```

- Parameterise over `INT` / `TERM` / `HUP` as three separately named tests
  (`tests/repair.sh:670-675`).
- Assert the exact exit status **130**, and make control unable to continue past the kill
  (`exit 92` at `tests/repair.sh:404`, asserted at `:410`).
- Drive the interrupt point deterministically by patching the extracted copy behind a sentinel file
  — never by racing (`tests/unit.sh:934-938`, `960-964`; sentinels cleaned at `949`, `975`).
- Assert finalization swallows the interrupt, proving no double rollback
  (`tests/repair.sh:327-331`).
- After an interrupt, assert full restoration (`cmp -s --`) and enumerate the temp patterns that must
  not survive (`tests/repair.sh:411-418`).

---

## 6. Style (shared with the product, except for strict mode)

- `#!/usr/bin/env bash`, then `set -Eeuo pipefail`, then `export LC_ALL=C`
  (`tests/unit.sh:1-4`). **Opposite of `src/`**, which sets no options — see
  `spec/shell/bash-conventions.md` §2.
- `ROOT_DIR` derived from `BASH_SOURCE`, marked `readonly`.
- `local` in every helper; shared state as documented `UPPER_CASE` globals; `TEST_HAS_*` capability
  flags; `MOCK_*` scenario knobs; verb-phrase `snake_case` case functions.
- Write files with `printf '%s\n'`, never `echo`; fixed-length fixtures via
  `printf 'a%.0s' {1..64}` (`tests/unit.sh:687`).
- `[[ ]]` over `[ ]`; `--` after `grep -F`, `rm`, `cp`, `ln`; `$(...)` over backticks.
- `|| true` inside `$( ... )` when a non-zero `grep` is legitimate under `set -e`
  (`tests/verify.sh:27`).
- Reason-bearing shellcheck pragmas when shadowing a product function or quoting literal `$VAR`
  fixture text (`tests/unit.sh:60-61`, `145-146`).

---

## Common mistakes

- Hardcoding a test count — the plan line is derived.
- Sourcing `src/00-bootstrap.sh` or `src/90-main.sh`, which executes `umask`, root checks, and the
  entrypoint.
- Forgetting the `[[ -n $extracted ]] || fail` guard, producing a vacuous pass.
- Leaving a function mock installed, breaking every later case in the file.
- Writing anything outside `$TEMP_DIR`, or requiring root.
- Asserting "it failed" without asserting what survived.
- Running `bash tests/unit.sh` directly against a stale `sb.sh` instead of using the gate.
