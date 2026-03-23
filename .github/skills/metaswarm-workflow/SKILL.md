---
name: metaswarm-workflow
description: "Use metaswarm for tracked development work in this repository. Use when the user wants to start or continue implementation through metaswarm, asks to use metaswarm explicitly, wants issue-backed work with beads, needs `/start-task`, `/prime`, `/review-design`, `/pr-shepherd`, or `/self-reflect`, or wants the full gated workflow instead of ad hoc edits. Do not use for casual questions, one-off explanations, or simple repository reads that do not need metaswarm orchestration."
---

# Metaswarm Workflow

Use metaswarm when work should be tracked, gated, and recoverable.

## When to use

- The user explicitly asks to use metaswarm.
- The task is a real implementation, bugfix, refactor, or review that should be tracked through beads.
- The work benefits from metaswarm gates such as planning, review, execution, or self-reflection.
- You need to resume work from prior metaswarm context in `.beads/` or `.metaswarm/`.

## When not to use

- Simple factual questions about the codebase.
- Tiny untracked edits where the user clearly does not want metaswarm overhead.
- Pure documentation or explanation requests with no workflow orchestration.

## Inputs I expect

- The user request.
- Any issue id, acceptance criteria, or constraints.

## Workflow

### 1) Prime the project context

- Use beads for work tracking. Prefer `bd prime`, `bd ready`, `bd show <id>`, and `bd update <id> --claim`.
- If beads is unavailable because Dolt cannot start in the sandbox, note that and continue with the code work unless tracking is the core task.

### 2) Enter metaswarm through the command shims

- For new tracked work, use `/start-task`.
- To reload project context before acting, use `/prime`.
- For design review, use `/review-design`.
- For post-implementation learning capture, use `/self-reflect`.
- For PR follow-through, use `/pr-shepherd`.

Prefer the short shim names. Do not recommend namespaced forms unless the shims are missing.

### 3) Follow repository guardrails

- Respect `.coverage-thresholds.json` as the metaswarm source of truth. In this repo the enforcement command is currently `true`, so run `bin/validate-addon.sh` for real validation.
- Keep work compatible with the Ascension 3.3.5a addon environment.
- If addon behavior changes, update `README.md` and `CHANGELOG.md`.
- Keep `.toc` entries in sync with added or renamed Lua files.

### 4) Close the loop

- Before finishing substantial work, run `bin/validate-addon.sh`.
- If metaswarm execution completed, run `/self-reflect` before wrapping up.
- Follow the repo’s push discipline from `AGENTS.md` and `CLAUDE.md`.

## Prompts that should trigger this skill

- "Use metaswarm for this feature."
- "Start this task with metaswarm."
- "Prime the metaswarm context and continue the work."
- "Run the tracked workflow for this bugfix."
