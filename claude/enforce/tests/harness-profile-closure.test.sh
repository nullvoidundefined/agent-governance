#!/usr/bin/env bash
# Watches: translate/apply-profile.mjs settings.json enforce/harness-profiles.json hooks/*
# Closure between docs/harness-audit.md and the protected sets that
# translate/apply-profile.mjs exports (IAN-518, PR #175 review round 2). Every
# hook the audit's Hooks table classes ENFORCE or STRUCTURAL, and every rule
# its CLAUDE.md rules table classes ENFORCE or STRUCTURAL, must be protected,
# so no profile can ever hide them. Every hook registered in
# claude/settings.json must be protected or classified in the audit, so a new
# hook nobody classified fails here instead of becoming silently removable.
# Every protected hook must have its script, and every hook the lean profile
# hides must be one the audit classes COACHING or ORCHESTRATION.
set -uo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/closure.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
const [repoTop] = process.argv.slice(2);
const { PROTECTED_HOOKS, PROTECTED_RULES } = await import(path.join(repoTop, "translate/apply-profile.mjs"));
const results = [];
const check = (name, ok) => results.push(`${ok ? "PASS" : "FAIL"}: ${name}`);
const audit = fs.readFileSync(path.join(repoTop, "docs/harness-audit.md"), "utf8");

// sectionRows(heading): the cells of every table row in the section that
// starts with heading, header and separator rows dropped.
const sectionRows = (heading) => {
  const start = audit.indexOf(`\n${heading}\n`);
  if (start === -1) return [];
  const rest = audit.slice(start + heading.length + 2);
  const end = rest.search(/\n## /);
  return (end === -1 ? rest : rest.slice(0, end)).split("\n")
    .filter((line) => line.startsWith("|") && !/^\|[-| ]+\|$/.test(line))
    .map((line) => line.split("|").slice(1, -1).map((cell) => cell.trim()))
    .slice(1);
};
const isEnforcing = (cls) => /ENFORCE|STRUCTURAL/.test(cls);

const hookRows = sectionRows("## Hooks").map(([name, , cls]) => ({ name, cls }));
const ruleRows = sectionRows("## Rules in `claude/CLAUDE.md`").map(([id, cls]) => ({ id: id.split(" ")[0], cls }));
// A parse sanity floor, lowered from 50 when IAN-568 removed nine hooks (48 rows remain).
check("the audit Hooks table parses to at least 40 rows", hookRows.length >= 40);
check("the audit rules table parses to at least 90 rows", ruleRows.length >= 90);

for (const { name } of hookRows.filter(({ cls }) => isEnforcing(cls)))
  check(`audit ENFORCE/STRUCTURAL hook ${name} is protected`, PROTECTED_HOOKS.has(name));
for (const { id } of ruleRows.filter(({ cls }) => isEnforcing(cls)))
  check(`audit ENFORCE/STRUCTURAL rule ${id} is protected`, PROTECTED_RULES.has(id));

const classified = new Set(hookRows.map(({ name }) => name));
const settings = JSON.parse(fs.readFileSync(path.join(repoTop, "claude/settings.json"), "utf8"));
const registered = new Set();
for (const groups of Object.values(settings.hooks)) for (const group of groups)
  for (const hook of group.hooks) registered.add(path.basename(hook.command).replace(/\.sh$/, ""));
for (const name of [...registered].sort())
  check(`registered hook ${name} is protected or classified in the audit`, PROTECTED_HOOKS.has(name) || classified.has(name));

for (const name of [...PROTECTED_HOOKS].sort())
  check(`protected hook ${name} has its script`, fs.existsSync(path.join(repoTop, "claude/hooks", `${name}.sh`)));

const lean = JSON.parse(fs.readFileSync(path.join(repoTop, "claude/enforce/harness-profiles.json"), "utf8")).profiles.lean;
const removableClass = new Map(hookRows.map(({ name, cls }) => [name, cls]));
for (const name of lean.hooks)
  check(`lean hook ${name} is classed COACHING or ORCHESTRATION in the audit`, /^(COACHING|ORCHESTRATION)$/.test(removableClass.get(name) ?? ""));

const safety = JSON.parse(fs.readFileSync(path.join(repoTop, "claude/enforce/harness-profiles.json"), "utf8")).profiles.safety;
for (const name of safety.hooks)
  check(`safety hook ${name} is classed PROCESS, COACHING or ORCHESTRATION in the audit`, /^(PROCESS|COACHING|ORCHESTRATION)$/.test(removableClass.get(name) ?? ""));

process.stdout.write(`${results.join("\n")}\n`);
EOF

fail=0
node "$TMP/closure.mjs" "$REPO_TOP" >"$TMP/out.txt" 2>&1 || { echo "FAIL: closure script crashed"; fail=1; }
cat "$TMP/out.txt"
grep -q '^FAIL' "$TMP/out.txt" && fail=1
grep -q '^PASS' "$TMP/out.txt" || { echo "FAIL: closure script produced no results"; fail=1; }
exit "$fail"
