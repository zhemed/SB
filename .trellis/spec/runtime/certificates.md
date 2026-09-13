# Certificates & ACME

Certificate deployment is the most safety-critical subsystem: it mutates the live TLS material of a
running service, unattended, from cron. The design exists to make every step reversible.

Primary sources: `src/10-acme.sh` (1494 lines), `src/60-cron.sh` (563), constants in
`src/00-bootstrap.sh:24-40`.

---

## 1. Layout and the single live pointer

```
/etc/sb/
├── acme/                      acme.sh home (700)
│   └── sb-stage/              staging dir (700) — acme.sh writes ONLY here
│       ├── fullchain.pem
│       └── private.key
├── acme-live/
│   ├── generations/
│   │   └── gen.<alnum>/       immutable; fullchain.pem + private.key
│   └── current -> generations/gen.<alnum>          ← THE pointer
├── acme-cert.pem  -> acme-live/current/fullchain.pem
├── acme-private.key -> acme-live/current/private.key
├── acme_server_name           exactly one validated domain line
└── acme_reload.sh             the reload hook (700, executable)
```

Rules:

- `acme-live/current` is the **only** live pointer. Consumers read `acme-cert.pem` /
  `acme-private.key`, which must be **relative** symlinks into it — validated by comparing
  `readlink` output as a literal string:
  ```bash
  # src/10-acme.sh:137-138
    [[ $(readlink "$ACME_CERT" 2>/dev/null) == 'acme-live/current/fullchain.pem' &&
       $(readlink "$ACME_KEY" 2>/dev/null) == 'acme-live/current/private.key' ]] || return 1
  ```
- `current` may only point at a directory named `generations/gen.<alnum>`, re-checked before every
  switch and before any prune:
  ```bash
  # src/10-acme.sh:388
    [[ $target =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 1
  ```
- Layout validation requires real directories where directories belong and symlinks only for
  `current` / cert / key (`src/10-acme.sh:134-144`).
- **Only the reload hook flips the pointer.** In-tree code merely validates it; the sole exception is
  the whole-tree restore in `restore_acme_state_backup`.

---

## 2. acme.sh writes to staging, never to the live path

```bash
# src/00-bootstrap.sh:32-34
ACME_STAGE="$ACME_HOME/sb-stage"
ACME_STAGE_CERT="$ACME_STAGE/fullchain.pem"
ACME_STAGE_KEY="$ACME_STAGE/private.key"
```

```bash
# src/10-acme.sh:843
  --key-file "$ACME_STAGE_KEY" --fullchain-file "$ACME_STAGE_CERT" \
```

Asserted by `tests/verify.sh:219-220` with the message
`acme.sh still writes certificate files outside the staging directory`.

Because the deployment target recorded in acme.sh's own domain conf is the staging path, the live
swap is delegated entirely to `Le_ReloadCmd`. "Deployment config is current" therefore means the
acme.sh state names exactly the stage paths and our reload hook:

```bash
# src/10-acme.sh:195-196
    for key in Le_RealCertPath Le_RealCACertPath Le_RealKeyPath Le_RealFullChainPath Le_ReloadCmd; do
      read_acme_domain_conf_value "$identity" "$key" >/dev/null || return 1
```

The reload command is compared in its **base64-encoded** form, because that is how acme.sh stores it
(`src/10-acme.sh:186-187`).

The stage directory is re-validated before every use, forced to 700, and must not be a symlink
(`src/10-acme.sh:801-810`).

---

## 3. The reload hook

The hook is a **complete, self-contained program** embedded in a quoted heredoc
(`src/10-acme.sh:359-750`), executed by acme.sh as a command after a renewal.

Four hard requirements, all gate-enforced:

**(a) Self-contained.** No main-script variables or functions; paths are hardcoded literals so the
test suite can parameterise them by substitution:

```bash
# src/10-acme.sh:366-370
  base="/etc/sb"
  cert="/etc/sb/acme-cert.pem"
  identity_file="/etc/sb/acme_server_name"
```

(`tests/unit.sh:885` rewrites `/etc/sb` → its sandbox with `sed`, which only works because these are
literals.)

**(b) Extractable by a flat `awk`.** Exactly one line equal to `ACMERELOAD` must exist in the whole
artifact, the opener must be quoted, and the terminator must sit at column 0:

```bash
# scripts/build.sh:159-163
[[ $(grep -Fxc -- 'ACMERELOAD' "$candidate" || true) -eq 1 ]] ||
  fail "ACME reload heredoc terminator is invalid"
hook_candidate=$(mktemp "$TEMP_ROOT/sb-acme-reload.XXXXXX") || fail "cannot create hook candidate"
awk '/<<'\''ACMERELOAD'\''/{inside=1; next} /^ACMERELOAD$/{inside=0} inside' \
  "$candidate" > "$hook_candidate"
```

Repeated on the published artifact by `tests/verify.sh:170-175`. The extracted hook must also pass
`bash -n` standalone.

**(c) Versioned by identity.** `ACME_RELOAD_IDENTITY="# sb-acme-reload-v2"`
(`src/00-bootstrap.sh:38`) appears exactly once inside the hook. Any **semantic** change to the hook
requires bumping this to `v3` and updating the anchor assertions — the identity is what marks an
installed old hook as stale.

**(d) Anchor-pinned.** `acme_reload_hook_is_current` (`src/10-acme.sh:762-796`) verifies the identity
count, the exact 7-line shape of the missing-config bypass, and a list of byte-exact source lines
including their leading whitespace:

```bash
# src/10-acme.sh:790-791
    grep -Fqx '     ! mv -Tf -- "$pointer_tmp" "$base/acme-live/current"; then' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx "     ! install_managed_link \"\$cert\" 'acme-live/current/fullchain.pem'; then" "$ACME_RELOAD" 2>/dev/null &&
```

**Reformatting the hook — re-indenting, reflowing a condition — marks every installed hook stale and
triggers a silent rewrite.** That is intentional, not decorative.

The missing-config bypass must stay provably limited to initial install (asserted by
`tests/verify.sh:176-192`, the exact 7-line block at `src/10-acme.sh:767-783`).

---

## 4. Deployment: validate, then switch

The hook validates the staged material **before any mutation** — parseable, not expired, already
effective, hostname present in the SAN, and the certificate's public key matching the staged private
key:

```bash
# src/10-acme.sh:504-507
  openssl x509 -in "$stage_cert" -noout -checkend 0 >/dev/null 2>&1 || exit 1
  ...
  [[ $not_before_epoch -le $(date +%s) ]] || exit 1
```

```bash
# src/10-acme.sh:518-520
  cert_public=$(openssl x509 -in "$stage_cert" -pubkey -noout 2>/dev/null) || exit 1
  [[ -n "$cert_public" && "$cert_public" == "$key_public" ]] || exit 1
```

(`tests/unit.sh:909-913` asserts an invalid staged cert leaves the active generation unchanged.)

Then it copies into a **new generation** and flips the pointer atomically, and only after a
**verified restart** does it prune superseded generations:

```bash
# src/10-acme.sh:740-745
  if restart_managed_service && sleep 1 && managed_service_active; then
    commit_deployment
    ...
  if rollback_deployment; then
    restart_managed_service >/dev/null 2>&1 || true
```

Critical detail: **a successful rollback still exits non-zero** (`src/10-acme.sh:749`). Never let
"we cleaned up" become "we succeeded".

Never delete the new generation while the pointer may still reference it
(`src/10-acme.sh:435-439`). Prune errors are tolerated (`|| true`) only because pruning is
housekeeping that happens *after* success.

---

## 5. Locking

Every certificate or renewal operation runs under `with_acme_lock`:

```bash
# src/60-cron.sh:83-98 (structure)
with_acme_lock(){
  local owned=0 status
  if [[ ${ACME_LOCK_HELD:-0} -ne 1 ]]; then
    acquire_acme_lock || {
      red "另一个证书或续期操作正在执行，请稍后重试"
      return 1
    }
    owned=1
  fi
  if "$@"; then status=0; else status=$?; fi
  if [[ $owned -eq 1 ]] && ! release_acme_lock; then
    red "释放 ACME 操作锁失败"
    [[ $status -ne 0 ]] || status=1
  fi
  return "$status"
}
```

- **Re-entrant**: an inner call reuses the held lock and does not release it.
- **Preserves the inner exit status**, except that a release failure forces non-zero.

**Lock ordering is fixed and must never be reversed:**

```bash
# src/60-cron.sh:66-67
  # All callers and generated runners acquire the global lock before the v1.8.0 lock.
  exec {ACME_LOCK_FD}> "$lock" || return 1
```

Release is the reverse order: `ACME_COMPAT_LOCK_FD` first, then `ACME_LOCK_FD`
(`src/60-cron.sh:33-51`).

- `ACME_LOCK="/run/sb-acme.lock"` lives **outside** the removable managed directory, so it survives
  uninstall and repair; `ACME_COMPAT_LOCK="$SB_DIR/acme.lock"` preserves v1.8.0 interop. Both facts
  are pinned by `tests/verify.sh:221-226`.
- Acquisition refuses symlink/non-regular lock files, forces 600, and requires `SB_DIR` to be a real
  directory (`src/60-cron.sh:58-63`).
- Timeout differs by caller class: `flock -w 30` for the interactive script
  (`src/60-cron.sh:68`), `flock -w 10` + `exit 75` (`EX_TEMPFAIL`) in the cron runner
  (`src/60-cron.sh:348-350`).
- **When `flock` is unavailable the script refuses to touch ACME state** rather than proceeding
  unprotected (`src/80-lifecycle.sh:39-41`, `304-306`).

Never run concurrently: `acme.sh --issue/--renew/--cron`, any pointer switch or rollback, recovery
point create/restore/discard, ACME crontab rewrite, and certificate activation (which rewrites
`sb.json` and restarts the service).

---

## 6. Managed cron entries

Two managed entries, each owned by an exact marker line:

| Entry | Schedule | Marker |
|-------|----------|--------|
| ACME renewal runner | `17 3,9,15,21 * * *` (`src/60-cron.sh:197`) | `# sb-managed-acme` |
| Daily restart | `0 1 * * *` (`src/80-lifecycle.sh:162-164`) | `# sb-managed-restart` |

Schedules are **constants, not user input**.

Ownership and currency are decided by exact counting — duplicates are as stale as absence:

```bash
# src/60-cron.sh:204-208
  exact_count=$(printf '%s\n' "$content" | grep -Fxc -- "$entry" || true)
  ...
    [[ $exact_count -eq 1 && $marker_count -eq 1 && $runner_count -eq 1 && $direct_count -eq 0 ]] &&
```

Removal filters delete **only** lines matching owned markers or known legacy patterns; every foreign
line survives (`src/60-cron.sh:213-218`), and the result is written back, re-read, and re-verified
(`src/60-cron.sh:457-462`, `527-529`).

Additional guards:

- **Never install a cron entry when the cron daemon is not running** — a task that cannot execute is
  not installed (`src/60-cron.sh:502-504`, `src/80-lifecycle.sh:154-156`).
- **A crontab read failure aborts the operation** — never overwrite a crontab you could not read
  (`src/60-cron.sh:21-22`).
- **If the certificate mode cannot be determined, keep the existing cron and fail loudly**
  (`src/60-cron.sh:559-561`), rather than guessing and interrupting renewals.
- Idempotency is **byte-level**: a current artifact is never rewritten
  (`src/60-cron.sh:286-287`; `tests/unit.sh:1023-1027`).

The generated renewal runner (`ACMERENEW`, `src/60-cron.sh:300-425`) reproduces the lock protocol
with hardcoded descriptors — 9 for the global lock, 8 for the compat lock — and those lines are
pinned byte-exactly by an identity check (`src/60-cron.sh:265-267`). It must never call back into
`sb.sh`.

---

## 7. Secrets

- The Cloudflare API Token is read through the ordinary **visible** `readp`
  (`src/10-acme.sh:1270`); `tests/verify.sh:74-80` fails the build if a hidden read or a
  "hidden input" message is introduced.
- It is passed **only** via the environment and cleared on every exit path — failure first, then
  success (`src/10-acme.sh:1315-1318`, `1324`).
- Alternative credential sources are explicitly neutralised so the script's own token is the only one
  acme.sh can use: `CF_Zone_ID='' CF_Key='' CF_Email=''` (`src/10-acme.sh:1316`).
- The token is **never printed**. Presence is verified by counting matching lines in acme.sh's own
  `account.conf` (`src/10-acme.sh:226-229`). Repo-wide, the only `CF_Token` references are
  `src/10-acme.sh:227` and `:1315`.
- The domain-conf reader **whitelists keys**, so secret-bearing acme.sh variables cannot be surfaced
  through it (`src/10-acme.sh:159-163`).
- Secrets live in 700 directories / 600 files, with the Windows mode-check exception described in
  `managed-assets.md` §5.

---

## 8. Recovery points

Any mutating certificate flow creates a 0700 recovery point first and removes it only after complete
success:

```bash
# src/10-acme.sh:1080-1082
  [[ -z ${ACME_STATE_BACKUP:-} ]] || return 1
  backup=$(mktemp -d "$SB_DIR/.acme-backup.XXXXXX") || return 1
  chmod 700 "$backup" || { rm -rf -- "$backup"; return 1; }
```

Restore is **staged** — materialise into a fresh tree, then replace whole trees — so a mid-restore
failure never leaves a half-state (`src/10-acme.sh:1142-1193`). Only whitelisted state names move to
whitelisted destinations; an unknown entry aborts (`:1130-1168`).

Ambiguity is never auto-resolved: two or more recovery points, an unparsable one, or a malformed one
makes the script refuse and demand manual intervention (`:982-987`, `1009-1011`). It will not delete
the only recovery point while the running configuration still references the ACME certificate
(`:1051-1055`, `1227-1233`).

### Discovered vs in-flight: `ACME_INFLIGHT_BACKUP`

`ACME_STATE_BACKUP` holds two different things, and the interrupt handler must tell them apart:

| Set by | Meaning |
|--------|---------|
| `find_orphaned_acme_state_backup` (`src/10-acme.sh:988`) | A recovery point **discovered at startup** — leftover from a previous run, and the user has not yet chosen what to do with it |
| `begin_acme_state_backup` (`src/10-acme.sh:1117`) | A recovery point **this process just created** for an operation that is about to mutate live state |

The handler restores only the second kind:

```bash
# src/90-main.sh
  elif [[ -n ${ACME_STATE_BACKUP:-} &&
          ${ACME_INFLIGHT_BACKUP:-} == "${ACME_STATE_BACKUP:-}" ]]; then
```

`ACME_INFLIGHT_BACKUP` is assigned in exactly one place — beside `ACME_STATE_BACKUP=$backup` at the
end of `begin_acme_state_backup` — and needs no cleanup, because the condition also requires
`ACME_STATE_BACKUP` to be non-empty.

Why a path comparison rather than a boolean flag: three management paths
(`src/70-management.sh:276-277`, `339-340`, `383-384`) deliberately **hand `ACME_STATE_BACKUP` off to
a local variable and clear the global while keeping the recovery point on disk**. A boolean set on
create and cleared on `clear_acme_state_backup` would stay stuck at 1 on all three, and the next
interrupt anywhere in the menu would print `证书操作已中断…` and enter a restore branch that has
nothing to restore. Keying on the path makes those hand-offs harmless automatically.

Consequence of getting this wrong in either direction:

- Too permissive (the old `[[ -n $ACME_STATE_BACKUP ]]`) — interrupting the script while it merely
  *asks* about a discovered recovery point silently restores it and consumes it, making a decision
  the user explicitly declined and potentially reverting a good certificate.
- Too strict — an interrupt during an actual issuance/replacement stops restoring ACME state.

Regression coverage: `tests/repair.sh` → `interrupt_handler_restores_only_inflight_acme_state`.

---

## 9. Change checklist

1. Editing the hook body → **bump `ACME_RELOAD_IDENTITY`** and update every anchor grep in
   `acme_reload_hook_is_current` (`src/10-acme.sh:762-796`) plus `tests/verify.sh:192-204`.
2. Keep the heredoc quoted, the terminator at column 0, exactly one `ACMERELOAD` line, and the hook
   `bash -n`-clean standalone.
3. Never reuse a heredoc helper's name for a top-level function — the build rejects duplicates.
4. Never let acme.sh write a live path; always `ACME_STAGE_*`.
5. Any new mutation path runs under `with_acme_lock`, taking the global lock first.
6. New crontab strings carry a marker, are counted with `grep -Fxc == 1`, and are filtered by exact
   pattern.
7. After every write, re-read and re-verify; a failed verification *is* the operation's failure.
8. `bash scripts/build.sh && bash tests/verify.sh` before committing.

---

## Common mistakes

- Reformatting the hook while "just tidying" — silently marks every installed hook stale.
- Adding a second line exactly equal to `ACMERELOAD`, or unquoting the heredoc delimiter.
- Calling `acme.sh --issue` outside `with_acme_lock`.
- Acquiring the compat lock before the global lock.
- Rewriting a byte-identical cron entry or hook, breaking hash-based idempotency assertions.
- Echoing the API Token, or switching the token prompt to a hidden read.
- Deleting a recovery point while `sb.json` still points at the ACME certificate.
