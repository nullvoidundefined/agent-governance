#!/usr/bin/env bash
# destructive-ops-guard: read-only docker, podman, nerdctl and compose commands
# run; every other subcommand asks, through wrappers and absolute paths. A
# delete of the repository root itself is denied.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)/destructive-ops-guard.sh"
REPO=$(mktemp -d); trap 'rm -rf "$REPO"' EXIT
REPO=$(cd "$REPO" && pwd -P); git -C "$REPO" init -q
fail=0
decision() {
  jq -n --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | (cd "$REPO" && bash "$HOOK") |
    jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null | grep . || echo none
}
expect() {
  got=$(decision "$2")
  if [ "$got" = "$1" ]; then echo "PASS: $1 for: $2"; else echo "FAIL: expected $1, got $got for: $2"; fail=1; fi
}
for c in "docker ps -a" "docker logs web" "docker compose ps" "docker --context prod ps" "docker container ls" "docker-compose logs" "podman images"; do
  expect none "$c"
done
for c in "docker rm -f web" 'docker rm -f $(docker ps -aq)' "docker system prune -af" "sudo docker volume rm data" \
  "/usr/local/bin/docker kill web" "bash -c 'docker rm -f web'" "docker-compose down -v" "docker compose down" \
  "podman rmi x" "nerdctl rm -f x" "docker image prune"; do
  expect ask "$c"
done
expect deny "rm -rf ."
expect deny "rm -rf $REPO"
expect deny "rm -rf ./"
expect ask "rm -rf build"
expect none "rm notes.txt"
[ "$fail" -eq 0 ] && echo "PASS: destructive-ops-guard-docker"
exit "$fail"
