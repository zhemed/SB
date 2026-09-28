# Test Suite Layer

> Conventions for `tests/verify.sh`, `tests/unit.sh`, `tests/repair.sh`, and `tests/replay.sh` —
> the only gate the project has.

There is no test framework. The suite is four Bash scripts producing TAP-ish output, runnable
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
| 3 | Pinned versions, digests, HTTPS policy, lifecycle strings, security settings | `tests/verify.sh:27-225` |
| 4 | Pinned ACME reload hook structure | `tests/verify.sh:249-283` |
| 5 | `shellcheck --severity=info` (skipped with a message if absent) | `tests/verify.sh:312-320` |
| 6 | `bash tests/unit.sh` | `tests/verify.sh:322` |
| 7 | `bash tests/repair.sh` | `tests/verify.sh:323` |
| 8 | `bash tests/replay.sh` — menu flows replayed against recorded behaviour | `tests/verify.sh:324` |

## Behavioural replay (`tests/replay.sh`)

`unit.sh` and `repair.sh` stub `commit_config`, the ownership checks, and the install entry, so a
green gate never proved that a **menu flow** still works: a refactor that renamed an argument or
swallowed a return code passed everything and still broke four menu paths.

`replay.sh` closes that hole. It extracts every function from `sb.sh`, drives 17 menu flows
(change UUID/port/password, enable/disable the SOCKS5 entry, set/clear the upstream) in a sandbox
with stubbed system commands, and compares four things per flow against
`tests/replay/expected/<flow>.txt`: the **return code**, the printed output, the resulting
`sb.json`, and the leftover files in `SB_DIR`.

- Any behavioural drift fails the gate. Review a diff line by line before running
  `bash tests/replay.sh --update`; the expectations are the contract, not a snapshot to refresh.
- The sandbox mirrors the globals `00-bootstrap.sh` initialises and runs under `set -u`, so an
  uninitialised global shows up as a flow failure instead of passing silently.
- When you add a menu flow that writes configuration, add it to the `FLOWS` list and record its
  behaviour in the same commit.
