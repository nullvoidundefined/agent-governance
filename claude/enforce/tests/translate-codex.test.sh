#!/usr/bin/env bash
# Verifies translate/codex.mjs: the codex port generator (spec
# 2026-09-17-codex-translator-design.md). Hermetic: builds a miniature
# claude/ source tree in a sandbox and never reads the real trees, so the
# fixture survives repo moves (2026-09-17 lesson). Grows one section per
# acceptance criterion B-1..B-11.
set -uo pipefail
REPO_TOP=$(git rev-parse --show-toplevel)
TRANSLATOR="$REPO_TOP/translate/codex.mjs"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
# not <cmd...>: negates a command's exit status. A bare "!" loses its
# reserved-word status once it travels through check()'s "$@" expansion, so
# negated checks route through this wrapper instead.
not() { ! "$@"; }
# tomlHeaderNamesTranslator <file>: a pipeline can't be a single check()
# argument list; "check ... | grep -q" would pipe check()'s own PASS/FAIL
# line into grep -q and silently swallow it, so the check never registers.
# Wrapping the pipeline in a function keeps it inside one check() argument.
tomlHeaderNamesTranslator() { head -1 "$1" | grep -q "translate/codex.mjs"; }
# skillHeaderAfterFrontmatter <file>: same pipe-in-a-function fix as
# tomlHeaderNamesTranslator above, for the line right after the skill copy's
# closing frontmatter "---".
skillHeaderAfterFrontmatter() { awk 'NR>1 && /^---$/ {getline; print; exit}' "$1" | grep -q "translate/codex.mjs"; }
# The hooks.json checks below need jq's own stdout suppressed with
# >/dev/null; putting that redirect on the check() invocation line instead
# would silence check()'s own PASS/FAIL echo (same pipe-in-a-function trap
# as above), so each jq call gets its own wrapper function.
portedHookListed() { jq -e '.hooks.PreToolUse[0].hooks[0].command | test("alpha-guard")' "$HJ" >/dev/null; }
statusMessageCarried() { jq -e '.hooks.PreToolUse[0].hooks[0].statusMessage == "Running alpha guard"' "$HJ" >/dev/null; }
timeoutCarried() { jq -e '.hooks.PreToolUse[0].hooks[0].timeout == 30' "$HJ" >/dev/null; }
matcherCarried() { jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$HJ" >/dev/null; }
descriptionNamesTranslator() { jq -e '.description | test("translate/codex.mjs")' "$HJ" >/dev/null; }
noEmptyConfigChangeGroup() { jq -e '.hooks | has("ConfigChange") | not' "$HJ" >/dev/null; }
hooksJsonEndsWithNewline() { [ "$(tail -c1 "$HJ" | wc -l)" -eq 1 ]; }

# make_source_tree <dir>: builds a miniature claude/-plus-translate/ source
# tree in <dir> (a repo-shaped --root), reused by every later task section.
# Ported hook: alpha-guard (PreToolUse, in the map's events). Unported hook:
# beta-check (ConfigChange, which the map's events translate to null). Also
# writes stub hand-authored codex/ files so later existence checks pass.
make_source_tree() {
  local dir="$1"
  mkdir -p "$dir/claude/agents" "$dir/claude/skills/sample-skill" "$dir/claude/rules"
  mkdir -p "$dir/translate"
  mkdir -p "$dir/codex/hooks" "$dir/codex/skills/session-start" "$dir/codex/skills/session-handoff"

  cat >"$dir/claude/CLAUDE.md" <<'EOF'
# Sandbox Rules

R-501: Run the alpha guard before any risky write. [hook:alpha-guard]
R-502: Run the beta check before any config change. [hook:beta-check]
EOF

  cat >"$dir/claude/rules/session-types.md" <<'EOF'
# Session Types

Sandbox session-type classification table for the codex translator fixture.
EOF

  cat >"$dir/claude/agents/audit-sample.md" <<'EOF'
---
name: audit-sample
description: Sandbox audit agent used by the codex translator fixture.
tools: Read, Grep
model: sonnet
---

# Audit Sample

Sandbox audit agent body used by the codex translator fixture tests.
EOF

  cat >"$dir/claude/agents/helper-role.md" <<'EOF'
---
name: helper-role
description: Sandbox non-audit agent used by the codex translator fixture.
tools: Read
model: sonnet
---

# Helper Role

Sandbox helper agent body used by the codex translator fixture tests.
Line with three apostrophes: '''
Line with a quote " and a backslash \ together.
Ends with an apostrophe'
EOF

  cat >"$dir/claude/skills/sample-skill/SKILL.md" <<'EOF'
---
name: sample-skill
description: sandbox skill
---

# Sample Skill

the sandbox skill body line
EOF

  cat >"$dir/claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/alpha-guard.sh",
            "timeout": 30,
            "statusMessage": "Running alpha guard"
          }
        ]
      }
    ],
    "ConfigChange": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/beta-check.sh" }
        ]
      }
    ]
  }
}
EOF

  cat >"$dir/translate/codex-port-map.json" <<'EOF'
{
  "builder": "translate/codex.mjs",
  "events": {
    "PreToolUse": "PreToolUse",
    "ConfigChange": null
  },
  "unported_reasons": {
    "beta-check": "ConfigChange is a Claude Code event; sandbox stub reason."
  },
  "hook_overrides": {},
  "agents_to_skills": ["audit-*"],
  "hand_authored": [
    "hooks/codex-hook-adapter.sh",
    "README.md",
    "skills/session-start/SKILL.md",
    "skills/session-handoff/SKILL.md"
  ],
  "port_status_appendix": "## Permission rules\n\nSandbox stub appendix line for the codex translator fixture."
}
EOF

  cat >"$dir/codex/hooks/codex-hook-adapter.sh" <<'EOF'
#!/usr/bin/env bash
# Sandbox stub hand-authored adapter for the codex translator fixture.
EOF
  chmod +x "$dir/codex/hooks/codex-hook-adapter.sh"

  cat >"$dir/codex/README.md" <<'EOF'
# Codex (sandbox)

Sandbox stub hand-authored README for the codex translator fixture.
EOF

  # Deliberately stale: .gitignore is generated (B-11), so this stub exists
  # only to prove --check reports it stale before the first --write.
  cat >"$dir/codex/.gitignore" <<'EOF'
# Sandbox stale gitignore stub for the codex translator fixture.
EOF

  cat >"$dir/codex/skills/session-start/SKILL.md" <<'EOF'
Sandbox stub hand-authored session-start skill for the codex translator fixture.
EOF

  cat >"$dir/codex/skills/session-handoff/SKILL.md" <<'EOF'
Sandbox stub hand-authored session-handoff skill for the codex translator fixture.
EOF
}

# B-10: mode hygiene, no file touched.
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
OUT=$(node "$TRANSLATOR" --root "$SANDBOX" 2>&1); ST=$?
check "no mode exits 2" test "$ST" -eq 2
check "no mode prints usage" grep -q -- "--write" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --check --root "$SANDBOX" 2>&1); ST=$?
check "both modes exit 2" test "$ST" -eq 2
OUT=$(node "$TRANSLATOR" --frobnicate --root "$SANDBOX" 2>&1); ST=$?
check "unknown flag exits 2" test "$ST" -eq 2
check "usage errors touch nothing" test -z "$(ls -A "$SANDBOX")"

# P2-1 (2026-09-17 audit): a bare positional argument and a single-dash flag
# were both discarded, because only `--`-prefixed tokens were inspected, and
# rootDir then fell back to the script's own repository. `--check` against the
# wrong tree is merely wrong; `--write` prunes orphans and removes emptied
# directories, so it is destructive. Both spellings must be usage errors.
OUT=$(node "$TRANSLATOR" --check "$SANDBOX" 2>&1); ST=$?
check "positional root exits 2" test "$ST" -eq 2
check "positional root prints usage" grep -q -- "--write" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --check -root "$SANDBOX" 2>&1); ST=$?
check "single-dash flag exits 2" test "$ST" -eq 2
OUT=$(node "$TRANSLATOR" --check --root "$SANDBOX" extra 2>&1); ST=$?
check "trailing positional after --root exits 2" test "$ST" -eq 2
# An empty root also exits 2 through SourceError, so the usage line is what
# distinguishes a parse refusal from a load failure here.
check "trailing positional prints usage" grep -q -- "usage:" <<<"$OUT"

# Final review finding 2: bare --root with no following value is a usage
# error (exit 2), not a crash. Run outside any sandbox root so a regression
# to the old TypeError behavior cannot leave stray writes on disk anywhere.
OUT=$(node "$TRANSLATOR" --check --root 2>&1); ST=$?
check "bare --root exits 2" test "$ST" -eq 2
check "bare --root prints usage" grep -q -- "--write" <<<"$OUT"

# Task 2: source failure modes (spec Failure modes).
SRC=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC"' EXIT
make_source_tree "$SRC"
rm "$SRC/claude/settings.json"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing settings exits 2" test "$ST" -eq 2
check "missing settings named" grep -q "settings.json" <<<"$OUT"
make_source_tree "$SRC"
printf '%s\n' "no frontmatter here" >"$SRC/claude/agents/helper-role.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "nameless agent exits 2" test "$ST" -eq 2
check "nameless agent named" grep -q "helper-role.md" <<<"$OUT"

# Task 3: agents to TOML, audit agents to skills (B-2, B-3 first half).
make_source_tree "$SRC"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
TOML="$SRC/codex/agents/helper-role.toml"
check "agent toml exists" test -f "$TOML"
check "toml carries name" grep -q '^name = "helper-role"$' "$TOML"
check "toml carries description" grep -q '^description = ' "$TOML"
check "toml carries body" grep -q 'developer_instructions = """' "$TOML"
check "toml drops tools and model" not grep -qE '^(tools|model) =' "$TOML"
check "toml header names the translator" tomlHeaderNamesTranslator "$TOML"
check "audit agent becomes a skill" test -f "$SRC/codex/skills/audit-sample/SKILL.md"
check "non-audit agent does not" test ! -e "$SRC/codex/skills/helper-role"

# B-2 soundness: developer_instructions must be a valid TOML multiline basic
# string for any source body, even one with apostrophe runs, embedded quotes,
# and backslashes (review round 1: the old ''' literal-string renderer
# mis-escaped these). No TOML parser is bundled, so this checks structurally:
# the body region carries no unescaped double quote, and the tricky lines
# round-trip through escaping exactly as TOML requires.
BODY_REGION=$(awk '/^developer_instructions = """$/{flag=1; next} flag && /^"""$/{flag=0; next} flag' "$TOML")
check "toml body has no unescaped double quote" not grep -qE '[^\\]"' <<<"$BODY_REGION"
check "toml body keeps apostrophe run verbatim" grep -qF "Line with three apostrophes: '''" <<<"$BODY_REGION"
check "toml body escapes the quote and backslash" grep -qF 'Line with a quote \" and a backslash \\ together.' <<<"$BODY_REGION"
check "toml body keeps trailing apostrophe" grep -qF "Ends with an apostrophe'" <<<"$BODY_REGION"

# Task 4: skill copies with the GENERATED header (B-3 second half).
# B-3 (skills): verbatim copy, header after frontmatter, body untouched.
COPIED="$SRC/codex/skills/sample-skill/SKILL.md"
check "skill copy exists" test -f "$COPIED"
check "header sits after frontmatter" skillHeaderAfterFrontmatter "$COPIED"
check "body is verbatim" grep -qF "the sandbox skill body line" "$COPIED"
check "frontmatter is verbatim" grep -q "^description: sandbox skill$" "$COPIED"

# Task 5: AGENTS.md with port-aware tag rewrites (B-1).
# alpha-guard is registered under PreToolUse, which the map's events
# translate to a real Codex event, so its tag stays untouched. beta-check is
# registered only under ConfigChange, which the map's events translate to
# null, so its tag gains the "in Claude Code; manual in Codex" suffix.
DOC="$SRC/codex/AGENTS.md"
check "AGENTS.md exists" test -f "$DOC"
check "preamble present" grep -q "rendered for Codex" "$DOC"
check "ported tag unchanged" grep -q '\[hook:alpha-guard\]' "$DOC"
check "unported tag rewritten" grep -q '\[hook:beta-check in Claude Code; manual in Codex\]' "$DOC"
check "session-types content appended" grep -q "Session Types" "$DOC"

# Task 6: hooks.json and PORT-STATUS.md derived from settings.json (B-4, B-5).
# alpha-guard (PreToolUse Bash, ported, timeout 30, statusMessage set) must
# appear in hooks.json under an adapter command; beta-check (ConfigChange,
# unported) must not, and the ConfigChange event group must be absent
# entirely since its only registration is dropped.
HJ="$SRC/codex/hooks.json"
check "hooks.json exists" test -f "$HJ"
check "ported hook listed" portedHookListed
check "unported hook absent" not grep -q "beta-check" "$HJ"
check "statusMessage carried" statusMessageCarried
check "timeout carried" timeoutCarried
check "matcher carried" matcherCarried
check "description names the translator" descriptionNamesTranslator
check "no empty event groups" noEmptyConfigChangeGroup
check "hooks.json ends with newline" hooksJsonEndsWithNewline

PS="$SRC/codex/PORT-STATUS.md"
check "PORT-STATUS.md exists" test -f "$PS"
check "port-status row per registration" grep -q '`alpha-guard`' "$PS"
check "ported row names event and matcher" grep -q 'ported: `PreToolUse` (matcher `Bash`)' "$PS"
check "unported row carries reason" grep -q 'not ported: ConfigChange is a Claude Code event; sandbox stub reason.' "$PS"
check "counts derived line present" grep -qE '^[0-9]+ of [0-9]+ hook registrations port, across [0-9]+ Codex events\.' "$PS"
check "counts derived correctly" grep -q '^1 of 2 hook registrations port, across 1 Codex events.' "$PS"
check "appendix appended after table" grep -q 'Sandbox stub appendix line for the codex translator fixture.' "$PS"
check "appendix heading present" grep -q '^## Permission rules$' "$PS"

# Task 7: manifest and all-or-nothing write (B-6).
# B-6: manifest hashes every generated file, marks hand-authored ones.
MF="$SRC/codex/.claude-port.json"
check "manifest exists" test -f "$MF"
# Each jq check below needs its own stdout suppressed with >/dev/null;
# putting that redirect on the check() invocation line instead would silence
# check()'s own PASS/FAIL echo (same pipe-in-a-function trap noted above), so
# each jq call gets its own wrapper function.
manifestHashesAgentsMd() { jq -e '.files["AGENTS.md"] | startswith("sha256:")' "$MF" >/dev/null; }
check "manifest hashes AGENTS.md" manifestHashesAgentsMd
manifestMarksHandAuthored() { jq -e '.hand_authored | index("hooks/codex-hook-adapter.sh") != null' "$MF" >/dev/null; }
check "manifest marks hand-authored" manifestMarksHandAuthored
handAuthoredNotHashed() { jq -e '.files | has("hooks/codex-hook-adapter.sh") | not' "$MF" >/dev/null; }
check "hand-authored not hashed" handAuthoredNotHashed
manifestBuilderNamesTranslator() { jq -e '.builder == "translate/codex.mjs"' "$MF" >/dev/null; }
check "manifest names the builder" manifestBuilderNamesTranslator
manifestOmitsItself() { jq -e '.files | has(".claude-port.json") | not' "$MF" >/dev/null; }
check "manifest does not hash itself" manifestOmitsItself
manifestKeysCoverGenerated() {
  local listed generated
  listed=$(jq -r '.files | keys[]' "$MF" | sort)
  generated=$(cd "$SRC/codex" && find . -type f -print | sed 's#^\./##' | sort)
  # Drop hand-authored and the manifest itself from the on-disk listing so it
  # compares apples to apples with the manifest's files map.
  generated=$(comm -23 <(printf '%s\n' "$generated") <(jq -r '.hand_authored[]' "$MF" | sort))
  generated=$(comm -23 <(printf '%s\n' "$generated") <(printf '.claude-port.json\n'))
  [ "$listed" = "$generated" ]
}
check "manifest files map covers every generated file" manifestKeysCoverGenerated

# Invariant: double write is byte-identical (determinism).
SNAP1=$(cd "$SRC/codex" && find . -type f -exec shasum {} + | sort)
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
SNAP2=$(cd "$SRC/codex" && find . -type f -exec shasum {} + | sort)
check "double write is deterministic" test "$SNAP1" = "$SNAP2"

# Task 8: --check (B-7, B-8, B-9) and carried-over fixture obligations.
# add_settings_hook <dir> <hook-name> <event> [matcher]: appends a new hook
# group registering <hook-name> under <event> in the sandbox's
# settings.json, with a matcher ("*" unless overridden). Used for fixture
# cases the primary make_source_tree registration set does not cover.
add_settings_hook() {
  local dir="$1" name="$2" event="$3" matcher="${4-*}"
  local settings="$dir/claude/settings.json" tmp
  tmp=$(mktemp)
  jq --arg event "$event" --arg matcher "$matcher" --arg cmd "~/.claude/hooks/$name.sh" \
    '.hooks[$event] = ((.hooks[$event] // []) + [{"matcher": $matcher, "hooks": [{"type": "command", "command": $cmd}]}])' \
    "$settings" >"$tmp" && mv "$tmp" "$settings"
}

# B-7: clean after --write; stale after a source edit.
node "$TRANSLATOR" --check --root "$SRC"; check "check clean after write" test $? -eq 0
printf '%s\n' "R-999: New rule. [manual]" >>"$SRC/claude/CLAUDE.md"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "check catches staleness" test "$ST" -eq 1
check "stale file named" grep -q "stale: AGENTS.md" <<<"$OUT"
# Invariant: --check mutated nothing.
SNAP3=$(cd "$SRC/codex" && find . -type f -exec shasum {} + | sort)
check "check never mutates" test "$SNAP2" = "$SNAP3"
make_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# B-8: an unclassified hook fails check. gamma-guard registers under a
# novel event name absent from the port map's events entirely (unlike
# ConfigChange, which is present and explicitly translates to null), so it
# exercises the classification closure gap --check exists to catch.
add_settings_hook "$SRC" "gamma-guard" "FutureEvent"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "unclassified hook fails check" test "$ST" -eq 1
check "unclassified hook named" grep -q "unclassified hook: gamma-guard" <<<"$OUT"
make_source_tree "$SRC"; node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1

# B-9: a missing hand-authored file fails check; its content is never diffed.
rm "$SRC/codex/hooks/codex-hook-adapter.sh"
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "missing hand-authored fails check" test "$ST" -eq 1
check "missing hand-authored named" grep -q "missing hand-authored file: hooks/codex-hook-adapter.sh" <<<"$OUT"
printf '%s\n' "locally customized" >"$SRC/codex/hooks/codex-hook-adapter.sh"
node "$TRANSLATOR" --check --root "$SRC"; check "hand-authored content never diffed" test $? -eq 0

# (d): a retired unported_reasons entry (naming no hook settings.json still
# registers) warns but does not fail an otherwise-clean check.
make_source_tree "$SRC"
jq '.unported_reasons["retired-hook"] = "no longer registered; kept for history."' \
  "$SRC/translate/codex-port-map.json" >"$SRC/translate/codex-port-map.json.tmp" \
  && mv "$SRC/translate/codex-port-map.json.tmp" "$SRC/translate/codex-port-map.json"
node "$TRANSLATOR" --write --root "$SRC" >/dev/null 2>&1
OUT=$(node "$TRANSLATOR" --check --root "$SRC" 2>&1); ST=$?
check "retired hook warns but stays clean" test "$ST" -eq 0
check "retired hook warning named" grep -q "warning: port map names retired hook retired-hook" <<<"$OUT"

# Carried-over cases 1-3: dual-event hook, a distinct translated event name,
# and empty-matcher omission, all in one variant sandbox (SRC2) so the
# primary sandbox above stays exactly as Tasks 3-8 assert it.
SRC2=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC2"' EXIT
make_source_tree "$SRC2"

# Case 1: alpha-guard registers a second time under ConfigChange (an event
# the port map lists and explicitly translates to null), so it still counts
# as classified (not "unclassified hook") even with no unported_reasons
# entry of its own; the generic "no Codex equivalent" fallback covers it.
add_settings_hook "$SRC2" "alpha-guard" "ConfigChange"
node "$TRANSLATOR" --write --root "$SRC2" >/dev/null 2>&1
HJ2="$SRC2/codex/hooks.json"
PS2="$SRC2/codex/PORT-STATUS.md"
dualEventStillPortedUnderPreToolUse() { jq -e '.hooks.PreToolUse[0].hooks[0].command | test("alpha-guard")' "$HJ2" >/dev/null; }
check "dual-event hook still ported under PreToolUse" dualEventStillPortedUnderPreToolUse
check "dual-event hook has two port-status rows" test "$(grep -c '`alpha-guard`' "$PS2")" -eq 2
check "dual-event ported row present" grep -q '`alpha-guard`.*ported: `PreToolUse`' "$PS2"
check "dual-event not-ported row present" grep -q '`alpha-guard`.*not ported:' "$PS2"
node "$TRANSLATOR" --check --root "$SRC2"; check "dual-event sandbox check stays clean" test $? -eq 0

# Case 2 + 3: rename PreToolUse's translated event to PreCommand, and add
# delta-check under PreToolUse with an empty matcher.
add_settings_hook "$SRC2" "delta-check" "PreToolUse" ""
jq '.events.PreToolUse = "PreCommand"' "$SRC2/translate/codex-port-map.json" \
  >"$SRC2/translate/codex-port-map.json.tmp" && mv "$SRC2/translate/codex-port-map.json.tmp" "$SRC2/translate/codex-port-map.json"
node "$TRANSLATOR" --write --root "$SRC2" >/dev/null 2>&1
hooksJsonKeyIsPreCommand() { jq -e '.hooks | has("PreCommand")' "$HJ2" >/dev/null; }
check "renamed event becomes hooks.json key" hooksJsonKeyIsPreCommand
emptyMatcherGroupOmitsMatcher() { jq -e '.hooks.PreCommand[-1] | has("matcher") | not' "$HJ2" >/dev/null; }
check "empty matcher group omits matcher key" emptyMatcherGroupOmitsMatcher
check "renamed event ported row" grep -q '`alpha-guard`.*ported: `PreCommand`' "$PS2"
check "empty matcher row omits matcher clause" grep -qF '| `delta-check` | PreToolUse | ported: `PreCommand` |' "$PS2"
node "$TRANSLATOR" --check --root "$SRC2"; check "renamed-event sandbox check stays clean" test $? -eq 0

# Case 4: collision guard fires through --check too, now that --check
# renders the planned tree (a fresh third sandbox, since a collision aborts
# rendering entirely and cannot share state with cases 1-3 above).
SRC3=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC2" "$SRC3"' EXIT
make_source_tree "$SRC3"
mkdir -p "$SRC3/claude/skills/audit-sample"
cat >"$SRC3/claude/skills/audit-sample/SKILL.md" <<'EOF'
---
name: audit-sample
description: Colliding skill for the codex translator collision-guard fixture.
---

# Audit Sample Collision

Deliberately colliding skill source for the codex translator fixture.
EOF
OUT=$(node "$TRANSLATOR" --write --root "$SRC3" 2>&1); ST=$?
check "collision guard fails write" test "$ST" -eq 2
check "collision guard via write names the offender" grep -q "skills/audit-sample/SKILL.md" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --check --root "$SRC3" 2>&1); ST=$?
check "collision guard fails check too" test "$ST" -eq 2
check "collision guard via check names the offender" grep -q "skills/audit-sample/SKILL.md" <<<"$OUT"

# Task 9: orphaned generated file detection and removal (final review
# finding 1). A stale generated file left behind after its claude/ source is
# deleted (simulated here by planting a file directly, cheaper than actually
# deleting a source and re-writing) must fail --check and be deleted by
# --write; a hand_authored path must never be flagged even though it too
# sits on disk outside the planned set.
SRC4=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC2" "$SRC3" "$SRC4"' EXIT
make_source_tree "$SRC4"
node "$TRANSLATOR" --write --root "$SRC4" >/dev/null 2>&1
printf 'stale toml\n' >"$SRC4/codex/agents/stale-agent.toml"
OUT=$(node "$TRANSLATOR" --check --root "$SRC4" 2>&1); ST=$?
check "orphan fails check" test "$ST" -eq 1
check "orphan named" grep -q "orphaned: agents/stale-agent.toml" <<<"$OUT"
check "hand-authored path never flagged as orphan" not grep -q "orphaned: hooks/codex-hook-adapter.sh" <<<"$OUT"
OUT=$(node "$TRANSLATOR" --write --root "$SRC4" 2>&1); ST=$?
check "write removes orphan" test ! -e "$SRC4/codex/agents/stale-agent.toml"
check "write summary reports removal count" grep -q "wrote .* files, removed 1 orphans" <<<"$OUT"
node "$TRANSLATOR" --check --root "$SRC4"; check "check clean after orphan removed" test $? -eq 0
OUT=$(node "$TRANSLATOR" --write --root "$SRC4" 2>&1); check "write summary omits removed clause when clean" not grep -q "removed" <<<"$OUT"

# Deleting a skill on the claude/ side orphans codex/skills/<name>/SKILL.md,
# and unlinking the file alone leaves the directory behind: invisible to git
# (which stores no empty directories) and invisible to --check (which lists
# files), so it survives every later run. Removing an emptied directory is
# the same single-owner invariant as removing the orphan itself.
mkdir -p "$SRC4/codex/skills/gone-skill/nested"
printf 'stale skill\n' >"$SRC4/codex/skills/gone-skill/SKILL.md"
printf 'stale nested\n' >"$SRC4/codex/skills/gone-skill/nested/NOTE.md"
node "$TRANSLATOR" --write --root "$SRC4" >/dev/null 2>&1
check "write removes the orphaned skill file" test ! -e "$SRC4/codex/skills/gone-skill/SKILL.md"
check "write removes the emptied skill directory" test ! -d "$SRC4/codex/skills/gone-skill"
check "write removes the emptied nested directory" test ! -d "$SRC4/codex/skills/gone-skill/nested"
check "write keeps a directory that still holds planned files" test -d "$SRC4/codex/skills/sample-skill"
check "write keeps codex/skills itself" test -d "$SRC4/codex/skills"
node "$TRANSLATOR" --check --root "$SRC4"; check "check clean after directory cleanup" test $? -eq 0

# Task 10: duplicate agent frontmatter name collision guard (final review
# finding 4). Two claude/agents files sharing one frontmatter name would
# otherwise both plan to write agents/helper-role.toml.
SRC5=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC2" "$SRC3" "$SRC4" "$SRC5"' EXIT
make_source_tree "$SRC5"
cat >"$SRC5/claude/agents/helper-role-duplicate.md" <<'EOF'
---
name: helper-role
description: Duplicate-named sandbox agent for the codex translator collision-guard fixture.
tools: Read
model: sonnet
---

# Helper Role Duplicate

Deliberately duplicate-named agent source for the codex translator fixture.
EOF
OUT=$(node "$TRANSLATOR" --check --root "$SRC5" 2>&1); ST=$?
check "duplicate agent name fails check" test "$ST" -eq 2
check "duplicate agent name names offender" grep -qE "helper-role(-duplicate)?\.md" <<<"$OUT"

# Task 11: codex/.gitignore is generated from the planned tree (B-11). It is
# an allowlist (`*` then one `!/` entry per tracked path), so while it was
# hand-authored a newly added skill was generated, ignored by git, and
# --check still passed: the port silently lost a file. Generating it makes
# the allowlist derived data, and staleness a --check failure.
SRC6=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$SRC" "$SRC2" "$SRC3" "$SRC4" "$SRC5" "$SRC6"' EXIT
make_source_tree "$SRC6"
GI="$SRC6/codex/.gitignore"

# The stub written by make_source_tree is not what the renderer produces, so
# the pre-write tree is stale on .gitignore and no longer missing a
# hand-authored file (the port map no longer claims it).
OUT=$(node "$TRANSLATOR" --check --root "$SRC6" 2>&1); ST=$?
check "stale gitignore fails check" test "$ST" -eq 1
check "stale gitignore named" grep -q "^stale: .gitignore$" <<<"$OUT"
check "gitignore no longer claimed hand-authored" not grep -q "missing hand-authored file: .gitignore" <<<"$OUT"

node "$TRANSLATOR" --write --root "$SRC6" >/dev/null 2>&1
check "gitignore written" test -f "$GI"
check "gitignore header names the translator" grep -q "translate/codex.mjs" "$GI"
check "gitignore ignores everything by default" grep -qx -- '\*' "$GI"
check "gitignore allowlists itself" grep -qx -- '!/.gitignore' "$GI"
check "gitignore allowlists the manifest" grep -qx -- '!/.claude-port.json' "$GI"
check "gitignore allowlists the rules doc" grep -qx -- '!/AGENTS.md' "$GI"
check "gitignore allowlists a generated skill" grep -qx -- '!/skills/sample-skill/SKILL.md' "$GI"
check "gitignore allowlists that skill's directory" grep -qx -- '!/skills/sample-skill/' "$GI"
check "gitignore allowlists an agent-derived skill" grep -qx -- '!/skills/audit-sample/SKILL.md' "$GI"
check "gitignore allowlists a generated agent toml" grep -qx -- '!/agents/helper-role.toml' "$GI"
check "gitignore allowlists a hand-authored file" grep -qx -- '!/README.md' "$GI"
check "gitignore allowlists a nested hand-authored file" grep -qx -- '!/hooks/codex-hook-adapter.sh' "$GI"
check "gitignore allowlists that file's directory" grep -qx -- '!/hooks/' "$GI"
check "gitignore allowlists a hand-authored skill" grep -qx -- '!/skills/session-start/SKILL.md' "$GI"
# Entry order is the deterministic-output invariant, checked in C locale
# because the renderer sorts byte-wise, not by the caller's collation.
gitignoreEntriesSorted() { local e; e=$(grep '^!/' "$GI"); [ "$e" = "$(LC_ALL=C sort <<<"$e")" ]; }
check "gitignore entries sorted deterministically" gitignoreEntriesSorted
check "no unported hook path allowlisted" not grep -q "beta-check" "$GI"
node "$TRANSLATOR" --check --root "$SRC6"; check "check clean after write" test $? -eq 0

# The regression itself: a skill added to claude/ reaches the allowlist with
# no hand edit to .gitignore.
mkdir -p "$SRC6/claude/skills/late-skill"
cat >"$SRC6/claude/skills/late-skill/SKILL.md" <<'EOF'
---
name: late-skill
description: sandbox skill added after the first write
---

# Late Skill

the sandbox late-skill body line
EOF
OUT=$(node "$TRANSLATOR" --check --root "$SRC6" 2>&1); ST=$?
check "new skill makes gitignore stale" test "$ST" -eq 1
check "new skill names gitignore stale" grep -q "^stale: .gitignore$" <<<"$OUT"
node "$TRANSLATOR" --write --root "$SRC6" >/dev/null 2>&1
check "new skill lands in the allowlist" grep -qx -- '!/skills/late-skill/SKILL.md' "$GI"
check "new skill directory lands in the allowlist" grep -qx -- '!/skills/late-skill/' "$GI"
node "$TRANSLATOR" --check --root "$SRC6"; check "check clean after the new skill" test $? -eq 0

# A deleted .gitignore is stale (rewritten by --write), never an orphan and
# never a missing hand-authored file.
rm "$GI"
OUT=$(node "$TRANSLATOR" --check --root "$SRC6" 2>&1)
check "absent gitignore reports stale" grep -q "^stale: .gitignore$" <<<"$OUT"
check "absent gitignore is not an orphan" not grep -q "orphaned: .gitignore" <<<"$OUT"
node "$TRANSLATOR" --write --root "$SRC6" >/dev/null 2>&1
check "write restores the gitignore" test -f "$GI"

# The manifest hashes .gitignore like any other generated file, and still
# does not claim it hand-authored.
manifestHashesGitignore() { jq -e '.files[".gitignore"] | test("^sha256:")' "$SRC6/codex/.claude-port.json" >/dev/null; }
manifestOmitsGitignoreFromHandAuthored() { jq -e '.hand_authored | index(".gitignore") | not' "$SRC6/codex/.claude-port.json" >/dev/null; }
check "manifest hashes the gitignore" manifestHashesGitignore
check "manifest omits gitignore from hand-authored" manifestOmitsGitignoreFromHandAuthored

[ "$fail" -eq 0 ] && echo "translate-codex.test.sh PASS" || exit 1
