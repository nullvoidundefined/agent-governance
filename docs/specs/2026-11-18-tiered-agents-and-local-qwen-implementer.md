# Local Qwen as Implementer, Codex Out of the Build Loop: Design

Date: 2026-11-18
Status: approved by Ian in conversation, 2026-11-18 (revision 3)

## Intent

Cut the cost of building. Claude plans, writes the tests and reviews. Local
Qwen writes the code. Codex leaves the build loop: paying for a second
service only makes sense with enough quota on both to split tests and
implementation between them, and the point of Qwen is to spend less.

The assignment of agents to roles moves into configuration, so the same
harness can be installed on another computer and pointed at whatever agents
that computer has.

## What Ian decided

- Claude asks before delegating. The ask happens once, after the
  implementation plan is approved and before implementation starts.
- Where the workflow already offers execution choices, Qwen is added as a
  choice and listed first.
- The Qwen mechanics live in their own skill. `tdd-gated-dispatch` calls it.
- Qwen runs as a second process: headless Claude Code pointed at local Ollama.
- Claude writes the tests. Qwen writes the code.
- Codex is taken out of the build loop.
- Agents are assigned through a configuration file with a primary and a
  secondary tier. Here primary is Claude and secondary is Qwen. A tertiary
  tier is left out for now.
- Qwen gets its rules from the harness. Start with the full generated
  `CLAUDE.md`; slim it only if real runs show Qwen acting on orchestrator
  rules.

## Division of work

Roles are assigned to tiers. Tiers are assigned to agents per machine.

| Step | Standard risk | High risk |
|---|---|---|
| Spec and plan | primary | primary |
| RED tests | primary, `test-author`, fresh context | primary, `test-author`, fresh context |
| GREEN | secondary if the owner said yes; otherwise, or after two failed attempts, primary `implementer` | primary `implementer` |
| Review | primary, `pr-reviewer`, fresh context | Same, plus `security-reviewer` on the strongest model |
| Merge | As today | As today |

On Ian's laptops primary is Claude and secondary is Qwen.

The separation rule changes from "the other model writes the tests" to "the
tests are written in a fresh context by a role that cannot write production
code, and the implementer cannot write tests". On standard-risk work with
Qwen the two sides are still different models. On high-risk work the
separation is fresh context plus role boundaries, which is what the harness
already does whenever Codex is unavailable.

## Goals

- One question per plan. A yes covers every standard-risk slice in it.
- The loop keeps its shape: RED, GREEN, one review, stop.
- Guard hooks fire on Qwen's tool calls the same as on Claude's.
- A slice Qwen cannot make green falls back to Claude's `implementer`, and
  the PR names the fallback.
- No step in the loop depends on Codex being installed, logged in or in quota.

## Non-goals

- Qwen as test author or reviewer.
- Qwen on high-risk work.
- Removing the Codex port from the harness (`codex/`, its translator, its
  hook adapter, its CI check). That is a separate follow-up; see Claude's
  calls.
- A tertiary tier.
- Codex as a secondary agent. The config format allows other agent kinds
  later, but this change ships a dispatch path for Qwen only.
- A gateway or per-subagent provider routing.
- A fourth translator target for Qwen (deferred until shown necessary).

## Anti-goals

- Delegating without asking, or asking more than once per plan.
- New ledgers, counters or gates whose only job is to manage this feature.
- A Qwen process that runs without the guard hooks.
- A Qwen process that inherits plugins and tries to run workflows itself.
- Weaker tests. The test author stays the strongest model in the loop.

## Constraints

- Source of truth is the agent-governance repo: prose under `rules/`, hooks
  and settings under `claude/`, generated ports via
  `node translate/all.mjs --write`, installed by `sync.sh`.
- Claude Code reads `CLAUDE.md`, not `AGENTS.md`.
- Claude Code talks to one provider per session, so Qwen needs its own
  process and environment.
- Local model: `qwen-coder-local` at `http://127.0.0.1:11434`, 64k context on
  the 36GB laptop.
- Harness rules apply to this change itself: prefer a sentence over a gate,
  keep process time below implementation time, every script has a test, one
  PR per slice with fixed scope.

## Approaches

1. **Qwen as the standard-risk implementer inside `tdd-gated-dispatch`,
   Claude on every other role, mechanics in a separate skill (chosen).**
2. **Two Qwen agents, one for tests and one for code.** Cheapest. Rejected
   for now: the tests are the gate, and a weak model writing the gate lets
   wrong code through everything downstream.
3. **Keep Codex for tests and review.** Rejected: it is usually out of
   quota, so the loop already runs on the Claude fallback, and a second
   subscription works against the cost goal.
4. **A standalone Qwen workflow parallel to the superpowers execution
   skills.** The first draft. Rejected: it rebuilt a test gate and a reviewer
   the loop already has.

## Design

### 1. Agent configuration

Two files, policy and machine.

**Policy, tracked, the same on every computer:**
`claude/enforce/route-steps.json`, rewritten. Each step names a tier, with a
risk override where needed:

```json
{
  "steps": {
    "spec":            { "tier": "primary" },
    "test-author":     { "tier": "primary" },
    "implement":       { "tier": "secondary", "high": { "tier": "primary" } },
    "review":          { "tier": "primary" },
    "security-review": { "tier": "primary", "model": "fable" },
    "merge":           { "tier": "owner" }
  }
}
```

**Machine, local, not tracked:**
`~/.claude/agent-tier-assignments.json`, created by hand from a shipped
`claude/agent-tier-assignments.template.json`:

```json
{
  "primary":   { "agent": "claude" },
  "secondary": { "agent": "qwen", "model": "qwen-coder-local",
                 "endpoint": "http://127.0.0.1:11434" }
}
```

This follows the harness's existing template-plus-local-file pattern.
`sync.sh` never deletes a live file it did not install, so the local file
survives syncs.

**Resolver:** `route.sh` keeps its name and its call shape
(`route.sh <step> --risk <standard|high>`), prints the agent on line 1 and
the reason on line 2, and still appends to `routing-log.jsonl`. Its body
becomes a lookup across the two files. The quota comparison between
providers and the cross-model review rule are removed.

**Defaults:** a missing machine file, an unset tier, or an unknown agent
kind resolves to primary, and primary defaults to `claude`. A fresh machine
with nothing configured runs everything on Claude.

**Setting up another computer:** clone and `sync.sh`, run the Qwen install
script if the machine should have Qwen, and write the machine file.

### 1a. The standing rule

One sentence in `rules/GLOBAL.md` under "Models and cost", inside an
`<!-- only: claude -->` block:

> After an implementation plan is approved and before implementation starts,
> if this machine has a secondary agent configured, ask once whether to
> delegate standard-risk implementation to it, naming it. Where the workflow
> offers execution choices, list the secondary agent first. A yes holds for
> the whole plan. If the secondary agent is not reachable, say so and
> continue without it.

### 2. New skill: `rules/skills/qwen-implementer-dispatch/`

`SKILL.md` plus `scripts/dispatch.sh`. Claude-only: kept out of the Codex and
Cursor ports.

The skill says when it applies (owner said yes for this plan, risk is
standard, RED is committed) and how to run one GREEN attempt.

`dispatch.sh` does one attempt:

- **Input:** repo root, the RED commit sha, a prompt file, a log path.
- **Model and endpoint:** read from the machine file's secondary entry.
- **Health check:** the endpoint answers and the model exists. If not,
  exit with a distinct "unavailable" status.
- **Process:** headless Claude Code with its environment pointed at Ollama
  and the model set to `qwen-coder-local`, for that process only. Runs in
  the background with stdin closed.
- **What the process loads:** guard hooks and `CLAUDE.md`: yes. Plugins, MCP
  servers and skills: no.
- **Permissions:** nothing prompts. Anything the settings allowlist does not
  permit is denied.
- **Caps:** a turn limit and a wall-clock timeout. Either ends the attempt
  as failed.
- **After the run, checked by the script, not by Qwen:**
  - no test, fixture or spec path changed since the RED sha (same patterns
    as `role-policy.json`),
  - the RED tests pass.
- **Output:** one status (`green`, `failed`, `unavailable`), the failing
  output when there is one, and the full log.

The prompt is the existing `implementer` agent contract plus the failing test
names, branch and head. Qwen returns GREEN or one `DISPUTE`, as the
implementer role does today.

### 3. Changes to `tdd-gated-dispatch`

- **Step 0, Route:** ask `route.sh implement --risk <risk>`. If it prints a
  secondary agent and the owner said yes for this plan, that agent
  implements. In every other case the primary `implementer` does.
- **Step 1, RED:** always the `test-author` agent in a fresh context, in the
  background. The `codex exec` test-author block is removed.
- **Step 2, GREEN:** for Qwen, call `qwen-implementer-dispatch`. On `failed`,
  one more attempt with the failing output added. On a second `failed`, or
  on `unavailable`, dispatch Claude's `implementer` and name the fallback in
  the PR.
- **Step 3, Review:** always one `pr-reviewer` in a fresh context. The
  `codex exec` review block is removed.
- The high-risk section loses its Codex mentions and is otherwise unchanged.

### 4. Changes to `rules/GLOBAL.md`

- "How a change is built", step 2: RED is written by a fresh-context
  `test-author`, never by the implementer. The Codex wording goes.
- "Models and cost": the provider-routing sentence is replaced by the
  division of work above in two lines, followed by the standing rule.

### 5. What stays installed but idle

The provider side of `quota-pace.sh`, `codex-billing-guard.sh` and
`handoff-summary.sh` are no longer called by the loop. This change does not
delete them. `route.sh` and `route-steps.json` stay in use in their new form.

## Claude's calls (not Ian's decisions; correct any)

- **Codex leaves the loop only; its port stays for now.** Removing the port
  touches the translator, its tests, CI and `sync.sh`. Your own rule is one
  slice per PR with fixed scope, so it is a follow-up, along with deleting
  the idle files in section 5. Asked in conversation, not answered.
- **Qwen is the only secondary kind this change can dispatch.** In
  conversation I said a machine could set secondary to Codex with no rule
  changes. That was wrong: it needs a Codex dispatch path, and this change
  removes the existing one. Adding a kind later means one more dispatch
  script, not a config redesign.
- **File names.** `agent-tier-assignments.json` for the machine file;
  `route-steps.json` and `route.sh` keep their names so callers and logs do
  not change.
- **Two Qwen attempts, then Claude's `implementer`.**
- **Test-path check lives in the dispatch script.** `protected-path-guard`
  enforces role boundaries by `agent_type`, which only subagents carry. A
  headless top-level process has none, so nothing would stop Qwen editing a
  RED test on standard-risk work. A post-run diff check is the cheapest tier
  that catches it.
- **No new hook.** Everything added is one script and a few sentences. The
  change removes more loop text than it adds.

## Left to the builder

- Exact flags for the headless process, verified against the current CLI
  reference and on the laptop. Two candidates for "hooks yes, plugins no":
  normal mode with plugins switched off through a per-process settings
  override, or bare mode with the hooks supplied explicitly.
- Whether the Stop hooks (`turn-summary-guard`, `claim-check-guard`) cause
  trouble in a headless Qwen run. They fail open after one retry.
- Turn limit and timeout values, set after a few real slices.
- Fixture tests for `dispatch.sh` and the rewritten `route.sh` in the
  harness's existing test layout. The current `route.sh` fixtures assert
  quota routing and will be replaced.
- JSON validation of the machine file: a malformed file resolves to primary
  with a one-line warning, never an error that blocks a build.
- Port-map entries that keep the new skill out of the Codex and Cursor ports.
- Any existing harness test that asserts the Codex wording being removed.

## Known limits

- None of this can be tested from the cloud session it was designed in. The
  first proof is one standard-risk slice on the laptop.
- On high-risk work Claude writes the tests, the code and the review. The
  separation is fresh context and role boundaries, not a second model.
- Qwen is a much weaker implementer than Codex. Fallbacks to Claude will come
  from failed attempts. Whether the loop is cheaper overall depends on Qwen's
  pass rate on real slices; the PR bodies will show it.
- A fresh process per attempt at about 43 tokens per second is slow. The
  saving is tokens, not wall-clock time.
- If Qwen acts on orchestrator rules in `CLAUDE.md`, the slim translator
  target becomes necessary.
