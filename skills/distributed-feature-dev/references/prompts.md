# Prompt and file templates

`orch.py` automatically puts a preamble in front of every prompt. It covers the
isolated worktree, reading AGENTS.md and the plan, no commits, no weakening of
tests, protected paths, the verify command, and for QA the read-only rule and
the report format. Don't repeat those rules. Write only the task-specific part.

Save every prompt as `.orch/prompts/<task-id>.r<round>.md` so there is a record
of exactly what each worker was told.

## Contents
1. AGENTS.md (shared project rules) + CLAUDE.md
2. docs/orch/plan.md (shared plan)
3. Task prompt
4. Fix prompt
5. QA prompt
6. Quota handoff prompt

---

## 1. AGENTS.md + CLAUDE.md

Commit both to the feature branch before the first dispatch. Every agent reads
AGENTS.md (the preamble tells them to). Claude Code also auto-loads CLAUDE.md,
so make CLAUDE.md a single line that imports AGENTS.md. If the repo already has
these files, extend them instead of replacing them.

```markdown
# AGENTS.md
## Project
<one paragraph: what the app is, main stack, directory map with real paths>

## Commands
- install: `<cmd>`   build: `<cmd>`   test: `<cmd>`   lint: `<cmd>`
- run one test: `<cmd>`

## Conventions
- <naming, file layout, error handling, logging, i18n...>
- <libraries to use / never add new dependencies without listing them in your notes>

## Hard rules
- Never edit files outside the ones your task owns.
- Never touch tests under `tests/contract/` — they define the expected behaviour.
```

`CLAUDE.md`:
```markdown
@AGENTS.md
```

## 2. docs/orch/plan.md

```markdown
# Feature: <name>
## Goal
<what the user gets>
## Done when (feature-level acceptance)
- [ ] ...
## Contracts (already on the feature branch)
- `<path>`: <interface/type/API/schema summary>
- Contract tests: `tests/contract/<...>`
## Tasks
| id | owner (worker:agent@model) | owns files | depends on | acceptance |
|----|----------------------------|-----------|------------|------------|
| api | pc1:claude@<model> | src/api/** | contracts | tests/contract/api.* pass |
```
Update the owner column whenever a task is handed off.

## 3. Task prompt (first dispatch)

```markdown
# Task <TASK-ID>: <short title>

## Context
<2-6 sentences: where this fits, which existing modules matter, real paths.>

## Your job
<Precise description of what to build.>

## Files you own
- <path or glob>
Anything else that must change: describe it in your notes file, don't do it.

## Contracts you must respect
<Exact signatures / API shapes / schema. Do not rename or "improve" them.>

## Acceptance criteria
- [ ] Contract tests pass: `<cmd for this task's tests>`
- [ ] <observable behaviour>
- [ ] New tests for edge cases: <which>
```

## 4. Fix prompt (reject → fix round)

One issue key per prompt. Quote the evidence verbatim.

````markdown
# Fix for task <TASK-ID> — issue `<ISSUE-KEY>` (round <N> of <MAX>)

Your work on this branch was reviewed and is NOT accepted yet. Your previous
commits are already here. Fix only what is below.

## Problem
<What is wrong, concretely.>

## Evidence
```
<exact failing output / QA blocker / diff excerpt, trimmed>
```
Location: `<file>:<line>`

## Required
1. <specific change>

## Done when
- [ ] `<exact command the manager will run>` passes

<round >= 2:> Last attempt you <what they did>; it failed because <reason>.
Use a different approach.
````

## 5. QA prompt (independent reviewer)

The preamble already gives the read-only rule and the report format.

```markdown
# QA for task <TARGET-ID>: <title>

## What was supposed to be built
<copy the task's "Your job" and acceptance criteria>

## Check
1. Run `<verify cmd>` and `<task test cmd>`.
2. Exercise the behaviour: <how — start server, call endpoint, open screen...>
3. Look for: edge cases <list>, error handling, contract compliance with <paths>,
   changes outside owned files <list>, security issues (input validation, secrets).
Report only real problems with evidence; style preferences are Nits.
```

## 6. Quota handoff prompt (re-dispatch to a fallback agent)

```markdown
# Continue task <TASK-ID> (handoff)

The previous agent (<worker:agent@model>) stopped because its quota ran out.
Its partial work is already committed on this branch — read `git log` and
`git diff origin/<feature-branch>...HEAD` first, then continue. Don't start over.

## Original task
<paste the original task prompt body>

## Status at handoff
- Done: <from the diff>
- Remaining: <list>
```
