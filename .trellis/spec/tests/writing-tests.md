# Writing Tests & the Rename Coupling Map

---

## 1. Which file does the test belong in?

| File | Owns |
|------|------|
| `tests/verify.sh` | Static assertions over the generated artifact: build sync, syntax, pinned versions/digests, required/forbidden literal strings, module structure, hook shape, shellcheck. No TAP. |
| `tests/unit.sh` | Pure validation, parsing, formatting, and single-function behaviour. Linear top-to-bottom script with inline fixtures. |
| `tests/repair.sh` | Repair pipeline, transaction lifecycle, multi-function integration, signal handling. Case functions defined at the top, invoked in a block later. |

They partition the domain deliberately — do not duplicate coverage:

- `unit.sh`: cron/hook identity and regeneration, renewal runner and state, ACME state
  backup/restore, credential flows, install-transaction cleanup and uninstall.
- `repair.sh`: ownership, core quarantine, last-good restore, Reality key, atomic writers versus
  symlinks/directories, ACME fallback, service-unit repairability, report defaults, transaction
  abort, and INT/TERM/HUP.

There is **no shared `tests/lib.sh`** — each file redefines `pass` / `fail` / `expect_*` and its own
collaborator stubs. Follow that; do not add a library.

### Case shape differs by file

`unit.sh` is linear and inline:

```bash
# tests/unit.sh:1347-1348
[[ $FLOW_MESSAGES == *'UUID格式错误'* ]] || fail "UUID format failure was not shown"
pass "UUID format failure was shown"
```

`repair.sh` uses self-contained case functions wrapped in a subshell, one `|| return 1` per step:

```bash
# tests/repair.sh:336-339 (structure)
repair_signal_restores_stack_and_cleans_temporary_files(){
  local signal=$1 ...
  ...
}
```

---

## 2. Recipe

1. **Pick the file** (§1).
2. **Load the code.** Source definition-only modules with `# shellcheck source=/dev/null`. For
   functions in `src/00-bootstrap.sh` or `src/90-main.sh`, `awk`-extract one function into
   `$TEMP_DIR` and source that inside a subshell — then assert the extraction is non-empty.
3. **Supply missing collaborators** as same-named functions, with a `# Called indirectly by …`
   comment and `# shellcheck disable=SC2317` where appropriate.
4. **Re-point every path the code will write** into `$TEMP_DIR` before the case runs. In `repair.sh`,
   do it inside the case's own subshell with a per-case directory.
5. **Declare the case.** Single assertion → `expect_success "description" fn args`. Multiple → a
   verb-phrase `snake_case` function, then register it with `expect_success` / `expect_failure`.
6. **Never edit a count.** The plan line is derived at `tests/unit.sh:1623` / `tests/repair.sh:692`.
   Inside a platform/conditional branch, add the mirrored placeholder `pass`/`skip` in the other
   branch.
7. **Clean up inside the case**: `unset -f` mocks, restore fixtures you perturbed. Everything else in
   `$TEMP_DIR` disappears with the EXIT trap.
8. **Assert the negative half**: state preserved, byte-idempotence via sha256, no leftover temp
   files.
9. **Update any pins you invalidated** in `tests/verify.sh` (see §3) and regenerate `sb.sh`.
10. **Validate with the gate**, not the file: `bash tests/verify.sh`.

---

## 3. Coupling map — what breaks when you change `src/`

This is the highest-cost part of working in this repository. Most of these assertions are **literal
string pins**, so a rename or reword is a test change too.

### (a) Function names, via `awk` range anchors

The hardest coupling. A test extracts a function body by matching `/^name\(\)\{/` for the start and
a **neighbouring function's name** for the end:

```bash
# tests/verify.sh:113-114
uuid_function=$(awk '/^changeuuid\(\)\{/{inside=1} /^change_socks_password\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
```

Other sites: `tests/verify.sh:120` (`sb_client` … `sbshare`), `:206` (`issue_cloudflare_certificate`
… `inscertificate`), `:211` (`register_acme_certificate_deployment` …
`config_uses_acme_certificate`); `tests/repair.sh:314`, `677-678`.

Breaks on: renaming either bracketing function, changing the definition style away from `name(){`
(no space, brace on the same line, column 0), or **reordering** the two functions — the range is
positional, so reordering silently changes what text is inspected. Always keep the paired
`[[ -n $extracted ]] || fail` guard, or the check degrades into a vacuous pass.

### (b) Exact source lines, including indentation

```bash
# tests/unit.sh:147-148 (asserted against src/10-acme.sh at :154)
for fixed_move in \
  '     ! chmod 600 "$identity_tmp" || ! mv -fT -- "$identity_tmp" "$ACME_IDENTITY"; then' \
```

Also `tests/repair.sh:617-618`. Re-indenting these lines, or rewriting `mv -fT` as `mv -Tf`, fails
the suite.

### (c) Pinned versions, digests, and policy strings

`tests/verify.sh:27-45` pins `CORE_VERSION`, `ACME_VERSION`, four SHA-256 digests (each required
exactly once), the HTTPS-only policy string, the verified acme.sh archive URL, and the **absence** of
`--install-online`. `tests/verify.sh:46-53` pins `SOCKS_USERNAME="sb"`, `sb_version`, `VERSION`, and
the README version line. See `spec/build/version-pins.md`.

### (d) User-visible messages

Eight modification success messages are required (`tests/verify.sh:82-93`), as are lifecycle strings
(`:54-68`), SOCKS5 integration strings (`:94-107`), client security settings (`:136-150`), and the
`SOCKS5本身不加密` warning (`:154-155`). `tests/unit.sh:1347-1348` pins `UUID格式错误`.

Rewording a user message is therefore a two-file change.

### (e) Internal paths, markers, and env-var names

`tests/verify.sh:221-226` pins `ACME_LOCK="/run/sb-acme.lock"` and
`ACME_COMPAT_LOCK="$SB_DIR/acme.lock"` — including the literal variable name `$SB_DIR`. Also
`:141`, `:216`, `:72-73` (`SHORTCUT`), `:74-75` (the visible Cloudflare token prompt).
`tests/repair.sh:262` writes the managed marker content verbatim.

### (f) Negative guards — do not delete these

```bash
# tests/unit.sh:158-161 (abridged)
if grep -Eq '(^|[[:space:];|&!])mv[[:space:]]+-f([[:space:]]|$)' "$ROOT_DIR/src/10-acme.sh"; then
  fail "ACME source still contains an unsafe fixed-target mv -f"
fi
```

`tests/repair.sh:681-684` fails if repair orchestration re-introduces
`cleanup_incomplete_install` or `rm -rf "$SB_DIR"`. These encode design decisions.

### (g) The ACME reload hook

`tests/verify.sh:170-204` re-extracts the hook from `sb.sh` and pins its structure. Any hook edit
must keep those lines byte-stable, or must update them deliberately together with
`ACME_RELOAD_IDENTITY`. See `spec/runtime/certificates.md` §3.

---

## 4. Known gaps in the suite

Documented as-is; do not assume coverage that does not exist.

- `tests/verify.sh:243-244` invokes `unit.sh` / `repair.sh` as bare commands under `set -e`, so the
  gate checks **only the exit status**. Nothing asserts the trailing `1..N` plan line exists, or that
  `N` meets a floor.
- **No test asserts the product's environment-variable names.** `SB_DIR`, `SB_CONFIG`, `SB_LAST_GOOD`,
  `SB_BIN`, `SB_MANAGED_MARKER`, and the `ACME_*` names are used by tests but never asserted to exist
  in the product; only incidental textual pins exist (`tests/verify.sh:225`). Renaming one surfaces
  late and unhelpfully.
- `tests/repair.sh:4` carries a file-level `shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317`
  without per-line justification.
- `shellcheck` is optional locally and self-skips with `verify: shellcheck not found; static lint
  skipped` (`tests/verify.sh:240`), so lint is only enforced where it is installed (including CI).

---

## Common mistakes

- Adding a new test file instead of extending `unit.sh` / `repair.sh`.
- Introducing a shared test library — each file is intentionally self-contained.
- Editing `tests/verify.sh` pins to match a rename **without** also deciding whether the rename was
  intended; the pins exist to make the coupling visible.
- Renaming a product function that a range-anchor extraction depends on, without updating the anchor
  *and* the neighbouring anchor.
- Reflowing `src/10-acme.sh` structure (moving a function) and silently changing which text an `awk`
  range test inspects.
- Adding a platform-gated case without the mirrored placeholder, which makes the plan count
  platform-dependent.
