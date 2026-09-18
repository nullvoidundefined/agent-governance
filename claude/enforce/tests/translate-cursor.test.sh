#!/usr/bin/env bash
# Shard: slow
# Watches: translate/* cursor/*
# Verifies translate/cursor.mjs: the cursor port generator. Hermetic: builds
# a miniature claude/-plus-translate/ source tree in a sandbox and never
# reads the real trees, so the fixture survives repo moves (2026-09-17
# lesson, carried over from translate-codex.test.sh). Covers usage hygiene,
# source loading and validation, every render class (stack rules, always-on
# rules, rulebook fan-out, agents/commands, skills, hooks.json,
# PORT-STATUS.md, the derived .gitignore, the manifest), and --write/--check
# divergence and parity.
set -uo pipefail
REPO_TOP=$(git rev-parse --show-toplevel)
TRANSLATOR="$REPO_TOP/translate/cursor.mjs"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
# not <cmd...>: negates a command's exit status. A bare "!" loses its
# reserved-word status once it travels through check()'s "$@" expansion, so
# a negated check routes through this wrapper instead (mirrors
# translate-codex.test.sh's identical helper).
not() { ! "$@"; }

# make_cursor_source_tree <dir>: builds a miniature claude/-plus-translate/
# source tree in <dir> (a repo-shaped --root). Ported hook: alpha-guard
# (PreToolUse Bash, which the map's events fan out to beforeShellExecution).
# Unported hook: beta-check (ConfigChange, which the map's events translate
# to an empty fan-out list). Also writes stub hand-authored cursor/ files so
# the existence checks below have something to find; make_cursor_source_tree
# itself never writes to cursor/, only --write does.
make_cursor_source_tree() {
  local dir="$1"
  mkdir -p "$dir/claude/agents" "$dir/claude/skills/structure-conventions" "$dir/claude/rules"
  mkdir -p "$dir/claude/global-memory" "$dir/claude/rulebook"
  mkdir -p "$dir/translate"
  mkdir -p "$dir/cursor/hooks" "$dir/cursor/commands"

  cat >"$dir/claude/CLAUDE.md" <<'EOF'
# Sandbox Rules

R-501: Run the alpha guard before any risky write. [hook:alpha-guard]
R-502: Run the beta check before any config change. [hook:beta-check]
R-503: Run both guards together in one pass. [hook:alpha-guard, hook:beta-check]
R-504: Run the gamma check after any risky edit. [hook:gamma-guard]
R-505: Run the delta check at session start. [hook:delta-guard]
EOF

  cat >"$dir/claude/rules/session-types.md" <<'EOF'
# Session Types

Sandbox session-type classification table for the cursor translator fixture.
EOF

  cat >"$dir/claude/global-memory/INDEX.md" <<'EOF'
# Global Memory Index

Sandbox cross-project index for the cursor translator fixture.

- [`feedback_sandbox_one.md`](./feedback_sandbox_one.md): Sandbox bullet one for the cursor translator fixture.
- [`feedback_sandbox_two.md`](./feedback_sandbox_two.md): Sandbox bullet two for the cursor translator fixture.
EOF

  cat >"$dir/claude/CLAUDE-BACKEND.md" <<'EOF'
---
paths:
  - "**/src/handlers/**"
  - "**/src/services/**"
---

# Backend Conventions

Sandbox backend stack conventions body for the cursor translator fixture.
EOF

  cat >"$dir/claude/CLOUD-DEPLOYMENT.md" <<'EOF'
# Cloud Deployment

Sandbox cloud deployment body for the cursor translator fixture.
EOF

  cat >"$dir/claude/rulebook/reference.md" <<'EOF'
# Global Rule Reference (full Specs)

Sandbox rulebook reference preamble for the cursor translator fixture.

## Session init (R-0xx)

R-501 spec body for the sandbox fixture.

### Nested detail (R-50x)

Sandbox nested subheading body that must stay inside the Session init file.

## Convention files

Sandbox convention-files body for the cursor translator fixture, no rule-range parenthetical.
EOF

  cat >"$dir/claude/rulebook/agents.md" <<'EOF'
# Agents and Dispatch

Sandbox rulebook agents body for the cursor translator fixture.
EOF

  cat >"$dir/claude/rulebook/audits.md" <<'EOF'
# Audits

Sandbox rulebook audits body for the cursor translator fixture.
EOF

  cat >"$dir/claude/rulebook/cost.md" <<'EOF'
# Cost, Routing, and Estimation

Sandbox rulebook cost body for the cursor translator fixture.
EOF

  cat >"$dir/claude/agents/audit-sample.md" <<'EOF'
---
name: audit-sample
description: Sandbox audit agent used by the cursor translator fixture.
tools: Read, Grep, Write
model: sonnet
---

# Audit Sample

Sandbox audit agent body used by the cursor translator fixture tests.
EOF

  cat >"$dir/claude/agents/spec-conformance-review.md" <<'EOF'
---
name: spec-conformance-review
description: Sandbox read-only review agent used by the cursor translator fixture.
tools: Read, Grep, Glob, Bash
model: opus
---

# Spec Conformance Review Sample

Sandbox read-only agent body used by the cursor translator fixture tests.
EOF

  cat >"$dir/claude/agents/helper-role.md" <<'EOF'
---
name: helper-role
description: Sandbox non-audit agent used by the cursor translator fixture.
tools: Read
model: sonnet
---

# Helper Role

Sandbox non-audit agent body used by the cursor translator fixture tests.
EOF

  cat >"$dir/claude/skills/structure-conventions/SKILL.md" <<'EOF'
---
name: structure-conventions
description: sandbox structure-conventions skill
---

# Structure Conventions

the sandbox structure-conventions skill body line
EOF

  cat >"$dir/claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/alpha-guard.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/gamma-guard.sh" }
        ]
      }
    ],
    "ConfigChange": [
      {
        "matcher": "user_settings",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/beta-check.sh" }
        ]
      },
      {
        "matcher": "user_settings",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/gamma-guard.sh" }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/delta-guard.sh" }
        ]
      }
    ]
  }
}
EOF

  cat >"$dir/translate/cursor-port-map.json" <<'EOF'
{
  "builder": "translate/cursor.mjs",
  "classifications_note": "class values: generated | importable | hand-authored-local | hand-authored-mapped | runtime-only-ignored | unsupported (B-9 taxonomy from the parked source-neutral spec)",
  "hand_authored": {
    "README.md": "hand-authored-local",
    "hooks/claude-hook-adapter.sh": "hand-authored-mapped",
    "commands/session-start.md": "hand-authored-local",
    "commands/session-handoff.md": "hand-authored-local"
  },
  "agents_to_subagents": ["audit-*", "spec-conformance-review"],
  "events": {
    "PreToolUse": { "Bash": ["beforeShellExecution", "preToolUse"] },
    "ConfigChange": { "*": [] },
    "SessionStart": { "*": ["sessionStart"] }
  },
  "adapter_internal_events": ["beforeReadFile"],
  "unported_reasons": {
    "beta-check": "ConfigChange is a Claude Code event; sandbox stub reason."
  },
  "rule_descriptions": {
    "000-global-rules.mdc": "Sandbox global rules description for the cursor translator fixture.",
    "001-session-types.mdc": "Sandbox session types description for the cursor translator fixture.",
    "002-global-memory-index.mdc": "Sandbox global memory index description for the cursor translator fixture.",
    "backend.mdc": "Sandbox backend stack rule description for the cursor translator fixture.",
    "cloud-deployment.mdc": "Sandbox cloud deployment rule description for the cursor translator fixture.",
    "rulebook-agents.mdc": "Sandbox rulebook agents description for the cursor translator fixture.",
    "rulebook-audits.mdc": "Sandbox rulebook audits description for the cursor translator fixture.",
    "rulebook-cost.mdc": "Sandbox rulebook cost description for the cursor translator fixture.",
    "rulebook-reference-r0xx-session-init.mdc": "Sandbox rulebook reference session-init description for the cursor translator fixture.",
    "rulebook-reference-convention-files.mdc": "Sandbox rulebook reference convention-files description for the cursor translator fixture."
  },
  "cursor_preamble": "Sandbox cursor preamble sentence for the cursor translator fixture.",
  "index_trailing_paragraph": "Sandbox index trailing paragraph for the cursor translator fixture.",
  "port_status_appendix": "## Permission rules\n\nSandbox stub appendix line for the cursor translator fixture."
}
EOF

  cat >"$dir/cursor/hooks/claude-hook-adapter.sh" <<'EOF'
#!/usr/bin/env bash
# Sandbox stub hand-authored adapter for the cursor translator fixture.
EOF
  chmod +x "$dir/cursor/hooks/claude-hook-adapter.sh"

  cat >"$dir/cursor/README.md" <<'EOF'
# Cursor (sandbox)

Sandbox stub hand-authored README for the cursor translator fixture.
EOF

  cat >"$dir/cursor/commands/session-start.md" <<'EOF'
Sandbox stub hand-authored session-start command for the cursor translator fixture.
EOF

  cat >"$dir/cursor/commands/session-handoff.md" <<'EOF'
Sandbox stub hand-authored session-handoff command for the cursor translator fixture.
EOF
}

# Usage hygiene (mirrors translate-codex.test.sh's usage-hygiene cases): no mode,
# both modes, an unknown flag, and a bare --root, all before any filesystem
# access, so a usage error touches nothing.
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
OUT=$(node "$TRANSLATOR" --root "$SANDBOX" 2>&1); ST=$?
check "no mode exits 2" test "$ST" -eq 2
check "no mode prints usage" grep -q -- "--write" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --check --root "$SANDBOX" 2>&1); ST=$?
check "both modes exit 2" test "$ST" -eq 2
OUT=$(node "$TRANSLATOR" --frobnicate --root "$SANDBOX" 2>&1); ST=$?
check "unknown flag exits 2" test "$ST" -eq 2
check "usage errors touch nothing" test -z "$(ls -A "$SANDBOX")"

# A bare --root (no following value) is a usage error (exit 2), not a crash.
# Run outside any sandbox root so a regression to the old TypeError behavior
# cannot leave stray writes on disk anywhere.
OUT=$(node "$TRANSLATOR" --check --root 2>&1); ST=$?
check "bare --root exits 2" test "$ST" -eq 2
check "bare --root prints usage" grep -q -- "--write" <<<"$OUT"

# A --root immediately followed by another flag is the same usage error, not
# a crash treating the next flag's text as the root directory.
OUT=$(node "$TRANSLATOR" --check --root --write 2>&1); ST=$?
check "--root before another flag exits 2" test "$ST" -eq 2

# Failure modes: missing settings.json and a port map missing a required key
# each exit 2 naming the offending file (spec's Failure modes section).
SRC=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC"' EXIT
make_cursor_source_tree "$SRC"
rm "$SRC/claude/settings.json"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing settings exits 2" test "$ST" -eq 2
check "missing settings named" grep -q "settings.json" <<<"$OUT"

make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
del data["events"]
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "port map missing key exits 2" test "$ST" -eq 2
check "port map missing key named" grep -q "cursor-port-map.json" <<<"$OUT"
check "port map missing key names the key" grep -q "missing events" <<<"$OUT"

# Every other required cursor port map key fails the same way, one at a
# time, so a future edit that drops any of them is caught here rather than
# surfacing later as an undefined deep inside a renderer.
for key in hand_authored agents_to_subagents adapter_internal_events unported_reasons \
  rule_descriptions cursor_preamble index_trailing_paragraph port_status_appendix; do
  make_cursor_source_tree "$SRC"
  python3 - "$SRC/translate/cursor-port-map.json" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
del data[key]
with open(path, "w") as f:
    json.dump(data, f)
PY
  OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
  check "port map missing $key exits 2" test "$ST" -eq 2
  check "port map missing $key named" grep -q "missing $key" <<<"$OUT"
done

# A nameless agent (no frontmatter name field) exits 2 naming the file, same
# mechanic as the codex loader's agent frontmatter validation.
make_cursor_source_tree "$SRC"
printf '%s\n' "no frontmatter here" >"$SRC/claude/agents/helper-role.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "nameless agent exits 2" test "$ST" -eq 2
check "nameless agent named" grep -q "helper-role.md" <<<"$OUT"

# A missing rulebook file (one of the four rulebook agents/audits/cost/
# reference sources) exits 2 naming the file: cursor.mjs loads all four
# every run, not only the ones a given claude/ tree happens to touch.
make_cursor_source_tree "$SRC"
rm "$SRC/claude/rulebook/cost.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing rulebook file exits 2" test "$ST" -eq 2
check "missing rulebook file named" grep -q "rulebook/cost.md" <<<"$OUT"

# A missing CLOUD-DEPLOYMENT.md exits 2 naming the file (loaded separately
# from the CLAUDE-*.md glob since it carries no CLAUDE- prefix).
make_cursor_source_tree "$SRC"
rm "$SRC/claude/CLOUD-DEPLOYMENT.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing CLOUD-DEPLOYMENT.md exits 2" test "$ST" -eq 2
check "missing CLOUD-DEPLOYMENT.md named" grep -q "CLOUD-DEPLOYMENT.md" <<<"$OUT"

# A missing or renamed structure-conventions skill exits 2 naming the
# expected path (review round 1): renderPlannedTree used to silently omit
# rules/structure-conventions.mdc when the skill was absent, the exact
# silent-drift class this tool exists to kill, since --check would then
# stay green with the generated rule quietly gone. Checked in both modes:
# --check must fail loudly (no rendering happens), and --write must refuse
# to write a partial tree rather than writing everything else and leaving
# the missing rule unnoticed.
make_cursor_source_tree "$SRC"
rm -rf "$SRC/claude/skills/structure-conventions"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing structure-conventions skill exits 2 (check mode)" test "$ST" -eq 2
check "missing structure-conventions skill named (check mode)" \
  grep -q "claude/skills/structure-conventions/SKILL.md" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1); ST=$?
check "missing structure-conventions skill exits 2 (write mode)" test "$ST" -eq 2
check "missing structure-conventions skill named (write mode)" \
  grep -q "claude/skills/structure-conventions/SKILL.md" <<<"$OUT"
check "missing structure-conventions skill write touches nothing" \
  test ! -e "$SRC/cursor/rules/backend.mdc"

# A produced Class C file with no rule_descriptions entry fails
# fast naming the missing key, in both modes, rather than writing a
# frontmatter with an undefined description or silently omitting the file.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
del data["rule_descriptions"]["rulebook-agents.mdc"]
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing rulebook-agents.mdc description exits 2" test "$ST" -eq 2
check "missing rulebook-agents.mdc description names cursor-port-map.json" \
  grep -q "cursor-port-map.json" <<<"$OUT"
check "missing rulebook-agents.mdc description names the missing key" \
  grep -q "rule_descriptions missing entry for rulebook-agents.mdc" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1); ST=$?
check "missing rulebook-agents.mdc description exits 2 (write mode)" test "$ST" -eq 2
check "missing rulebook-agents.mdc description write touches nothing" \
  test ! -e "$SRC/cursor/rules/rulebook-agents.mdc"

# Same fail-fast for a produced reference-splitter file's description.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
del data["rule_descriptions"]["rulebook-reference-convention-files.mdc"]
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing reference-splitter description exits 2" test "$ST" -eq 2
check "missing reference-splitter description names the missing key" \
  grep -q "rule_descriptions missing entry for rulebook-reference-convention-files.mdc" <<<"$OUT"

# Same fail-fast for a Class B stack-rule file's description (review I-1):
# render-cursor-stack-rules.mjs used to read rule_descriptions[mdcName] with
# no guard at all, so a CLAUDE-*.md source with no matching port-map entry
# rendered a frontmatter block whose description literally read the string
# "undefined", and --check stayed green from that point on since the
# rendered content was internally consistent with itself. Class B's
# filenames are the one class actually driven by which claude/CLAUDE-*.md
# files happen to exist, which is exactly the case a static presence check
# on the rule_descriptions object cannot cover, so this mirrors the Class C
# cases above rather than trusting the object's mere existence.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
del data["rule_descriptions"]["backend.mdc"]
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing backend.mdc description exits 2" test "$ST" -eq 2
check "missing backend.mdc description names cursor-port-map.json" \
  grep -q "cursor-port-map.json" <<<"$OUT"
check "missing backend.mdc description names the missing key" \
  grep -q "rule_descriptions missing entry for backend.mdc" <<<"$OUT"
check "missing backend.mdc description never renders the literal string undefined" \
  not grep -q "description: undefined" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1); ST=$?
check "missing backend.mdc description exits 2 (write mode)" test "$ST" -eq 2
check "missing backend.mdc description write touches nothing" \
  test ! -e "$SRC/cursor/rules/backend.mdc"

# Clean sandbox: both modes load every source and exit 0. --write now
# renders the Class B/D files: the hand-authored stub tree's own
# hashes prove --write leaves hand-authored content untouched while the
# generated rules/*.mdc files land alongside it.
make_cursor_source_tree "$SRC"
HAND_AUTHORED_SNAP_BEFORE=$(cd "$SRC/cursor" && shasum README.md hooks/claude-hook-adapter.sh commands/session-start.md commands/session-handoff.md | sort)
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
check "clean tree write exits 0" test $? -eq 0
HAND_AUTHORED_SNAP_AFTER=$(cd "$SRC/cursor" && shasum README.md hooks/claude-hook-adapter.sh commands/session-start.md commands/session-handoff.md | sort)
check "write leaves hand-authored files untouched" test "$HAND_AUTHORED_SNAP_BEFORE" = "$HAND_AUTHORED_SNAP_AFTER"
node "$TRANSLATOR" --check --root "$SRC" >/dev/null 2>&1
check "clean tree check exits 0" test $? -eq 0

# Class B (stack rules) and Class D (structure-conventions skill
# rule) renderers, wired into --write's planned tree.
BACKEND_MDC="$SRC/cursor/rules/backend.mdc"
check "backend.mdc exists" test -f "$BACKEND_MDC"
check "backend.mdc globs match the source's own paths list" \
  grep -q '^globs: \*\*/src/handlers/\*\*,\*\*/src/services/\*\*$' "$BACKEND_MDC"
check "backend.mdc description from rule_descriptions" \
  grep -q '^description: Sandbox backend stack rule description for the cursor translator fixture\.$' "$BACKEND_MDC"
check "backend.mdc alwaysApply false" grep -q '^alwaysApply: false$' "$BACKEND_MDC"
check "backend.mdc GENERATED header names the builder and source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from CLAUDE-BACKEND\.md\.' "$BACKEND_MDC"
check "backend.mdc body verbatim past the header" \
  diff <(tail -n +7 "$BACKEND_MDC") - <<'EOF'

# Backend Conventions

Sandbox backend stack conventions body for the cursor translator fixture.
EOF

CLOUD_MDC="$SRC/cursor/rules/cloud-deployment.mdc"
check "cloud-deployment.mdc exists" test -f "$CLOUD_MDC"
check "cloud-deployment.mdc empty-globs case" grep -qx 'globs:' "$CLOUD_MDC"
check "cloud-deployment.mdc description from rule_descriptions" \
  grep -q '^description: Sandbox cloud deployment rule description for the cursor translator fixture\.$' "$CLOUD_MDC"
check "cloud-deployment.mdc body verbatim past the header" \
  diff <(tail -n +7 "$CLOUD_MDC") - <<'EOF'

# Cloud Deployment

Sandbox cloud deployment body for the cursor translator fixture.
EOF

STRUCTURE_MDC="$SRC/cursor/rules/structure-conventions.mdc"
check "structure-conventions.mdc exists" test -f "$STRUCTURE_MDC"
check "structure-conventions.mdc description matches the skill frontmatter" \
  grep -qx 'description: sandbox structure-conventions skill' "$STRUCTURE_MDC"
check "structure-conventions.mdc empty globs" grep -qx 'globs:' "$STRUCTURE_MDC"
check "structure-conventions.mdc alwaysApply false" grep -q '^alwaysApply: false$' "$STRUCTURE_MDC"
check "structure-conventions.mdc GENERATED header names the skill source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from skills/structure-conventions/SKILL\.md\.' "$STRUCTURE_MDC"
check "structure-conventions.mdc body verbatim past the header" \
  diff <(tail -n +7 "$STRUCTURE_MDC") - <<'EOF'

# Structure Conventions

the sandbox structure-conventions skill body line
EOF

# Class A always-on renderers (000-global-rules, 001-session-types,
# 002-global-memory-index). alpha-guard stays a single-registration ported
# hook; beta-check stays a single-registration unported hook (also
# unported_reasons-listed); gamma-guard is a deliberate hazard case,
# registered twice (a porting PreToolUse Bash registration and a
# non-porting ConfigChange registration) so portedness must be per-hook, not
# per-registration, resolving the verification-gate Stop/SubagentStop shape;
# delta-guard is registered under SessionStart with an empty-string matcher
# that is not itself a literal key in the map's SessionStart row, so it must
# fall back to the row's "*" wildcard rather than reading as unported.
GLOBAL_MDC="$SRC/cursor/rules/000-global-rules.mdc"
check "000-global-rules.mdc exists" test -f "$GLOBAL_MDC"
check "000-global-rules.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox global rules description for the cursor translator fixture.' "$GLOBAL_MDC"
check "000-global-rules.mdc empty globs" grep -qx 'globs:' "$GLOBAL_MDC"
check "000-global-rules.mdc alwaysApply true" grep -qx 'alwaysApply: true' "$GLOBAL_MDC"
check "000-global-rules.mdc GENERATED header names CLAUDE.md" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from CLAUDE\.md\.' "$GLOBAL_MDC"
check "000-global-rules.mdc preamble present" \
  grep -q "Sandbox cursor preamble sentence for the cursor translator fixture\." "$GLOBAL_MDC"
check "000-global-rules.mdc ported tag unchanged" grep -q '\[hook:alpha-guard\]' "$GLOBAL_MDC"
check "000-global-rules.mdc unported tag rewritten" \
  grep -q '\[hook:beta-check in Claude Code; manual in Cursor\]' "$GLOBAL_MDC"
check "000-global-rules.mdc multi-hook bracket rewrites only the unported token" \
  grep -q '\[hook:alpha-guard, hook:beta-check in Claude Code; manual in Cursor\]' "$GLOBAL_MDC"
check "000-global-rules.mdc multi-hook bracket leaves the ported token bare" \
  test -z "$(grep '\[hook:alpha-guard in Claude Code; manual in Cursor, hook:beta-check' "$GLOBAL_MDC")"
check "000-global-rules.mdc dual-registration hook (one porting, one not) counts as ported" \
  grep -q '\[hook:gamma-guard\]' "$GLOBAL_MDC"
check "000-global-rules.mdc dual-registration hook not rewritten" \
  test -z "$(grep 'hook:gamma-guard in Claude Code' "$GLOBAL_MDC")"
check "000-global-rules.mdc empty-string matcher falls back to the wildcard row" \
  grep -q '\[hook:delta-guard\]' "$GLOBAL_MDC"
check "000-global-rules.mdc empty-string matcher hook not rewritten" \
  test -z "$(grep 'hook:delta-guard in Claude Code' "$GLOBAL_MDC")"

SESSION_TYPES_MDC="$SRC/cursor/rules/001-session-types.mdc"
check "001-session-types.mdc exists" test -f "$SESSION_TYPES_MDC"
check "001-session-types.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox session types description for the cursor translator fixture.' "$SESSION_TYPES_MDC"
check "001-session-types.mdc alwaysApply true" grep -qx 'alwaysApply: true' "$SESSION_TYPES_MDC"
check "001-session-types.mdc GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from rules/session-types\.md\.' "$SESSION_TYPES_MDC"
check "001-session-types.mdc body verbatim" \
  diff <(tail -n +7 "$SESSION_TYPES_MDC") - <<'EOF'

# Session Types

Sandbox session-type classification table for the cursor translator fixture.
EOF

MEMORY_MDC="$SRC/cursor/rules/002-global-memory-index.mdc"
check "002-global-memory-index.mdc exists" test -f "$MEMORY_MDC"
check "002-global-memory-index.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox global memory index description for the cursor translator fixture.' "$MEMORY_MDC"
check "002-global-memory-index.mdc alwaysApply true" grep -qx 'alwaysApply: true' "$MEMORY_MDC"
check "002-global-memory-index.mdc GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from global-memory/INDEX\.md\.' "$MEMORY_MDC"
check "002-global-memory-index.mdc source body present" \
  grep -q "Sandbox cross-project index for the cursor translator fixture\." "$MEMORY_MDC"
check "002-global-memory-index.mdc source bullets present" \
  grep -q "feedback_sandbox_two.md" "$MEMORY_MDC"
check "002-global-memory-index.mdc trailing paragraph appended after the INDEX body" \
  grep -q "Sandbox index trailing paragraph for the cursor translator fixture\." "$MEMORY_MDC"
check "002-global-memory-index.mdc trailing paragraph comes after the source bullets" \
  test "$(grep -n 'feedback_sandbox_two.md' "$MEMORY_MDC" | cut -d: -f1)" -lt \
       "$(grep -n 'Sandbox index trailing paragraph' "$MEMORY_MDC" | cut -d: -f1)"

# Class C rulebook fan-out (rulebook-agents/audits/cost.mdc
# whole-file copies) and the reference.md section splitter
# (rulebook-reference-<slug>.mdc, one per top-level ## heading; ###
# subheadings stay nested inside their parent section, never splitting out
# on their own).
AGENTS_MDC="$SRC/cursor/rules/rulebook-agents.mdc"
check "rulebook-agents.mdc exists" test -f "$AGENTS_MDC"
check "rulebook-agents.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox rulebook agents description for the cursor translator fixture.' "$AGENTS_MDC"
check "rulebook-agents.mdc empty globs" grep -qx 'globs:' "$AGENTS_MDC"
check "rulebook-agents.mdc alwaysApply false" grep -qx 'alwaysApply: false' "$AGENTS_MDC"
check "rulebook-agents.mdc GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from rulebook/agents\.md\.' "$AGENTS_MDC"
check "rulebook-agents.mdc Source line names the section" \
  grep -qx 'Source: `~/.claude/rulebook/agents.md`, section "Agents and Dispatch". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in `~/.cursor/PORT-STATUS.md`.' "$AGENTS_MDC"
check "rulebook-agents.mdc body verbatim past the boilerplate" \
  diff <(tail -n +9 "$AGENTS_MDC") - <<'EOF'

# Agents and Dispatch

Sandbox rulebook agents body for the cursor translator fixture.
EOF

AUDITS_MDC="$SRC/cursor/rules/rulebook-audits.mdc"
check "rulebook-audits.mdc exists" test -f "$AUDITS_MDC"
check "rulebook-audits.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox rulebook audits description for the cursor translator fixture.' "$AUDITS_MDC"
check "rulebook-audits.mdc GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from rulebook/audits\.md\.' "$AUDITS_MDC"
check "rulebook-audits.mdc Source line names the section" \
  grep -qx 'Source: `~/.claude/rulebook/audits.md`, section "Audits". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in `~/.cursor/PORT-STATUS.md`.' "$AUDITS_MDC"
check "rulebook-audits.mdc body present" \
  grep -q "Sandbox rulebook audits body for the cursor translator fixture\." "$AUDITS_MDC"

COST_MDC="$SRC/cursor/rules/rulebook-cost.mdc"
check "rulebook-cost.mdc exists" test -f "$COST_MDC"
check "rulebook-cost.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox rulebook cost description for the cursor translator fixture.' "$COST_MDC"
check "rulebook-cost.mdc GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from rulebook/cost\.md\.' "$COST_MDC"
check "rulebook-cost.mdc Source line names the section" \
  grep -qx 'Source: `~/.claude/rulebook/cost.md`, section "Cost, Routing, and Estimation". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in `~/.cursor/PORT-STATUS.md`.' "$COST_MDC"
check "rulebook-cost.mdc body present" \
  grep -q "Sandbox rulebook cost body for the cursor translator fixture\." "$COST_MDC"

SESSION_INIT_MDC="$SRC/cursor/rules/rulebook-reference-r0xx-session-init.mdc"
check "rulebook-reference-r0xx-session-init.mdc exists (slug preserves the rule-range prefix)" \
  test -f "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox rulebook reference session-init description for the cursor translator fixture.' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc empty globs" grep -qx 'globs:' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc alwaysApply false" grep -qx 'alwaysApply: false' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc GENERATED header names reference.md" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from rulebook/reference\.md\.' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc Source line names the section" \
  grep -qx 'Source: `~/.claude/rulebook/reference.md`, section "Session init (R-0xx)". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in `~/.cursor/PORT-STATUS.md`.' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc carries the top-level heading" \
  grep -qx '## Session init (R-0xx)' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc keeps the nested ### subheading" \
  grep -qx '### Nested detail (R-50x)' "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc keeps the nested subheading body" \
  grep -q "Sandbox nested subheading body that must stay inside the Session init file\." "$SESSION_INIT_MDC"
check "rulebook-reference-r0xx-session-init.mdc does not leak the next section" \
  test -z "$(grep 'Convention files' "$SESSION_INIT_MDC")"

CONVENTION_MDC="$SRC/cursor/rules/rulebook-reference-convention-files.mdc"
check "rulebook-reference-convention-files.mdc exists (no rule-range parenthetical, plain kebab)" \
  test -f "$CONVENTION_MDC"
check "rulebook-reference-convention-files.mdc description from rule_descriptions" \
  grep -qx 'description: Sandbox rulebook reference convention-files description for the cursor translator fixture.' "$CONVENTION_MDC"
check "rulebook-reference-convention-files.mdc Source line names the section" \
  grep -qx 'Source: `~/.claude/rulebook/reference.md`, section "Convention files". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in `~/.cursor/PORT-STATUS.md`.' "$CONVENTION_MDC"
check "rulebook-reference-convention-files.mdc carries the top-level heading" \
  grep -qx '## Convention files' "$CONVENTION_MDC"
check "rulebook-reference-convention-files.mdc does not carry the other section's nested subheading" \
  test -z "$(grep 'Nested detail' "$CONVENTION_MDC")"

check "no separate file is produced for the nested ### subheading" \
  test ! -e "$SRC/cursor/rules/rulebook-reference-r50x-nested-detail.mdc"

# agents_to_subagents agents/commands and the full skills/ copy.
# audit-sample matches the "audit-*" glob and carries Write in its tools
# list, so it exercises the agent+command render with readonly: false;
# spec-conformance-review matches the port map's exact-name entry (not the
# glob) and carries neither Write nor Edit, exercising readonly: true;
# helper-role matches neither pattern and must be absent from both
# cursor/agents/ and cursor/commands/.
AUDIT_AGENT="$SRC/cursor/agents/audit-sample.md"
AUDIT_COMMAND="$SRC/cursor/commands/audit-sample.md"
check "audit-sample.md agent exists" test -f "$AUDIT_AGENT"
check "audit-sample.md agent name verbatim" grep -qx 'name: audit-sample' "$AUDIT_AGENT"
check "audit-sample.md agent description verbatim" \
  grep -qx 'description: Sandbox audit agent used by the cursor translator fixture.' "$AUDIT_AGENT"
check "audit-sample.md agent model always inherit" grep -qx 'model: inherit' "$AUDIT_AGENT"
check "audit-sample.md agent readonly false (tools carries Write)" grep -qx 'readonly: false' "$AUDIT_AGENT"
check "audit-sample.md agent drops the tools field entirely" test -z "$(grep '^tools:' "$AUDIT_AGENT")"
check "audit-sample.md agent GENERATED header names the source" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from agents/audit-sample\.md\.' "$AUDIT_AGENT"
check "audit-sample.md agent body verbatim past the header" \
  diff <(tail -n +9 "$AUDIT_AGENT") - <<'EOF'
# Audit Sample

Sandbox audit agent body used by the cursor translator fixture tests.
EOF

check "audit-sample.md command exists" test -f "$AUDIT_COMMAND"
check "audit-sample.md command carries no YAML frontmatter" \
  test "$(head -n1 "$AUDIT_COMMAND")" != "---"
check "audit-sample.md command GENERATED header is line 1" \
  grep -qx '^<!-- GENERATED by translate/cursor\.mjs from agents/audit-sample\.md\. Do not edit; change the source and run: node translate/cursor\.mjs --write -->$' \
  <(head -n1 "$AUDIT_COMMAND")
check "audit-sample.md command opening paragraph is the source description" \
  grep -qx 'Sandbox audit agent used by the cursor translator fixture.' "$AUDIT_COMMAND"
check "audit-sample.md command carries the delegate boilerplate with the right name" \
  grep -qx 'Delegate this to the `audit-sample` subagent. If subagents are unavailable in this build, read `~/.claude/agents/audit-sample.md` and carry out that role definition in this conversation, honoring its model-routing and output-discipline sections.' "$AUDIT_COMMAND"

SPEC_AGENT="$SRC/cursor/agents/spec-conformance-review.md"
check "spec-conformance-review.md agent exists (exact-name agents_to_subagents match)" test -f "$SPEC_AGENT"
check "spec-conformance-review.md agent model always inherit" grep -qx 'model: inherit' "$SPEC_AGENT"
check "spec-conformance-review.md agent readonly true (tools carries neither Write nor Edit)" \
  grep -qx 'readonly: true' "$SPEC_AGENT"
check "spec-conformance-review.md agent drops the tools field entirely" test -z "$(grep '^tools:' "$SPEC_AGENT")"
check "spec-conformance-review.md command exists" \
  test -f "$SRC/cursor/commands/spec-conformance-review.md"

check "non-matching agent (helper-role) absent from cursor/agents/" \
  test ! -e "$SRC/cursor/agents/helper-role.md"
check "non-matching agent (helper-role) absent from cursor/commands/" \
  test ! -e "$SRC/cursor/commands/helper-role.md"

STRUCTURE_SKILL="$SRC/cursor/skills/structure-conventions/SKILL.md"
check "structure-conventions skill copy exists (one-to-one, alongside its own Class D rule)" \
  test -f "$STRUCTURE_SKILL"
check "structure-conventions skill copy frontmatter verbatim" \
  grep -qx 'description: sandbox structure-conventions skill' "$STRUCTURE_SKILL"
check "structure-conventions skill copy GENERATED header lands right after the frontmatter" \
  test "$(sed -n '5p' "$STRUCTURE_SKILL")" = \
  '<!-- GENERATED by translate/cursor.mjs from skills/structure-conventions/SKILL.md. Do not edit; change the source and run: node translate/cursor.mjs --write -->'
check "structure-conventions skill copy body verbatim past the header" \
  diff <(tail -n +7 "$STRUCTURE_SKILL") - <<'EOF'
# Structure Conventions

the sandbox structure-conventions skill body line
EOF

# commands/session-start.md and commands/session-handoff.md are
# hand-authored per the port map; the agent/command renderers never emit them
# (neither source agent exists), so --write must leave them exactly as the
# stub hand-authored content, with no GENERATED header, while the
# hand-authored existence check above still finds them on disk.
check "session-start.md carries no GENERATED header (never planned by a renderer)" \
  test -z "$(grep 'GENERATED by' "$SRC/cursor/commands/session-start.md")"
check "session-handoff.md carries no GENERATED header (never planned by a renderer)" \
  test -z "$(grep 'GENERATED by' "$SRC/cursor/commands/session-handoff.md")"
check "session-start.md still passes the hand-authored existence check" \
  test -f "$SRC/cursor/commands/session-start.md"
check "session-handoff.md still passes the hand-authored existence check" \
  test -f "$SRC/cursor/commands/session-handoff.md"

# Review round 1 (Important): planned-path collision guard, ported from
# codex.mjs's established Set-based pattern into exporter-core's shared
# claimPlannedPath (one Set spanning the whole cursor tree, not one Set per
# file type, per the review's ruling). Two claude/agents files sharing one
# frontmatter name would otherwise both plan to write
# cursor/agents/audit-sample.md, and writePlannedTreeCore's plain
# fs.writeFileSync would silently let whichever renders second win. A brand
# new sandbox (not the shared $SRC, which cursor/ output from earlier
# passing cases already populated): a collision aborts rendering entirely
# and writes nothing, so reusing $SRC would leave its last known-good
# cursor/agents/audit-sample.md on disk from an earlier successful write,
# making a "write touches nothing" check meaningless.
SRC_DUP=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC_DUP"' EXIT
make_cursor_source_tree "$SRC_DUP"
cat >"$SRC_DUP/claude/agents/audit-sample-duplicate.md" <<'EOF'
---
name: audit-sample
description: Duplicate-named sandbox agent for the cursor translator collision-guard fixture.
tools: Read
model: sonnet
---

# Audit Sample Duplicate

Deliberately duplicate-named agent source for the cursor translator fixture.
EOF
OUT=$(node "$TRANSLATOR" --check --root "$SRC_DUP" 2>&1); ST=$?
check "duplicate agent name fails check" test "$ST" -eq 2
check "duplicate agent name names one offending file (check mode)" \
  grep -qE "audit-sample(-duplicate)?\.md" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC_DUP" 2>&1); ST=$?
check "duplicate agent name fails write too" test "$ST" -eq 2
check "duplicate agent name names one offending file (write mode)" \
  grep -qE "audit-sample(-duplicate)?\.md" <<<"$OUT"
check "duplicate agent name write touches nothing" test ! -e "$SRC_DUP/cursor/agents/audit-sample.md"

# Review round 1 (Minor fold-in): a tools token that merely starts with
# "Write" (WriteFoo) must not read as the real Write tool; hasWriteOrEditTool
# matches whole comma-separated tokens only, so this agent (tools: WriteFoo,
# Read, neither Write nor Edit present) must still render readonly: true.
# Its own fresh sandbox too, so a stray file from the collision case above
# can never leak in and make this write fail for an unrelated reason.
SRC_WRITEFOO=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC_DUP" "$SRC_WRITEFOO"' EXIT
make_cursor_source_tree "$SRC_WRITEFOO"
cat >"$SRC_WRITEFOO/claude/agents/audit-writefoo.md" <<'EOF'
---
name: audit-writefoo
description: Sandbox agent with a Write-prefixed but distinct tool token.
tools: WriteFoo, Read
model: sonnet
---

# Audit WriteFoo

Sandbox agent body proving a WriteFoo tool token is not read as Write.
EOF
node "$TRANSLATOR" --write --root "$SRC_WRITEFOO" >/dev/null 2>&1
WRITEFOO_AGENT="$SRC_WRITEFOO/cursor/agents/audit-writefoo.md"
check "WriteFoo tool token does not count as Write: agent renders readonly true" \
  grep -qx 'readonly: true' "$WRITEFOO_AGENT"

# hooks.json's many-to-many fan-out and PORT-STATUS.md's derived
# summary. The sandbox's events map (updated above) fans PreToolUse
# Bash to TWO Cursor events (beforeShellExecution, preToolUse), so both
# alpha-guard and gamma-guard (the PreToolUse Bash matcher group registered
# second, per the Class A fixture above) appear under BOTH entries, in that order:
# this is simultaneously the "one hook fans to two Cursor events" case and
# the "two matcher groups feeding one Cursor event in the documented order"
# aggregation-order case. beta-check (ConfigChange) stays unported and
# absent from hooks.json; gamma-guard's own ConfigChange registration is
# unported too, but carries no unported_reasons entry, so its PORT-STATUS
# row exercises the generic no-equivalent fallback text. delta-guard
# (SessionStart, empty-string matcher falling back to "*") is the lone
# single-event ported row. beforeReadFile is adapter-internal: no
# settings.json registration reaches it, so it gets an entry with zero
# hook names. Known sandbox counts: 5 registrations total (alpha, gamma x2,
# beta, delta), 3 port (alpha, gamma's PreToolUse row, delta), across 4
# Cursor events (beforeShellExecution, preToolUse, sessionStart,
# beforeReadFile).
HOOKS_JSON="$SRC/cursor/hooks.json"
check "hooks.json exists" test -f "$HOOKS_JSON"
check "hooks.json is valid JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOOKS_JSON"
check "hooks.json top-level version is 1" \
  test "$(python3 -c "import json; print(json.load(open('$HOOKS_JSON'))['version'])")" = "1"

BEFORE_SHELL_CMD=$(python3 -c "import json; print(json.load(open('$HOOKS_JSON'))['hooks']['beforeShellExecution'][0]['command'])")
check "beforeShellExecution invokes the adapter with the event name" \
  grep -q '^~/.cursor/hooks/claude-hook-adapter.sh beforeShellExecution ' <<<"$BEFORE_SHELL_CMD"
check "beforeShellExecution aggregates alpha-guard then gamma-guard (settings order)" \
  test "$BEFORE_SHELL_CMD" = "~/.cursor/hooks/claude-hook-adapter.sh beforeShellExecution alpha-guard gamma-guard"

PRE_TOOL_USE_CMD=$(python3 -c "import json; print(json.load(open('$HOOKS_JSON'))['hooks']['preToolUse'][0]['command'])")
check "alpha-guard (PreToolUse/Bash) fans into preToolUse too (dual-event hook)" \
  test "$PRE_TOOL_USE_CMD" = "~/.cursor/hooks/claude-hook-adapter.sh preToolUse alpha-guard gamma-guard"

SESSION_START_CMD=$(python3 -c "import json; print(json.load(open('$HOOKS_JSON'))['hooks']['sessionStart'][0]['command'])")
check "delta-guard's empty-string matcher still fans into sessionStart" \
  test "$SESSION_START_CMD" = "~/.cursor/hooks/claude-hook-adapter.sh sessionStart delta-guard"

BEFORE_READ_CMD=$(python3 -c "import json; print(json.load(open('$HOOKS_JSON'))['hooks']['beforeReadFile'][0]['command'])")
check "beforeReadFile (adapter-internal) carries zero hook names" \
  test "$BEFORE_READ_CMD" = "~/.cursor/hooks/claude-hook-adapter.sh beforeReadFile"

check "beta-check (unported) never appears anywhere in hooks.json" \
  test -z "$(grep -o 'beta-check' "$HOOKS_JSON")"
check "hooks.json carries no ConfigChange entry (beta-check's only registration, unported)" \
  python3 -c "import json,sys; sys.exit(1 if 'ConfigChange' in json.load(open(sys.argv[1]))['hooks'] else 0)" "$HOOKS_JSON"

PORT_STATUS="$SRC/cursor/PORT-STATUS.md"
check "PORT-STATUS.md exists" test -f "$PORT_STATUS"
check "PORT-STATUS.md GENERATED header names settings.json" \
  grep -q '^<!-- GENERATED by translate/cursor\.mjs from settings\.json\.' "$PORT_STATUS"
check "PORT-STATUS.md heading" grep -qx '# Cursor port status' "$PORT_STATUS"
check "PORT-STATUS.md derived summary line (3 of 5 registrations, across 4 Cursor events)" \
  grep -qx '3 of 5 hook registrations port, across 4 Cursor events.' "$PORT_STATUS"
check "PORT-STATUS.md dual-event row names both Cursor events for alpha-guard" \
  grep -qx '| `alpha-guard` | PreToolUse (Bash) | ported: `beforeShellExecution`, `preToolUse` |' "$PORT_STATUS"
check "PORT-STATUS.md gamma-guard's PreToolUse row also names both events" \
  grep -qx '| `gamma-guard` | PreToolUse (Bash) | ported: `beforeShellExecution`, `preToolUse` |' "$PORT_STATUS"
check "PORT-STATUS.md beta-check row uses its unported_reasons text" \
  grep -qx '| `beta-check` | ConfigChange (user_settings) | not ported: ConfigChange is a Claude Code event; sandbox stub reason. |' "$PORT_STATUS"
check "PORT-STATUS.md gamma-guard's ConfigChange row falls back to the generic no-equivalent text" \
  grep -qx '| `gamma-guard` | ConfigChange (user_settings) | not ported: the ConfigChange event has no Cursor equivalent. |' "$PORT_STATUS"
check "PORT-STATUS.md delta-guard row (empty-string matcher, bare event name, no parenthetical)" \
  grep -qx '| `delta-guard` | SessionStart | ported: `sessionStart` |' "$PORT_STATUS"
check "PORT-STATUS.md carries no beforeReadFile row (adapter-internal, not a settings.json registration)" \
  test -z "$(grep 'beforeReadFile' "$PORT_STATUS")"
check "PORT-STATUS.md appendix appears verbatim after the table" \
  grep -q 'Sandbox stub appendix line for the cursor translator fixture\.' "$PORT_STATUS"
check "PORT-STATUS.md appendix comes after the table's last row" \
  test "$(grep -n 'delta-guard' "$PORT_STATUS" | cut -d: -f1)" -lt \
       "$(grep -n 'Sandbox stub appendix line' "$PORT_STATUS" | cut -d: -f1)"
check "PORT-STATUS.md appendix heading present" grep -qx '## Permission rules' "$PORT_STATUS"

# Manifest B-9 classes, derived .gitignore, orphans, and --check parity.
# Continues directly from the hooks/PORT-STATUS $SRC state above:
# untouched since the "clean tree write" pass (line ~422 above), so it is
# still an exact --write of the current make_cursor_source_tree() shape.

# add_cursor_settings_hook <dir> <hook-name> <event> [matcher]: appends a
# new hook group registering <hook-name> under <event> (matcher "*" unless
# overridden) in the sandbox's settings.json. Used below for registrations
# the base fixture's minimal hook set does not cover.
add_cursor_settings_hook() {
  local dir="$1" name="$2" event="$3" matcher="${4-*}"
  python3 - "$dir/claude/settings.json" "$name" "$event" "$matcher" <<'PY'
import json, sys
path, name, event, matcher = sys.argv[1:5]
with open(path) as f:
    data = json.load(f)
data.setdefault("hooks", {}).setdefault(event, [])
data["hooks"][event].append({"matcher": matcher, "hooks": [{"type": "command", "command": f"~/.claude/hooks/{name}.sh"}]})
with open(path, "w") as f:
    json.dump(data, f)
PY
}

# Manifest: every planned path is classified "generated"; every
# hand-authored path carries the port map's own B-9 class value (not a
# forced single value the way codex's flat hand_authored array would);
# hand_authored is still the flat compat array too, insertion order
# preserved from the port map's own key order.
MANIFEST="$SRC/cursor/.claude-port.json"
check "manifest exists" test -f "$MANIFEST"
check "manifest is valid JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MANIFEST"
manifestBuilderNamesTranslator() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['builder'] == 'translate/cursor.mjs' else 1)
"; }
check "manifest names the builder" manifestBuilderNamesTranslator
manifestOmitsItself() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(1 if '.claude-port.json' in d['files'] else 0)
"; }
check "manifest does not hash itself" manifestOmitsItself
manifestClassifiesGeneratedFile() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['classes'].get('hooks.json') == 'generated' else 1)
"; }
check "manifest classifies a generated file 'generated'" manifestClassifiesGeneratedFile
manifestClassifiesGitignoreGenerated() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['classes'].get('.gitignore') == 'generated' else 1)
"; }
check "manifest classifies .gitignore itself 'generated'" manifestClassifiesGitignoreGenerated
manifestHashesGitignore() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['files'].get('.gitignore', '').startswith('sha256:') else 1)
"; }
check "manifest hashes .gitignore like any other generated file" manifestHashesGitignore
manifestClassifiesHandAuthoredLocal() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['classes'].get('README.md') == 'hand-authored-local' else 1)
"; }
check "manifest classifies README.md hand-authored-local from the map" manifestClassifiesHandAuthoredLocal
manifestClassifiesHandAuthoredMapped() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(0 if d['classes'].get('hooks/claude-hook-adapter.sh') == 'hand-authored-mapped' else 1)
"; }
check "manifest classifies the adapter hand-authored-mapped from the map" manifestClassifiesHandAuthoredMapped
manifestFilesOmitsHandAuthored() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
exit(1 if 'README.md' in d['files'] else 0)
"; }
check "manifest files map omits hand-authored paths" manifestFilesOmitsHandAuthored
manifestHandAuthoredArrayCompat() { python3 -c "
import json
d = json.load(open('$MANIFEST'))
expected = ['README.md', 'hooks/claude-hook-adapter.sh', 'commands/session-start.md', 'commands/session-handoff.md']
exit(0 if d['hand_authored'] == expected else 1)
"; }
check "manifest hand_authored compat array preserves port map insertion order" manifestHandAuthoredArrayCompat

# A hand_authored port-map entry naming a path a renderer also plans to
# generate is a self-contradictory manifest, not a valid configuration
# (review M-2): before this guard, buildManifestClassifications let the
# hand-authored class silently overwrite the "generated" one, so the
# manifest simultaneously hashed the file as generated content and listed
# it as hand-authored, findOrphanFiles exempted it from orphan detection,
# and --write kept overwriting it on every run while the manifest told a
# reader it was human-owned, all while --check stayed green throughout.
# PORT-STATUS.md is both a real generated path (renderCursorPortStatus)
# and, once added here, a port-map hand_authored entry, so this reproduces
# the exact collision the review found rather than a synthetic one.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["hand_authored"]["PORT-STATUS.md"] = "hand-authored-local"
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "hand_authored/generated collision exits 2" test "$ST" -eq 2
check "hand_authored/generated collision names the colliding path" \
  grep -q "PORT-STATUS.md" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1); ST=$?
check "hand_authored/generated collision exits 2 (write mode)" test "$ST" -eq 2
# Restore a clean, current $SRC/cursor tree: the corrupted port map above
# never let --write reach the filesystem, so the sections below (which
# assume the "clean tree write" pass's output is still on disk, line ~422)
# need a fresh source tree and a real write, not just a port-map reset.
make_cursor_source_tree "$SRC"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# Derived .gitignore: ignore-all then one `!` allowlist line per expected
# path, mirroring the real file's shape (cursor-shapes-study section 6
# ruling: .gitignore is generated, not hand-authored). A directory needs its
# own `!/dir/` line before git will even look for the files inside it.
GITIGNORE="$SRC/cursor/.gitignore"
check "gitignore exists" test -f "$GITIGNORE"
check "gitignore ignores everything by default" grep -qx '\*' "$GITIGNORE"
check "gitignore allowlists itself (generated)" grep -qx '!/.gitignore' "$GITIGNORE"
check "gitignore allowlists the manifest" grep -qx '!/.claude-port.json' "$GITIGNORE"
check "gitignore allowlists a top-level generated file" grep -qx '!/hooks.json' "$GITIGNORE"
check "gitignore allowlists a nested generated file's ancestor directory" grep -qx '!/rules/' "$GITIGNORE"
check "gitignore allowlists the nested generated file itself" grep -qx '!/rules/backend.mdc' "$GITIGNORE"
check "gitignore allowlists a doubly-nested generated file's two ancestor directories" \
  grep -qx '!/commands/' "$GITIGNORE"
check "gitignore allowlists hand-authored files too" grep -qx '!/README.md' "$GITIGNORE"
check "gitignore allowlists the hand-authored adapter" grep -qx '!/hooks/claude-hook-adapter.sh' "$GITIGNORE"
check "gitignore's directory line for a path precedes its files' lines" \
  test "$(grep -n '^!/rules/$' "$GITIGNORE" | cut -d: -f1)" -lt \
       "$(grep -n '^!/rules/backend\.mdc$' "$GITIGNORE" | cut -d: -f1)"

# Fixture: adding a new sandbox generated file adds its own `!` line. The
# added agent matches the base fixture's "audit-*" agents_to_subagents
# pattern, so it renders both an agent and a command.
cat >"$SRC/claude/agents/audit-newcheck.md" <<'EOF'
---
name: audit-newcheck
description: Sandbox additional audit agent for the cursor gitignore fixture.
tools: Read
model: sonnet
---

# Audit Newcheck

Sandbox additional audit agent body for the cursor gitignore fixture.
EOF
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
check "gitignore gains a line for a newly added generated agent" \
  grep -qx '!/agents/audit-newcheck.md' "$GITIGNORE"
check "gitignore gains a line for the newly added agent's command" \
  grep -qx '!/commands/audit-newcheck.md' "$GITIGNORE"
rm "$SRC/claude/agents/audit-newcheck.md"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# --check parity: staleness, never mutates.
node "$TRANSLATOR" --check --root "$SRC"; check "check clean after write" test $? -eq 0
printf '%s\n' "R-999: New sandbox rule. [manual]" >>"$SRC/claude/CLAUDE.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "check catches staleness" test "$ST" -eq 1
check "stale file named" grep -q "stale: rules/000-global-rules.mdc" <<<"$OUT"
TASK8_SNAP_BEFORE=$(cd "$SRC/cursor" && find . -type f -exec shasum {} + | sort)
node "$TRANSLATOR" --check --root "$SRC" >/dev/null 2>&1
TASK8_SNAP_AFTER=$(cd "$SRC/cursor" && find . -type f -exec shasum {} + | sort)
check "check never mutates" test "$TASK8_SNAP_BEFORE" = "$TASK8_SNAP_AFTER"
make_cursor_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# --check parity: unclassified-hook closure. epsilon-guard registers under a
# novel event absent from the port map's events entirely (unlike
# ConfigChange, which is present with an explicit empty fan-out), so it
# exercises the classification gap --check exists to catch.
add_cursor_settings_hook "$SRC" "epsilon-guard" "FutureEvent"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "unclassified hook fails check" test "$ST" -eq 1
check "unclassified hook named" grep -q "unclassified hook: epsilon-guard" <<<"$OUT"
make_cursor_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# --check parity: missing hand-authored file fails check; its content is
# never diffed once it exists again (only existence is checked).
rm "$SRC/cursor/hooks/claude-hook-adapter.sh"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing hand-authored fails check" test "$ST" -eq 1
check "missing hand-authored named" grep -q "missing hand-authored file: hooks/claude-hook-adapter.sh" <<<"$OUT"
printf '%s\n' "locally customized" >"$SRC/cursor/hooks/claude-hook-adapter.sh"
node "$TRANSLATOR" --check --root "$SRC"; check "hand-authored content never diffed" test $? -eq 0
make_cursor_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# --check parity: a retired unported_reasons entry (naming no hook
# settings.json still registers) warns but does not fail an otherwise-clean
# check.
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["unported_reasons"]["retired-hook"] = "no longer registered; kept for history."
with open(path, "w") as f:
    json.dump(data, f)
PY
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "retired hook warns but stays clean" test "$ST" -eq 0
check "retired hook warning named" grep -q "warning: port map names retired hook retired-hook" <<<"$OUT"
make_cursor_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# Orphaned generated file detection and removal: --write deletes it,
# --write never deletes a hand-authored path even though it too sits on
# disk outside the planned set.
printf 'stale rule\n' >"$SRC/cursor/rules/stale-rule.mdc"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "orphan fails check" test "$ST" -eq 1
check "orphan named" grep -q "orphaned: rules/stale-rule.mdc" <<<"$OUT"
check "hand-authored path never flagged as orphan" \
  test -z "$(grep 'orphaned: hooks/claude-hook-adapter.sh' <<<"$OUT")"
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1); ST=$?
check "write removes orphan" test ! -e "$SRC/cursor/rules/stale-rule.mdc"
check "write summary reports removal count" grep -q "wrote .* files, removed 1 orphans" <<<"$OUT"

# PR #13 review: the generated .gitignore promised that tool-dropped state
# under cursor/ survives, while the orphan sweep deleted every unplanned
# file. The B-9 class runtime-only-ignored now reaches the sweep: a declared
# path (or directory, trailing slash) is neither flagged by --check nor
# deleted by --write, and an undeclared stray is still an orphan.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["hand_authored"][".cursor-cache/"] = "runtime-only-ignored"
data["hand_authored"]["local-state.json"] = "runtime-only-ignored"
with open(path, "w") as f:
    json.dump(data, f)
PY
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
mkdir -p "$SRC/cursor/.cursor-cache/sub"
printf 'cache\n' >"$SRC/cursor/.cursor-cache/sub/blob.bin"
printf '{}\n' >"$SRC/cursor/local-state.json"
printf 'undeclared\n' >"$SRC/cursor/scratch-note.txt"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "runtime-only-ignored directory is not flagged" \
  test -z "$(grep 'orphaned: .cursor-cache' <<<"$OUT")"
check "runtime-only-ignored file is not flagged" \
  test -z "$(grep 'orphaned: local-state.json' <<<"$OUT")"
check "undeclared stray is still an orphan" grep -q "orphaned: scratch-note.txt" <<<"$OUT"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
check "write keeps the runtime-only-ignored directory" test -e "$SRC/cursor/.cursor-cache/sub/blob.bin"
check "write keeps the runtime-only-ignored file" test -e "$SRC/cursor/local-state.json"
check "write still deletes the undeclared stray" test ! -e "$SRC/cursor/scratch-note.txt"
GITIGNORE_BODY=$(cat "$SRC/cursor/.gitignore")
check "gitignore does not name runtime-only-ignored paths in the allowlist" \
  test -z "$(grep '^!local-state.json' <<<"$GITIGNORE_BODY")"
check "gitignore header states the orphan sweep" \
  grep -q "runtime-only-ignored" <<<"$GITIGNORE_BODY"

# PR #13 review: Class A descriptions were an unchecked lookup, so a removed
# fixed key rendered the literal "undefined" into an always-on rule file.
make_cursor_source_tree "$SRC"
python3 - "$SRC/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
del data["rule_descriptions"]["000-global-rules.mdc"]
with open(path, "w") as f:
    json.dump(data, f)
PY
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing Class A description exits 2" test "$ST" -eq 2
check "missing Class A description names the key" \
  grep -q "rule_descriptions missing entry for 000-global-rules.mdc" <<<"$OUT"
make_cursor_source_tree "$SRC"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
node "$TRANSLATOR" --check --root "$SRC"; check "check clean after orphan removed" test $? -eq 0
OUT=$(node "$TRANSLATOR" --write --root "$SRC" 2>&1)
check "write summary omits removed clause when clean" test -z "$(grep 'removed' <<<"$OUT")"

# Invariant: double --write is byte-identical (determinism).
TASK8_SNAP_D1=$(cd "$SRC/cursor" && find . -type f -exec shasum {} + | sort)
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
TASK8_SNAP_D2=$(cd "$SRC/cursor" && find . -type f -exec shasum {} + | sort)
check "double write is deterministic" test "$TASK8_SNAP_D1" = "$TASK8_SNAP_D2"

# Carried map cleanup #4: verification-gate's unported_reasons entry is now
# an object keyed by Claude Code event, not a plain string, so its Stop
# registration must still render "ported" while its SubagentStop
# registration gets a specific reason (rather than the generic "no Cursor
# equivalent" fallback, and rather than the whole-hook veto a plain-string
# entry would apply, which would wrongly mark the Stop row unported too).
# task-commit-reminder stays the ordinary whole-hook-veto (plain string)
# case, its only registration never porting, but still needs its own
# specific reason instead of the generic fallback. Neither hook fits the
# base fixture's minimal event set (Stop/SubagentStop/PostToolUse are not
# registered there), so this runs in its own sandbox.
SRC6=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC_DUP" "$SRC_WRITEFOO" "$SRC6"' EXIT
make_cursor_source_tree "$SRC6"
printf '\nR-999: Verification gate sandbox check. [hook:verification-gate]\n' >>"$SRC6/claude/CLAUDE.md"
add_cursor_settings_hook "$SRC6" "verification-gate" "Stop" ""
add_cursor_settings_hook "$SRC6" "verification-gate" "SubagentStop" ""
add_cursor_settings_hook "$SRC6" "task-commit-reminder" "PostToolUse" "TaskUpdate"
python3 - "$SRC6/translate/cursor-port-map.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["events"]["Stop"] = {"*": ["stop"]}
data["events"]["SubagentStop"] = {"*": []}
data["events"]["PostToolUse"] = {}
data["unported_reasons"]["verification-gate"] = {
    "SubagentStop": "Sandbox SubagentStop-specific reason for the cursor translator fixture; the Stop registration of this hook ports.",
}
data["unported_reasons"]["task-commit-reminder"] = \
    "Sandbox task-commit-reminder reason for the cursor translator fixture; fires on a Claude Code-only tool event."
with open(path, "w") as f:
    json.dump(data, f)
PY
node "$TRANSLATOR" --write --root "$SRC6" >/dev/null 2>&1
PORT_STATUS6="$SRC6/cursor/PORT-STATUS.md"
check "verification-gate Stop row still shows ported (object reason carries no whole-hook veto)" \
  grep -qx '| `verification-gate` | Stop | ported: `stop` |' "$PORT_STATUS6"
check "verification-gate SubagentStop row shows its own event-scoped reason" \
  grep -qx '| `verification-gate` | SubagentStop | not ported: Sandbox SubagentStop-specific reason for the cursor translator fixture; the Stop registration of this hook ports. |' "$PORT_STATUS6"
check "task-commit-reminder row shows its own reason, not the generic fallback" \
  grep -qx '| `task-commit-reminder` | PostToolUse (TaskUpdate) | not ported: Sandbox task-commit-reminder reason for the cursor translator fixture; fires on a Claude Code-only tool event. |' "$PORT_STATUS6"
GLOBAL_MDC6="$SRC6/cursor/rules/000-global-rules.mdc"
check "verification-gate's rule tag stays unrewritten (still counts as ported overall)" \
  grep -q '\[hook:verification-gate\]' "$GLOBAL_MDC6"
check "verification-gate's rule tag is not given the Cursor-manual caveat" \
  test -z "$(grep 'hook:verification-gate in Claude Code' "$GLOBAL_MDC6")"
node "$TRANSLATOR" --check --root "$SRC6"; check "SRC6 check stays clean after write" test $? -eq 0

# Review round 1 (Important): findUnclassifiedHookNames must scope its
# exemption per REGISTRATION, not per hook name. Reproduces the reviewer's
# probe exactly: verification-gate gains a THIRD registration, under a
# novel event (PreCompact) absent from the port map's events object
# entirely. Its unported_reasons entry is an object scoped only to
# "SubagentStop", so this PreCompact registration is covered by neither a
# whole-hook veto (hasWholeHookVeto is false for an object entry) nor a
# per-event reason (unportedReasonFor("verification-gate", "PreCompact",
# ...) is undefined: the object only names "SubagentStop"). A closure check
# gated on bare `name in unported_reasons` would silently exempt this
# registration just because the hook's name happens to appear there for an
# unrelated event; the fixed check must still catch it. task-commit-
# reminder gets the same new-event registration too, but its
# unported_reasons entry is a plain string (a real whole-hook veto), so it
# must stay exempt under any event.
add_cursor_settings_hook "$SRC6" "verification-gate" "PreCompact" ""
add_cursor_settings_hook "$SRC6" "task-commit-reminder" "PreCompact" ""
# --write first, so the two new settings.json registrations stop being an
# incidental source of "stale: hooks.json" / "stale: PORT-STATUS.md" /
# "stale: .claude-port.json" noise; --write itself performs no hook-
# classification check (only --check does), so it succeeds regardless of
# the closure gap under test, leaving the follow-up --check's output
# attributable to the closure check alone.
node "$TRANSLATOR" --write --root "$SRC6" >/dev/null 2>&1
OUT=$(node "$TRANSLATOR" --check --root "$SRC6" 2>&1); ST=$?
check "closure check fails on an object-reason hook's uncovered registration" test "$ST" -eq 1
check "unclassified hook names verification-gate for its PreCompact registration" \
  grep -q "unclassified hook: verification-gate" <<<"$OUT"
check "closure check still exempts a whole-hook string-veto hook under the same novel event" \
  test -z "$(grep 'unclassified hook: task-commit-reminder' <<<"$OUT")"
check "closure check output is exactly the one expected line (no other registration flagged)" \
  test "$OUT" = "unclassified hook: verification-gate (PreCompact)"

[ "$fail" -eq 0 ] && echo "translate-cursor.test.sh PASS" || exit 1
