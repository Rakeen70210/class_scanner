## Issue Tracking (Beads / `bd`)

This project uses **Beads** (`bd`) for task tracking and long-horizon planning.

### Always do this first

- `bd prime` (or `bd prime --work-type recovery` if resuming after an interruption)

### Quick reference

- `bd ready` — list unblocked work
- `bd create "Title" -p 2 -t task` — create an issue
- `bd show <id>` — view details
- `bd update <id> --claim` — start work
- `bd dep add <child> <parent>` — add a blocking dependency
- `bd close <id> "<reason>"` — finish work
- `bd dolt pull` / `bd dolt push` — sync issue DB (if a remote is configured)

### Notes

- Prefer `--json` output when you need to process results.
- Avoid interactive editor flows (`bd edit`); use `bd update` flags or stdin (`--description=-`).
- See `.github/skills/beads-workflow/SKILL.md` for full workflow patterns and recipes.
