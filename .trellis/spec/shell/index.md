# Shell Source Layer

> How to author, extend, and modify the Bash modules under `src/` that are concatenated into
> `sb.sh`.

`src/` is the product. Each file is a **build fragment**, not a runtime plugin: the modules are
concatenated into one program and never `source`d (`scripts/build.sh:148-149`). Writing a module is
therefore writing part of a single, very long Bash script.

## When to read this layer

- You are adding or changing a function in `src/`.
- You are adding a new protocol, menu action, validator, or user-facing message.
- You are unsure which module should own a new piece of code.
- You are writing an embedded helper script (heredoc-delivered program).

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [module-structure.md](./module-structure.md) | Which module owns what, where new code goes, top-level code rules, embedded helper scripts |
| [bash-conventions.md](./bash-conventions.md) | Language-level style: definitions, quoting, `local`, arithmetic, error propagation, exit codes |
| [input-validation.md](./input-validation.md) | `valid_*` validator contract and the interactive prompt/retry loop |
| [user-output.md](./user-output.md) | Color helpers, Chinese UX text, message severity placement |

## Related layers

- `spec/build/build-contract.md` — the header markers, text hygiene, and duplicate-function rules
  your module must satisfy before it compiles into a release.
- `spec/runtime/` — the installed-system invariants your code must preserve.

## Orientation

- **263 functions** across 11 modules. `src/10-acme.sh` (53), `src/40-service.sh` (42),
  `src/85-repair.sh` (29), `src/60-cron.sh` (28) are the largest.
- The runtime script sets **no `set -e` / `set -u` / `set -o pipefail`**. Every failure is handled
  explicitly. See `bash-conventions.md` §5.
- All 263 function definitions are written `name(){` at **column 0** — no leading indentation, no
  space before `{`.
- User-facing text is **Chinese**; identifiers, comments, and specs are English.
