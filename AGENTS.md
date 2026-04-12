# Project Guidelines

## Scope

- Use this file as the single workspace instruction source for agent behavior.

## Build And Validation

- Run `bin/validate-addon.sh` before finishing code changes.
- Use `bin/validate-addon.sh --strict` to mirror CI behavior when Lua 5.1 tooling is available.
- Packaging tasks are defined in [.vscode/tasks.json](.vscode/tasks.json):
	- `Zip Addon`
	- `Package Addon`
- Coverage policy is defined in [.coverage-thresholds.json](.coverage-thresholds.json). Current enforcement command is `true` (coverage disabled until an automated test suite exists).

## Task tracking (Beads / `bd`)

This repo uses **Beads** (`bd`) for long-horizon task tracking and context recovery.

### Agent workflow

- Start by loading context:
	- `bd prime` (normal)
	- `bd prime --work-type recovery` (after interruption/compaction)
- Pick work:
	- `bd ready` (unblocked work)
	- `bd show <id>` (details)
	- `bd update <id> --claim` (start work)
- Track structure:
	- Dependencies: `bd dep add <child> <parent>` (parent *blocks* child)
	- Use relationships like `relates_to`, `duplicates`, `supersedes`, `replies_to` when relevant
	- Use epics + child IDs (`bd-xxxx.1`, `bd-xxxx.2`) for larger features
- Finish:
	- `bd close <id> "<reason>"`
	- If a Dolt remote is configured, sync at the end: `bd dolt push`

### Guardrails

- Prefer `bd ... --json` for machine consumption.
- Avoid interactive editor flows (`bd edit`); use `bd update` flags or stdin (`--description=-`) instead.
- Optional: install Beads git hooks for automatic sync behavior: `bd hooks install`.
- This repo gitignores `.beads/` runtime state; do not commit it. For shared issue tracking, configure a Dolt remote and rely on `bd dolt push` / `bd dolt pull`.

## Architecture

- Target client is Ascension 3.3.5a (`Interface: 30300`).
- Module load order is defined in [ClassScanner/ClassScanner.toc](ClassScanner/ClassScanner.toc):
	1. `Constants.lua`
	2. `Utils.lua`
	3. `SpecDetection.lua`
	4. `Scanning.lua`
	5. `CombatTracking.lua`
	6. `UI.lua`
	7. `ClassScanner.lua`
- Modules share a single addon table via `local addonName, CS = ...`.
- SavedVariables are `ClassScannerDB`, `ClassScannerSettings`, and `ClassScannerBackups`.

## Conventions

- Keep [ClassScanner/ClassScanner.toc](ClassScanner/ClassScanner.toc) synchronized with added/renamed Lua files.
- Prefer WotLK 3.3.5a-compatible APIs and patterns. Do not assume modern retail WoW APIs.
- For combat log handling, prefer varargs parsing in `COMBAT_LOG_EVENT_UNFILTERED` paths.
- Make SavedVariables changes additive when possible: add defaults/backfills instead of destructive migrations.
- When user-visible behavior changes, update both [README.md](README.md) and [CHANGELOG.md](CHANGELOG.md).

## Link, Do Not Duplicate

- User-facing usage and command documentation: [README.md](README.md)
- Release history: [CHANGELOG.md](CHANGELOG.md)
- Addon implementation workflow and Ascension-specific coding guidance: [.github/skills/ascension-335a-addon-workflow/SKILL.md](.github/skills/ascension-335a-addon-workflow/SKILL.md)
- Beads workflow + command recipes: [.github/skills/beads-workflow/SKILL.md](.github/skills/beads-workflow/SKILL.md)
- Service inventory template/status: [SERVICE-INVENTORY.md](SERVICE-INVENTORY.md)

## Project knowledge rules

- The project knowledge lives in `docs/knowledge/`.
- Prefer updating `Status.md`, `Notes.md`, and `Decisions.md` before creating extra files.
- Extra files may be created under `docs/knowledge/` only when clearly warranted.
- If an extra file is created, reference it from a canonical knowledge file.
- When you are about to report a task as done, fixed, implemented, completed, ready, or move on after finishing meaningful work, invoke the `knowledge-maintenance` skill first.
- If the `knowledge-maintenance` skill decides the work was non-material, skip note updates.
- If it decides the work was material, update the relevant knowledge files before the completion response.
