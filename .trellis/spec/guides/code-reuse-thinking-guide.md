# Code Reuse Thinking Guide

> **Purpose**: Find the helper that already exists before writing a new one.

Because `src/` is concatenated into a single namespace, reuse here is not just tidiness — a duplicate
function name is a **build failure**, and a re-implemented pattern is a new place to get atomicity,
permissions, or ownership wrong.

---

## The rule

**Before writing any function:**

```bash
# does this already exist?
grep -rn '^name_you_are_about_to_write()' src/

# does something in the same family exist?
grep -rn '^\(atomic_\|managed_\|valid_\|with_\|save_\|write_managed\|install_managed\)' src/
```

**Before changing any value:**

```bash
grep -rn "value_to_change" src/ tests/ README.md VERSION
```

---

## Helper families that already exist

Do not re-implement these. Use them, or extend them where they live.

### Atomic publication (`src/40-service.sh`, `src/10-acme.sh`)

| Helper | Signature / use |
|--------|-----------------|
| `atomic_write_private_text <dest> <value>` | Single string → 600 file inside `$SB_DIR` |
| `atomic_copy_private_file <src> <dest>` | Copy of a file → 600 file inside `$SB_DIR` |
| `install_managed_link <dest> <relative_target>` | Symlink swap (hook-local) |
| `write_managed_marker_at <dir>` | Directory + `.sb-managed` marker |
| `save_last_good_config [source]` | Validated snapshot with skip-if-identical |

Everything else hand-rolls `mktemp` → `chmod` → `mv -fT`. The protocol is in
`spec/runtime/atomic-writes.md`.

### Trust and ownership (`src/40-service.sh`)

`managed_path_is_trusted`, `managed_regular_file_is_trusted`, `managed_symlink_is_trusted`,
`managed_directory_is_owned`, `service_is_owned`, `shortcut_is_owned`,
`service_definition_is_repairable`.

### Validation (`src/20-ports.sh`, `src/00-bootstrap.sh`)

`valid_port`, `valid_uuid`, `valid_socks_password`, `valid_reality_key`, `valid_short_id`,
`valid_hostname`, `valid_ipv4`, `valid_ipv6`.

### Locking (`src/60-cron.sh`)

`with_acme_lock <command...>` — the only supported way to touch certificate state.

### Output (`src/00-bootstrap.sh`)

`red`, `green`, `yellow`, `blue`, `white`, `readp`.

---

## Duplicated names fail the build

```bash
# scripts/build.sh:151-153
duplicate_functions=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)()[[:space:]]*{.*/\1/p' "$candidate" |
  sort | uniq -d)
[[ -z $duplicate_functions ]] || fail "duplicate function definitions: $duplicate_functions"
```

The check does not understand heredocs, so **a helper defined inside a generated script counts too**.
Names used inside `ACMERELOAD` (`switch_current`, `install_managed_link`, `rollback_deployment`,
`commit_deployment`, `cleanup_deploy_files`, `handle_deploy_signal`, `managed_service_active`,
`restart_managed_service`) are effectively reserved artifact-wide.

---

## The subtle duplication: same decision, two places

Not all duplication is a copied function. Watch for **the same decision implemented twice**, which
drifts silently:

- **Service-unit ownership** is checked in `src/40-service.sh` *and* independently inside the ACME
  hook (`src/10-acme.sh:686-720`). Both must agree on `# Managed by sb.sh` and the exact exec line.
- **Domain validation** exists as `valid_hostname` (`src/20-ports.sh:24-33`) and again inline in the
  cron runner (`src/60-cron.sh:310-319`), because the runner cannot call the main script.
- **The ACME lock protocol** is implemented in `with_acme_lock` and re-implemented with hardcoded
  descriptors 9 and 8 in the runner (`src/60-cron.sh:343-370`), pinned byte-exactly by an identity
  check.

Where duplication is unavoidable (a separate process cannot call into the script), it is **pinned by
an assertion** so drift fails the build. If you create such a duplicate, add a pin.

---

## Anti-patterns

### Re-implementing the atomic write

```bash
# WRONG — no same-directory temp, no mode on the temp, no cleanup on failure
printf '%s\n' "$value" > "$SB_DIR/foo"
```

```bash
# RIGHT
atomic_write_private_text "$SB_DIR/foo" "$value" || return 1
```

### Inlining a regex instead of extending a validator

An inline `[[ $x =~ ... ]]` at one call site means the definition of "valid" diverges between
install, management, and repair paths. Extend the `valid_*` function instead.

### Repeating the same failure message in several callers

Low-level functions return status silently; the function that owns the decision prints. Otherwise the
same sentence appears three times with three different phrasings, and a test pin catches only one.

### Copying a helper into a new module "to keep modules self-contained"

Modules are **not** self-contained — they are fragments of one file. Put the helper where its domain
belongs (`spec/shell/module-structure.md` §1) and call it from anywhere.

---

## Quick checklist

- [ ] I grepped for an existing helper before writing one.
- [ ] The name I chose is not defined anywhere else in `src/`, including inside heredocs.
- [ ] I used the existing atomic-write / validator / lock helper rather than an inline equivalent.
- [ ] If I had to duplicate a decision because a separate process cannot call the script, I added a
      test pin so drift fails the build.
- [ ] I grepped `tests/` for literal pins on any value I changed.
