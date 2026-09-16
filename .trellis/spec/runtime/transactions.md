# Transactions, Signals & Recovery

The script performs two long, interruptible, system-mutating operations: **install** and **repair**.
They use different transaction models on purpose, and they must never be conflated.

---

## 1. Two transactions, two contracts

| | Install | Repair |
|--|---------|--------|
| Flag | `INSTALL_TRANSACTION_ACTIVE` | `REPAIR_TRANSACTION_ACTIVE` (+ per-artifact flags) |
| On abort | Full cleanup — removes everything this install created | **Restore** the pre-repair stack |
| Touches `/etc/sb` on failure | Yes — removes it if this run created it | **Never deletes `/etc/sb`** |
| Terminators | `cleanup_install_transaction` (`src/80-lifecycle.sh:91`) | `abort_repair_transaction` (`src/85-repair.sh:613`), `commit_repair_transaction` (`:641`) |

Flags are declared as globals in `src/00-bootstrap.sh:42-52`; all reads use the `${VAR:-0}` form
because the module may run before the variable is set in a test harness.

---

## 2. Install transaction

Opened only after every precondition refusal has passed:

```bash
# src/90-main.sh:27-35 (abridged)
  INSTALL_TRANSACTION_ACTIVE=1
  prepare_managed_directory || { abort_install_transaction; return 1; }
  if [[ ! -f $SB_DIR/.deps_ok ]] || ! dependencies_ready; then
    install_dependencies || { abort_install_transaction; return 1; }
  fi
  v6only
  inssb || { abort_install_transaction; return 1; }
  inscertificate || { abort_install_transaction; return 1; }
  insport || { abort_install_transaction; return 1; }
```

Rules:

- **Every hard step uses `cmd || { abort_install_transaction; return 1; }`.** Failures before the
  transaction opens (service-name conflict, already installed, incomplete data present) simply
  `return 1` without cleanup — those refusals are at `src/90-main.sh:5-26` and must stay first.
- **Cosmetic steps do not abort.** Non-critical failures are downgraded:
  ```bash
  # src/90-main.sh:46
    save_last_good_config "$SB_CONFIG" || yellow "安装已完成，但最后可用配置快照保存失败"
  ```
- **Success clears the flag without cleaning** (`src/90-main.sh:81`).
- `cleanup_install_transaction` clears the flag **before** doing the work, which is what makes it
  idempotent and safe under re-entry:
  ```bash
  # src/80-lifecycle.sh:91-95
  cleanup_install_transaction(){
    [[ ${INSTALL_TRANSACTION_ACTIVE:-0} -eq 1 ]] || return 0
    INSTALL_TRANSACTION_ACTIVE=0
    cleanup_incomplete_install
  }
  ```
- `abort_install_transaction` always **returns 1** and reports two distinct outcomes — cleaned, or
  cleanup incomplete:
  ```bash
  # src/80-lifecycle.sh:97-104
  abort_install_transaction(){
    red "安装未完成，正在清理本次安装产生的文件和服务……"
    if cleanup_install_transaction; then
      green "本次安装残留已清理"
    else
      red "自动清理未完整完成，请检查上方错误后再使用菜单[2]修复"
    fi
    return 1
  }
  ```

---

## 3. Repair transaction

Repair opens with a rollback point and records **per-artifact** change flags:

```bash
# src/85-repair.sh:417-421 (abridged)
begin_repair_transaction(){
  local backup service_path service_mode
  REPAIR_TRANSACTION_ACTIVE=1
  ... preserve_config_before_repair ... backup core ... backup unit ...
```

- `REPAIR_CORE_REPLACED`, `REPAIR_CONFIG_CHANGED`, `REPAIR_SERVICE_CHANGED` are set **before** the
  corresponding mutation, with an explicit comment at `src/85-repair.sh:183-185` explaining why: an
  interrupt must not be able to land between `mv(1)` and the rollback-state update.
- `REPAIR_ORIGINAL_STACK_VALID` records whether the saved state is actually usable: all backups
  present **and** the service active **and** the backed-up core able to validate the backed-up
  config. If not, rollback is marked `not_available` rather than attempted
  (`src/85-repair.sh:617-626`).

Both terminators raise `REPAIR_TRANSACTION_FINALIZING=1` first, then clear both flags:

```bash
# src/85-repair.sh:613-639 (abridged)
abort_repair_transaction(){
  local status=0
  [[ ${REPAIR_TRANSACTION_ACTIVE:-0} -eq 1 ]] || return 0
  REPAIR_TRANSACTION_FINALIZING=1
  if [[ ${REPAIR_CORE_REPLACED:-0} -eq 1 || ... ]]; then
    if [[ ${REPAIR_ORIGINAL_STACK_VALID:-0} -eq 1 ]]; then
      restore_original_repair_stack || status=1
    else
      REPAIR_ROLLBACK_STATE=not_available
    fi
  else
    REPAIR_ROLLBACK_STATE=not_needed
  fi
  ... drop backups only if original_restored ...
  cleanup_repair_temporary_files || status=1
  REPAIR_TRANSACTION_ACTIVE=0
  REPAIR_TRANSACTION_FINALIZING=0
  return "$status"
}
```

`commit_repair_transaction` deletes the recovery points, cleans temporaries, **still disarms the
transaction** if cleanup fails, and returns non-zero to report it (`src/85-repair.sh:641-655`).

Repair never lets a cosmetic failure abort a healthy core: maintenance failures set
`maintenance_failed=1`, the report is printed before every early return, and the function returns 0
only when nothing failed.

---

## 4. Signal handling

One trap, installed once, in the entrypoint module:

```bash
# src/90-main.sh:205
trap handle_install_interrupt INT TERM HUP
```

The handler's order is fixed and load-bearing:

```bash
# src/90-main.sh:174-204 (structure)
handle_install_interrupt(){
  if [[ ${REPAIR_TRANSACTION_FINALIZING:-0} -eq 1 ]]; then
    return 0                      # (a) finalization in progress → swallow
  fi
  trap '' INT TERM HUP            # (b) make re-entry structurally impossible
  echo
  if [[ ${REPAIR_TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
    ... abort_repair_transaction ...
  elif [[ ${INSTALL_TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
    clear_acme_state_backup >/dev/null 2>&1 || true
    abort_install_transaction || true
  elif [[ -n ${ACME_STATE_BACKUP:-} &&
          ${ACME_INFLIGHT_BACKUP:-} == "${ACME_STATE_BACKUP:-}" ]]; then
    ... restore_acme_state_backup, maybe reactivate the old certificate ...
  fi
  cleanup_core_download_temp >/dev/null 2>&1 || true
  exit 130
}
```

Requirements:

- **(a) before (b)** — the finalizing check must precede disabling the trap, or a signal arriving
  during commit would trigger a second rollback.
- **(b) `trap ''` is the re-entrancy guard.** After it, a second signal cannot re-enter the handler.
- **Exit status is 130** for interrupt-initiated exits. `tests/repair.sh:390` asserts this.
- Cleanup of transient download state happens last and is best-effort.
- **There is no EXIT trap in the main script.** Only the generated ACME deploy child has one
  (`src/10-acme.sh:481-482`).

### Ordering requirement

The trap is installed **before** any pre-flight work, so that `prepare_runtime_state` — which creates
the managed directory and can enter the ACME recovery-point flow — can never run unguarded:

```bash
# src/90-main.sh — after the `# sb-entrypoint` marker
handle_install_interrupt(){ ... }
trap handle_install_interrupt INT TERM HUP
prepare_runtime_state || exit 1
```

If you add work to the entrypoint, add it **after** the trap. All flags the handler reads are
initialized in `src/00-bootstrap.sh`, so the handler is safe to install at the earliest point.

---

## 5. Backups of pre-existing state

All repair backups are hidden `mktemp` files **inside** `$SB_DIR`, named
`<subsystem>-<artifact>`:

| Path | Purpose |
|------|---------|
| `.repair-core-backup.XXXXXX` | previous core binary |
| `.repair-service-backup.XXXXXX` | previous unit file (original mode recorded separately) |
| `.sb.json.before-repair.XXXXXX` | config as it was before repair |
| `.sb.json.backup.XXXXXX` | per-commit config backup (`commit_config`) |
| `.acme-backup.XXXXXX/` | ACME recovery point (directory, 700) |

Never `/tmp`, never adjacent to the original. The original mode is recorded and re-applied with
`install -m` to a fresh temp followed by `mv -fT`; restoring a unit is followed by
`systemctl daemon-reload`.

Before touching live paths, the restored pair is re-validated in a scratch copy, and the **current**
(post-repair) state is snapshotted first so the newest working copy is never destroyed.

---

## 6. Last-good config

```bash
# src/00-bootstrap.sh:18
SB_LAST_GOOD="$SB_DIR/sb.json.last-good"
```

Written **only** from a config that passes the full gate (non-empty, trusted file, current core,
`check` passes), atomically, and only after the service is confirmed running on it:

```bash
# src/40-service.sh:518-520
  if restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rm -f "$backup"
    save_last_good_config "$SB_CONFIG" || yellow "配置已生效，但最后可用配置快照更新失败"
```

A failure to refresh it is a warning, never a rollback trigger. Repair's restore priority is:
live config → last-good (skipped when it equals the live config) → reserved backups newest-first.
The file counts as install data (`managed_install_data_present`, `src/40-service.sh:418-422`), and is
exempt from the temporary-file sweep.

---

## 7. Rebuild: last resort, explicitly confirmed

Repair reaches the rebuild path only after the live config, last-good, and every reserved backup have
all failed to yield a usable parameter set. It requires the user to type the literal word `REBUILD`:

```bash
# src/85-repair.sh:271-274 (structure)
  ... announce the consequence BEFORE prompting ...
  [[ $confirmation == REBUILD ]] || return 1
```

It regenerates **in place**: it never deletes `/etc/sb`, never deletes ACME state, and preserves
certificates. `REPAIR_NODE_REBUILT=1` makes the final report warn that client configurations must be
re-issued. A cancelled or failed rebuild leaves the original data intact.

---

## 8. Uninstall

Fixed order, each step gating the next: service → managed crons → `rm -rf $SB_DIR` → owned shortcut.
A failure aborts and states what was kept. It refuses up front on a foreign service-name conflict or
unprovable `$SB_DIR` ownership — before any prompt, stop, or delete — and is serialised under the
ACME lock. If `flock` is missing while ACME renewal state exists, it refuses entirely.

Deliberately **untouched**: legacy or other sing-box installs, installed packages, and foreign
crontab lines (only marker-matching lines are filtered).

---

## Common mistakes

- Aborting an install step without calling `abort_install_transaction` — leaves a half-installed
  system behind.
- Making repair delete `/etc/sb`; that is install-transaction behaviour, and `tests/repair.sh:773-776`
  fails the build if it reappears.
- Setting a `REPAIR_*_CHANGED` flag *after* the mutation — an interrupt in between leaves the
  transaction believing nothing needs rolling back.
- Reordering the signal handler so `trap ''` runs before the `FINALIZING` check.
- Attempting a rollback when `REPAIR_ORIGINAL_STACK_VALID` is 0 instead of reporting
  `not_available`.
- Performing a `REBUILD` without the typed confirmation, or deleting the user's data on a failed
  rebuild.
- Treating a failed last-good refresh as a reason to roll back a working configuration.
