# Build & Repository Layer

> How the release artifact `sb.sh` is produced, how pinned versions stay in sync, and how
> repository-level files are wired.

This layer governs the **build-time** contract of the repository. It does not describe how the
installed script behaves on a target host — that belongs to `spec/runtime/`. It does not describe
how to author a module — that belongs to `spec/shell/`.

## When to read this layer

- You are about to change, add, remove, or reorder anything under `src/`.
- You need to regenerate or verify `sb.sh`.
- You are bumping the script version, the sing-box version, or acme.sh.
- You touch `.editorconfig`, `.gitattributes`, `.gitignore`, or CI.

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [build-contract.md](./build-contract.md) | Module manifest, module header markers, text hygiene, artifact generation |
| [version-pins.md](./version-pins.md) | `VERSION` / `sb_version` sync, pinned upstream versions and SHA-256 digests |
| [repository-conventions.md](./repository-conventions.md) | Line endings, encoding, ignore rules, CI entry point |

## Non-negotiables

1. **`sb.sh` is a generated artifact. Never edit it directly.** Edit `src/` and rebuild.
2. **`src/` is a build manifest, not a source directory.** Adding a file to `src/` without
   updating `scripts/build.sh` fails the build.
3. **`bash tests/verify.sh` is the gate that matters.** `scripts/build.sh --check` alone is not
   sufficient; `verify.sh` adds pinned-value, shellcheck, and unit/repair assertions.
4. **Pushing to `main` is a release,** so a change under `src/` must bump `VERSION` in the same
   change. `scripts/check-version-bump.sh` enforces this and runs in its own CI step — see
   `version-pins.md` §1.
