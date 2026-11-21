# Using this skill together with adaptive-agent-skills

Repo: https://github.com/mahmoudredash/adaptive-agent-skills

That package defines **who does what with which model** (roles, a user-owned
model catalog, fallbacks when quota runs out, adaptive concurrency, safe
handoffs) on one machine. This skill adds **where and how**: several
machines over SSH, worktrees, branches, merge, fix rounds. Combined, the
policy file is the source of truth for roles and models, and `orch.py`
executes them across the machines.

## Install

The README's commands use the slug `mahmoudredash/adaptive-agent-skills-`
(trailing hyphen), but the repository is `mahmoudredash/adaptive-agent-skills`.
If the hyphenated form fails, use the one without it.

Manager machine (in the project):
```bash
npx skills add mahmoudredash/adaptive-agent-skills \
  --skill adaptive-multi-agent-orchestrator --skill agent-role-model-routing \
  --skill project-safety-acceptance --agent claude-code
mkdir -p .config && cp <clone>/.config/agent-model-policy.yaml .config/
```
Fill in the policy with real model IDs, then commit it to the feature branch
(or main) so workers can read it too.

Each worker (global, so every worktree sees it). Use the agent names the
Skills CLI prints with `--list`; do not assume agy's CLI name.
```bash
# implementer agents
npx skills add mahmoudredash/adaptive-agent-skills --global \
  --skill agy-implementation-workflow --skill project-safety-acceptance --agent <agy-name>
# QA agents
npx skills add mahmoudredash/adaptive-agent-skills --global \
  --skill opencode-independent-qa --skill project-safety-acceptance --agent opencode
```

## How the policy maps onto orch.py

| Policy section | What the manager does |
|---|---|
| `model_catalog[].use_when / avoid_when` | Choose `--model` per task in `dispatch`/`qa`. Only IDs from the catalog. Never invent one. |
| `agents.<x>.default_role / allowed_roles` | Choose `--agent` and `--role`. Implementers → `dispatch`. `independent_qa` → `qa`. |
| `agents.<x>.fallback_models` | On `quota`: first re-dispatch the same agent with the next model (`reject`/`dispatch --model`). |
| `quota_fallback.<x>.eligible_agents` | If no model fallback is left, re-dispatch to the next eligible agent (`dispatch --worker W --agent Y` with the handoff prompt). |
| `require_user_approval_for_role_change: true` | Ask the user before changing an agent's role. Pause that task, keep others running. |
| `allow_single_agent_to_self_review_as_independent: false` | Never `qa --allow-self`. If no other agent is free, report "QA not independent" and hold acceptance. |
| `resource_policy.concurrency: adaptive` | `capacity` + slots. "NO FREE SLOT" = machine pressure → queue/choose another worker. Do not switch model for that. |
| `never_kill_running_agents_automatically: true` | Set `task_timeout_min: 0`. Stalls are then only reported, never killed. |
| `handoff.require_task_state_checkpoint` | Already true: the runner commits and pushes partial work before reporting `quota`/`timeout`. Add the handoff prompt. |
| `require_explicit_file_ownership_transfer` | Update the owner column in `docs/orch/plan.md` on every handoff/takeover. |
| `report_model_or_agent_substitution` | Mention every substitution in the final report (`summary` history has them). |

## Where the two designs differ, and how it is resolved

- **Shared workspace by default / worktrees only on explicit request.**
  Distributed mode needs isolated worktrees. Adopting this skill is the
  user's explicit request, and every preamble says so to the worker.
- **No stage/commit without request.** Worker agents still never commit. The
  runner commits on their behalf, which is part of the flow the user set up.
  The one exception is the automatic rebase prompt, which explicitly authorizes
  `git rebase` for that step only.
- **One writer per file.** Enforced by file ownership in the plan and by
  separate worktrees. Two tasks must never own the same file.
