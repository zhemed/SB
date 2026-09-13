# Module Structure & Code Placement

## 1. Module ownership map

Each module owns a domain. Place new code in the module that already owns that domain rather than
the one that is "closest" to the call site.

| Module | Owns |
|--------|------|
| `src/00-bootstrap.sh` | Constants and global declarations, `LANG`/`umask` preamble, root + OS + architecture guards, color helpers, `readp`, IP validation & detection, sing-box core download (`inssb`) |
| `src/10-acme.sh` | Certificate metadata/validation, acme.sh install + Cloudflare DNS API, managed link installation, certificate deployment generations, the `ACMERELOAD` hook, self-signed fallback (`SELFSIGN`) |
| `src/20-ports.sh` | All `valid_*` validators, port conflict detection and selection, credential generation |
| `src/30-server-config.sh` | Server-side `sb.json` rendering and its install-time candidate validation |
| `src/40-service.sh` | Managed-path trust checks, atomic private writers, systemd/OpenRC unit rendering + ownership, `commit_config`, last-good config, service start/stop/state |
| `src/50-client-output.sh` | Share links (VLESS / Hysteria2 / SOCKS5) and generated client files `sbox.json` / `clash.yaml` |
| `src/60-cron.sh` | Crontab marker management, the `ACMERENEW` renewal runner, daily restart task, `with_acme_lock` |
| `src/70-management.sh` | Management menus 4–8: certificate mode, SNI, ports, credentials, IP priority |
| `src/80-lifecycle.sh` | Dependency installation, `/usr/bin/sb` shortcut, `prepare_runtime_state`, uninstall |
| `src/85-repair.sh` | Diagnosis and the repair transaction |
| `src/90-main.sh` | Install flow, main menu, interrupt trap, the entrypoint |

Practical consequences:

- A **new validator** goes in `src/20-ports.sh` — even hostname/IP-ish ones, unless it is an IP
  literal check, which lives in `src/00-bootstrap.sh`. Keep the `valid_*` family together.
- A **new protocol** is a cross-module change: port selection (`20`), server config (`30`), client
  output (`50`), management menu (`70`), and often pinned assertions in `tests/verify.sh`.
- A **new user-facing mutation** of an installed node belongs in `src/70-management.sh` and must go
  through the candidate → validate → `commit_config` path. See `spec/runtime/atomic-writes.md`.
- A **new shared helper** goes in `src/00-bootstrap.sh` if it is generic, or `src/40-service.sh` if
  it touches the managed directory. There is no `source`, so a helper can live in any module that
  is concatenated; correctness only requires that the definition is *executed* before first call,
  which the module order guarantees.

## 2. Top-level code is restricted to two modules

Verified across all 11 modules: only `src/00-bootstrap.sh` and `src/90-main.sh` contain top-level
executable statements that run in the main process.

**`src/00-bootstrap.sh` — the preamble.** Environment, constants, global state, and hard guards that
must run before anything else:

```bash
# src/00-bootstrap.sh:5-6
export LANG=en_US.UTF-8
umask 077
```

```bash
# src/00-bootstrap.sh:71-74
if [[ $EUID -ne 0 ]]; then
  yellow "请以root模式运行脚本"
  exit 1
fi
```

**`src/90-main.sh` — the entrypoint.** Everything after the `# sb-entrypoint` marker. The order is
fixed: define the handler, install the trap, then do any pre-flight work.

```bash
# src/90-main.sh:198
handle_install_interrupt(){
...
# src/90-main.sh:229
trap handle_install_interrupt INT TERM HUP

# Install the trap first: prepare_runtime_state can create the managed
# directory and resolve ACME recovery points, so it must not run unguarded.
prepare_runtime_state || exit 1
```

The final `menu` call is the last statement in the file (`src/90-main.sh:241`). See
`spec/runtime/transactions.md` §4 for why the trap must precede the pre-flight work.

**Every other module contains function definitions only.** No stray `echo`, no module-level
variable assignments, no `if` blocks at column 0. This is what makes concatenation order safe: by
the time `menu` runs, all 234 functions exist.

Global variables that persist across calls are therefore declared **only** in `00-bootstrap.sh`:

```bash
# src/00-bootstrap.sh:41-50
INSTALL_TRANSACTION_ACTIVE=0
...
REPAIR_TRANSACTION_ACTIVE=0
REPAIR_TRANSACTION_FINALIZING=0
```

## 3. Embedded helper scripts (heredoc-delivered programs)

Three places embed a **complete, independent Bash program** inside a heredoc. They are written to
disk and executed as separate processes — usually by cron or by acme.sh.

| Program | Location | Run by |
|---------|----------|--------|
| `ACMERELOAD` | `src/10-acme.sh:359-750` | acme.sh reload hook after a renewal |
| `SELFSIGN` | `src/10-acme.sh:1380-1391` | self-signed fallback config |
| `ACMERENEW` | `src/60-cron.sh:300-425` | root crontab |

Rules that follow from this design:

**(a) Use a quoted delimiter — always.** `cat > "$hook_tmp" <<'ACMERELOAD'`. Quoting suppresses
expansion so the body is delivered verbatim and stays self-contained. A quoted delimiter plus
single-quoted content is why these bodies can define their own helpers named like main-script
helpers without colliding at runtime.

**(b) The terminator must sit at column 0.** `ACMERELOAD`, `ACMERENEW`, `SELFSIGN` each appear alone
on a line with no indentation, even though the `cat` command itself is indented:

```bash
# src/60-cron.sh:300 — opener is indented...
    cat <<'ACMERENEW'
# src/60-cron.sh:425 — ...terminator is not
ACMERENEW
```

**(c) Embedded programs are independently executed, so they use `exit`, not `return`**, and they
carry their own traps:

```bash
# src/10-acme.sh:481-482
trap cleanup_deploy_files EXIT
trap handle_deploy_signal HUP INT TERM
```

```bash
# src/10-acme.sh:459-463
handle_deploy_signal(){
  trap '' HUP INT TERM
  rollback_deployment || true
  exit 1
}
```

**(d) Embedded programs encode failure in distinct exit codes.** `ACMERENEW` reuses meaningful
statuses so the caller can distinguish causes:

```bash
# src/60-cron.sh:335-336 — usage error
  1) [[ ${1-} == --force ]] || exit 2; force=1 ;;
  *) exit 2 ;;
# src/60-cron.sh:348-351 — lock contention
if ! flock -w 10 9; then
  exec 9>&-
  exit 75
fi
```

`exit 75` is `EX_TEMPFAIL` — "try again later", not a failure to alarm on.

**(e) Function names must be globally unique across the entire concatenated file**, including names
defined inside heredoc bodies. `scripts/build.sh:151-153` collects every line matching
`^name(){` in the assembled candidate and fails on duplicates — it does not understand heredocs.
So a helper inside `ACMERENEW` (e.g. `valid_acme_identity`, `certificate_fingerprint`,
`read_runner_acme_identity`) may not share a name with any main-script function.

**(f) Validate the environment at the top of the embedded program.** These run unattended from
cron, where the working directory and environment are not what you expect:

```bash
# src/60-cron.sh:338-342
for candidate in "$lock_file" "$compat_lock_file"; do
  if [[ -e $candidate || -L $candidate ]]; then
    [[ -f $candidate && ! -L $candidate ]] || exit 1
  fi
done
```

## 4. Adding a new module

Only do this when you are adding a genuinely new domain. Checklist:

1. Create `src/NN-name.sh` with `# sb-module: NN-name` as line 1 (and nothing else before it).
2. Insert `"NN-name.sh"` into `MODULES` in `scripts/build.sh:17-29`, in the same numeric position.
3. Keep the file function-definitions-only.
4. `bash scripts/build.sh && bash tests/verify.sh`.
5. If the module is not the last one, it must not contain `# sb-entrypoint`.

## Common mistakes

- Adding a helper to `40-service.sh` because the call site is there, when it belongs to
  `00-bootstrap.sh` — helpers end up in the wrong domain and get duplicated later.
- Putting a top-level statement (a log line, a variable assignment) in the middle of a module — it
  now executes during concatenation-order load, before guards and before the trap is installed.
- Using `cat <<EOF` (unquoted) for an embedded script — variables in the body get expanded at write
  time and the delivered program is corrupted.
- Indenting the heredoc terminator to match the surrounding code — the heredoc never terminates and
  the build breaks or the script swallows the rest of the module.
- Defining `cleanup()` inside an embedded heredoc when a `cleanup()` already exists in the main
  script — the build fails with `duplicate function definitions`.
