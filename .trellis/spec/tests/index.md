# Test Suite Layer

> Conventions for `tests/verify.sh`, `tests/unit.sh`, and `tests/repair.sh` — the only gate the
> project has.

There is no test framework. The suite is three Bash scripts producing TAP-ish output, runnable
**without root** and without touching the host system. CI runs exactly one command
(`bash tests/verify.sh`).

## When to read this layer

- You are adding or changing a test.
- You renamed a product function, constant, message, or file path — many assertions are literal pins.
- You are adding a user-visible message, a pinned version, or a managed marker.

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [harness.md](./harness.md) | Gate order, TAP output protocol, sandboxing, mocks, function extraction |
| [writing-tests.md](./writing-tests.md) | Recipe for adding a test, file selection, and what breaks on rename |

## The one rule that matters most

**`tests/verify.sh` is the only entry point.** The product's conventions are pinned as literal
strings in the suite, so a change to `src/` frequently requires a matching change to `tests/`.
Always finish with:

```bash
bash scripts/build.sh && bash tests/verify.sh
```

`tests/verify.sh:20` runs `build.sh --check` first, so a stale `sb.sh` fails the gate before any
behavioural test runs.

## Gate order

| Order | Step | Location |
|-------|------|----------|
| 1 | `scripts/build.sh --check` — artifact in sync | `tests/verify.sh:20` |
| 2 | `bash -n` on `sb.sh`, `build.sh`, all three test files | `tests/verify.sh:21-25` |
| 3 | Pinned versions, digests, HTTPS policy, lifecycle strings, security settings | `tests/verify.sh:27-168` |
| 4 | Pinned ACME reload hook structure | `tests/verify.sh:170-231` |
| 5 | `shellcheck --severity=info` (skipped with a message if absent) | `tests/verify.sh:233-241` |
| 6 | `bash tests/unit.sh` | `tests/verify.sh:243` |
| 7 | `bash tests/repair.sh` | `tests/verify.sh:244` |
