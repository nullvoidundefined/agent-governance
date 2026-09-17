#!/usr/bin/env bash
# port-checks.sh: the one inventory of translator freshness checks, shared by
# every place that verifies this repository. Three callers used to keep their
# own list (hooks/verification-gate.sh at turn end, hooks/pre-push.sample at
# push time, .github/workflows/enforce.yml in CI), and they had already
# drifted: the turn-end gate checked the codex port only while pre-push and CI
# checked codex and cursor, so a stale cursor/ tree survived every local turn
# and surfaced only at push (2026-09-18 external audit, finding 7). Adding a
# third port to the repository would have repeated that drift three ways.
#
# Independent enforcement is deliberately preserved: each caller still decides
# when to run the checks and what a failure means (a blocked Stop, a refused
# push, a red CI job). Only the question "which checks exist" is centralized.

# listPortChecks(toplevel): prints one shell command per line, one per
# translator present under <toplevel>/translate/. A translator that is absent
# contributes nothing, because translate/ exists in the monorepo layout only:
# a legacy checkout or a live ~/.claude copy must not gain a check it has no
# script to satisfy. Paths are emitted relative to the toplevel the caller
# passed, so a caller that cd's to the toplevel and a caller that prefixes
# paths both get what they need.
listPortChecks() {
  local toplevel="${1:-.}" translator
  for translator in codex cursor; do
    if [ -f "$toplevel/translate/$translator.mjs" ]; then
      printf 'node translate/%s.mjs --check\n' "$translator"
    fi
  done
}
