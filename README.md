# agent-governance

**A governance harness for AI coding agents.** It gives Claude Code, Cursor, and the Codex CLI a
shared set of rules, a shared set of workflows, and a layer of mechanical gates that sit at the
tool-call boundary and refuse the operations those rules forbid. One repository is the source of
truth; `sync.sh` installs it into each tool's live configuration directory.

The premise is simple to state and uncomfortable to accept. An agent that has been told a rule will
follow it most of the time, and the times it does not are exactly the times that cost you: late in a
long session, under pressure to finish, on the change that touches production. Prose alone cannot
carry a guarantee. So this repository takes every rule that can be made mechanical and makes it
mechanical, and it is honest about which ones are still prose.

```bash
git clone https://github.com/nullvoidundefined/agent-governance.git
cd agent-governance
./sync.sh
```

---

## Table of contents

- [Why this exists](#why-this-exists)
- [What you get](#what-you-get)
- [How a feature actually gets built](#how-a-feature-actually-gets-built)
- [The two build skills, and how to tell them apart](#the-two-build-skills-and-how-to-tell-them-apart)
- [The four layers](#the-four-layers)
- [Repository layout](#repository-layout)
- [One source, three tools](#one-source-three-tools)
- [Install](#install)
- [Verification](#verification)
- [What this does not do](#what-this-does-not-do)
- [Working in this repository](#working-in-this-repository)
- [License](#license)

---

## Why this exists

The development strategy this harness replaced was the obvious one: give the agent a task, tell it
what the task is, and let it run unsupervised. That strategy failed across roughly two weeks of real
use, and it failed in classes rather than one-offs. Two of those incidents are recorded in
`claude/PROTOCOL.md`: a secret reached a command line, and a runbook went on describing a deployment
procedure the code no longer performed. Other classes have a rule but no incident narrative behind
them, and the rules are worth reading as the shape of the risk rather than as a war story: R-405
exists so that a protection which caught a failure is never the thing that gets relaxed to make the
failure go away, and R-403 exists so that a fix cannot ship without a test that failed before it.
None of these are exotic. Each is a case where a behavioral instruction was the only thing standing
between the agent and the mistake, and a behavioral instruction is a suggestion that the model is
free to reason its way around.

Every layer in this repository was added after a specific failure, and the design discipline is not
"follow the rules" but "add the next layer the next time a failure teaches you where one is
missing." `claude/PROTOCOL.md` is the catalog: eleven layers, each named for the class of failure it
catches. It is worth reading before you adopt any of this, because it tells you what the layers are
for rather than what they are.

The honest accounting matters as much as the design. `PROTOCOL.md` states it plainly: six of the
eleven layers are mechanically enforced by scripts that run whether the session remembers them or
not, and five are prose that depends on the session honoring them. The framework's stated intent is
to migrate prose layers down to mechanical ones as enforcement paths get wired. Treat a rule tagged
`[manual]` as yours to honor, not as something the harness will catch for you.

## What you get

Every count below was taken from this checkout, not from a summary.

| Surface | Size | What it is |
|---|---|---|
| Rules | 84 norm lines in `claude/CLAUDE.md` | One line per rule, grouped by concern: session init, secrets and trust, conduct and output, architecture and naming, testing, git and process, lifecycle and memory. Each line names its enforcer in trailing brackets. The full specification for every rule lives in `claude/rulebook/reference.md` and is read on demand. |
| Enforcement | 114 registered entries in `claude/enforce/manifest.json` | Every mechanizable rule is registered with a tier: 43 `regex`, 37 `ast`, 29 `advisory`, and 5 `llm-judge`. A rule with no manifest entry depends on the session recalling it, and the manifest is what makes that distinction auditable rather than a matter of opinion. |
| Hooks | 68 scripts in `claude/hooks/` (65 bash, one Node scanner, two Python helpers), plus the tracked `pre-push.sample` | These run at Claude Code's tool-call events. A `PreToolUse` hook can refuse a `Bash` command or a `Write` before it happens; a `Stop` hook can refuse to let the turn end on a red test suite. This is the layer that catches what prose cannot. |
| Skills | 18 in `claude/skills/` | Procedural workflows the agent invokes by name: classifying a task, opening a ticket, running a test-first slice, reviewing a spec, cleaning up at the end. |
| Agent roles | 15 in `claude/agents/` | Nine audit roles (engineering, security, criticism, customer, design, UX, financial, legal, marketing), the four build roles (`test-author`, `implementer`, `slice-critic`, and `spec-conformance-review`), and the two pre-merge reviewers: `pr-reviewer` (R-517) and `security-reviewer` (R-109, on the strongest model). |
| Convention tracks | 12 `claude/CLAUDE-*.md` files | Stack-specific conventions for TypeScript and Node, Python, Ruby, Go, and the React, Next, Vite, Vue, and Nuxt frontend frameworks. They auto-load by file path when the work touches a matching file, so the context stays lean. |
| Fixtures | 101 in `claude/enforce/tests/`, 22 in `claude/hooks/tests/` | Shell fixtures that drive the real guards. A guard without a fixture is a guard nobody has proven fires, so a new mechanized rule ships with its fixture or it does not ship. |

## How a feature actually gets built

The skills are not a menu you browse. They form a sequence, and each one hands off to the next. What
follows is the path a single feature takes from a sentence the user typed to a commit on `main`.

**1. Classification, before anything else.** The `task-start` skill reads the request and sorts it
into exactly one of five tiers: Trivial, Standard, Complex, Saga, or Investigation. The tier is not
a label; it determines the process, and the process is not negotiable. A Trivial task gets a branch
and a pull request and nothing else. A Complex task gets one spec, an adversarial review of that
spec, one plan, an isolated worktree, and test-first slices. Investigation is orthogonal to the
other four and is chosen by what the task produces (an answer) rather than by how large it is.

**2. A ticket, before the first edit.** Above the Trivial tier, `ticket-lifecycle` opens a tracker
ticket carrying the tier, the estimate, the model, the repository, and the branch. This is
mechanically gated: `ticket-at-start-gate.sh` refuses the first `Write` and every `git commit` until
the ledger on that branch names the ticket. The estimate comes from the history of closed tickets in
the same tier rather than from a guess, and at close the ticket records attributable working minutes
so the next estimate is better than this one.

**3. A spec, for anything Complex or larger.** The spec is written, then reviewed adversarially by a
different model than the one that wrote it, looking for acceptance criteria that would not fail if
the feature were missing, contradictions with the convention files, and security gaps. It also runs
a two-sided build-versus-buy audit: for each piece the spec builds by hand, whether a mature tool
already does it, and for each suggested dependency, whether it removes more risk than it adds.
"Keep the current choice" is an expected answer. Every finding is fixed or answered before the owner
approves the spec.

**4. The build, one behavior at a time.** This is where the two build skills come in, and where most
of the harness's weight sits. See the next section.

**5. Review before merge.** Every non-trivial pull request is reviewed against the spec and its
acceptance criteria by an independent agent before it merges, and the findings and their
dispositions go in the pull request body. `git-workflow-guard.sh` refuses `gh pr merge` while that
section is missing or empty.

**6. Cleanup and handoff.** `task-cleanup` scans the diff, answers what shipped, updates the feature
list and user stories, closes the ticket with measured actuals, and writes the session handoff so
the next session starts from state rather than from scratch.

## The two build skills, and how to tell them apart

Two skills in this repository both look like "the one that builds things," and their triggers
overlap enough that their own frontmatter cross-references the ambiguity. They are not alternatives.
One is the outer loop and one is the inner loop, and a real build runs both at once.

### `build-by-slice-require-review` is the outer loop

It governs **cadence and human approval**. The build is a sequence of slices; each slice is a
sequence of reviewable pull requests; each pull request is a sequence of test-first tasks. The human
owns the architecture, which means the human owns the spec and the slice plans. The agent executes.
Comprehension is preserved because a human reads the work at fixed gates rather than at the end.

There are two hard gates. **Gate 1** is the slice plan document, written to
`docs/slices/slice-<nn>-<slug>.md` before any code, listing every pull request in the slice with its
context, problem, approach, contents, tests, review focus, and size, and recording on a
`**Merge mode:**` line which merge mode the owner chose for the slice. The user approves that
document before building starts. **Gate 2** is the pull request itself: by default the user reads
and merges it on GitHub and the session stops there. A slice may opt out of Gate 2 at Gate 1, which
lets the session merge that slice's pull requests itself once CI is green and the pre-merge review
has passed. The owner's merge is the default because a review by a subagent is not a substitute for
the owner reading the diff, and a skill named require-review should not remove them from the loop
without being asked to (IAN-352).

This skill is portable prose. It describes a discipline that works in any tool, including ones with
no hook surface at all, because nothing in it requires a script to be present. Where the hook
surface does exist, two guards back its gates rather than replacing them:
`hooks/spec-glossary-check.sh` reminds you on the write when a slice plan's pull request block is
missing any of the seven labels or the plan records no merge mode, and `hooks/git-workflow-guard.sh`
denies `gh pr merge` while the review section of the body is missing or empty. Neither one can tell whether a human actually read
the pull request, which is the part that matters and the part that stays with you.

**Reach for it when** the question is "how does this work reach the human, in what size pieces, and
when do they get to say no."

### `tdd-gated-dispatch` is the inner loop

It governs **one behavior, and who is allowed to write what**. Each acceptance criterion that a test
can fail becomes one slice, and every slice runs the same cycle: open, RED, commit, GREEN, refactor,
commit, review, close. What distinguishes it from ordinary test-driven development is where the
proof lives. The harness proves RED and GREEN, not the prompt and not the agent's own report that it
followed the cycle.

The mechanism is `claude/enforce/tdd.sh` plus a lock file at `.claude/tdd-lock.json`. Its
subcommands are `open`, `red`, `green`, `expected-red`, `close`, `status`, and `validate`. The lock
has phases, and `hooks/protected-path-guard.sh` reads them:

```text
tdd.sh open "<slice>" --spec <spec-path>   # production writes are now denied
tdd.sh red  <test-path>                    # the named tests must fail, the rest must pass
tdd.sh green                               # named tests pass, suite at or above baseline,
tdd.sh close                               #   and the locked test hashes match the RED commit
```

Two consequences follow, and they are the reason this skill exists separately from the outer loop.
The first is that a production write is denied while the lock is in phase `open`, so the failing
test has to come first. The second is that the tests, fixtures, and spec are read-only from RED to
close, and `tdd.sh green` compares the locked hashes against the RED commit, so making a red test
green by editing the test is refused rather than merely discouraged. A test the agent believes is
wrong is not quietly amended; it is returned to the human as `DISPUTE: <test>`.

Both behaviors are covered by shell fixtures that drive the real guard rather than a mock:
`claude/enforce/tests/protected-path-guard.test.sh` and
`claude/enforce/tests/tdd-red-green.test.sh`, with `tdd-expected-red.test.sh`,
`tdd-red-manifest-drift.test.sh`, and `tdd-pytest.test.sh` alongside them. They run in the same CI
job as everything else, which is the reason to believe the guards fire rather than the reason to
hope they do.

Authorship is split across separate contexts to make it structural rather than a matter of restraint.
The test author is permitted to write only test and fixture trees, and is never shown the plan's
code blocks, so the test argues from the stated behavior rather than from the implementation someone
already sketched. The implementer receives those code blocks as a suggestion and is not permitted to
write tests, fixtures, or specs. The slice critic is permitted to write nothing at all and reviews
from a fresh context that has never seen the implementer's transcript.
`claude/enforce/role-policy.json` declares those boundaries by agent type and
`hooks/protected-path-guard.sh` applies them.

The test runner supports Vitest, Jest, pytest, and bash `*.test.sh` fixtures. Any other runner
refuses rather than guessing, and the cycle still applies by hand.

**Reach for it when** the question is "how do I build this one behavior so that the test genuinely
came first and nobody can quietly make a red thing green."

### Side by side

| | `build-by-slice-require-review` | `tdd-gated-dispatch` |
|---|---|---|
| Scope | A whole build: slices, then pull requests, then tasks | One behavior, one RED/GREEN cycle |
| Governs | Cadence, review gates, human approval | Authorship boundaries, proof of RED and GREEN |
| Enforced by | The human at the gates, with two hooks backing the artifacts | `tdd.sh`, the lock file, and `protected-path-guard.sh` |
| Unit of work | A pull request a human can read in one sitting | A single acceptance criterion a test can fail |
| Artifact | `docs/slices/slice-<nn>-<slug>.md` | `.claude/tdd-lock.json` and one commit per phase |
| Portability | Any tool, needing no script at all | Any tool with a hook surface: Claude Code, and Codex and Cursor through their adapters |
| Fails by | A human approving without reading | A refusal you have to resolve before continuing |

**They compose.** Step 4 of the outer loop, "build each pull request as a sequence of test-first
tasks," is the inner loop. Every one of those tasks should go through `tdd-gated-dispatch`, because
the slice lock denies production writes outside that sequence anyway. Both skills ship in all three
ports, and `protected-path-guard` is ported to Codex and Cursor through their adapters, so the inner
loop is not a Claude Code exclusive. It degrades to a discipline you keep by hand only in a tool
with no hook surface at all, where the outer loop still works unchanged.

## The four layers

The harness has four kinds of content, and knowing which kind you are looking at tells you how much
to trust it.

**Rules** are the prose contract, one norm line each in `claude/CLAUDE.md`, with the full
specification, scope, and enforcement detail in `claude/rulebook/reference.md`. Each norm line ends
with the name of its enforcer in brackets. A rule tagged `[hook:secret-scan]` is caught
mechanically. A rule tagged `[manual]` depends on the session recalling it, and the bracket is there
so you never have to guess which kind you are relying on.

**Hooks** are the mechanical layer. They run at Claude Code's tool-call events and can refuse the
call. They catch what a rule cannot: a `DROP TABLE` aimed at a remote database, a secret-shaped
literal about to be written to a file, a commit message that does not parse, a turn trying to end on
a red suite, a `git push` of a public repository carrying a local filesystem path.

**Skills** are the procedural layer: named workflows with a fixed sequence of steps, invoked by the
agent when the work matches. They are how a decision that would otherwise be an implicit judgment
call becomes mechanical and repeatable.

**Agents** are the review layer. The nine audit roles produce dated reports under `docs/audits/`.
The engineering role is the one that spells out the autonomy posture in full: never soften a finding
to be polite, never suppress a category of findings for feeling out of scope, and say so explicitly
when unsure rather than omitting silently. The security role carries its own shorter version of the
first clause, and the remaining seven roles state their posture in their own terms, so read the role
file rather than assuming the engineering wording applies everywhere. The four build roles exist to
keep authorship separated inside a slice, which the previous section describes.

## Repository layout

```text
agent-governance/
├── claude/              The source of truth. Everything below is authored here.
│   ├── CLAUDE.md          84 rule norm lines, one per rule, grouped by concern
│   ├── PROTOCOL.md        The eleven layers and the failure each one catches
│   ├── SETUP.md           Install, prerequisites, what does not ship, stacks
│   ├── CLAUDE-*.md        12 stack convention tracks, auto-loaded by file path
│   ├── rulebook/          Full rule specs, plus per-session-type tier 2 reading
│   ├── rules/             Session types and the path-scoped convention symlinks
│   ├── hooks/             68 tool-call guards, with 22 fixtures under tests/
│   ├── enforce/           tdd.sh, doctor.sh, the manifest, ESLint rules, 101 fixtures
│   ├── skills/            18 workflow skills
│   ├── agents/            9 audit roles and 4 build roles
│   ├── prompts/           Review prompts and document templates
│   └── global-memory/     Cross-project lessons, loaded at session start
├── cursor/              Generated from claude/ by translate/cursor.mjs
├── codex/               Generated from claude/ by translate/codex.mjs
├── translate/           The exporters and their port maps
├── docs/                Audits, pull request documents, slice plans, handoffs
├── sync.sh              Installs each payload into its tool's live directory
├── RECIPES.md           Task-shaped entry points into the workflows above
└── AGENTS.md            This repository's own project config for Codex
```

The shape carries an intent worth stating. `claude/` is authored and `cursor/` and `codex/` are
generated, which means a rule is written once and lands in three tools rather than being maintained
in three dialects that drift apart. Each exporter's `--check` mode exits nonzero when a source edit
was never regenerated. Three callers run it from one shared inventory in
`claude/enforce/port-checks.sh`, so adding a fourth port does not mean remembering to register it in
three places: the turn-end gate in `claude/hooks/verification-gate.sh`, the pre-push hook, and the
`Translator port checks` step in `.github/workflows/enforce.yml`. (`claude/enforce/doctor.sh` checks
port freshness too, but from its own hardcoded list of the two current translators rather than from
that inventory, so a new port does have to be added there by hand.) The CI step is the binding one,
because the pre-push hook can be skipped with `--no-verify` and the doctor check is something you
choose to run.

## One source, three tools

The three tools do not offer the same enforcement surface, and the ports do not pretend otherwise.

Claude Code has the full hook surface, so the mechanical layer works as designed. Cursor reaches it
through an adapter. The Codex CLI reaches it through `codex/hooks/codex-hook-adapter.sh`, which
replays each `apply_patch` as the file edits the gates read and translates the decisions back into
Codex's shape.

Where a gate has no event to hang on in a given tool, the generated rule file says so in the rule's
own tag: `hook:X in Claude Code; manual in Codex`. `codex/PORT-STATUS.md` and `cursor/PORT-STATUS.md`
carry the per-surface accounting. A rule that reads as enforced in one tool and manual in another is
a fact about that tool, recorded where you will see it rather than discovered when it fails to fire.

## Install

Full detail on prerequisites, what does not ship, and the per-stack convention tracks is in
[`claude/SETUP.md`](claude/SETUP.md). One caveat while reading it: that document's install step 1
still says to clone the repository to `~/.claude`, which describes the layout before this became a
monorepo. The quick start below is the current path, and `sync.sh` is the authority on it.

You need `git` and `bash` (macOS or Linux; on Windows use WSL, because the hooks are bash), `jq`
(every `PreToolUse` and `SessionStart` hook parses its input with it), `node` (the clean-code scanner
and the ESLint push gate), and `python3` (the manifest closure test and the latency test's clock).
Per-stack linters (`ruff`, `rubocop`, `golangci-lint`) are optional at runtime and fail open when
absent, with one exception: `ruff` must be on `PATH` to run the fixture suite, because one fixture
drives the real binary.

```bash
git clone https://github.com/nullvoidundefined/agent-governance.git
cd agent-governance
./sync.sh
```

`sync.sh` never deletes a live file it did not install. It records what it installed in a
`.sync-manifest` inside each live directory, and it removes a file only when three things are true
at once: that manifest lists the file, the repository no longer tracks it, and its live content is
unchanged. A file you edited live is kept and reported. This is a deliberate trade-off made after a
destructive incident, and the cost of it is that a stale live file can survive a sync if you edited
it.

In Claude Code the sync also runs on its own. The `harness-sync` `SessionStart` hook compares the
live `~/.claude` against the checkout and syncs when the live directory is absent or differs, so a
fresh cloud container and a stale laptop both start a session under the committed harness. Cursor
and the Codex CLI have no project-local hook surface, so in those tools `./sync.sh` is a step you
take rather than one the harness takes for you.

## Verification

```bash
bash claude/enforce/doctor.sh --full
```

`doctor.sh` runs the install checks (settings parsing, settings schema keys, hook executability,
dependencies, sandbox availability, and the status line among them) and reports each one by name
with a pass, fail, warn, or skipped verdict. `--full` adds both fixture suites as a single
`fixture-suites` check, which passes only when both are green. It should exit 0; it exits 1 on any
fail and 2 on a usage error. The full check list and the exit contract are in
[`claude/enforce/README.md`](claude/enforce/README.md). The same two fixture suites run in CI via
`.github/workflows/enforce.yml`, in a job named `fixtures`.

Name that CI job as a required status check under your repository's branch settings. The local
pre-push hook can be skipped with `--no-verify` by anyone who wants to, so it is advisory however it
is written; the required check is the one that runs where it cannot be skipped.

One install step is easy to miss. The ESLint-backed fixtures need `claude/enforce/node_modules`,
which is gitignored and therefore absent from a fresh clone. `./sync.sh` installs it with a locked
`npm ci`. To do it by hand, run `npm ci --prefix ~/.claude/enforce`, never `npm install`, which can
resolve differently from the committed lockfile.

## What this does not do

A landing page that only lists strengths is not useful for deciding whether to adopt something.

**It does not confine a subprocess.** Hooks and permission rules act at the Claude Code tool-call
boundary. They do not constrain a process that has already been spawned, and an actor working
outside that boundary can bypass them. The one layer that would confine a `Bash` subprocess at the
operating-system level is the sandbox, which ships in `claude/settings.json` configured but disabled
(`sandbox.enabled: false`). `claude/enforce/README.md` documents the enablement procedure, the
coverage table showing which layer catches which kind of leak, and the one vector no layer covers
until the sandbox is both enabled and given a `sandbox.credentials` block.

**It is not free, and the cost is measured rather than guessed.** The standing accounting is
[`docs/audits/2026-09-19-maintenance-tax.md`](docs/audits/2026-09-19-maintenance-tax.md), which
counted 282 commits and found that about a third carry harness self-maintenance rather than product
work: 89 of them (32%) touch the checked-in hash manifest alone, 42 touch generated port output, and
roughly two thirds of the bug fixes are the harness repairing its own plumbing. That audit names the
three design choices responsible (a checked-in hash manifest, checked-in generated ports, and a
copy-based sync into live directories) and a known replacement for each. Whether the tax is one-time
architecture debt or structural is still being measured against a decision rule written before any
data came in. The document is in the repository rather than in a drawer for a reason.

**Most of it is one person's workflow.** The same audit estimates that the portion which would
survive contact with four other engineers' preferences is the safety floor, roughly a fifth of the
rules; the rest is a personal profile that should be opt-in on a team rather than a mandate. If you
adopt this, adopt the floor first and take the rest only where you agree with it.

**Some of it is still prose.** Five of the eleven protocol layers depend on the session honoring
them. The manifest is what makes this checkable: 114 entries with an enforcer each, and every rule
that is not in it is recall-dependent by definition.

**The opinions are real opinions.** The architecture rules take positions (no catch-all `utils`
directories, one responsibility per file, dependencies flowing one direction through named layers,
a fixed word order for every schema and model name) that are defensible but not universal. Fork the
repository and change them. That is a cheaper path than arguing with a rule you disagree with at
every commit.

## Working in this repository

This section is for contributors to the harness itself rather than for people adopting it.

The dotted `.claude/` and `.cursor/` directories at the root are this repository's own project
config, not payload. They are how a session opened here reaches the harness this repository defines.
`.claude/settings.json` registers a `SessionStart` hook that runs `claude/hooks/harness-sync.sh`,
which syncs automatically. Cursor has no equivalent automatic entry point, so
`.cursor/rules/000-harness-bootstrap.mdc` states the same contract as an always-on rule and asks for
one `./sync.sh` run. The Codex CLI merges a project-level `AGENTS.md` at this root with its own
`~/.codex/AGENTS.md`, so the root `AGENTS.md` carries the same contract there.

The payload directories (`claude/`, `cursor/`, `codex/`, no dot) are what `sync.sh` installs.
`cursor/` and `codex/` are generated from `claude/` by `translate/cursor.mjs` and
`translate/codex.mjs`, and `--check` gates their freshness in CI, at push, and in
`claude/enforce/doctor.sh`. Everything under `codex/` is generated except the paths in the port
map's `hand_authored` key, which at the time of writing are four:
`codex/hooks/codex-hook-adapter.sh`, `codex/README.md`, `codex/skills/session-start/SKILL.md`, and
`codex/skills/session-handoff/SKILL.md`. Read the key rather than this list, because the list is a
snapshot and the key is the authority. Editing any other file under `codex/` is lost at the next
`--write`, and `--check` fails until it is reverted; change the `claude/` source or the port map
instead, then regenerate.

The root `AGENTS.md` carries an older two-entry version of that same list, and `claude/SETUP.md`
step 1 still describes the pre-monorepo layout in which the repository was cloned directly to
`~/.claude`. Both predate the current structure and are tracked for correction. Where either
contradicts this file on the install path or the generated-file list, `sync.sh` and
`translate/codex-port-map.json` are the authorities.

The monorepo design is specced at
`claude/docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md`.

## License

MIT. See [`LICENSE`](LICENSE).
