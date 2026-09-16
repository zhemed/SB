# Atomic Writes & Config Commits

**No live file is ever written in place.** Every mutation builds a candidate next to its
destination, validates it, then publishes it with a same-filesystem atomic rename. This is the most
repeated pattern in the codebase — over 30 `mktemp` candidate sites across `src/`.

---

## 1. The protocol

```
mktemp "$DEST_DIR/.prefix.XXXXXX"     → candidate (same filesystem)
write content to candidate
chmod <mode> candidate                 → mode set BEFORE publication
validate candidate                     → if applicable (see §4)
mv -fT -- candidate "$DESTINATION"     → atomic replace
on any failure: rm -f candidate; return 1
```

Reference implementation:

```bash
# src/40-service.sh:25-36
atomic_write_private_text(){
  local destination=$1 value=$2 candidate name
  name=${destination##*/}
  [[ ${destination%/*} == "$SB_DIR" && $name =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -d $SB_DIR && ! -L $SB_DIR ]] && managed_path_is_trusted "$SB_DIR" || return 1
  candidate=$(mktemp "$SB_DIR/.managed-write.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$candidate" || ! chmod 600 "$candidate" ||
     ! mv -fT -- "$candidate" "$destination"; then
    rm -f -- "$candidate"
    return 1
  fi
}
```

Three details are load-bearing:

- **`mktemp` targets the destination directory**, never `${TMPDIR}`. A cross-filesystem `mv` degrades
  to copy+unlink, which is not atomic.
- **`chmod` runs on the candidate**, so the destination is never observable with a permissive mode.
- **`mv -fT`** (`-T` = treat destination as a normal file, never a directory) is used everywhere.
  The symlink variants use `mv -Tf`; both spellings appear and are equivalent.

---

## 2. The helper family

| Helper | Location | Publication mechanism |
|--------|----------|-----------------------|
| `atomic_write_private_text` | `src/40-service.sh:25` | `printf` → chmod 600 → `mv -fT` |
| `atomic_copy_private_file` | `src/40-service.sh:38` | `cp` → chmod 600 → `mv -fT` |
| `write_managed_marker_at` | `src/40-service.sh:112` | `mkdir`+chmod 700, then marker via `mv -fT` |
| `save_last_good_config` | `src/40-service.sh:439` | validate → skip-if-identical → `cp -p` → chmod → `mv -fT` |
| `write_service_definition` | `src/40-service.sh:248` | heredoc → chmod → `mv -fT` (temp inside the unit dir) |
| `inssbjson` | `src/30-server-config.sh:104` | render → chmod 600 → `$SB_BIN check` → `mv -fT` |
| `commit_config` | `src/40-service.sh:495` | validate → backup → `mv -fT` → restart → verify/rollback |
| `install_managed_link` | `src/10-acme.sh:398` | `mktemp` → `rm -f` → `ln -s` → `mv -Tf` |
| `switch_current` | `src/10-acme.sh:388` | same symlink protocol for `acme-live/current` |
| `atomic_install_shortcut` | `src/80-lifecycle.sh:209` | `install -m` → `mv -fT` |

Use one of these rather than hand-rolling the sequence.

---

## 3. The symlink variant needs an extra `rm -f`

`mktemp` creates a **regular file**, so a symlink cannot be created at that path until the file is
removed. Forgetting this makes `ln -s` fail and the whole write abort.

```bash
# src/10-acme.sh:396-404
install_managed_link(){
  local destination=$1 target=$2 link_tmp
  link_tmp=$(mktemp "$base/.acme-link.XXXXXX") || return 1
  rm -f -- "$link_tmp" || return 1
  if ! ln -s -- "$target" "$link_tmp" || ! mv -Tf -- "$link_tmp" "$destination"; then
    rm -f -- "$link_tmp"
    return 1
  fi
}
```

The link target is always **relative** (`acme-live/current/fullchain.pem`), and the resulting layout
is validated by comparing `readlink` output as a literal relative string
(`src/10-acme.sh:137-138`). Never `ln -sfn` onto the live name, and never `rm` the destination first
— both create a window where the live path does not exist, and both are explicitly asserted against
(`tests/unit.sh:1063-1077`, `1131-1135`).

---

## 4. Validate before replacing

For configuration, the candidate is checked by the core before it becomes live:

```bash
# src/30-server-config.sh:113-119
  if ! "$SB_BIN" check -c "$candidate" >/dev/null 2>&1; then
    red "初始配置未通过Sing-box v${CORE_VERSION}检查"
    "$SB_BIN" check -c "$candidate"
    rm -f "$candidate"
    return 1
  fi
  mv -fT -- "$candidate" "$SB_CONFIG"
```

Note the re-run without suppression: the user must see the reason. See
`spec/shell/user-output.md` §3.

Management flows do the same with `jq -e` re-validation after generating a candidate
(`src/70-management.sh:29-43`).

---

## 5. Commit with verified effect — `commit_config`

A config that parses is not a config that *runs*. `commit_config` is the only supported path for
changing a live node configuration:

```bash
# src/40-service.sh:495-532 (structure)
commit_config(){
  local candidate=$1 backup
  ... validate candidate ...
  backup=$(mktemp "$SB_DIR/.sb.json.backup.XXXXXX") || { rm -f "$candidate"; return 1; }
  cp -p "$SB_CONFIG" "$backup" || { ... return 1; }
  chmod 600 "$candidate"
  mv -fT -- "$candidate" "$SB_CONFIG" || { ... return 1; }
  if restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rm -f "$backup"
    save_last_good_config "$SB_CONFIG" || yellow "配置已生效，但最后可用配置快照更新失败"
    return 0
  fi
  red "服务未能使用新配置启动，正在回滚"
  if cp -p "$backup" "$SB_CONFIG" && chmod 600 "$SB_CONFIG" && \
     restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rm -f "$backup"
    red "已恢复修改前的配置和服务"
    return 1
  fi
  red "自动回滚失败！请立即检查服务；原配置备份保留在 $backup"
  return 2
}
```

Contract:

- **Success is `service_is_active` after a restart**, never merely "the file was replaced".
- **`return 1`** = the change did not take effect, old state restored. **`return 2`** = rollback also
  failed, backup retained at a named path. Callers must branch on 2
  (`src/70-management.sh:44-54`).
- **`sleep 1` before judging activity** — services do not fail instantly.
- The candidate is deleted on every failure path; the backup is deleted only after the new config is
  confirmed working.

---

## 6. Skip the write when content is unchanged

Idempotent publication preserves mtimes and avoids needless service churn. Compare before writing:

```bash
# src/40-service.sh:442-448
  if [[ -e $destination || -L $destination ]]; then
    [[ -f $destination && ! -L $destination ]] || return 1
    if cmp -s -- "$source" "$destination"; then
      chmod 600 "$destination"
      return
    fi
  fi
```

Note the defensive re-`chmod`: the early return still enforces the mode contract.

The same rule applies to generated cron entries and the ACME reload hook, where rewriting a
byte-identical file would change its hash and trip the test suite
(`tests/unit.sh:1152-1156`).

---

## 7. Refuse to replace a non-regular file

If something other than a regular file (or our own symlink) sits at the destination, abort rather
than clobbering it:

```bash
# src/10-acme.sh:352-356
  if [[ -e $ACME_RELOAD || -L $ACME_RELOAD ]] && \
     [[ ! -f $ACME_RELOAD || -L $ACME_RELOAD ]]; then
    ...
    rm -f "$hook_tmp"
    return 1
```

Tested at `tests/unit.sh:1321-1338`: an injected `mv` failure must leave the previous content
intact, and a directory at the destination must be rejected.

---

## Common mistakes

- Writing `> "$SB_CONFIG"` directly — a crash mid-write leaves a truncated live config.
- `mktemp` in `/tmp` for a destination under `/etc/sb`.
- `chmod` after the `mv` — a brief window with the wrong mode on a secret.
- Forgetting `rm -f` before `ln -s` in the symlink variant.
- Treating "config validated" as success without restarting and confirming the service is up.
- Collapsing `return 2` into `return 1`, so the user is told the state was restored when it was not.
- Leaving the candidate behind on a failure path — every branch must `rm -f` it or the repair sweep
  will find debris.
