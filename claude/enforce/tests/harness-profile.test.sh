#!/usr/bin/env bash
# Watches: translate/apply-profile.mjs enforce/harness-profiles.json CLAUDE.md settings.json skills/* agents/* rules/* rulebook/* audits/* prompts/* PROTOCOL.md CLAUDE-*.md
# Verifies translate/apply-profile.mjs and claude/enforce/harness-profiles.json
# (IAN-518): the one switch that hides every COACHING and ORCHESTRATION item
# of the harness without deleting it. Reads the real claude/ tree, because the
# point of the closure check is that the profile cannot drift from it: every
# id the lean profile lists must still exist. Then proves what lean removes
# and what it must keep: every other rule line, every enforcing hook
# (harness-sync included), the scripts gates read under task-start and
# build-fast, and the TDD and review agents. No profile is the identity.
set -uo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
MODULE="$REPO_TOP/translate/apply-profile.mjs"
PROFILES="$REPO_TOP/claude/enforce/harness-profiles.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
not_grep() { ! grep -q "$@"; }

check "apply-profile.mjs exists" test -f "$MODULE"
check "harness-profiles.json exists and parses" jq -e '.profiles.lean' "$PROFILES"

# The whole behavioural check runs as one node script so each assertion reads
# the module's real return values rather than a shell re-implementation.
cat >"$TMP/assert.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
const [modulePath, profilesPath, claudeDir] = process.argv.slice(2);
const { loadHarnessProfiles, loadSourceSet, applyProfile, ProfileError } = await import(modulePath);
const results = [];
const check = (name, ok) => results.push(`${ok ? "PASS" : "FAIL"}: ${name}`);
const profiles = loadHarnessProfiles(profilesPath);
const lean = profiles.profiles.lean;
const source = loadSourceSet(claudeDir);
const text = (set, rel) => set.get(rel)?.content?.toString("utf8");

// Identity: no profile returns every entry unchanged and omits nothing.
const identity = applyProfile(undefined, source, profiles);
check("no profile keeps every entry", identity.files.size === source.size
  && [...source.keys()].every((rel) => identity.files.get(rel) === source.get(rel)));
check("no profile omits nothing", identity.omitted.size === 0);
const full = applyProfile("full", source, profiles);
check("profile full is the identity", full.files.size === source.size && full.omitted.size === 0);

// Unknown profile and a stale id are both errors.
let threw = false;
try { applyProfile("no-such-profile", source, profiles); } catch (err) { threw = err instanceof ProfileError; }
check("unknown profile is a ProfileError", threw);
for (const [kind, bogus] of [["rules", "R-999"], ["hooks", "no-such-hook"], ["skills", "no-such-skill"], ["agents", "no-such-agent"], ["files", "no/such/file.md"]]) {
  const drifted = structuredClone(profiles);
  drifted.profiles.lean[kind] = [...drifted.profiles.lean[kind], bogus];
  let staleThrew = false;
  try { applyProfile("lean", source, drifted); } catch (err) { staleThrew = err instanceof ProfileError && err.message.includes(bogus); }
  check(`a ${kind} id missing from claude/ is a ProfileError naming it`, staleThrew);
}

// Permission, not only existence (PR #175 review): an item that enforces,
// delivers the guards, or holds the TDD and review split can never be
// removed by any profile, whatever category lists it.
const protectedCases = [
  ["hooks", "destructive-db-guard"], ["hooks", "harness-sync"], ["hooks", "verification-gate"],
  ["agents", "security-reviewer"], ["agents", "test-author"],
  ["files", "rulebook/reference.md"], ["files", "skills/task-start/scripts/task-tier.sh"],
  ["files", "hooks/harness-sync.sh"], ["files", "hooks/secret-scan.sh"], ["files", "enforce/role-policy.json"],
  ["files", "enforce/tdd.sh"], ["files", "agents/pr-reviewer.md"], ["files", "settings.json"],
  ["rules", "R-109"], ["rules", "R-003"], ["rules", "R-412"], ["rules", "R-517"],
  // Round 2: the STRUCTURAL prompt contracts and the template a check reads,
  // and every hooks/ file that is not a removable hook script.
  ["files", "prompts/security-review-prompt.md"], ["files", "prompts/codex-pr-review-prompt.md"],
  ["files", "prompts/spec-template.md"],
  ["files", "hooks/pre-push.sample"], ["files", "hooks/shell-command-segments.py"],
  ["files", "hooks/shell-command-tokens.sh"],
];
for (const [kind, id] of protectedCases) {
  const widened = structuredClone(profiles);
  widened.profiles.lean[kind] = [...widened.profiles.lean[kind], id];
  let refused = false;
  try { applyProfile("lean", source, widened); } catch (err) { refused = err instanceof ProfileError && err.message.includes(id) && /protected/.test(err.message); }
  check(`a profile listing protected ${kind} ${id} is refused as protected`, refused);
}

// The inverted hooks/ rule still lets a profile omit a removable hook script.
{
  const widened = structuredClone(profiles);
  widened.profiles.lean.files = [...widened.profiles.lean.files, "hooks/session-start.sh"];
  let omitsScript = false;
  try { omitsScript = applyProfile("lean", source, widened).omitted.has("hooks/session-start.sh"); } catch { omitsScript = false; }
  check("a profile may omit a removable hook script such as hooks/session-start.sh", omitsScript);
}

// Closure: the committed lean profile applies cleanly to the real tree.
let result;
try { result = applyProfile("lean", source, profiles); check("lean applies to the real claude/ tree", true); }
catch (err) { check(`lean applies to the real claude/ tree (${err.message})`, false); process.stdout.write(results.join("\n") + "\n"); process.exit(0); }
const { files, omitted } = result;

// CLAUDE.md: each listed rule gone, every other rule line kept verbatim.
const ruleLine = /^(R-\d{3})( \[[a-z]+\])?:/;
const sourceRules = text(source, "CLAUDE.md").split("\n").filter((line) => ruleLine.test(line));
const leanRules = text(files, "CLAUDE.md").split("\n").filter((line) => ruleLine.test(line));
const listed = new Set(lean.rules);
check("lean lists 40 rules (41 before R-002 was deleted, IAN-518)", lean.rules.length === 40);
check("lean CLAUDE.md lacks every listed rule", leanRules.every((line) => !listed.has(ruleLine.exec(line)[1])));
const expectedKept = sourceRules.filter((line) => !listed.has(ruleLine.exec(line)[1]));
check("lean CLAUDE.md keeps every other rule line verbatim", JSON.stringify(leanRules) === JSON.stringify(expectedKept));
check("lean CLAUDE.md keeps R-003 and R-109", leanRules.some((l) => l.startsWith("R-003:")) && leanRules.some((l) => l.startsWith("R-109:")));

// settings.json: listed hooks gone from every event, every other hook kept.
const hookNames = (settings) => {
  const names = [];
  for (const groups of Object.values(settings.hooks)) for (const group of groups)
    for (const hook of group.hooks ?? []) names.push(path.basename(hook.command).replace(/\.sh$/, ""));
  return names;
};
const sourceSettings = JSON.parse(text(source, "settings.json"));
const leanSettings = JSON.parse(text(files, "settings.json"));
const leanHooks = hookNames(leanSettings);
const droppedHooks = new Set(lean.hooks);
check("lean never drops harness-sync", !droppedHooks.has("harness-sync") && leanHooks.includes("harness-sync"));
check("lean drops every listed hook", lean.hooks.every((name) => !leanHooks.includes(name)));
const keptHooks = hookNames(sourceSettings).filter((name) => !droppedHooks.has(name));
check("lean keeps every other hook registration", JSON.stringify(leanHooks) === JSON.stringify(keptHooks));
for (const guard of ["secret-scan", "protected-path-guard", "git-workflow-guard", "verification-gate", "settings-change-guard", "no-em-dash"])
  check(`lean keeps enforcing hook ${guard}`, leanHooks.includes(guard));
// Exact retention (PR #175 review): lean's hooks object equals the full one
// with exactly the listed commands removed, every other field of every
// registration (event, matcher, command, timeout, type, anything else)
// unchanged, empty groups and events dropped.
const expectedHooks = {};
for (const [event, groups] of Object.entries(sourceSettings.hooks)) {
  const kept = groups
    .map((group) => ({ ...group, hooks: group.hooks.filter((hook) => !droppedHooks.has(path.basename(hook.command).replace(/\.sh$/, ""))) }))
    .filter((group) => group.hooks.length > 0);
  if (kept.length > 0) expectedHooks[event] = kept;
}
check("lean hooks equal full hooks minus exactly the listed commands, field for field", JSON.stringify(leanSettings.hooks) === JSON.stringify(expectedHooks));

// An independent, hard-coded guard list: each keeps every (event, matcher)
// pair it has in the full settings.json.
const guardNames = [
  "secret-scan", "no-em-dash", "fix-commit-requires-test", "conflict-markers", "commit-message-guard",
  "destructive-db-guard", "destructive-command-guard", "codex-billing-guard", "protected-path-guard",
  "global-repo-push-guard", "git-workflow-guard", "push-eslint-gate", "push-ruff-gate",
  "push-semgrep-gate", "pr-ticket-ref-gate",
  "constant-change-guard", "migration-defaults-guard", "structure-gate", "content-gate", "dependency-add-guard",
  "mcp-action-guard",
  "linear-todo-label-gate", "verification-gate", "settings-change-guard", "harness-sync",
];
const registrationsOf = (settings, name) => {
  const pairs = [];
  for (const [event, groups] of Object.entries(settings.hooks)) for (const group of groups)
    for (const hook of group.hooks) if (path.basename(hook.command) === `${name}.sh`) pairs.push(`${event}|${group.matcher ?? ""}|${hook.command}`);
  return pairs.sort();
};
for (const name of guardNames) {
  const fullPairs = registrationsOf(sourceSettings, name);
  check(`guard ${name} keeps every registration and matcher`, fullPairs.length > 0 && JSON.stringify(registrationsOf(leanSettings, name)) === JSON.stringify(fullPairs));
}
check("lean leaves no empty hook group", Object.values(leanSettings.hooks).every((groups) => groups.length > 0 && groups.every((g) => g.hooks.length > 0)));
const { hooks: _sourceHooks, ...sourceRest } = sourceSettings;
const { hooks: _leanHooks, ...leanRest } = leanSettings;
check("lean settings.json keeps every non-hook key", JSON.stringify(sourceRest) === JSON.stringify(leanRest));

// Skills: every SKILL.md hidden, every script and data file kept.
const skillDirs = fs.readdirSync(path.join(claudeDir, "skills"));
check("lean lists every skill", lean.skills.length === skillDirs.length && skillDirs.every((d) => lean.skills.includes(d)));
check("lean omits every SKILL.md", skillDirs.every((d) => !files.has(`skills/${d}/SKILL.md`) && omitted.has(`skills/${d}/SKILL.md`)));
for (const keep of ["skills/task-start/scripts/task-tier.sh", "skills/task-start/scripts/finding.sh", "skills/build-fast/scripts/build-lane.sh", "skills/build-fast/lane-rules.json"])
  check(`lean keeps ${keep}`, files.has(keep) && files.get(keep) === source.get(keep));

// Agents: the nine audit agents hidden, the six structural ones kept.
check("lean omits the nine audit agents", lean.agents.length === 9 && lean.agents.every((a) => a.startsWith("audit-") && !files.has(`agents/${a}.md`)));
for (const agent of ["test-author", "implementer", "slice-critic", "spec-conformance-review", "pr-reviewer", "security-reviewer"])
  check(`lean keeps agent ${agent}`, files.has(`agents/${agent}.md`));

// Files: convention files, their rule symlinks, audits, rulebook extras gone.
check("lean omits every listed file", lean.files.every((rel) => !files.has(rel) && omitted.has(rel)));
for (const gone of ["CLAUDE-PYTHON.md", "rules/python.md", "rules/session-types.md", "rulebook/cost.md", "PROTOCOL.md", "rulebook/audits.md", "agents/audit-security.md", "prompts/subagent-branch-setup.md"])
  check(`lean omits ${gone}`, !files.has(gone));
for (const keep of ["rulebook/reference.md", "CLOUD-DEPLOYMENT.md", "prompts/codex-pr-review-prompt.md", "prompts/security-review-prompt.md", "enforce/tdd.sh", "hooks/harness-sync.sh", "hooks/session-start.sh"])
  check(`lean keeps ${keep}`, files.has(keep));
check("lean omits no CLAUDE-*.md it does not list", [...source.keys()].filter((rel) => /^CLAUDE-.*\.md$/.test(rel)).every((rel) => lean.files.includes(rel)));
check("every omitted path was in the source", [...omitted].every((rel) => source.has(rel)));
check("lean only removes or rewrites, never adds", [...files.keys()].every((rel) => source.has(rel)));

process.stdout.write(results.join("\n") + "\n");
EOF

if [ -f "$MODULE" ] && [ -f "$PROFILES" ]; then
  node "$TMP/assert.mjs" "$MODULE" "$PROFILES" "$REPO_TOP/claude" >"$TMP/out.txt" 2>&1
  cat "$TMP/out.txt"
  grep -q '^FAIL' "$TMP/out.txt" && fail=1
  grep -q '^PASS' "$TMP/out.txt" || { echo "FAIL: assertion script produced no results"; fail=1; }
fi

# CLI: --in-place filters a copy of the tracked claude/ tree on disk.
mkdir -p "$TMP/copy"
git -C "$REPO_TOP" ls-files -- claude >"$TMP/tracked.txt"
rsync -a --files-from="$TMP/tracked.txt" "$REPO_TOP/" "$TMP/copy/"
node "$MODULE" --profile lean --in-place "$TMP/copy/claude" >"$TMP/cli.log" 2>&1
check "--in-place exits 0" test $? -eq 0
check "--in-place removes skills/gof/SKILL.md" test ! -e "$TMP/copy/claude/skills/gof/SKILL.md"
check "--in-place removes the rules/python.md symlink" test ! -L "$TMP/copy/claude/rules/python.md"
check "--in-place keeps task-tier.sh executable" test -x "$TMP/copy/claude/skills/task-start/scripts/task-tier.sh"
check "--in-place drops R-001 from CLAUDE.md" not_grep '^R-001:' "$TMP/copy/claude/CLAUDE.md"
check "--in-place keeps R-101 in CLAUDE.md" grep -q '^R-101:' "$TMP/copy/claude/CLAUDE.md"
check "--in-place leaves settings.json valid JSON without session-start" jq -e '[.hooks[][].hooks[].command] | map(select(test("session-start"))) | length == 0' "$TMP/copy/claude/settings.json"

node "$MODULE" --profile no-such-profile --in-place "$TMP/copy/claude" >/dev/null 2>&1
check "--in-place refuses an unknown profile with exit 2" test $? -eq 2
node "$MODULE" --validate --root "$REPO_TOP" >"$TMP/validate.log" 2>&1
check "--validate passes on the real tree" test $? -eq 0

exit "$fail"
