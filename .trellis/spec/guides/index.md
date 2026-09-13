# Thinking Guides

> **Purpose**: Ask the right questions *before* writing code in this repository.

---

## Why these guides exist here

`sb` is a **2,500-line Bash script** that installs and manages a live sing-box service on a remote
host the user may not be able to reach. Most of its bugs are not syntax errors — they are:

- a value changed in one module but not in the three others that consume it;
- a failure path that leaves the service down or the state half-written;
- a literal string changed in `src/` but not in the assertion that pins it.

The spec layers describe *what the rules are*. These guides are the checklists for *when to stop and
think*.

---

## Available Guides

| Guide | Purpose | When to use |
|-------|---------|-------------|
| [Cross-Layer Thinking Guide](./cross-layer-thinking-guide.md) | Trace a value across module, process, and host boundaries | Adding a protocol field, a global, a marker, or an inter-process contract |
| [Code Reuse Thinking Guide](./code-reuse-thinking-guide.md) | Find the helper that already exists | Any time you are about to write a new function or change a constant |

---

## The three triggers that matter most in this repo

### 1. You are changing *any* value or string

**Search first. Always.**

```bash
grep -rn "value_to_change" src/ tests/ README.md VERSION
```

Then check the test pins:

```bash
grep -rn "value_to_change" tests/
```

A version, a marker line, a user-facing message, an env-var name — each is likely asserted literally
somewhere. `tests/writing-tests.md` §3 is the coupling map.

### 2. You are about to add a new helper

Search for an existing one first. Atomic writers, trust predicates, validators, and marker checks
already exist and are the only sanctioned way to do those things:

```bash
grep -rn '^\(atomic_\|managed_\|valid_\|with_\|save_\|write_managed\)' src/
```

And remember: **two top-level functions with the same name fail the build**, because all modules are
concatenated into one namespace.

### 3. You are adding a failure path

Ask, in order:

- What is the state of the service right now?
- What did this operation already change, and is that change tracked so it can be rolled back?
- Does the message tell the user what was **kept**?
- Should this be `red` (stop) or `yellow` (continue degraded)?

If the answer involves "the user must fix this by hand", the return code is **2**, not 1.

→ See `spec/runtime/transactions.md` and `spec/shell/bash-conventions.md` §4.

---

## Pre-modification rule (CRITICAL)

> **Before changing ANY value, search first!**

This single habit prevents most "forgot to update X" bugs in this repository, because the project
deliberately pins its contracts as literal text in many places.

---

**Core principle**: 30 minutes of thinking saves 3 hours of debugging on a machine you cannot reach.
