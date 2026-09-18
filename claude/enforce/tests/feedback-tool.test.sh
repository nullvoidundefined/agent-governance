#!/usr/bin/env bash
# feedback-tool.test.sh: verifies skills/resolve-user-feedback/scripts/feedback.mjs
# (2026-09-17 skills audit, S-7) without a database: --dry-run prints the
# composed SQL and bound parameters; close refuses without --confirm naming
# the host and the ids (R-101); a non-identifier table or a non-integer id is
# a usage error; a missing DATABASE_URL is exit 4; the host line never
# carries the credentials.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TOOL="$CLAUDE_HARNESS_ROOT/skills/resolve-user-feedback/scripts/feedback.mjs"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
not_reports() { ! grep -qF "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
# The connection string is assembled at run time so no credential-shaped
# literal sits in a committed file (secret scanners flag a full URI).
FAKE_PW="placeholder-not-a-secret"
printf 'DATABASE_URL=%s://%s:%s@%s/%s\n' postgres user "$FAKE_PW" db.example.invalid:5432 app > "$SB/.env"

OUT=$(cd "$SB" && node "$TOOL" list --dry-run 2>&1); ST=$?
check "list dry run exits 0" test "$ST" -eq 0
check "list sql composed from the default table" reports "SELECT id, type, description, page_url, created_at FROM app_feedback WHERE status = \$1 ORDER BY created_at DESC"
check "list params bound" reports 'params: ["open"]'

OUT=$(cd "$SB" && node "$TOOL" list --table user_feedback --status-col state --dry-run 2>&1)
check "identifiers substituted" reports "FROM user_feedback WHERE state = \$1"

OUT=$(cd "$SB" && node "$TOOL" close 12 15 --dry-run 2>&1); ST=$?
check "close without confirm exits 3" test "$ST" -eq 3
check "close without confirm names the ids" reports "[12, 15]"
check "close without confirm names the host" reports "db.example.invalid/app"
check "close without confirm cites R-101" reports "R-101"
check "credentials never printed" not_reports "$FAKE_PW"

OUT=$(cd "$SB" && node "$TOOL" close 12 15 --confirm --dry-run 2>&1); ST=$?
check "close confirmed dry run exits 0" test "$ST" -eq 0
check "close sql parameterized" reports "UPDATE app_feedback SET status = \$1 WHERE id = ANY(\$2::int[]) RETURNING id, type, status"
check "close params bound" reports 'params: ["closed",[12,15]]'

OUT=$(cd "$SB" && node "$TOOL" list --table 'app_feedback; drop table x' --dry-run 2>&1); ST=$?
check "injected table name is a usage error" test "$ST" -eq 2
OUT=$(cd "$SB" && node "$TOOL" close abc --confirm --dry-run 2>&1); ST=$?
check "non-integer id is a usage error" test "$ST" -eq 2
OUT=$(cd "$SB" && node "$TOOL" frobnicate 2>&1); ST=$?
check "unknown command is a usage error" test "$ST" -eq 2

rm "$SB/.env"
OUT=$(cd "$SB" && env -u DATABASE_URL node "$TOOL" list 2>&1); ST=$?
check "missing DATABASE_URL exits 4" test "$ST" -eq 4

[ "$fail" -eq 0 ] && echo "feedback-tool.test.sh PASS"
exit "$fail"
