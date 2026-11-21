---
name: distributed-feature-dev
description: Act as the lead/manager agent that splits one feature across several worker machines over SSH, running several coding agents per machine in parallel (Claude Code, opencode, agy/Antigravity) in isolated git worktrees sized to each machine's CPU/RAM, with contract tests, automatic verify/self-fix/rebase on the worker, independent QA by a different agent, quota-aware model/agent fallback, review, merge, fix prompts and takeover after 3 failed rounds. Use this whenever the user wants to build a feature "in parallel", "on my machines/devices/servers", "distribute the work to other agents", "use the full power of each machine", orchestrate agents over ssh, run a manager/worker or multi-agent team on a git repo, or mentions an agent-model-policy / adaptive-agent-skills setup — even if they don't say "orchestrate".
compatibility: Runs on the manager machine inside the project repo, with bash, git, python3 and SSH key access to every worker. Workers need git with push access, tmux, timeout (coreutils) and flock recommended, and their agent CLIs installed and logged in.
---

# Distributed feature development (manager role)

You are the **manager / technical lead**. You plan the feature, write the
contracts and contract tests, split the work into tasks, run them on as many
agent slots as the machines can carry, get finished work independently
QA'd, review, merge, send precise fix prompts, and own the final result.

All mechanics go through `scripts/orch.py` (run `python3 <skill-dir>/scripts/orch.py <cmd>`
from the repo root). Use it rather than ad-hoc ssh/git so `.orch/state.json`
stays right. The round limits, slots and quota tracking depend on it.
`orch.py -h` lists every command.

## What happens on a worker (so you know what to expect)

Each task runs in its own worktree `<repo_path>.wt/<task>` inside a tmux session:
agent works → runner commits → **rebases onto the latest feature branch**
(if that conflicts, the agent is asked to resolve it) → runs `verify` →
on red, the agent gets the failure output and fixes it, up to
`self_fix_attempts` times → pushes. It reports one of:
`done green` · `done red` · `done conflict` · `quota` · `timeout` · `failed: <why>`.
Partial work is always pushed, so a branch is a checkpoint you can hand to
another agent.

## Phase 0 — Setup and health check

1. `.orch/config.json` from `config.example.json` (fill it in with the user).
   Set `verify` to the project's lint+build+test command. Without it the
   worker can't check its own work, so always set it.
2. If `.config/agent-model-policy.yaml` exists (adaptive-agent-skills), read it
   now and follow `references/adaptive-agent-skills.md`. It decides roles,
   models and fallback order. Never invent model IDs.
3. `orch.py doctor`. Fix every ERROR before going on. If an agent's headless
   command is unknown (agy especially), ask the user and set it in config.
4. Clean working tree, then `orch.py init --feature <short-name>`.

## Phase 1 — Plan, contracts, shared context

Read the request and the codebase. Then, **on the feature branch, before any
dispatch**, commit:

1. `AGENTS.md` (+ `CLAUDE.md` containing `@AGENTS.md`): project rules,
   commands, conventions. Template in `references/prompts.md`. Every agent's
   preamble tells it to read this, so all machines write code the same way.
2. **Contracts**: interfaces, types, API shapes, DB schema that several tasks
   share. Implement them yourself.
3. **Contract tests**: failing tests that define each task's expected
   behaviour, under a path in `protected_paths` (e.g. `tests/contract/`).
   This makes review objective: "make these pass without editing them".
   `review` flags any change to protected paths.
4. `docs/orch/plan.md`: goal, feature-level acceptance, contracts, and a task
   table (id, owner worker:agent@model, owned files, depends-on, acceptance).

Task design:
- **Split by file ownership.** Two tasks that own the same file will conflict.
- **More, smaller tasks than slots.** Smaller tasks come back with fewer fix
  rounds, and a queue keeps every slot busy. Mark `depends on` and only
  dispatch a task once what it depends on is accepted.
- **Match tasks to agents and models.** Use the worker's `strengths` and the
  policy's `use_when`. Strong models for hard or cross-cutting tasks, fast ones
  for routine work, so quota lasts. Keep the most integrative part for yourself.

Show the plan to the user briefly; continue unless they object.

## Phase 2 — Fill every slot

`orch.py capacity` shows free slots per worker. Slots come from real CPU,
free RAM and load (`slots` in config), or from a fixed `max_slots`.
"NO FREE SLOT" (exit 4) means the machine is under pressure. Queue the task
or use another worker. Don't switch model for that.

For each ready task write a prompt (template: `references/prompts.md` §3) to
`.orch/prompts/<id>.r0.md`, then:
```
orch.py dispatch --task api --worker pc1 --agent claude --model <id-from-policy> --prompt-file .orch/prompts/api.r0.md
```
Keep dispatching until no free slot or no ready task is left.

## Phase 3 — Your own task, and the loop

`orch.py local --task core`. Implement, commit, push, `orch.py accept --task core`.

Between steps of your own work, run `orch.py status`. When idle, run `orch.py wait`.
It returns when something finishes, or when a task looks stalled (no file
activity for `stall_minutes`; check `log --task X --what agent`). Each time a
slot frees up, dispatch the next ready task (Phase 2) or a QA (Phase 4).

## Phase 4 — Handle each finished task

| Status | Action |
|---|---|
| `done green` | Independent QA, then review (below). |
| `done red` | Self-fix was exhausted. `log --task X --what verify`, then a fix prompt. |
| `done conflict` | Fix prompt with issue `merge-conflict`. The runner rebases again. |
| `quota` | Checkpoint is pushed. Fallback (below). |
| `timeout` / `failed` | `log` to see why. Fix prompt, re-dispatch, or take over. |

**Independent QA**: send it to a slot running a *different* agent from the
implementer. The script refuses the same agent unless you pass `--allow-self`,
and the policy may forbid that.
```
orch.py qa --task api --worker pc2 --agent opencode --prompt-file .orch/prompts/api.qa.md
orch.py report --task api-qa1            # once it finishes
```
QA works read-only. Its changes are discarded and it writes a VERDICT report.
Idle slots are perfect for QA.

**Review**: `orch.py review --task api --verify` (commits, files, protected-path
alarm, and verify run locally in `.orch/wt/api`). Add `--full` for the diff.
Read `docs/orch/notes/api.md` if it exists. Decide:

- **Accept** → `orch.py accept --task api` (merge --no-ff into the feature
  branch, push, clean the worker worktree). Exit 2 = conflict: resolve it
  yourself if small, otherwise reject with `merge-conflict`.
- **Reject** → fix prompt (§4) to `.orch/prompts/api.r<N>.md`, then
  `orch.py reject --task api --issue <key> --prompt-file ...`

Severity: **Blockers/Majors** go back to the worker and count as rounds.
**Nits** never go back. Fix them yourself after merging.

**Issue keys and limits**: the key names *the problem* (`auth-tests-fail`,
`missing-validation`, `merge-conflict`). Reuse it when the same problem returns.
After `max_fix_rounds` (3) on one issue, or `max_total_rounds` (5) on the task,
`reject` refuses with **TAKEOVER** (exit 3). Then run `orch.py takeover --task api`,
fix it yourself, push, accept. Never send that problem back again.

**Quota fallback** (follow the policy when there is one):
1. Same agent, next fallback model: `orch.py reject --task X --issue quota-handoff --model <next> --prompt-file <handoff>` (§6). Or use `dispatch` if you don't want it counted as a round.
2. Otherwise the next eligible agent, on any worker with a free slot:
   `orch.py dispatch --task X --worker pc3 --agent opencode --prompt-file <handoff>`
   If the policy requires approval for a role change, ask the user first.
3. `orch.py clear-quota --worker pc1 --agent claude [--model M]` once the quota resets. Quota is tracked per worker+agent+model, so a different model of the same agent stays usable.
Update the owner in `docs/orch/plan.md` and mention the substitution in the report.

## Phase 5 — Verify the whole feature

When `orch.py summary` says ALL TASKS ACCEPTED: check out the feature branch
fresh and run verify, plus anything else the project has (e2e, type check).
Walk every feature-level acceptance item in the plan, and run the feature
end-to-end if possible. For gaps: fix small ones yourself (`local`), and turn
separable ones into new tasks (back to Phase 2). Repeat until clean.

## Phase 6 — Report and hand over

Remove `docs/orch/notes/` (and `docs/orch/` itself unless the user wants to
keep it), commit, push. Report from `orch.py summary`: what was built, who did
what (worker:agent@model), fix rounds, takeovers, substitutions, QA verdicts,
test results, metrics per agent (useful for routing next time). Offer to
open a PR or merge into the base branch, and do it only after the user agrees.

## Squeezing every machine (checklist)

- Install every agent you can on every machine. More agents per machine
  means more slots and fallback without moving work across machines.
- Leave `max_slots: "auto"` and tune `slots` (`mem_per_slot_gb`,
  `cpu_per_slot`) to how heavy the project's build/tests are.
- Add the manager machine as a worker (`host: localhost`, its own `repo_path`)
  so its spare cores work too.
- Keep slots full: queue small tasks, and run QA on whatever is idle.
- Let workers self-fix (`self_fix_attempts`). A test run on the worker is
  much cheaper than a manager review round.
- Share package caches on each worker (pnpm store, ~/.m2, ~/.cache/pip) so
  new worktrees install fast.

## Rules

- Workers know only what is in their prompt + AGENTS.md + plan.md.
- Quote exact errors in fix prompts. Vague feedback burns rounds.
- Never print or commit secrets from logs. `.orch/` is git-excluded.
- `--dangerously-skip-permissions` gives an agent full control of its
  machine. Recommend a dedicated user or a VM per worker.
- Nothing reaches the base branch without the user's OK.
