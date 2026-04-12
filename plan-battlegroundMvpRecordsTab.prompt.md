## Plan: Battleground MVP Records Tab

Add battleground-end MVP capture using scoreboard totals, then surface it in a dedicated UI tab with two sections.  
Each completed battleground records exactly two outcomes:
1. Top Damage winner
2. Top Healing winner

Records are stored as a rolling list, deduplicated by player + role, so the same player winning the same role later overwrites their prior role record.

Note: This file documents the original MVP tab implementation. The addon now also stores a capped match history to support class/spec leaderboards.

**Steps**
1. Add persisted BG MVP data fields and additive backfill in initialization logic.
2. Track battleground session lifecycle (active vs ended) and keep per-session scoreboard candidate totals.
3. Extend scoreboard parsing so each player stores session damageDone and healingDone candidates.
4. On battleground end, compute and persist exactly two winners (damage + healing).
5. Apply overwrite rule keyed by playerKey + role.
6. Add a new UI tab control in the header and introduce view state switching.
7. Build tab content with two sections:
1. Top Damage table
2. Top Healing table
8. Keep existing filters/sort/search behavior scoped to the Players view; BG MVP tab uses role-specific sorting by value then recency.
9. Extend battleground reset scope so battleground data reset also clears BG MVP records.
10. Update command help/docs/changelog and run validation.

**Phase grouping**
1. Data and lifecycle plumbing (steps 1-5)
2. UI integration (steps 6-8, depends on phase 1)
3. Reset/docs/verification (steps 9-10, depends on phases 1-2)

**Relevant files**
- [ClassScanner/Scanning.lua](ClassScanner/Scanning.lua) — battleground score ingestion and session boundary handling.
- [ClassScanner/ClassScanner.lua](ClassScanner/ClassScanner.lua) — event registration, SavedVariables backfill, reset scope wiring, help text.
- [ClassScanner/UI.lua](ClassScanner/UI.lua) — tab controls and BG MVP tab renderer (two sections).
- [ClassScanner/Utils.lua](ClassScanner/Utils.lua) — only if a new default setting toggle is introduced.
- [README.md](README.md) — user-facing behavior documentation.
- [CHANGELOG.md](CHANGELOG.md) — Added/Changed release notes.

**Verification**
1. Run bin/validate-addon.sh.
2. In-game test: complete one battleground and verify exactly two winners are stored.
3. Complete another battleground where the same player wins the same role and verify overwrite (no duplicate for that player-role).
4. Verify one player can hold both roles at once (two distinct records).
5. Verify Players view behavior is unchanged.
6. Verify battleground data reset clears both old battleground flags and new MVP records.

**Locked decisions from your answers**
- Storage: rolling list across battlegrounds.
- Metrics shown: raw totals only (no DPS/HPS).
- UI layout: separate tab with two sections.
- Deduplication: player + role.

If this plan looks right, I can hand this off for implementation exactly as specified.
