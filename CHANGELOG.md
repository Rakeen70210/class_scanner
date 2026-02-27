# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2026-02-27

### Fixed

- On startup (`ADDON_LOADED`), any existing DB entry whose spec field contains an invalid name is automatically cleared.
- Added `/cs cleanspecs` command to manually scrub invalid spec entries from the database.

## [1.3.0] - 2026-02-27

### Added

- Added a new **Top Spec** stat card in the UI header, similar to **Top BG Class**.
- Top Spec is computed from the current filtered result set, so changing filters (including Battleground location) updates the top spec accordingly.
- Added a hover tooltip on Top Spec showing a full spec breakdown by player count.
- Added per-spec color mapping so Top Spec value text and tooltip entries are color-coded by specialization.

## [1.2.2] - 2026-02-26

### Fixed

- **Talent detection fails on Ascension** — `GetTalentTabInfo` returns 0 points in all tabs. Self-spec detection (`UpdateSelfSpecFromTalents` and `TryUpdateSpecFromUnit`) now falls through to buff-based detection when talents return nothing.
- Removed ambiguous "Lightning Shield" → "Elemental/Enhancement" buff mapping.

### Added

- Massively expanded buff-name recognition table with **talent-proc buffs** for all 10 classes (e.g., Elemental Oath → Elemental, Maelstrom Weapon → Enhancement, Hot Streak → Fire, Shadow Dance → Subtlety, etc.).
- Buff detection now fires for your own character when talent detection fails, not just for other players.

## [1.2.1] - 2026-02-26

### Fixed

- Spec detection now matches by **spell name** (in addition to spell ID), fixing detection on clients where spell IDs differ from retail WotLK (e.g., rank-specific IDs or Ascension remaps).
- Buff-based spec detection now also matches by buff name as fallback.
- Lowered default `specEvidenceMinHits` from 2 to 1 so a single distinctive spell cast is enough to infer a spec.
- Added `tonumber()` coercion for spell IDs from the combat log to handle string-typed IDs.

### Added

- `/cs specdebug` — toggles verbose spec detection debug output in chat (shows buff scans, combat spell matches, talent tab info, and evidence accumulation in real time).
- `/cs spectest` — dumps your own talent tab info, current DB spec entry, and target buff list for diagnosis.

## [1.2.0] - 2026-02-26

### Added

- Specialization tracking per player (`spec`, `specSource`, `specConfidence`, `specUpdatedAt`) with confidence-aware merge rules.
- Multi-source specialization detection on Ascension Bronzebeard:
  - Self talent parsing (`PLAYER_LOGIN`, `PLAYER_TALENT_UPDATE`, `ACTIVE_TALENT_GROUP_CHANGED`)
  - Target inspect parsing (`INSPECT_READY`, throttled `NotifyInspect`)
  - Buff/aura inference for obvious specs/forms/presences
  - Combat-log spell heuristics using distinctive spec abilities
- UI: Spec filter dropdown and row display now includes race + detected spec.
- Tooltips: added spec details and source/confidence metadata.

### Changed

- Search now matches specialization and specialization source fields in both UI and `/cs search` output.
- Existing databases are backfilled to normalize any legacy spec strings when available.

## [1.1.0] - 2026-02-25

### Added

- Combat damage tracking: records the hardest single hit and peak burst DPS (configurable sliding window, default 3s) from each player that damages you.
- Pet/guardian damage attribution: pet damage is attributed to the owner via SPELL_SUMMON tracking when possible.
- UI: Sort dropdown (Most Seen / Most Damage / Hardest Hit / Max Burst DPS) for ranking players by combat stats.
- UI: Player tooltips now display a Combat Stats section showing total damage, hardest hit (with spell name), and max burst DPS.
- Slash commands: `/cs topdmg [n]` prints top N players by damage to you; `/cs topclassdmg [n]` prints top N classes.
- Slash commands: `/cs dmg on|off` toggles damage tracking; `/cs burst <sec>` sets burst window; `/cs dmgclear` clears combat data.
- Settings: `trackDamageToPlayer`, `burstWindowSec`, `encounterTimeoutSec`, `includePeriodicDamage`, `includeDamageShields`.

## [1.0.10] - 2026-02-25

### Added

- UI: Added a **Location** filter (World/Dungeon/Raid/Battleground/etc.) to show a full breakdown for a specific first-met context.
- UI: Added a **Top BG Class** stat card; hover it for a complete per-class battleground count breakdown.

### Changed

- UI: Reflowed filters into two rows to keep all controls within the frame.

## [1.0.8] - 2026-02-22

### Added

- Track and store where you first met a player (zone/subzone and instance/BG context) as a write-once field per player.
- UI: Added a compact "Met" column and extended the row tooltip to show first-met details.

## [1.0.9] - 2026-02-22

### Added

- UI: Class header rows now show a per-class breakdown of where players were first met (World/Dungeon/BG/etc.).
- UI: Hovering a class header shows a tooltip with the full breakdown.

## [1.0.7] - 2026-01-27

### Fixed

- Normalized class tokens when ingesting/storing data (e.g., battleground scoreboards returning localized class names) to prevent duplicate class buckets in the class distribution legend.

## [1.0.6] - 2026-01-20

### Added

- Mouseover suppression: prevent repeated scans of the same player via mouseover to reduce processing overhead.

### Changed

- Enhanced tooltip handling: improved logic for capturing player data from tooltips with better throttling and reliability.

## [1.0.5] - 2026-01-15

### Added

- Nameplate scanning: detect and scan player nameplates (uses C_NamePlate.GetNamePlates when available) and fallback to legacy nameplate unit tokens.
- Tooltip resolver queue: programmatic tooltip scanning with throttling to capture tooltip-protected player info from tooltips.

### Changed

- Enhanced player scanning logic: more robust GUID scanning (combat log, group, battleground), better backfilling of class/race/level information, and refreshed last-seen timestamps when improved data is observed.


## [1.0.4] - 2026-01-14

### Changed

- UI: Removed the global "Filters" header and positioned per-filter titles directly above each control (Faction, Race, Class, Level). Labels are now centered above each dropdown and widths adjusted to match controls.



## [1.0.3] - 2025-12-30

### Added

- List view statistics header:
  - Total players (for current filters)
  - Most detected class
  - Most played race
  - Level spread (min-max) and average level (based on known levels only)
- Per-class average level displayed under each class header.
- Class-counts summary near the top of the list (counts per class for current filters).

### Changed

- Sorting now prioritizes classes by frequency (most seen first), then class name, then recency.
- Race tokens are normalized for display/statistics (e.g., `NightElf` → `Night Elf`, `BloodElf` → `Blood Elf`).

## [1.0.2] - 2025-12-29

### Changed

- Grouped the player list by class with class headers.
- Updated list sorting to prioritize class grouping.

## [1.0.1] - 2025-12-29

### Added

- Settings management (quiet mode and print throttling).
- `/cs refresh`, `/cs help`, and improved `/cs` command handling.

### Changed

- Improved age formatting in the list view.
- Improved player scanning robustness (GUID validation and safer scanning from combat log events).

## [1.0.0] - 2025-12-29

### Added

- Initial release of ClassScanner.
- Tracks player race/class/level when encountered (target, mouseover, combat log proximity).
