#!/usr/bin/env bash
# Shard: slow
# require-stack-observability-docs.test.sh: verifies
# enforce/require-stack-observability-docs.sh (R-608) against sandboxed
# repositories: a dependency added to or removed from a package.json,
# pyproject.toml, Gemfile, or go.mod requires docs/stack.md; an analytics
# event registry entry, an error-code registry entry, or a log event name
# added or removed requires docs/observability.md; version bumps, indirect Go
# modules, reused log event names, and test files do not trigger; the
# .enforce.json opt-outs stackDoc and observabilityDoc each turn off one half.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECK="$CLAUDE_HARNESS_ROOT/enforce/require-stack-observability-docs.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
OUT=""; ST=0

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }

# reports <text>: true when the last run's output contains the text.
reports() { grep -qF -- "$1" <<< "$OUT"; }

# lacks <text>: true when the last run's output does not contain the text.
lacks() { ! grep -qF -- "$1" <<< "$OUT"; }

# make_repo <name>: a repository with one commit on main and a checked-out
# feat/x branch; prints its path.
make_repo() {
  local dir="$SB/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '# app\n' > "$dir/README.md"
  git -C "$dir" add -A && git -C "$dir" commit -qm init
  git -C "$dir" switch -q -c feat/x
  printf '%s' "$dir"
}

# write_file <repo> <path> <content>: writes the content (printf %b, so \n is
# a newline) and commits it on the current branch.
write_file() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%b' "$3" > "$1/$2"
  git -C "$1" add -A && git -C "$1" commit -qm "write $2"
}

# write_base <repo> <path> <content>: writes and commits the file on main,
# then fast-forwards feat/x onto it, so the content is part of the base.
write_base() {
  git -C "$1" switch -q main
  write_file "$1" "$2" "$3"
  git -C "$1" switch -q feat/x
  git -C "$1" merge -q --ff-only main
}

# touch_doc <repo> <path>: changes a doc on the branch.
touch_doc() { write_file "$1" "$2" "doc $RANDOM\n"; }

# run_check <repo> [base]: runs the script inside the repository with the
# base defaulting to main; sets OUT and ST.
run_check() {
  OUT=$(cd "$1" && FEATURE_CHECKLIST_BASE="${2:-main}" bash "$CHECK" 2>&1); ST=$?
}

PKG_BASE='{\n  "name": "app",\n  "dependencies": {\n    "express": "^5.0.0"\n  },\n  "devDependencies": {\n    "vitest": "^2.0.0"\n  }\n}\n'
PKG_ADDED='{\n  "name": "app",\n  "dependencies": {\n    "express": "^5.0.0",\n    "zod": "^3.23.0"\n  },\n  "devDependencies": {\n    "vitest": "^2.0.0"\n  }\n}\n'
PKG_BUMPED='{\n  "name": "app",\n  "dependencies": {\n    "express": "^5.1.0"\n  },\n  "devDependencies": {\n    "vitest": "^3.0.0"\n  }\n}\n'
PKG_REMOVED='{\n  "name": "app",\n  "dependencies": {\n    "express": "^5.0.0"\n  }\n}\n'

# S-1: an added package.json dependency without docs/stack.md.
R=$(make_repo s1); write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_ADDED"; run_check "$R"
check "S-1 added npm dependency exits 1" test "$ST" -eq 1
check "S-1 names R-608" reports "R-608"
check "S-1 names the manifest" reports "package.json"
check "S-1 names the dependency" reports "zod"
check "S-1 names docs/stack.md" reports "docs/stack.md"
check "S-1 does not ask for observability" lacks "docs/observability.md"

# S-2: a version bump, even across a major, changes no dependency name.
R=$(make_repo s2); write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_BUMPED"; run_check "$R"
check "S-2 version bump exits 0" test "$ST" -eq 0

# S-3: a removed dependency triggers and is named as removed.
R=$(make_repo s3); write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_REMOVED"; run_check "$R"
check "S-3 removed npm dependency exits 1" test "$ST" -eq 1
check "S-3 names the removed dependency" reports "vitest"

# S-4: the same change with docs/stack.md touched passes.
R=$(make_repo s4); write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_ADDED"
touch_doc "$R" docs/stack.md; run_check "$R"
check "S-4 added dependency with stack.md exits 0" test "$ST" -eq 0

# S-5: a new workspace manifest at a monorepo prefix counts every dependency.
R=$(make_repo s5); write_file "$R" apps/server/package.json "$PKG_BASE"; run_check "$R"
check "S-5 new workspace manifest exits 1" test "$ST" -eq 1
check "S-5 names the prefixed manifest" reports "apps/server/package.json"
check "S-5 names its dependency" reports "express"

# S-6: pyproject.toml, PEP 621 and Poetry tables; a version bump passes.
PY_BASE='[project]\nname = "app"\ndependencies = [\n    "fastapi>=0.115",\n    "pydantic>=2.9",\n]\n\n[dependency-groups]\ndev = ["pytest>=8"]\n'
PY_ADDED='[project]\nname = "app"\ndependencies = [\n    "fastapi>=0.115",\n    "pydantic>=2.9",\n    "structlog>=24.4",\n]\n\n[dependency-groups]\ndev = ["pytest>=8"]\n'
PY_BUMPED='[project]\nname = "app"\ndependencies = [\n    "fastapi>=0.120",\n    "pydantic[email]>=3.0",\n]\n\n[dependency-groups]\ndev = ["pytest>=9"]\n'
PY_DEV_ADDED='[project]\nname = "app"\ndependencies = [\n    "fastapi>=0.115",\n    "pydantic>=2.9",\n]\n\n[dependency-groups]\ndev = ["pytest>=8", "ruff>=0.7"]\n'
R=$(make_repo s6); write_base "$R" pyproject.toml "$PY_BASE"; write_file "$R" pyproject.toml "$PY_ADDED"; run_check "$R"
check "S-6 added PEP 621 dependency exits 1" test "$ST" -eq 1
check "S-6 names structlog" reports "structlog"
R=$(make_repo s6dev); write_base "$R" pyproject.toml "$PY_BASE"; write_file "$R" pyproject.toml "$PY_DEV_ADDED"; run_check "$R"
check "S-6 added dependency-group entry exits 1" test "$ST" -eq 1
check "S-6 names ruff" reports "ruff"
R=$(make_repo s6bump); write_base "$R" pyproject.toml "$PY_BASE"; write_file "$R" pyproject.toml "$PY_BUMPED"; run_check "$R"
check "S-6 version and extras change exits 0" test "$ST" -eq 0
POETRY_BASE='[tool.poetry]\nname = "app"\n\n[tool.poetry.dependencies]\npython = "^3.12"\nfastapi = "^0.115"\n'
POETRY_ADDED='[tool.poetry]\nname = "app"\n\n[tool.poetry.dependencies]\npython = "^3.12"\nfastapi = "^0.115"\nhttpx = "^0.27"\n'
R=$(make_repo s6poetry); write_base "$R" pyproject.toml "$POETRY_BASE"; write_file "$R" pyproject.toml "$POETRY_ADDED"; run_check "$R"
check "S-6 added Poetry dependency exits 1" test "$ST" -eq 1
check "S-6 names httpx" reports "httpx"

# S-7: Gemfile gems.
R=$(make_repo s7); write_base "$R" Gemfile "source \"https://rubygems.org\"\ngem \"rails\", \"~> 8.0\"\n"
write_file "$R" Gemfile "source \"https://rubygems.org\"\ngem \"rails\", \"~> 8.0\"\ngem 'sidekiq', '~> 7.3'\n"; run_check "$R"
check "S-7 added gem exits 1" test "$ST" -eq 1
check "S-7 names sidekiq" reports "sidekiq"

# S-8: go.mod direct requirements count; an indirect one does not.
GO_BASE='module example.invalid/app\n\ngo 1.23\n\nrequire (\n\tgithub.com/go-chi/chi/v5 v5.1.0\n)\n'
GO_ADDED='module example.invalid/app\n\ngo 1.23\n\nrequire (\n\tgithub.com/go-chi/chi/v5 v5.1.0\n\tgithub.com/jackc/pgx/v5 v5.7.1\n)\n'
GO_INDIRECT='module example.invalid/app\n\ngo 1.23\n\nrequire (\n\tgithub.com/go-chi/chi/v5 v5.1.0\n\tgolang.org/x/text v0.19.0 // indirect\n)\n'
R=$(make_repo s8); write_base "$R" go.mod "$GO_BASE"; write_file "$R" go.mod "$GO_ADDED"; run_check "$R"
check "S-8 added go module exits 1" test "$ST" -eq 1
check "S-8 names pgx" reports "github.com/jackc/pgx/v5"
R=$(make_repo s8ind); write_base "$R" go.mod "$GO_BASE"; write_file "$R" go.mod "$GO_INDIRECT"; run_check "$R"
check "S-8 indirect go module exits 0" test "$ST" -eq 0

# S-9: stackDoc false turns off only the stack half.
R=$(make_repo s9); printf '{"stackDoc": false}\n' > "$R/.enforce.json"
write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_ADDED"; run_check "$R"
check "S-9 stackDoc false exits 0" test "$ST" -eq 0
write_file "$R" analytics/events.ts 'export const EVENTS = {\n    tripCreated: "trip_created",\n} as const;\n'; run_check "$R"
check "S-9 stackDoc false still checks observability" test "$ST" -eq 1

# O-1: an analytics event registry entry added, TypeScript.
EVENTS_BASE='export const EVENTS = {\n    signupCompleted: "signup_completed",\n} as const;\n'
EVENTS_ADDED='export const EVENTS = {\n    signupCompleted: "signup_completed",\n    tripCreated: "trip_created",\n} as const;\n'
R=$(make_repo o1); write_base "$R" src/analytics/events.ts "$EVENTS_BASE"; write_file "$R" src/analytics/events.ts "$EVENTS_ADDED"; run_check "$R"
check "O-1 added analytics event exits 1" test "$ST" -eq 1
check "O-1 names docs/observability.md" reports "docs/observability.md"
check "O-1 names the registry" reports "src/analytics/events.ts"
check "O-1 does not ask for stack" lacks "docs/stack.md"
touch_doc "$R" docs/observability.md; run_check "$R"
check "O-1 with observability.md exits 0" test "$ST" -eq 0

# O-2: an analytics event registry entry removed, Python.
PY_EVENTS_BASE='class AnalyticsEvent(StrEnum):\n    SIGNUP_COMPLETED = "signup_completed"\n    TRIP_CREATED = "trip_created"\n'
PY_EVENTS_REMOVED='class AnalyticsEvent(StrEnum):\n    SIGNUP_COMPLETED = "signup_completed"\n'
R=$(make_repo o2); write_base "$R" app/analytics/events.py "$PY_EVENTS_BASE"; write_file "$R" app/analytics/events.py "$PY_EVENTS_REMOVED"; run_check "$R"
check "O-2 removed analytics event exits 1" test "$ST" -eq 1

# O-3: a comment-only registry change does not trigger.
R=$(make_repo o3); write_base "$R" app/analytics/events.py "$PY_EVENTS_BASE"
write_file "$R" app/analytics/events.py "# The registry.\n$PY_EVENTS_BASE"; run_check "$R"
check "O-3 comment-only registry change exits 0" test "$ST" -eq 0

# O-4: error-code registries, Python and TypeScript.
R=$(make_repo o4py); write_base "$R" app/constants/error_codes.py 'class ErrorCode(StrEnum):\n    AUTH_REQUIRED = "AUTH_REQUIRED"\n'
write_file "$R" app/constants/error_codes.py 'class ErrorCode(StrEnum):\n    AUTH_REQUIRED = "AUTH_REQUIRED"\n    TRIPS_NOT_FOUND = "TRIPS_NOT_FOUND"\n'; run_check "$R"
check "O-4 added python error code exits 1" test "$ST" -eq 1
check "O-4 names the error-code registry" reports "app/constants/error_codes.py"
R=$(make_repo o4ts); write_file "$R" src/constants/errorCodes.ts 'export const ERROR_CODES = {\n    TRIPS_NOT_FOUND: "TRIPS_NOT_FOUND",\n} as const;\n'; run_check "$R"
check "O-4 new typescript error-code registry exits 1" test "$ST" -eq 1

# O-5: a new log event name, per stack; a name that already exists passes.
R=$(make_repo o5py); write_file "$R" app/services/trips/create_trip.py 'logger.info("trip_created", trip_id=trip.id)\n'; run_check "$R"
check "O-5 new python log event exits 1" test "$ST" -eq 1
check "O-5 names the python event" reports "trip_created"
R=$(make_repo o5ts); write_file "$R" src/services/trips/createTrip.ts 'logger.info({ tripId }, "Trip created");\n'; run_check "$R"
check "O-5 new pino log message exits 1" test "$ST" -eq 1
check "O-5 names the pino message" reports "Trip created"
R=$(make_repo o5rb); write_file "$R" app/services/create_trip.rb 'Rails.logger.info(event: "trip_created", trip_id: trip.id)\n'; run_check "$R"
check "O-5 new ruby log event exits 1" test "$ST" -eq 1
R=$(make_repo o5go); write_file "$R" services/trips/create.go 'slog.Info("trip created", "trip_id", id)\n'; run_check "$R"
check "O-5 new go log event exits 1" test "$ST" -eq 1
R=$(make_repo o5reuse); write_base "$R" app/services/a.py 'logger.info("trip_created", trip_id=1)\n'
write_file "$R" app/services/b.py 'logger.info("trip_created", trip_id=2)\n'; run_check "$R"
check "O-5 reused log event exits 0" test "$ST" -eq 0

# O-6: a log event name that disappears from the tree triggers.
R=$(make_repo o6); write_base "$R" app/services/a.py 'logger.info("trip_created", trip_id=1)\n'
write_file "$R" app/services/a.py 'pass\n'; run_check "$R"
check "O-6 removed log event exits 1" test "$ST" -eq 1

# O-7: log calls in test files do not trigger.
R=$(make_repo o7); write_file "$R" tests/test_trips.py 'logger.info("fixture_loaded")\n'
write_file "$R" src/services/createTrip.test.ts 'logger.info({}, "Fixture loaded");\n'; run_check "$R"
check "O-7 test-file log events exit 0" test "$ST" -eq 0

# O-8: observabilityDoc false turns off only the observability half.
R=$(make_repo o8); printf '{"observabilityDoc": false}\n' > "$R/.enforce.json"
write_file "$R" app/services/a.py 'logger.info("trip_created", trip_id=1)\n'; run_check "$R"
check "O-8 observabilityDoc false exits 0" test "$ST" -eq 0
write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_ADDED"; run_check "$R"
check "O-8 observabilityDoc false still checks stack" test "$ST" -eq 1

# O-9: extra registries from .enforce.json; a bad pattern is ignored.
R=$(make_repo o9); printf '{"observabilityDoc": {"extraRegistries": ["(^|/)telemetry/catalog\\\\.ts$"]}}\n' > "$R/.enforce.json"
write_file "$R" src/telemetry/catalog.ts 'export const CATALOG = ["trip_created"];\n'; run_check "$R"
check "O-9 extra registry exits 1" test "$ST" -eq 1
R=$(make_repo o9bad); printf '{"observabilityDoc": {"extraRegistries": ["(unclosed"]}}\n' > "$R/.enforce.json"
write_file "$R" src/analytics/events.ts "$EVENTS_ADDED"; run_check "$R"
check "O-9 bad pattern keeps built-in registries" test "$ST" -eq 1
check "O-9 bad pattern is reported" reports "(unclosed"

# O-10 (PR #124 review): an identifier that merely ends in "log" is not a
# logger, and neither is a key that merely ends in "event".
R=$(make_repo o10); write_file "$R" src/services/report.ts 'backlog.info("weekly_report_generated");\ncatalog.error({ id }, "catalog_missing");\nprevent: "double_submit"\n'; run_check "$R"
check "O-10 backlog, catalog, prevent exit 0" test "$ST" -eq 0

# O-11 (PR #124 review): a logger call wrapped across lines is still read,
# and req.log is a logger.
R=$(make_repo o11); write_file "$R" src/services/createOrder.ts 'logger.info(\n    { requestId },\n    "order_created",\n);\n'; run_check "$R"
check "O-11 multi-line log call exits 1" test "$ST" -eq 1
check "O-11 names the wrapped event" reports "order_created"
R=$(make_repo o11req); write_file "$R" src/handlers/orders.ts 'req.log.warn({ orderId }, "order_rejected");\n'; run_check "$R"
check "O-11 req.log call exits 1" test "$ST" -eq 1

# O-12 (PR #124 review): a wrapped call removed from the tree is read too.
R=$(make_repo o12); write_base "$R" src/services/createOrder.ts 'logger.info(\n    { requestId },\n    "order_created",\n);\n'
write_file "$R" src/services/createOrder.ts 'export {};\n'; run_check "$R"
check "O-12 removed multi-line log call exits 1" test "$ST" -eq 1

# B-1: both halves in one report.
R=$(make_repo b1); write_base "$R" package.json "$PKG_BASE"; write_file "$R" package.json "$PKG_ADDED"
write_file "$R" src/analytics/events.ts "$EVENTS_ADDED"; run_check "$R"
check "B-1 both missing exits 1" test "$ST" -eq 1
check "B-1 names stack.md" reports "docs/stack.md"
check "B-1 names observability.md" reports "docs/observability.md"

# B-2: skip on main and on an unresolvable base; an unrelated diff passes.
R=$(make_repo b2main); git -C "$R" switch -q main; write_file "$R" src/analytics/events.ts "$EVENTS_ADDED"; run_check "$R" "HEAD~1"
check "B-2 on main exits 0" test "$ST" -eq 0
R=$(make_repo b2base); write_file "$R" src/analytics/events.ts "$EVENTS_ADDED"; run_check "$R" "no-such-ref"
check "B-2 unresolvable base exits 0" test "$ST" -eq 0
R=$(make_repo b2plain); write_file "$R" src/services/trips.ts 'export function listTrips() { return []; }\n'; run_check "$R"
check "B-2 unrelated diff exits 0" test "$ST" -eq 0
check "B-2 unrelated diff prints nothing" test -z "$OUT"

[ "$fail" -eq 0 ] && echo "require-stack-observability-docs.test.sh PASS"
exit "$fail"
