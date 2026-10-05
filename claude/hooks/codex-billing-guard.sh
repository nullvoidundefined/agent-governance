#!/usr/bin/env bash
# codex-billing-guard.sh: PreToolUse(Bash) hook backing R-908. An opted-in slice dispatches
# test-writing to the `codex` CLI under the ChatGPT subscription; this warns
# before any `codex` invocation that would instead bill the metered OpenAI API,
# so that switch never happens silently. Two things flip billing: an
# OPENAI_API_KEY the codex CLI can see (inline in the command, exported earlier
# in the same command, or already present in the calling environment) and a
# `codex login --with-api-key`/`--with-access-token` re-auth. Absent either,
# the live `codex login status` is the authority. Asks, never blocks: API
# billing may be a deliberate choice, but never an accidental one.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# Only commands that actually invoke the codex CLI matter here. A command that
# merely names codex (git diff -- codex, grep codex, echo codex) does not. The
# decision is per simple command, from the parse shell-command-segments.py
# produces (it unwraps bash -c, eval, env, sudo, xargs, and reduces a program
# path to its basename), so bash -c 'codex ...' and /usr/local/bin/codex count.
# A package runner launching codex (npx, bunx, pnpm dlx/exec, yarn dlx, npm
# exec, by name or as @openai/codex, with or without -p) and node running a
# codex script count too. Variable or alias indirection ($CODEX exec, an
# alias) is a known limit: the command is not run to find out. When the parser is unusable, fall back to asking whenever the
# text mentions codex at all: a missed billing switch costs more than an extra
# confirmation.
case "$cmd" in *codex*) ;; *) exit 0 ;; esac

# package_program <word>: the program a package spec names: a leading @scope
# and a trailing @version are dropped (@openai/codex@latest -> codex).
package_program() {
  local spec="${1#@}"
  spec="${spec%@*}"
  printf '%s' "${spec##*/}"
}

# launched_package <words...>: prints the program a package runner launches,
# skipping the runner's own options (a -p/--package value counts as what it
# launches); empty when the words are not a package runner. node <path> counts
# as running the script at <path>.
launched_package() {
  local program="$1" word package=""
  shift
  case "$program" in
    node)
      for word in "$@"; do
        case "$word" in -*) continue ;; *) printf '%s' "${word##*/}"; return 0 ;; esac
      done
      return 0 ;;
    npx | bunx | pnpx) ;;
    pnpm | yarn | npm)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --prefix | --dir | -C | --workspace | -w | --filter | --cwd) shift; [ "$#" -gt 0 ] && shift ;;
          -*) shift ;;
          dlx | exec | x) shift; break ;;
          *) return 0 ;;
        esac
      done ;;
    *) return 0 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --) shift ;;
      -p | --package) shift; [ "$#" -gt 0 ] && package="$(package_program "$1")" && shift ;;
      --package=*) package="$(package_program "${1#--package=}")"; shift ;;
      -c | --call) return 0 ;;
      -*) shift ;;
      *)
        [ "$package" = codex ] && { printf codex; return 0; }
        package_program "$1"; return 0 ;;
    esac
  done
  printf '%s' "$package"
}

# invokes_codex: true when any simple command runs the codex CLI.
invokes_codex() {
  local segments words index program helper
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-command-segments.py"
  segments="$(python3 "$helper" <<< "$cmd" 2>/dev/null)" && [ -n "$segments" ] || return 0
  while IFS=$'\037' read -r -a words; do
    index=0
    while [ "$index" -lt "${#words[@]}" ] && [[ "${words[index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      index=$((index + 1))
    done
    program="${words[index]:-}"
    program="${program##*/}"
    [ "$program" = codex ] && return 0
    [ "$(launched_package "$program" "${words[@]:index+1}")" = codex ] && return 0
  done <<< "$segments"
  return 1
}
invokes_codex || exit 0

emit() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

if grep -Eq 'codex login[^;&|]*--with-(api-key|access-token)' <<< "$cmd"; then
  emit "codex-billing-guard: this command runs 'codex login --with-api-key' or '--with-access-token', switching the codex CLI from the ChatGPT subscription to metered API billing (R-908). Confirm this is deliberate."
fi

if grep -Eq '(^|[;&|[:space:]])(export[[:space:]]+)?OPENAI_API_KEY=' <<< "$cmd"; then
  emit "codex-billing-guard: this command sets OPENAI_API_KEY, which the codex CLI prefers over the stored ChatGPT login and switches usage to metered API billing (R-908). Confirm this is deliberate, or drop it to stay on the subscription."
fi

if [ -n "${OPENAI_API_KEY:-}" ]; then
  emit "codex-billing-guard: OPENAI_API_KEY is set in the environment this command inherits, which the codex CLI prefers over the stored ChatGPT login and switches usage to metered API billing (R-908). Confirm this is deliberate, or unset OPENAI_API_KEY to stay on the subscription."
fi

status="$(${CLAUDE_CODEX_CMD:-codex} login status 2>&1 || true)"
if ! grep -qi 'Logged in using ChatGPT' <<< "$status"; then
  emit "codex-billing-guard: 'codex login status' does not report ChatGPT auth (got: '${status:-empty}'). Running codex now likely bills the OpenAI API instead of the ChatGPT subscription (R-908). Confirm before proceeding, or run 'codex login' to reauthenticate with ChatGPT."
fi

exit 0
