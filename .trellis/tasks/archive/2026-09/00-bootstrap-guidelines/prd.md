# Bootstrap Task: Fill Project Development Guidelines

**You (the AI) are running this task. The developer does not read this file.**

The developer just ran `trellis init` on this project for the first time.
`.trellis/` now exists with empty spec scaffolding, and this bootstrap task
exists under `.trellis/tasks/`. When they want to work on it, they should start
this task from a session that provides Trellis session identity.

**Your job**: help them populate `.trellis/spec/` with the team's real
coding conventions. Every future AI session — this project's
`trellis-implement` and `trellis-check` sub-agents — auto-loads spec files
listed in per-task jsonl manifests. Empty spec = sub-agents write generic
code. Real spec = sub-agents match the team's actual patterns.

Don't dump instructions. Open with a short greeting, figure out if the repo
has any existing convention docs (CLAUDE.md, .cursorrules, etc.), and drive
the rest conversationally.

---

## Status (update the checkboxes as you complete each item)

- [x] Fill shell guidance (authoring `src/*.sh`)
- [x] Fill runtime guidance (installed-system invariants)
- [x] Fill build guidance (artifact + version pins)
- [x] Fill test guidance (harness + rename coupling)
- [x] Add code examples with real file paths
- [x] Remove non-applicable template layers (`backend/`, `frontend/`)

**Completed 2026-09-13 by @SB.** The template's `backend`/`frontend` layers do not
apply — this repository is a single Bash script, not a fullstack application. The
spec was rebuilt around the repository's real ownership boundaries, with every
rule backed by a verified `file:line` citation.

---

## Spec files to populate

### Shell layer — authoring `src/*.sh`

| File | What it documents |
|------|-------------------|
| `.trellis/spec/shell/module-structure.md` | Module ownership map, top-level code rules, embedded heredoc programs |
| `.trellis/spec/shell/bash-conventions.md` | No `set -e`, the three error idioms, exit codes 0/1/2/75, quoting, `10#`, `local` |
| `.trellis/spec/shell/input-validation.md` | `valid_*` predicate contract, prompt/retry loops, menu input |
| `.trellis/spec/shell/user-output.md` | `red`/`green`/`yellow`/`blue`/`readp` severity model, Chinese UX text |

### Runtime layer — installed-system invariants

| File | What it documents |
|------|-------------------|
| `.trellis/spec/runtime/managed-assets.md` | `/etc/sb` layout, marker files, three ownership proofs, permissions |
| `.trellis/spec/runtime/atomic-writes.md` | candidate → validate → `mv -fT` protocol; `commit_config` |
| `.trellis/spec/runtime/service-management.md` | systemd/OpenRC duality, unit ownership, verified start/cleanup |
| `.trellis/spec/runtime/certificates.md` | ACME staging, generation switching, reload hook, lock ordering, secrets |
| `.trellis/spec/runtime/transactions.md` | Install vs repair transactions, signal handling, rollback, last-good |

### Build layer — artifact & release

| File | What it documents |
|------|-------------------|
| `.trellis/spec/build/build-contract.md` | Module manifest, header markers, text hygiene, `sb.sh` generation |
| `.trellis/spec/build/version-pins.md` | `VERSION` sync in four places, pinned versions/digests, security pins |
| `.trellis/spec/build/repository-conventions.md` | `.editorconfig`/`.gitattributes`/`.gitignore`, CI entry point, toolchain |

### Tests layer

| File | What it documents |
|------|-------------------|
| `.trellis/spec/tests/harness.md` | Gate order, TAP protocol, sandboxing, mocks, function extraction |
| `.trellis/spec/tests/writing-tests.md` | Recipe for adding a test; the rename coupling map; known gaps |

### Thinking guides (adapted)

`.trellis/spec/guides/` was rewritten from the fullstack template into
project-grounded versions: cross-layer now covers the module→artifact→child-process→cron→test-pin
boundaries, and code-reuse covers the existing helper families and the build-fatal duplicate-name
rule.


### Thinking guides (already populated)

`.trellis/spec/guides/` contains general thinking guides pre-filled with
best practices. Customize only if something clearly doesn't fit this project.

---

## How to fill the spec

### Step 1: Import from existing convention files first (preferred)

Search the repo for existing convention docs. If any exist, read them and
extract the relevant rules into the matching `.trellis/spec/` files —
usually much faster than documenting from scratch.

| File / Directory | Tool |
|------|------|
| `CLAUDE.md` / `CLAUDE.local.md` | Claude Code |
| `AGENTS.md` | Codex / Claude Code / agent-compatible tools |
| `.cursorrules` | Cursor |
| `.cursor/rules/*.mdc` | Cursor (rules directory) |
| `.windsurfrules` | Windsurf |
| `.clinerules` | Cline |
| `.roomodes` | Roo Code |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.vscode/settings.json` → `github.copilot.chat.codeGeneration.instructions` | VS Code Copilot |
| `CONVENTIONS.md` / `.aider.conf.yml` | aider |
| `CONTRIBUTING.md` | General project conventions |
| `.editorconfig` | Editor formatting rules |

### Step 2: Analyze the codebase for anything not covered by existing docs

Scan real code to discover patterns. Before writing each spec file:
- Find 2-3 real examples of each pattern in the codebase.
- Reference real file paths (not hypothetical ones).
- Document anti-patterns the team clearly avoids.

### Step 3: Document reality, not ideals

**Critical**: write what the code *actually does*, not what it should do.
Sub-agents match the spec, so aspirational patterns that don't exist in the
codebase will cause sub-agents to write code that looks out of place.

If the team has known tech debt, document the current state — improvement
is a separate conversation, not a bootstrap concern.

---

## Quick explainer of the runtime (share when they ask "why do we need spec at all")

- Every AI coding task spawns two sub-agents: `trellis-implement` (writes
  code) and `trellis-check` (verifies quality).
- Each task has `implement.jsonl` / `check.jsonl` manifests listing which
  spec files to load.
- The platform hook auto-injects those spec files + the task's `prd.md`
  into every sub-agent prompt, so the sub-agent codes/reviews per team
  conventions without anyone pasting them manually.
- Source of truth: `.trellis/spec/`. That's why filling it well now pays
  off forever.

---

## Completion

When the developer confirms the checklist items above are done with real
examples (not placeholders), guide them to run:

```bash
python3 ./.trellis/scripts/task.py finish
python3 ./.trellis/scripts/task.py archive 00-bootstrap-guidelines
```

After archive, every new developer who joins this project will get a
`00-join-<slug>` onboarding task instead of this bootstrap task.

---

## Suggested opening line

"Welcome to Trellis! Your init just set me up to help you fill the project
spec — a one-time setup so every future AI session follows the team's
conventions instead of writing generic code. Before we start, do you have
any existing convention docs (CLAUDE.md, .cursorrules, CONTRIBUTING.md,
etc.) I can pull from, or should I scan the codebase from scratch?"
