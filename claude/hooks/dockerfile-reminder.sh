#!/usr/bin/env bash
# dockerfile-reminder.sh: PostToolUse(Write|Edit) advisory for R-351, the rule
# that every deployable artifact is Dockerized from its first commit. Three
# checks, all project-shape questions no linter can see from one file:
#   1. An artifact marker is written (a service or worker entry file, a
#      package.json with a start script, a frontend framework config, or a
#      platform deploy config) and no Dockerfile exists between that file's
#      directory and the repo root.
#   2. A Dockerfile exists on that path but no .dockerignore sits beside it.
#   3. The written file IS a Dockerfile and it never switches to a non-root
#      USER, or a FROM pulls an unpinned image (no tag, or :latest).
# Reads the written file from disk, matches by path and cheap regexes, and
# emits a non-blocking reminder (additionalContext). Every check is a
# heuristic, so this never blocks; the compose file, the CI image build, and
# the platform wiring stay manual. Silent for tests, fixtures, vendored trees,
# build output, and library packages (a package.json with no start script).
file_path=$(jq -rc '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
  *.test.* | *.spec.* | *__tests__* | *__fixtures__* | */tests/* | */fixtures/* | */test_* | *_test.py | *_test.go | */spec/* | *_spec.rb | */vendor/* | */node_modules/* | */dist/* | */build/* | */.git/*) exit 0 ;;
esac

base=$(basename "$file_path")
dir=$(dirname "$file_path")
content=$(cat "$file_path" 2>/dev/null) || exit 0
reminders=""
add() { reminders="${reminders}- $1"$'\n'; }

# Walk from the file's directory to the repo root (the first directory holding
# .git) and print the first directory that carries an image definition.
find_dockerfile_dir() {
  local current="$1" candidate
  while :; do
    for candidate in "$current"/Dockerfile "$current"/Dockerfile.* "$current"/*.Dockerfile "$current"/Containerfile; do
      [ -f "$candidate" ] && { printf '%s' "$current"; return 0; }
    done
    [ -e "$current/.git" ] && return 1
    [ "$current" = "/" ] && return 1
    current=$(dirname "$current")
  done
}

# Check 3: the written file is a Dockerfile.
is_dockerfile=0
case "$base" in Dockerfile | Dockerfile.* | *.Dockerfile | Containerfile) is_dockerfile=1 ;; esac
if [ "$is_dockerfile" -eq 1 ]; then
  if ! printf '%s\n' "$content" | grep -qiE '^[[:space:]]*USER[[:space:]]+[^[:space:]]'; then
    add "R-351: this Dockerfile never switches to a non-root user. Add \`USER node\` (or \`USER app\`) after the runtime stage's COPY lines."
  fi
  stage_names=$(printf '%s\n' "$content" | grep -ioE '^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+[A-Za-z0-9_.-]+' | awk '{print tolower($NF)}' | sort -u)
  unpinned=$(printf '%s\n' "$content" | grep -iE '^[[:space:]]*FROM[[:space:]]' | sed -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+//; s/--platform=[^[:space:]]+[[:space:]]+//' | awk '{print $1}' | while IFS= read -r image; do
    [ -z "$image" ] && continue
    lowered=$(printf '%s' "$image" | tr 'A-Z' 'a-z')
    [ "$lowered" = "scratch" ] && continue
    printf '%s\n' "$stage_names" | grep -qxF "$lowered" && continue
    case "$image" in
      *@sha256:*) continue ;;
      *:latest) printf '%s ' "$image" ;;
      */*:*) continue ;;
      *:*) continue ;;
      *) printf '%s ' "$image" ;;
    esac
  done)
  if [ -n "$unpinned" ]; then
    add "R-351: unpinned base image (${unpinned% }). Pin every FROM to a version tag (\`node:22-alpine\`, \`python:3.13-slim\`), never \`latest\` and never an untagged image."
  fi
  [ -f "$dir/.dockerignore" ] || add "R-351: no \`.dockerignore\` beside this Dockerfile. Add one excluding \`.git\`, \`node_modules\`, \`dist\`, \`.env*\`, and the test trees, so no secret or build cache enters the image."
fi

# Checks 1 and 2: the written file marks a deployable artifact.
artifact=""
if [ "$is_dockerfile" -eq 0 ]; then
  case "$file_path" in
    */apps/server/src/index.ts | */apps/server/src/app.ts | */apps/server/src/server.ts | */apps/server/src/main.ts | \
    */server/src/index.ts | */server/src/app.ts | */server/src/server.ts | */server/src/main.ts | \
    */packages/worker/src/index.ts | */packages/worker/src/workers.ts | */packages/worker/src/main.ts | \
    */apps/worker/src/index.ts | */apps/worker/src/workers.ts | */apps/worker/src/main.ts | */src/workers/index.ts)
      artifact="service entry file" ;;
    */main.py | */app.py | */manage.py | */wsgi.py | */asgi.py | */main.go | */config.ru)
      artifact="service entry file" ;;
    */next.config.js | */next.config.mjs | */next.config.ts | */vite.config.js | */vite.config.mjs | */vite.config.ts)
      artifact="frontend build config" ;;
    */railway.toml | */railway.json | */fly.toml | */render.yaml | */Procfile | */app.yaml | */nixpacks.toml)
      artifact="platform deploy config" ;;
    */package.json)
      printf '%s\n' "$content" | grep -qE '"start"[[:space:]]*:' && artifact="package.json with a start script" ;;
  esac
fi

if [ -n "$artifact" ]; then
  if dockerfile_dir=$(find_dockerfile_dir "$dir"); then
    [ -f "$dockerfile_dir/.dockerignore" ] || add "R-351: \`$dockerfile_dir\` carries a Dockerfile but no \`.dockerignore\`. Add one excluding \`.git\`, \`node_modules\`, \`dist\`, \`.env*\`, and the test trees."
  else
    add "R-351: this $artifact marks a deployable artifact and no Dockerfile exists between \`$dir\` and the repo root. Add a multi-stage \`Dockerfile\` (pinned base image, non-root USER, HEALTHCHECK on /health), a \`.dockerignore\`, and a \`docker-compose.yml\` entry in the same commit; the image is the deploy unit."
  fi
fi

[ -z "$reminders" ] && exit 0
jq -n --arg f "$file_path" --arg r "$reminders" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Dockerization reminder for " + $f + " (advisory; R-351 is a project-shape check no linter can make):\n" + $r + "Pattern in ~/.claude/CLAUDE-BACKEND.md under Containers. If the file is a library or otherwise not a deployable artifact, say so and move on.")
  }
}'
exit 0
