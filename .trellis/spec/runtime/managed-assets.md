# Managed Assets, Markers & Permissions

The script owns a fixed set of paths on the target host. It must be able to prove ownership before
overwriting or deleting anything, and it must never touch a file it does not own.

---

## 1. Managed paths

| Constant | Path | Kind |
|----------|------|------|
| `SB_DIR` | `/etc/sb` | Managed directory, mode 700 |
| `SB_CONFIG` | `/etc/sb/sb.json` | Server config, 600 |
| `SB_LAST_GOOD` | `/etc/sb/sb.json.last-good` | Last known-good config, 600 |
| `SB_BIN` | `/etc/sb/sing-box` | Pinned core binary, 755 |
| `SB_MANAGED_MARKER` | `/etc/sb/.sb-managed` | Ownership marker, 600 |
| `SYSTEMD_UNIT` | `/etc/systemd/system/sb.service` | Unit, 600 |
| `OPENRC_UNIT` | `/etc/init.d/sb` | Unit, 700 |
| `SHORTCUT` | `/usr/bin/sb` | Installed copy of the script, 755 |
| `ACME_LOCK` | `/run/sb-acme.lock` | Global lock, 600 |
| `ACME_COMPAT_LOCK` | `/etc/sb/acme.lock` | v1.8.0 interop lock, 600 |

Defined once in `src/00-bootstrap.sh:15-31`. Use the constants; do not re-type paths.

### Non-secret artefacts inside `SB_DIR`

`SHA256.txt`, `server_ip.log`, `server_ipcl.log`, `hy2.txt`, `socks5.txt`, `jhdy.txt`,
`jhsub.txt`, `sbox.json`, `clash.yaml`, `cert.pem`, `private.key`, `.ip_cache`, `.deps_ok`.

`public.key` no longer has a producer — it is still named in `managed_install_data_present` only so
a pre-removal Reality installation is still recognised as existing install data.

### ACME subtree

`acme/` (acme.sh home, 700) → `acme/sb-stage/` (staging) → `acme-live/generations/gen.*/` (immutable
generations) → `acme-live/current` (symlink pointer) → `acme-cert.pem` / `acme-private.key`
(relative symlinks into `current`). Plus `acme_server_name`, `acme_reload.sh`, `acme_renew.sh`,
`acme_renew.state`.

See `certificates.md`.

---

## 2. Temp and backup naming is a convention, not an accident

Every temporary candidate is a **hidden dotfile created inside its own destination directory** so
that the final `mv` is a same-filesystem atomic rename. Prefixes are `<subsystem>.<artifact>`:

| Prefix | Produced by |
|--------|-------------|
| `.sb.json.XXXXXX` | Config candidates for management flows (`src/70-management.sh`) |
| `.sb.json.install.XXXXXX` | Install-time config candidate (`src/30-server-config.sh:90`) |
| `.sb.json.last-good.XXXXXX` | Last-good snapshot (`src/40-service.sh:372`) |
| `.sb.json.backup.XXXXXX` | Pre-commit config backup (`src/40-service.sh:431`) |
| `.managed-write.XXXXXX` / `.managed-copy.XXXXXX` | Generic private writers (`src/40-service.sh:30,44`) |
| `.core.XXXXXX` (dir), `.sing-box.XXXXXX` | Core download & install (`src/00-bootstrap.sh:207,234`) |
| `.repair-*` | Repair transaction artefacts (`src/85-repair.sh`) |
| `.acme-backup.XXXXXX` | ACME recovery point, mode 700 (`src/10-acme.sh:1081`) |
| `.acme-restore.XXXXXX` | Staged restore tree (`src/10-acme.sh:1142`) |

Never create a candidate in `${TMPDIR}` when it is destined for `/etc/sb` — cross-filesystem `mv`
is a copy, not an atomic rename, and an interrupted copy leaves a half-written live file.

The repository-root counterparts (`.sb.sh.*`, `.acme-reload.*`, `.verify-hook.*`) are covered by
`.gitignore`; they are build/test temporaries, a different mechanism. See
`spec/build/repository-conventions.md` §3.

### Repair's temp sweep has explicit carve-outs

`src/85-repair.sh:438-446` sweeps leftover candidates by glob. New recovery-point prefixes that must
survive a repair have to be added to the carve-out list, or repair will delete them.

---

## 3. Ownership proofs

Three independent proofs, one per asset class. Each is a strict predicate that returns non-zero on
any doubt.

### (a) Directory marker

```bash
# src/40-service.sh:70-74
  [[ -d $SB_DIR && ! -L $SB_DIR && -f $SB_MANAGED_MARKER && ! -L $SB_MANAGED_MARKER ]] || return 1
  managed_path_is_trusted "$SB_DIR" && managed_regular_file_is_trusted "$SB_MANAGED_MARKER" || return 1
  grep -Fqx 'managed_by=sb.sh' "$SB_MANAGED_MARKER" 2>/dev/null &&
    grep -Fqx 'identity=sb' "$SB_MANAGED_MARKER" 2>/dev/null &&
    grep -Fqx 'directory=/etc/sb' "$SB_MANAGED_MARKER" 2>/dev/null
```

The marker content is produced by `write_managed_marker_at` (`src/40-service.sh:52-63`). Note that
`directory=/etc/sb` is **hardcoded in both producer and consumer** — moving `SB_DIR` requires editing
both (`src/40-service.sh:58` and `:74`).

### (b) Service unit marker + exact exec lines

```bash
# src/40-service.sh:113-115
  grep -Eq "$marker_pattern" "$unit" 2>/dev/null &&
    grep -Fqx "WorkingDirectory=$directory" "$unit" 2>/dev/null &&
    grep -Fqx "ExecStart=$binary run -c $config" "$unit" 2>/dev/null
```

The marker pattern is `'^# Managed by sb\.sh$'` (`src/40-service.sh:314,317`), emitted by both unit
generators (`src/40-service.sh:177,196`). Ownership is not enough to *modify*: drop-ins present means
owned-but-not-repairable (`src/40-service.sh:148-155`).

### (c) Shortcut identity

`/usr/bin/sb` is ours only if the copied script carries the project identity
(`script_copy_has_identity`, `shortcut_is_owned` at `src/80-lifecycle.sh:200-202`). This is what makes
the fallback download at `src/90-main.sh:81` safe — the downloaded file is verified before it is
accepted.

### The trust predicate underneath all three

```bash
# src/40-service.sh:4-9
  [[ -e $path && ! -L $path ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
```

Requires: exists, not a symlink, owned by the effective uid, and **not group- or other-writable**
(`& 0022 == 0`). Specialisations: `managed_regular_file_is_trusted` (`:12-15`),
`managed_symlink_is_trusted` (`:17-23`).

Trust is re-derived per path and never inherited into a subtree — see
`src/85-repair.sh:67-77`.

A fourth predicate decides whether an **unowned** managed directory is our own torn creation rather
than a foreign one — see §4.

---

## 4. Foreign assets are refused, never overwritten

```bash
# src/40-service.sh:91-100
prepare_managed_directory(){
  if [[ ! -e $SB_DIR && ! -L $SB_DIR ]]; then
    write_managed_marker
  elif managed_directory_is_owned; then
    chmod 700 "$SB_DIR"
  else
    red "检测到不属于本脚本的 $SB_DIR，拒绝覆盖"
    return 1
  fi
}
```

The same shape appears for the service unit (`src/40-service.sh:224-227`, `269-271`), for the reload
hook target (`src/10-acme.sh:354-358`) and for the shortcut. Every refusal names the path and says
what was not done.

### Adopting our own torn creation

Creating the managed directory is `mkdir -p` followed by an atomic marker rename. An interrupt
between the two would leave `/etc/sb` present but unowned — and without a guard, every later run
would refuse with the *misleading* message `检测到不属于本脚本的 /etc/sb` (the directory is in fact
ours). An empty directory is indistinguishable from a foreign one purely by ownership, so the code
recognises the only shapes a torn creation can take:

```bash
# src/40-service.sh
managed_directory_is_incomplete_creation(){
  local entry name
  [[ -d $SB_DIR && ! -L $SB_DIR ]] || return 1
  managed_directory_is_owned && return 1
  [[ ! -e $SB_MANAGED_MARKER && ! -L $SB_MANAGED_MARKER ]] || return 1
  # mv -fT is atomic, so an interrupt between mkdir and the marker rename can
  # only leave an empty directory or stray marker temporaries behind.
  for entry in "$SB_DIR"/* "$SB_DIR"/.[!.]* "$SB_DIR"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    [[ $name == .sb-managed.* ]] || return 1
  done
}
```

`prepare_managed_directory` gains one branch for it:

```bash
  elif managed_directory_is_incomplete_creation; then
    yellow "检测到上次运行中断留下的空 $SB_DIR，按本脚本目录接管"
    write_managed_marker
```

Boundaries that must not be loosened:

- **Only** an empty directory, or one containing nothing but `.sb-managed.*` temporaries, is adopted.
  Any other content → still refused, and the content is left untouched.
- A `.sb-managed` file that **exists but fails validation** is still refused. Because the marker
  rename is atomic, a torn creation never leaves a valid-looking marker in place; a present-but-wrong
  marker means corruption or a foreign tool, and preserving it is the safe choice.
- This applies to directories only. Files, unit definitions, and links keep the strict
  exists-and-owned checks.

Regression coverage: `tests/repair.sh` →
`incomplete_managed_directory_is_adopted` (four sub-cases: empty, stray temporary, foreign content,
invalid marker).

---

## 5. Permissions

`umask 077` is the runtime default (`src/00-bootstrap.sh:6`); `scripts/build.sh:5` uses `022`
instead. **Never rely on umask** — every created file gets an explicit mode, applied to the
**temporary candidate before the rename**:

| Mode | Applies to |
|------|-----------|
| 600 | `sb.json`, `last-good`, marker, identity, ACME state, staged cert/key, both unit files, locks |
| 700 | `SB_DIR`, `acme/`, `sb-stage`, `acme_reload.sh`, `acme_renew.sh`, OpenRC unit, recovery points |
| 755 | `sing-box` core, `/usr/bin/sb` |

```bash
# src/40-service.sh:30-35 — chmod precedes mv, always
  candidate=$(mktemp "$SB_DIR/.managed-write.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$candidate" || ! chmod 600 "$candidate" ||
     ! mv -fT -- "$candidate" "$destination"; then
```

Directories: `mkdir -p` then `chmod`, never umask-dependent (`src/40-service.sh:55-56`).

### Windows filesystem exception

Mode enforcement is skipped on MINGW/MSYS, where POSIX modes are not meaningful. This is the **only**
sanctioned platform branch, and it applies only to mode checks — never to ownership or symlink
checks:

```bash
# src/10-acme.sh:887-888
  case $(uname -s 2>/dev/null) in
    MINGW*|MSYS*) enforce_modes=0 ;;
```

Also at `src/60-cron.sh:129` and `:249`.

---

## Common mistakes

- Creating a candidate in `/tmp` for a destination under `/etc/sb` — the rename is no longer atomic.
- Using `chown`/`chmod` after the `mv` instead of before — the live file is briefly too permissive.
- Checking only the marker file's presence, not its exact three lines — a stale or hand-edited marker
  would be accepted.
- Adding a new recovery-point prefix without adding it to the repair carve-out list.
- Relying on `umask 077` and skipping the explicit `chmod 600`.
- Assuming ownership implies repairability — a systemd drop-in makes the unit owned but not
  repairable.
