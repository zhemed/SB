# Repository Conventions

Repository-level files that are not product code but are load-bearing: they define how the source
must be written, what is ignored, and how CI runs.

---

## 1. EditorConfig — matches what the build enforces

```ini
# .editorconfig
[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true

[*.sh]
indent_style = space
indent_size = 2

[Makefile]
indent_style = tab
```

- The `[*]` rules are **not advisory**: `scripts/build.sh:84-92` fails the build on BOM, CR, NUL, or
  a missing final LF in any `src/` module. See `spec/build/build-contract.md` §4.
- **2-space indent** for shell. Use spaces, never tabs, inside `src/`, `scripts/`, `tests/`.
  The `Makefile` is the only tab-indented file.
- Chinese user-facing strings are normal and expected; the file stays valid UTF-8.

---

## 2. `.gitattributes` — LF for every text file

```bash
# .gitattributes
*.sh text eol=lf
sb.sh text eol=lf
VERSION text eol=lf
Makefile text eol=lf
```

`VERSION` is listed explicitly because `scripts/build.sh` matches `sb_version` against its content
byte-for-byte (`scripts/build.sh:155-156`); a CRLF checkout would break that comparison.

The file also carries the Trellis journal merge rule:

```bash
.trellis/workspace/*/journal-*.md merge=union
```

Journals are append-only, so `merge=union` lets parallel sessions merge without conflicts. **Do not
add a `merge=union` rule for `.trellis/workspace/*/index.md`** — it is fully regenerated each
session, so a real conflict there is expected and either side is safe to pick. Task state lives in
`task.json`, not in `index.md`.

---

## 3. `.gitignore` — build temporaries only

```bash
# .gitignore
.sb.sh.*
.acme-reload.*
.verify-hook.*
```

These patterns exist because the atomic build/test pattern creates same-directory temp files that
must never be committed. If you introduce a new temp prefix in the repository root, add it here —
repository-root `mktemp` candidates are visible to `git status` otherwise.

Note the contrast with the installed script: on a target host, temp candidates are hidden dotfiles
inside `/etc/sb` (`$SB_DIR/.xxx.XXXXXX`), which is a different mechanism. See
`spec/runtime/atomic-writes.md`.

---

## 4. CI entry point

```yaml
# .github/workflows/ci.yml
- name: Install ShellCheck
  run: sudo apt-get update && sudo apt-get install -y shellcheck
- name: Require a version bump for source changes
  env:
    BASE_REF: ${{ github.event.before || github.event.pull_request.base.sha }}
  run: bash scripts/check-version-bump.sh "$BASE_REF"
- name: Verify generated release
  run: bash tests/verify.sh
```

The checkout uses `fetch-depth: 0` because the version-bump guard compares against a base revision
and cannot work from the default single-commit checkout.

There is no separate lint job, no matrix, and no packaging step. **Whatever CI would catch,
`bash tests/verify.sh` catches locally** — so always run it before committing, and prefer adding an
assertion to `tests/verify.sh` over adding a CI step. The version-bump guard is the one deliberate
exception: it needs git history, so it lives in `scripts/` and gets its own step rather than being
folded into the gate.

ShellCheck is optional locally (`tests/verify.sh:268-276` prints
`verify: shellcheck not found; static lint skipped` and continues), but a shellcheck failure **is**
fatal where shellcheck is installed — including in CI.

---

## 5. Make targets are thin wrappers

```make
# Makefile
build:
	bash scripts/build.sh

check:
	bash scripts/build.sh --check

test:
	bash tests/verify.sh
```

`make` is convenience only. Scripts must remain directly runnable, because CI and the docs use the
`bash scripts/build.sh` form (`README.md:49-60`).

---

## 6. Toolchain assumptions

| Tool | Used by | Notes |
|------|---------|-------|
| `bash` | everything | The script is `#!/bin/bash`; it uses arrays, `mapfile`, `[[ ]]`, `${var,,}`-style expansions. Not POSIX `sh`. |
| `shellcheck` | `tests/verify.sh` | `--severity=info`; optional locally, required in CI. |
| `iconv`, `od`, `sha256sum`, `cmp`, `mktemp` | `scripts/build.sh` | Preflight-checked at `scripts/build.sh:58-61`. |
| `python3` | `.trellis/scripts/*.py` | Trellis workflow only; not a product dependency. |

When you add a build-time command, add it to the preflight list at `scripts/build.sh:58-61` so the
failure message is `missing command: X` rather than a confusing downstream error.

---

## Common mistakes

- Adding a repository with `core.autocrlf=true` and committing CRLF — the build fails with
  `contains CR characters`.
- Committing a `.sb.sh.XXXXXX` leftover because the build was interrupted; the ignore rule covers
  it, but verify with `git status` before committing.
- Adding a CI step instead of a `tests/verify.sh` assertion — the invariant then only holds in CI.
- Tabs in shell files (copied from the `Makefile`) — no gate catches this, but it violates
  `.editorconfig` and is inconsistent with the rest of `src/`.
