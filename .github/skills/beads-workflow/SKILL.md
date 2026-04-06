---
name: beads-workflow
description: "Use Beads (bd) for persistent task tracking: create/show/update/close issues, dependency graphs, messages/threads, sync via Dolt, backups/exports, and context recovery via bd prime."
---

# Beads Workflow (bd)

Beads (`bd`) is a local, offline-first issue tracker designed for AI-agent workflows. It stores issues in a version-controlled Dolt database under `.beads/`.

This skill is a **practical operator manual**: it focuses on workflows and command recipes, and links to upstream docs for deeper details.

## When to use

Use this skill when you need:

- Long-horizon task tracking (multi-step changes, multi-agent work, interruptions)
- Dependency-aware sequencing (`bd ready`)
- Stable IDs across branches/merges (hash-based IDs)
- Context recovery and “what was I doing?” (`bd prime`)

## When not to use

- Trivial one-line changes where issue overhead would exceed the work
- Interactive flows that require a TTY editor (avoid `bd edit` in agent contexts)

## Core concepts (what Beads can do)

### Issue types and hierarchy

- Issues are addressed by IDs like `bd-a1b2`.
- Epics can have hierarchical child IDs like `bd-a1b2.1`, `bd-a1b2.2`.

### Dependency graph

- Dependencies are typed and enable deterministic “ready work” detection.
- The most common relationship is **blocking** (parent blocks child).

### Relationships (knowledge graph)

Beads supports graph links such as:

- `relates_to`
- `duplicates`
- `supersedes`
- `replies_to` (useful for message threads)

### Storage & sync (Dolt)

- All writes are recorded in Dolt history.
- Collaboration happens through Dolt sync (`bd dolt push` / `bd dolt pull`).

### Compaction & recovery

- Beads supports compaction to reduce context window size.
- Recovery workflows should use `bd prime --work-type recovery`.

## Setup modes

Choose the mode that matches your repo + collaboration expectations.

### Standard (shared) mode

Use when you want to share issue state between machines/agents.

- `bd init` (interactive for humans)
- `bd init --quiet` (non-interactive for agents)

If a Dolt remote is configured, use `bd dolt push/pull` to sync.

### Stealth (local-only) mode

Use when you want Beads locally without repo-level side effects.

- `bd init --stealth`

You can also set `BEADS_DIR=/path/to/.beads` to bypass repo discovery.

### Contributor / maintainer routing

Beads can route planning issues to a separate location for contributors. See upstream docs.

## Command surface (index)

Use `bd --help` and `bd help <subcommand>` for the exact flags in your installed version.

Common command groups:

- **Discovery**: `bd ready`, `bd list`, `bd show <id>`
- **Authoring**: `bd create`, `bd update`, `bd close`
- **Ownership**: `bd update <id> --claim` (some versions also expose a dedicated `bd claim`)
- **Dependencies**: `bd dep add <child> <parent>`, `bd dep tree <id>`
- **Sync & storage (Dolt)**: `bd dolt status`, `bd dolt start`, `bd dolt stop`, `bd dolt pull`, `bd dolt push`, `bd dolt show`, `bd dolt commit`
- **Git hooks (optional)**: `bd hooks install`
- **Backups & portability**: `bd export`, `bd backup`, `bd backup restore` (see FAQ)
- **Conflict resolution**: `bd vc conflicts`, `bd vc resolve`
- **Federation**: `bd federation sync`
- **Daemon management**: `bd daemon start` / `bd daemon stop` (helpful for git-free setups)
- **Health checks**: `bd doctor`

If a command in this skill doesn’t match your installed version, fall back to `bd --help` and update the workflow accordingly.

## Daily workflow recipes (CLI)

### 1) Start of session: prime + pick work

```bash
bd prime
bd ready
bd show <id>
bd update <id> --claim
```

If resuming after interruption/compaction:

```bash
bd prime --work-type recovery
```

### 2) Create issues (tasks, bugs, features, epics)

```bash
bd create "Fix combat log parsing regression" -t bug -p 1
bd create "Refactor scanning pipeline" -t task -p 2
bd create "Export UI overhaul" -t epic -p 2
```

Tips for agents:

- Prefer `--json` output when you need to parse results.
- If shell escaping is painful, use stdin:

```bash
echo 'Description with `backticks` and "quotes"' | bd create "Title" --stdin
```

### 3) Update issue fields (without an editor)

Avoid `bd edit` in agent contexts. Use `bd update`:

```bash
bd update <id> --title "New title"
bd update <id> --description "New description"
bd update <id> --acceptance "Acceptance criteria"
bd update <id> --notes "Notes" \
  --design "Design notes"
```

For complex text:

```bash
echo 'long description…' | bd update <id> --description=-
```

### 4) Dependencies and trees

Add a blocking dependency:

```bash
bd dep add <child> <parent>
```

Explore what’s blocking what:

```bash
bd dep tree <id>
```

Then:

```bash
bd ready
```

### 5) Close work

```bash
bd close <id> "Implemented and validated"
```

### 6) Sync across machines/agents (recommended at end)

```bash
bd dolt pull
bd dolt push
```

If you work with multiple repos/peers, look into federation sync:

- `bd federation sync` (see upstream docs)

## Messages and threads

Use message issues when you want lightweight threaded discussions:

- Create message issues and use threading (`--thread`) to reply.

(Exact flags evolve; consult upstream docs for the current CLI surface.)

## Backups, export/import, and portability

- Day-to-day sync should use Dolt:
  - `bd dolt push` / `bd dolt pull`
- For portability:
  - `bd export` produces JSONL
  - `bd backup` can produce/restores snapshots (see FAQ)

## Daemon mode

If you need local daemon management (particularly in git-free or stealth setups), Beads supports daemon start/stop flows (see upstream docs and release notes).

## Troubleshooting (quick hits)

- Enable debug logging:

```bash
export BD_DEBUG=1
export BD_DEBUG_RPC=1
bd ready
```

- Inspect server logs:

```bash
tail -f .beads/dolt/sql-server.log
```

See upstream troubleshooting for fixes such as port conflicts and wrong-server routing.

## Upstream docs (authoritative)

- Main project README: https://github.com/steveyegge/beads
- Copilot integration: https://github.com/steveyegge/beads/blob/main/docs/COPILOT_INTEGRATION.md
- FAQ: https://github.com/steveyegge/beads/blob/main/docs/FAQ.md
- Troubleshooting: https://github.com/steveyegge/beads/blob/main/docs/TROUBLESHOOTING.md
- Protected branches / sync notes: https://github.com/steveyegge/beads/blob/main/docs/PROTECTED_BRANCHES.md

## Agent safety checklist

- ✅ Use `bd ... --json` when machine-reading output
- ✅ Use `bd update` flags / stdin; avoid `bd edit`
- ✅ Use `bd dep add` to model blockers (so `bd ready` works)
- ✅ Close issues when done (`bd close`)
- ✅ Sync at session end (`bd dolt push`) if remotes are configured
