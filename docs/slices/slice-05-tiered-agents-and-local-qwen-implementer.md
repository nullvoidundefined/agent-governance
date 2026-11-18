# Slice 05: tiered agents and a local Qwen implementer

**Ticket:** owner to assign
**Spec:** `docs/specs/2026-11-18-tiered-agents-and-local-qwen-implementer.md`
**Merge mode:** merge on green
**Risk:** standard for PRs 1 to 3. They replace the router's body, add a dispatch script, and change prose rules. None touches auth, secrets, redaction, money, or a security control. PR 2 starts a process that can edit the working tree; its inputs are the owner's own config and CLI, and it runs under the existing guard hooks. A PR that turns out to weaken a guard is reclassified to high before it merges.
**Fuzzy controls:** none.

## Goal

Claude plans, writes the tests and reviews. A local Qwen model writes standard-risk code. Codex leaves the build loop. Which agent fills which role comes from configuration, so the harness installs unchanged on another computer.

## Owner decisions (2026-11-18)

1. **Division of work.** Roles map to tiers: spec, RED tests, review and security review are primary. Standard-risk GREEN is secondary, falling back to primary. High-risk GREEN is primary. Merge is unchanged.
2. **Tiers map to agents per machine.** On the owner's laptops primary is Claude and secondary is Qwen. No tertiary tier.
3. **Ask first.** After a plan is approved and before implementation starts, Claude asks once whether to delegate standard-risk implementation to the secondary agent, and lists it first where choices are offered. A yes holds for the plan.
4. **Second process.** Qwen runs as headless Claude Code pointed at the local Ollama server.
5. **Codex out of the loop.** The Codex port stays in the harness; removing it is a follow-up slice.
6. **Rules for Qwen.** The Qwen process loads the full generated `CLAUDE.md`. A slim target is built only if real runs show Qwen acting on orchestrator rules.

## Builder rulings on the spec

- **The dispatch script lives in `claude/enforce/`, not inside the skill.** The spec put it under the skill's `scripts/`. Every script the skills call today (`route.sh`, `tdd.sh`, `handoff-summary.sh`) lives in `enforce/` and is tested from `enforce/tests/` through `harness-root.sh`. Following that pattern needs no new test layout.
- **The new skill is ported to Codex and Cursor like every skill.** The spec said Claude-only. The translator copies every skill and has no per-skill exclusion; adding one is harness work this slice does not need. The ported copies are inert without the machine file.
- **`route.sh` accepts and ignores `--author` and `--security` until PR 3 lands,** so the current `tdd-gated-dispatch` text keeps working between PRs. They are removed with the idle files in the follow-up slice.

## Machine file

`~/.claude/agent-tier-assignments.json`, which `AGENT_TIER_ASSIGNMENTS_FILE` can override. Untracked. `claude/agent-tier-assignments.template.json` is the checked-in shape:

```json
{
  "_comment": "Copy to ~/.claude/agent-tier-assignments.json. Assigns an agent to each tier that enforce/route-steps.json names. Known agents: claude, qwen. An unset or unknown tier resolves to primary; primary defaults to claude.",
  "primary":   { "agent": "claude" },
  "secondary": { "agent": "qwen", "model": "qwen-coder-local", "endpoint": "http://127.0.0.1:11434" }
}
```

### PR 1: Tier resolver

- **Context:** first PR of slice 05. `route.sh` routes between `claude` and `codex` by quota pace, and `route-steps.json` names providers directly.
- **Problem:** role assignments are the same on every machine and hardcode two provider names.
- **Approach:** `route-steps.json` names a tier per step. `route.sh` keeps its name, call shape, two-line output and log, and becomes a lookup: step and risk give a tier, the machine file gives the agent. It no longer calls `quota-pace.sh`. Bash and jq, bash 3.2 safe.
- **Contents:** `claude/enforce/route.sh`, `claude/enforce/route-steps.json`, `claude/agent-tier-assignments.template.json`, `claude/enforce/tests/route.test.sh` (rewritten; the quota presets go), one row in `claude/SETUP.md`, one line in `claude/enforce/README.md`, and this plan.
- **Step table:** `spec`, `test-author`, `review` are `primary`. `implement` is `secondary`, with `high` overriding to `primary`. `security-review` is `primary` with `model: fable`. `merge` is `owner`.
- **Acceptance:**
  1. With the template as the machine file, `route.sh implement --risk standard` prints `qwen` on line 1.
  2. With the same file, `route.sh implement --risk high` prints `claude`.
  3. `spec`, `test-author` and `review` print `claude` at either risk. `security-review` prints `claude` and its reason names the model `fable`.
  4. `merge` prints `owner` whatever the machine file says.
  5. With no machine file, every step except `merge` prints `claude`, and the reason says no machine file was found.
  6. With a machine file that is not valid JSON, every step except `merge` prints `claude`, one warning line goes to stderr, and the exit code is 0.
  7. With `secondary` unset, `implement --risk standard` prints the primary agent.
  8. With `secondary.agent` set to an unknown name (`gemini`), `implement --risk standard` prints the primary agent and the reason names the unknown agent.
  9. With `primary` unset or unknown, the primary agent is `claude`.
  10. Each routed call appends exactly one JSON line to `$ROUTING_LOG` with `ts`, `step`, `risk`, `tier`, `provider` and `reason`.
  11. `--author <name>` and `--security` are accepted and change nothing in the output.
  12. The existing rejection cases still exit 2 and log nothing: unknown step, missing or invalid `--risk`, metacharacters or command substitution in any argument, oversized arguments.
  13. `route.sh` runs with no quota file present and never invokes `quota-pace.sh`.
- **How we know it works:** `bash claude/enforce/tests/route.test.sh` prints `PASS: route`, and `bash claude/enforce/tests/run-tests.sh` is all `ok`.

### PR 2: Qwen dispatch script and skill

- **Context:** PR 1 can name `qwen` as the implementer. Nothing can run it yet.
- **Problem:** the loop needs one command that runs a single GREEN attempt on the local model and reports a result Claude does not have to take on trust.
- **Step 1, spike (no tests, recorded in this file under "Spike result"):** on the laptop, find the headless Claude Code invocation that loads the guard hooks and `CLAUDE.md` but no plugins, MCP servers or skills, against the Ollama endpoint. Two candidates: normal mode with plugins disabled through a per-process `--settings` override, or `--bare` with the hooks supplied explicitly. Proof for hooks: a denied `rm -rf ~` attempt shows the guard's reason in the log. Proof for plugins: the log shows no skill or plugin listing. Also record whether the Stop hooks delay or break the run, and the token count of the first request, to set the caps below. Starting point for the environment: `ANTHROPIC_BASE_URL=<endpoint>`, `ANTHROPIC_AUTH_TOKEN=ollama`, `ANTHROPIC_API_KEY=""`, with `claude -p --model <model> --permission-mode dontAsk --max-turns <n> --no-session-persistence`.
- **Approach:** add `claude/enforce/qwen-implementer-dispatch.sh` (bash and jq, bash 3.2 safe). It reads the secondary entry of the machine file for the model and endpoint, checks the server, runs the invocation the spike settled on in the repository with stdin closed, then judges the result itself. Add the skill `rules/skills/qwen-implementer-dispatch/SKILL.md`, which says when the script applies and how to build its prompt: the `implementer` agent's contract plus the failing test names, branch and head, and the instruction not to commit.
- **Interface:** `qwen-implementer-dispatch.sh --repo <root> --red <sha> --prompt <file> --log <file> --test-cmd <command>`.
  - Line 1 of stdout is the status; line 2 is the reason.
  - `green`, exit 0: the test command passed and no protected path changed.
  - `failed`, exit 1, with reason `tests-failed`, `touched-protected-path`, `timeout`, `turn-limit` or `process-error`. For `tests-failed` the last 60 lines of the test output follow from line 3.
  - `unavailable`, exit 3, with reason `no-secondary-configured`, `server-unreachable` or `model-missing`.
  - Usage errors exit 2.
  - `QWEN_DISPATCH_TIMEOUT_SECONDS` (default 1800) and `QWEN_DISPATCH_MAX_TURNS` (default 60) set the caps. The spike may change the defaults.
- **Protected paths:** the `tests`, `specs` and `lock` patterns from `enforce/role-policy.json`, matched against every path that differs from the RED sha, tracked or untracked.
- **Contents:** `claude/enforce/qwen-implementer-dispatch.sh`, `claude/enforce/tests/qwen-implementer-dispatch.test.sh`, `rules/skills/qwen-implementer-dispatch/SKILL.md`, the regenerated ports, one line in `claude/enforce/README.md`, one row in `README.md`.
- **Test method:** the fixture puts stub `claude` and `curl` executables first on `PATH` and works in a temporary git repository. No case contacts a real server or model.
- **Acceptance:**
  1. When the stub `claude` makes the test command pass and touches only production paths, the script prints `green` and exits 0.
  2. When the test command still fails after the run, the script prints `failed` and `tests-failed`, exits 1, and includes the tail of the test output.
  3. When the run edits a file matching the `tests` pattern, the script prints `failed` and `touched-protected-path` and names the path, even if the test command passes.
  4. The same holds for a new untracked file under a test tree, and for a path matching `specs`.
  5. When the stub `claude` runs longer than the timeout, the script stops it, prints `failed` and `timeout`, and leaves no child process.
  6. When the stub `claude` exits nonzero, the script prints `failed` and `process-error`.
  7. With no machine file, or no `secondary` entry, or a secondary agent other than `qwen`, the script prints `unavailable` and `no-secondary-configured`, exits 3, and never starts `claude`.
  8. When the endpoint does not answer, the script prints `unavailable` and `server-unreachable` and never starts `claude`.
  9. When the server answers but does not list the configured model, the script prints `unavailable` and `model-missing`.
  10. The stub `claude` receives the endpoint and model from the machine file in its environment and arguments, and the calling shell's `ANTHROPIC_BASE_URL` is unchanged after the script returns.
  11. The full output of the run is written to the `--log` path in every case that starts `claude`.
  12. A missing `--repo`, `--red`, `--prompt`, `--log` or `--test-cmd`, or a `--red` that is not a commit in the repository, exits 2.
  13. The script makes no commit and does not move `HEAD`.
- **How we know it works:** `bash claude/enforce/tests/qwen-implementer-dispatch.test.sh` prints `PASS`, `run-tests.sh` is all `ok`, `node translate/all.mjs --check` exits 0, and one manual run on the laptop against a trivial failing test returns `green` with the guard hooks visible in the log.

### PR 3: The loop and the rules

- **Context:** the resolver and the dispatch script exist. The loop still describes Codex as test author, implementer and reviewer.
- **Problem:** the documented loop no longer matches the intended division of work, and nothing tells Claude to ask before delegating.
- **Approach:** prose changes under `rules/`, then `node translate/all.mjs --write`. Tests-first exception: these are rules text, which cannot be tested first; the checks below are the verification.
- **Contents and changes:**
  - `rules/skills/tdd-gated-dispatch/SKILL.md`
    - Step 0: ask `route.sh implement --risk <risk>`. If it names a secondary agent and the owner said yes for this plan, that agent implements. Otherwise the primary `implementer` does.
    - Step 1: RED is always the `test-author` agent in a fresh context, in the background. Remove the `codex exec` block, the billing note and the Codex-as-implementer line.
    - Step 2: for Qwen, use the `qwen-implementer-dispatch` skill. On `failed`, discard the attempt if the reason is `touched-protected-path`, then run one more attempt with the failing output added to the prompt. On a second `failed`, or on `unavailable`, discard Qwen's changes back to the RED commit, dispatch the primary `implementer`, and name the fallback in the PR.
    - Step 3: the review is always one `pr-reviewer` in a fresh context. Remove the `codex exec` review block and the `route.sh review` call.
    - High-risk section: remove the Codex mentions; nothing else changes.
  - `rules/GLOBAL.md`
    - "How a change is built", step 2: RED is written by a fresh-context `test-author`, never by the implementer.
    - "Models and cost": replace the provider-routing bullet with two lines stating that `route.sh` resolves each step to the agent this machine assigns, and that standard-risk implementation goes to the secondary agent when one is configured and the owner agreed.
    - Add the standing rule from the spec, inside an `<!-- only: claude -->` block.
  - `rules/agents/test-author.md`: the description no longer says "when Codex is not the test author".
  - `README.md`: the skills row gains `qwen-implementer-dispatch`; the hooks row is unchanged.
- **Acceptance:**
  1. `rules/skills/tdd-gated-dispatch/SKILL.md` contains no `codex exec` and no `route.sh review`.
  2. The standing rule appears in the generated `claude/CLAUDE.md` and in neither `codex/AGENTS.md` nor any file under `cursor/`.
  3. `node translate/all.mjs --check` exits 0.
  4. `bash claude/enforce/tests/run-tests.sh`, `bash sync-tests/sync.test.sh` and `node --test translate/tests/*.test.mjs` pass. Any fixture that asserted the removed Codex wording is updated in this PR.
- **How we know it works:** the checks above, then the rollout below.

## Rollout (owner, after PR 3 merges)

1. `./sync.sh`.
2. Copy `claude/agent-tier-assignments.template.json` to `~/.claude/agent-tier-assignments.json`.
3. In any project, plan one small standard-risk slice. Confirm Claude asks about Qwen once, after the plan is approved.
4. Say yes. Confirm the PR shows a `test-author` RED commit, a Qwen GREEN, and a `pr-reviewer` review.
5. On the second laptop: clone, `./sync.sh`, run the Qwen install script, repeat steps 2 to 4.

## Follow-up slice (not part of this one)

Remove the Codex port and the files this slice leaves idle: `codex/`, `translate/codex.mjs` and its renderers and port map, the Codex CI checks, `codex-billing-guard.sh`, `handoff-summary.sh`, the provider comparison in `quota-pace.sh`, and the ignored `--author` and `--security` arguments.

## Spike result

To be filled in during PR 2, step 1.
