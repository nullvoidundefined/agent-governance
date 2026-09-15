#!/usr/bin/env bash
# Verifies dependency-add-guard.sh (R-331): a Write or Edit that adds a new
# third-party dependency name to package.json, pyproject.toml, go.mod, or a
# Gemfile asks, naming the packages; a version change, a script change, or an
# unrelated file is silent; an unparsable result fails open.
set -euo pipefail
HOOK="$HOME/.claude/hooks/dependency-add-guard.sh"
REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q

write() { jq -nc --arg f "$1" --arg c "$2" --arg d "$REPO" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:$c}}'; }
edit() { jq -nc --arg f "$1" --arg o "$2" --arg n "$3" --arg d "$REPO" '{tool_name:"Edit",cwd:$d,tool_input:{file_path:$f,old_string:$o,new_string:$n}}'; }
decision() { local out; out=$("$HOOK"); if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi; }
expect() { local want="$1" label="$2" got; got=$(decision); [ "$got" = "$want" ] || { echo "FAIL: $label: expected $want, got $got"; exit 1; }; }
reason_names() { local pattern="$1" label="$2"; "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -q "$pattern" || { echo "FAIL: $label: reason did not name '$pattern'"; exit 1; }; }

# --- package.json -------------------------------------------------------------
printf '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0" }, "devDependencies": { "vitest": "5.0.0" } }\n' > "$REPO/package.json"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0", "zod": "^3.23.0" }, "devDependencies": { "vitest": "5.0.0" } }' | expect ask "Write adding a dependency"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0", "zod": "^3.23.0" }, "devDependencies": { "vitest": "5.0.0" } }' | reason_names 'zod' "added package is named"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0", "zod": "^3.23.0" }, "devDependencies": { "vitest": "5.0.0" } }' | reason_names 'R-331' "reason cites R-331"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.20.0" }, "devDependencies": { "vitest": "5.0.0" } }' | expect allow "Write bumping a version"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0" }, "devDependencies": { "vitest": "5.0.0", "@types/node": "^22" } }' | expect ask "Write adding a devDependency"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run", "lint": "eslint ." }, "dependencies": { "express": "^4.19.0" }, "devDependencies": { "vitest": "5.0.0" } }' | expect allow "Write changing scripts only"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run" }, "dependencies": { "express": "^4.19.0" } }' | expect allow "Write removing a dependency"
edit "$REPO/package.json" '"express": "^4.19.0"' '"express": "^4.19.0", "pino": "^9.0.0"' | expect ask "Edit inserting a dependency"
edit "$REPO/package.json" '"express": "^4.19.0"' '"express": "^4.19.0", "pino": "^9.0.0"' | reason_names 'pino' "Edit-added package is named"
edit "$REPO/package.json" '"express": "^4.19.0"' '"express": "^4.21.0"' | expect allow "Edit changing a version"
write "$REPO/package.json" '{ "name": "fixture", "dependencies": { "express": "^4.19.0", ' | expect allow "unparsable Write fails open"
write "$REPO/apps/server/package.json" '{ "name": "server", "dependencies": { "fastify": "^5" } }' | expect ask "new manifest with dependencies asks"
write "$REPO/apps/server/package.json" '{ "name": "server", "dependencies": {} }' | expect allow "new manifest with no dependencies is silent"

# --- pyproject.toml -----------------------------------------------------------
printf '[project]\nname = "fixture"\ndependencies = ["fastapi>=0.110", "sqlalchemy>=2"]\n\n[project.optional-dependencies]\ndev = ["pytest>=8"]\n' > "$REPO/pyproject.toml"
write "$REPO/pyproject.toml" '[project]
name = "fixture"
dependencies = ["fastapi>=0.110", "sqlalchemy>=2", "httpx>=0.27"]

[project.optional-dependencies]
dev = ["pytest>=8"]
' | expect ask "pyproject adding a project dependency"
write "$REPO/pyproject.toml" '[project]
name = "fixture"
dependencies = ["fastapi>=0.110", "sqlalchemy>=2", "httpx>=0.27"]

[project.optional-dependencies]
dev = ["pytest>=8"]
' | reason_names 'httpx' "pyproject added package is named"
write "$REPO/pyproject.toml" '[project]
name = "fixture"
dependencies = ["fastapi>=0.115", "sqlalchemy>=2"]

[project.optional-dependencies]
dev = ["pytest>=8"]
' | expect allow "pyproject version change"
write "$REPO/pyproject.toml" '[project]
name = "fixture"
dependencies = ["fastapi>=0.110", "sqlalchemy>=2"]

[project.optional-dependencies]
dev = ["pytest>=8", "ruff>=0.5"]
' | expect ask "pyproject adding an optional dependency"
write "$REPO/pyproject.toml" '[tool.poetry.dependencies]
python = "^3.12"
fastapi = "^0.110"
sqlalchemy = "^2"
' | expect allow "poetry table with the same packages (python key ignored)"
write "$REPO/pyproject.toml" '[tool.poetry.dependencies]
python = "^3.12"
fastapi = "^0.110"
sqlalchemy = "^2"
celery = "^5"
' | expect ask "poetry table adding a package"

# --- go.mod -------------------------------------------------------------------
printf 'module example.com/app\n\ngo 1.22\n\nrequire (\n\tgithub.com/go-chi/chi/v5 v5.0.12\n\tgithub.com/jackc/pgx/v5 v5.5.5\n)\n' > "$REPO/go.mod"
write "$REPO/go.mod" 'module example.com/app

go 1.22

require (
	github.com/go-chi/chi/v5 v5.0.12
	github.com/jackc/pgx/v5 v5.5.5
	github.com/rs/zerolog v1.32.0
)
' | expect ask "go.mod adding a require"
write "$REPO/go.mod" 'module example.com/app

go 1.22

require (
	github.com/go-chi/chi/v5 v5.1.0
	github.com/jackc/pgx/v5 v5.5.5
)
' | expect allow "go.mod version bump"
write "$REPO/go.mod" 'module example.com/app

go 1.22

require (
	github.com/go-chi/chi/v5 v5.0.12
	github.com/jackc/pgx/v5 v5.5.5
	golang.org/x/text v0.14.0 // indirect
)
' | expect allow "go.mod indirect require is tidy output, not a choice"

# --- Gemfile ------------------------------------------------------------------
printf 'source "https://rubygems.org"\n\ngem "rails", "~> 7.1"\ngem "pg"\n' > "$REPO/Gemfile"
write "$REPO/Gemfile" 'source "https://rubygems.org"

gem "rails", "~> 7.1"
gem "pg"
gem "sidekiq"
' | expect ask "Gemfile adding a gem"
write "$REPO/Gemfile" "source \"https://rubygems.org\"

gem 'rails', '~> 7.2'
gem 'pg'
" | expect allow "Gemfile version change with quote style change"

# --- out of scope -------------------------------------------------------------
write "$REPO/src/services/score.ts" 'import zod from "zod";' | expect allow "source file is not a manifest"
write "$REPO/package-lock.json" '{ "packages": { "node_modules/zod": {} } }' | expect allow "lockfiles are not judged"
jq -nc '{tool_name:"Read",tool_input:{file_path:"/x/package.json"}}' | expect allow "Read is never gated"

rm -rf "$REPO"
echo "dependency-add-guard.test.sh PASS"
