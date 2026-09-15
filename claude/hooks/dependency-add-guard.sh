#!/usr/bin/env bash
# dependency-add-guard.sh: PreToolUse (Write, Edit) ask for R-331. When a
# dependency manifest gains a third-party dependency NAME it did not have on
# disk, ask, naming the packages, so the addition is a decision rather than a
# side effect of an implementer's convenience (2026-09-06 TDD harness
# assessment H-5, decision "ask on every new dependency"). A version change, a
# removal, a script change, or an unrelated file is silent.
#
# Manifests and what counts as a dependency name:
#   package.json     keys of dependencies, devDependencies, peerDependencies,
#                    optionalDependencies
#   pyproject.toml   [project] dependencies and optional-dependencies (PEP 508
#                    names), [dependency-groups] (PEP 735), [tool.poetry.*
#                    dependencies] keys except python
#   go.mod           require lines without "// indirect" (tidy output is not a
#                    choice)
#   Gemfile          gem "name" lines
# An Edit is judged on the file as it will be after the replacement (first
# occurrence, as the Edit tool applies it). Lockfiles are never judged. A
# result that does not parse fails open: this hook asks about choices, and a
# broken manifest is caught by the install, not here. The parsing lives in
# dependency-add-scan.py beside this hook; python3 is spawned only for manifest
# writes, so the per-edit chain stays cheap for every other file.
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write | Edit) ;; *) exit 0 ;; esac
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
case "$(basename "$FILE")" in package.json | pyproject.toml | go.mod | Gemfile) ;; *) exit 0 ;; esac
command -v python3 >/dev/null 2>&1 || exit 0

ADDED=$(printf '%s' "$INPUT" | python3 "$(dirname "${BASH_SOURCE[0]}")/dependency-add-scan.py" "$FILE" 2>/dev/null)
[ -n "$ADDED" ] || exit 0

source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-331" "dependency-add-guard" "ask"
COUNT=$(printf '%s\n' "$ADDED" | wc -w | tr -d ' ')
jq -n --arg r "dependency-add-guard (R-331): this write adds $COUNT new dependenc$( [ "$COUNT" = 1 ] && echo y || echo ies ) to $(basename "$FILE"): $ADDED. A new package is a decision, not a side effect: name the need that services/, clients/, and the existing packages cannot meet (R-308), or reuse what is there. Confirm to add it." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
