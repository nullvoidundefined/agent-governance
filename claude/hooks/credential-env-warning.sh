#!/usr/bin/env bash
# SessionStart hook. Prints one line naming each credential variable present
# in the session's environment (spec docs/specs/2026-10-05-credential-reads.md,
# C-8), so the agent knows which names credential-read-guard.sh will refuse to
# print. Names only, never a value; nothing when there is none. The name list
# comes from credential_judge.py, the one definition of a credential name.
# Always exits 0: a warning must never block a session.
set -uo pipefail

CREDENTIAL_JUDGE="$(dirname "${BASH_SOURCE[0]}")/credential_judge.py"

cat >/dev/null 2>&1 || true
command -v python3 >/dev/null 2>&1 && [ -f "$CREDENTIAL_JUDGE" ] || exit 0
names="$(python3 "$CREDENTIAL_JUDGE" --list-env-names 2>/dev/null </dev/null | paste -sd, - | sed 's/,/, /g')" || exit 0
[ -n "$names" ] || exit 0
printf 'credential-env-warning: credential variables are set in this session: %s. Programs may use them (psql "$DATABASE_URL"); never print their values, which credential-read-guard denies.\n' "$names"
exit 0
