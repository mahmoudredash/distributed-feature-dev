# distributed-feature-dev

An agent skill that turns one coding agent into a **technical lead** for a team of
coding agents spread over several machines. You describe a feature. The lead
plans it, writes the contracts and contract tests, splits the work, and runs it in
parallel on your machines over SSH with Claude Code, opencode or agy
(Antigravity). Each machine runs as many agents as its CPU and RAM allow. The
lead then gets the work independently QA'd, reviews it, merges it, sends precise
fix prompts, and takes a task over itself after 3 failed rounds on the same issue.

Arabic: [README.ar.md](README.ar.md)

## What it does

- **Plan → contracts → tasks.** Shared interfaces and failing *contract tests* go
  on the feature branch first, so review is objective ("make these pass without
  editing them"). `AGENTS.md` and `docs/orch/plan.md` give every agent the same
  rules and the full picture.
- **Use every machine fully.** Each task runs in its own git worktree, so a
  machine runs several agents at once. Slots are sized from real CPU, free RAM
  and load. Machine pressure queues work, and the manager machine can be a
  worker too.
- **Workers check their own work.** After the agent finishes, the runner
  commits, rebases onto the latest feature branch (the agent resolves conflicts),
  runs your `verify` command and lets the agent self-fix failures before
  reporting. Partial work is always pushed as a checkpoint.
- **Independent QA.** A *different* agent reviews each task read-only and
  writes a PASS/FAIL report. Self-review is refused.
- **Quota-aware.** Rate-limit or quota errors are detected per
  worker+agent+model. Work moves to the next model or agent from your policy
  and continues from the pushed checkpoint.
- **Bounded fix loop.** Fix rounds are counted per issue (3) and per task (5).
  At the limit the lead takes the task over and fixes it itself.
- **Safety.** Timeouts, stall detection, protected paths, nothing merged
  into your base branch without your OK.

Works with [adaptive-agent-skills](https://github.com/mahmoudredash/adaptive-agent-skills):
its `agent-model-policy.yaml` decides roles, models and fallback order, and this
skill executes them across machines. See
`skills/distributed-feature-dev/references/adaptive-agent-skills.md`.

## Install

With the [Skills CLI](https://github.com/vercel-labs/skills) on the **manager** machine:
```bash
npx skills add mahmoudredash/distributed-feature-dev --skill distributed-feature-dev --agent claude-code
```
Or by hand for Claude Code:
```bash
git clone https://github.com/mahmoudredash/distributed-feature-dev.git
cp -r distributed-feature-dev/skills/distributed-feature-dev ~/.claude/skills/
```
Workers don't need this skill. They need git (with push access), tmux,
coreutils `timeout`, `flock`, and their agent CLIs installed and logged in.

## Setup

1. In your project: `mkdir -p .orch && cp <skill>/config.example.json .orch/config.json`
   and fill in the workers, the agents each one has, and your `verify` command
   (lint + build + test).
2. Make SSH from the manager to every worker work with keys (no password).
   Each worker's `repo_path` must be a clone used only by the orchestrator.
3. **Check the `agy` command.** Its headless invocation and model flag in the
   example config are placeholders.
4. `python3 <skill>/scripts/orch.py doctor` and fix every ERROR.
5. In Claude Code: *"Use distributed-feature-dev to build <feature>."*

## Requirements

- Manager: Linux or macOS, bash, git, python3 ≥ 3.8, ssh.
- Workers: Linux or macOS (Windows via WSL), see above.

## Tests

```bash
bash tests/e2e.sh
```
This runs the whole flow (dispatch, self-fix, quota fallback, QA, conflicts and
auto-rebase, protected paths, round limits) against fake SSH and fake agents
in a temp dir. CI runs it on every push.

## Security

The example config runs Claude Code with `--dangerously-skip-permissions`, which
gives the agent full control of the worker. Use a dedicated user or a VM per
worker, and per-worker deploy keys that can push only to `feature/*--*` branches.
