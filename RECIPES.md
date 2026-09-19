# Workflow recipes

These recipes describe existing harness workflows. Begin with [setup](claude/SETUP.md). Skill names below are the current names; proposed naming changes are not implemented. Invoke a named skill through your tool's supported skill interface or ask the agent to use it. Availability varies by port.

## Start a feature

**Trigger:** A requested behavior needs implementation. Ask the agent to use [task-start](claude/skills/task-start/SKILL.md), then [feature-create](claude/skills/feature-create/SKILL.md) when an approved plan exists. Supply the intended behavior and acceptance criteria.

**Success:** The task has a scope classification, an appropriate branch or worktree, and a named next implementation step. If planning or a gate stops progress, inspect the named skill and the gate's evidence before proceeding.

## Write or update a spec

**Trigger:** A behavior or boundary needs agreement before implementation. Use the [spec template](claude/prompts/spec-template.md), then ask for [spec grounding](claude/skills/spec-grounding/SKILL.md) against the actual repository.

**Success:** Acceptance criteria refer to real interfaces and verification paths. Store local planning under `docs/superpowers/`; it is ignored. If a claim cannot be grounded, record the unresolved decision instead of treating intent as existing behavior.

## Run a test-first slice

**Trigger:** An approved behavior is ready to implement. Use [tdd-gated-dispatch](claude/skills/tdd-gated-dispatch/SKILL.md). From the target project's root, the lifecycle is:

```text
tdd.sh open "<slice>" --spec <spec-path>
tdd.sh red <test-path>            # or <test-path>::<test id> for a new test in a file that already passes
tdd.sh green
tdd.sh close
```

Invoke the installed script as `bash "$HOME/.claude/enforce/tdd.sh"` followed by the arguments shown. The test author writes the failing test between `open` and `red`; the implementation author works between `red` and `green`. Follow the skill's authorship boundaries and commit requirements.

**Success:** RED establishes the intended failure, GREEN verifies the implementation with locked tests unchanged, and close accepts the completed slice. On refusal, inspect the lock with `tdd.sh status` and resolve the reported cause. The runner supports Vitest, Jest, pytest, and bash `*.test.sh` fixtures; consult the script before using another stack.

## Dispatch a reviewer

**Trigger:** A bounded diff or spec needs independent review. Supply the artifact path or diff range and invoke [spec-conformance-review](claude/agents/spec-conformance-review.md) for requirements coverage or [bug-hunt](claude/skills/bug-hunt/SKILL.md) for correctness.

**Success:** Findings identify evidence and scope; an empty result states what was reviewed. If artifacts are missing, provide them before dispatch. A primary/secondary model CLI and automatic cross-tool fallback remain planned features, not commands available today.

## Complete a task

**Trigger:** Implementation and focused verification are complete. Use [task-cleanup](claude/skills/task-cleanup/SKILL.md), inspect the diff, and commit the discrete change after applicable checks pass.

**Success:** Documentation matches delivered behavior and remaining work is recorded. Investigate failed checks without suppressing them. Follow repository authorization requirements for merge and publication.

## Sync live configuration

**Trigger:** Reviewed configuration should be installed. Follow the [setup preview](claude/SETUP.md#preview-in-isolated-directories), then run from this repository's root:

```sh
node translate/codex.mjs --check
./sync.sh
```

**Success:** Port verification succeeds and all surfaces report a sync result. If the port is stale, update its sources and run `node translate/codex.mjs --write`, review the diff, then repeat verification. A sync error names the surface requiring investigation; earlier surfaces may already have been copied.

## Prepare a public push

**Trigger:** A reviewed change is ready for publication. Run the [verification commands](README.md#verification), then inspect:

```sh
git diff origin/main
git status --short
```

**Success:** Checks pass and the proposed public diff contains only intended, publishable content. Inspect staged deletions as well as additions. Local handoffs and planning files should be ignored. Resolve unexpected paths or sensitive content before requesting publication approval; no recipe authorizes bypassing a gate.

## Write a session handoff

**Trigger:** Work pauses or moves to another session. Follow the handoff requirements in [the rulebook](claude/rulebook/reference.md) to write `docs/session-handoff/session-handoff.md` with completed work, verification, unresolved decisions, and the next action.

**Success:** Another session can resume using named artifacts and commit references. In this repository the handoff is local and ignored, which takes precedence over generic instructions to commit it. Preserve a private backup if continuity across machines is needed. Never force-add it to satisfy a generic cleanup checklist.
