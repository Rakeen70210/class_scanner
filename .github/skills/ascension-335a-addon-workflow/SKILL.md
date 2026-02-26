---
name: ascension-335a-addon-workflow
description: "**WORKFLOW SKILL** — Develop and maintain the ClassScanner WoW addon for Ascension.gg (Bronzebeard) on the custom 3.3.5a client (WotLK, Interface: 30300). USE FOR: adding features/bugfixes in `ClassScanner/ClassScanner.lua`, updating `ClassScanner/ClassScanner.toc`, adding slash commands (`/cs`), evolving SavedVariables (`ClassScannerDB`, `ClassScannerSettings`), and updating `README.md` + `CHANGELOG.md` (Keep a Changelog + SemVer). INCLUDES: researching Ascension-Addons repos when Ascension-specific APIs/quirks are involved, and running repo packaging tasks (tar.gz + zip). DO NOT USE FOR: non-addon tasks or doc-only edits."
---

# ClassScanner Addon Workflow (Ascension 3.3.5a)

Implement or modify **ClassScanner**, a World of Warcraft addon used on Ascension’s custom 3.3.5a client.

## When to use

Use this skill when you want to:

- Implement a new feature or fix a bug in `ClassScanner`.
- Add or change scanning sources (target/mouseover/nameplates/group/scoreboard/combat log).
- Add or change SavedVariables (`ClassScannerDB`, `ClassScannerSettings`) or defaults/backfills.
- Add or change `/cs` slash commands, UI sorting/filtering, or tooltip rendering.
- Add Ascension-specific compatibility guards when a standard API is missing/quirky.

## When *not* to use

- Pure documentation-only edits that don’t change addon behavior.
- Tasks unrelated to WoW addons.

## Inputs I expect

- The feature request (what to add/change, and why).
- Any constraints (performance, no chat spam, avoid in-combat UI edits, etc.).

## Outputs I will produce

- Code changes (primarily in `ClassScanner/ClassScanner.lua`).
- Updated `ClassScanner/ClassScanner.toc` if version/SavedVariables/files change.
- Updated `README.md` for user-facing usage/commands.
- Updated `CHANGELOG.md` (Keep a Changelog + SemVer) when behavior changes.
- Packaged artifacts by running the repo’s packaging tasks.

## Workflow

### 0) ClassScanner repo conventions (pin these first)

- Addon folder: `ClassScanner/`
- Entry points:
  - `ClassScanner/ClassScanner.toc`
  - `ClassScanner/ClassScanner.lua` (single-file addon)
- Target client: `## Interface: 30300`
- SavedVariables:
  - `ClassScannerDB` (player DB)
  - `ClassScannerSettings` (settings)
- Documentation/versioning:
  - `CHANGELOG.md` uses Keep a Changelog and Semantic Versioning

If the request conflicts with these conventions, call it out and propose the smallest safe refactor.

### 1) Confirm client + addon metadata

- Ensure the `.toc` targets Ascension/WotLK: `## Interface: 30300`.
- Verify `.toc` lists:
  - `## Title`, `## Notes`, `## Author`
  - `## Version` (SemVer)
  - `## SavedVariables` (if any)
  - All Lua/XML file entries in correct load order

If adding a new file, add it to the `.toc`.

### 2) Decide: standard WoW API vs Ascension-specific behavior

- If the request is straightforward with standard WotLK APIs (events, Unit* APIs, tooltips, combat log varargs), implement directly.
- If it’s not straightforward (e.g., “Ascension button”, “broadcasts”, “custom systems”, undocumented behavior), research patterns in Ascension-maintained addon repos:
  - https://github.com/orgs/Ascension-Addons/repositories?type=all

Prefer looking at:

- `.toc` conventions (Interface number, SavedVariables, XML usage)
- README install notes (folder naming expectations)
- How they handle combat log / custom events / throttling

Only after you find a working pattern should you mirror it.

### 3) Design data + SavedVariables safely

- Prefer additive changes: backfill defaults on load rather than requiring migrations.
- Keep SavedVariables stable; if you must rename fields, include a one-time migration block.
- If storing per-player/per-GUID data, avoid unbounded growth:
  - add expiry, max sizes, or periodic pruning.

ClassScanner-specific: if you add a setting, update `DefaultSettings()` and the backfill logic under `ADDON_LOADED`.

### 4) Implement in an event-driven, low-overhead style

- Prefer event triggers (`ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_TARGET_CHANGED`, etc.) over tight OnUpdate loops.
- Throttle work that can fire frequently (mouseover, nameplate scans, combat log).
- Avoid expensive work during combat when possible (`InCombatLockdown()` guards for UI and heavy scans).
- Combat log handling:
  - On some Ascension 3.3.5a environments, prefer parsing `COMBAT_LOG_EVENT_UNFILTERED` varargs directly rather than relying on modern helpers like `CombatLogGetCurrentEventInfo()`.

ClassScanner-specific scanning guidance:

- If you add a new scan source, add a `source` string and plumb it into `ScanPlayer(..., source)` so “first met” context remains explainable.
- If you add periodic work, keep it behind a conservative ticker and/or guard it with `InCombatLockdown()` if it can be skipped during combat.

### 5) UI/UX expectations

- Provide slash commands for core interactions and troubleshooting.
- Make UI resilient:
  - nil checks
  - sane defaults when data is missing
  - avoid taint-prone operations in combat
- Keep chat output optional (quiet mode / throttling).

### 6) Verification checklist

- No Lua syntax errors; no accidental global leaks.
- SavedVariables initialize correctly on first install and upgrade.
- Feature works in:
  - world
  - instances/battlegrounds (if relevant)
- No performance cliffs:
  - throttled scans
  - bounded tables

### 7) Release hygiene

- Bump `.toc` `## Version` when behavior changes.
- Add a new entry in `CHANGELOG.md` with date, and categorize changes (Added/Changed/Fixed).
- Run the repo’s build/package tasks so distributables are updated:
  - “Package Addon” (tar.gz)
  - “Zip Addon” (zip)

## ClassScanner-specific “don’t forget” list

- If you add/change slash commands: update in-code help text and `README.md`.
- If you add/change SavedVariables: update `ClassScanner/ClassScanner.toc` and ensure defaults/backfills are present.
- If you change user-visible behavior: add a `CHANGELOG.md` entry and bump `.toc` `## Version`.
- Before finishing: run both packaging tasks.

## Prompts that work well with this skill

- “Add a new slash command to export stats to chat, and update the changelog.”
- “Track a new per-player metric from combat log damage events without hurting performance.”
- “This feature might need Ascension-specific APIs—research Ascension-Addons repos for an example, then implement.”
