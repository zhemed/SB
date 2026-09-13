# Installed Runtime Layer

> What the script must guarantee on a target host: filesystem layout, ownership proof, atomic
> publication, service management, certificate deployment, and transaction rollback.

This layer is about **invariants**, not syntax. `spec/shell/` tells you how to write code; this layer
tells you what the code must not break. Most of these rules exist because the script mutates a
**live, running** service on a machine the user cannot easily debug.

## When to read this layer

- You are adding any code that writes to `/etc/sb`, `/etc/systemd/system`, `/etc/init.d`, `crontab`,
  or `/usr/bin/sb`.
- You are changing service start/stop/reload behaviour.
- You are changing anything in the certificate path.
- You are adding a step to the install or repair flow.

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [managed-assets.md](./managed-assets.md) | `/etc/sb` layout, marker files, ownership proofs, permissions, foreign-asset refusal |
| [atomic-writes.md](./atomic-writes.md) | The candidate → validate → `mv -fT` protocol for every file and symlink |
| [service-management.md](./service-management.md) | systemd/OpenRC duality, unit ownership, start/verify/cleanup |
| [certificates.md](./certificates.md) | ACME staging, generation switching, the reload hook, locks |
| [transactions.md](./transactions.md) | Install and repair transactions, signal handling, rollback, last-good config |

## The five cross-cutting invariants

1. **No path is touched without proof of ownership.** Three independent proofs exist (directory
   marker, unit marker + exact exec lines, script identity). See `managed-assets.md`.
2. **Every mutation is candidate → validate → `mv -fT` → verify the runtime effect.** There are no
   in-place writes. See `atomic-writes.md`.
3. **Every destructive step is gated on the previous step's verified end state**, never on an exit
   code alone.
4. **Every failure message states what was kept.** See `spec/shell/user-output.md` §4.
5. **Install and repair transactions are never conflated.** Repair never deletes `/etc/sb`;
   install-transaction cleanup does. See `transactions.md` §1.

## Startup guard ordering

The entrypoint installs the interrupt trap **before** any pre-flight work:

```
# src/90-main.sh — after `# sb-entrypoint`
handle_install_interrupt(){ … }
trap handle_install_interrupt INT TERM HUP
prepare_runtime_state || exit 1
```

`prepare_runtime_state` creates the managed directory and can enter the ACME recovery-point flow, so
it must never run unguarded. See `transactions.md` §4.

## Resolved gaps

Both items below were found during the initial spec bootstrap and have since been fixed. They are
kept here as a record of *why* two non-obvious guards exist.

| Was | Now |
|-----|-----|
| `prepare_runtime_state` ran before the trap, so an interrupt during startup was unguarded | Trap is installed first (see above) |
| An interrupt while the script merely *displayed* a discovered recovery point auto-restored and consumed it | The handler restores only a recovery point created by the in-flight operation (`ACME_INFLIGHT_BACKUP`); a discovered orphan is preserved for the next run. See `certificates.md` §8 |
| `.sb.json.rollback.*` sat in the repair temp sweep with no producer | Removed from both the sweep and the test's pattern list |
| A torn `/etc/sb` (interrupt between `mkdir` and the marker rename) made every later run refuse with "不属于本脚本" | `managed_directory_is_incomplete_creation` adopts an empty or marker-temporary-only directory. See `managed-assets.md` §4 |
