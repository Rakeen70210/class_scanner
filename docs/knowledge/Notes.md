# Project Notes

## Notes

- BG MVP tab now has a match-history model (array of match snapshots) rather than only a deduped per-player record store. Each match snapshot stores top 3 for damage and healing.
- The existing `ClassScannerBGMVPRecords` (rank #1 only, deduped) is still maintained for “all-time peak per player” style usage, while history powers the UI.
- New SavedVariable: `ClassScannerBGMVPHistory` (capped; currently 200 matches).

## Research and findings

- `GetBattlefieldScore()` return order differs across WotLK/Ascension variants; unpacking by a fixed signature can misalign race/class/damage/healing.
- Implemented defensive parsing in `Scanning.lua`:
  - Detect class token / localized class name by scanning for strings recognized by `CanonicalizeClass`.
  - Detect race by scanning for strings that map to a known faction via `GetFactionFromRace` (with optional `CanonicalizeRace`).
  - Prefer damage/healing numbers found immediately after the class fields; fall back to the last two numeric fields if needed.

## Debugging insights

- Scoreboard parsing correctness is critical for BG MVP leaderboards; misalignment silently corrupts both history and win/peak aggregation.
