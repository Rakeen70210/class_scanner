# Project Decisions

## Decisions

### Defensive parsing for `GetBattlefieldScore()`

- Decision: Parse `GetBattlefieldScore()` returns defensively (scan for class/race tokens and derive damage/healing positions), rather than relying on a fixed positional signature.
- Rationale: Return order varies across WotLK/Ascension variants; fixed positional unpacking can misalign class/race/damage/healing.
- Consequences: The parsing logic is more complex, but it is resilient to upstream API variance and reduces silent data corruption in BG MVP history.

## Decision format

For each decision, record:

- Decision
- Rationale
- Consequences
