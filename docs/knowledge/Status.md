# Project Status

## Current state

- BG MVP tab expansion is in progress: match history (top 3 damage/healing per match), windowed view, and class/spec leaderboards with wins and peaks.
- Scoreboard parsing for `GetBattlefieldScore()` is now defensive to handle Ascension/WotLK return-order variants.
- Changes are uncommitted and need in-game verification.

## Active priorities

- Verify BG MVP history capture and leaderboard correctness in-game (class/spec alignment, top-3 per match, Unknown-spec exclusion for spec leaderboards).
- Commit changes once verified.

## Blockers

- `bin/validate-addon.sh --strict` cannot run locally until `lua5.1` tooling is installed.

## Next steps

- Test a few battlegrounds and confirm scoreboard-derived fields (class/race/damage/healing) are correct.
- Confirm resets and backups include `ClassScannerBGMVPHistory`.
- Commit the BG MVP history/leaderboard changes.
