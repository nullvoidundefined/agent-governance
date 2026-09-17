#!/usr/bin/env bash
# secret-scan.sh
#
# PreToolUse hook for the Bash, Write, and Edit tools. Scans the command about
# to be executed AND any file payload about to be written (.tool_input.content
# for Write, .tool_input.new_string for Edit) for plaintext secret patterns,
# and blocks the call if any match. Also blocks Write/Edit calls that target a
# protected credential path directly (R-103), mirroring the Bash mutation guard.
#
# Why this exists: On 2026-04-08, a plaintext Anthropic production key was
# passed on the command line via `railway variables --set ...`. The value
# leaked to shell history, the tool-call transcript, the permission prompt
# UI, and process argv. The user's rule: this must never happen again.
#
# How it works: Claude Code feeds hook stdin as JSON with shape
# { "tool_name": "Bash", "tool_input": { "command": "..." } }. This script
# extracts .tool_input.command, scans it with grep -E for known secret
# patterns, and if any match emits a JSON deny response on stdout. The hook
# always exits 0; the JSON on stdout is what controls the tool decision.
#
# No match: script emits nothing and exits 0 (tool proceeds as normal).
# Match: script emits a hookSpecificOutput with permissionDecision=deny
# and an explanatory permissionDecisionReason, then exits 0.
#
# Patterns block full-length secret strings only. Placeholders like
# `sk-ant-api03-...` (ellipsis) or `whsec_REDACTED` stay under the length
# thresholds and do not trigger a false positive.
#
# To test manually:
#   echo '{"tool_input":{"command":"echo sk-ant-api03-'$(printf 'A%.0s' $(seq 1 54))'"}}' | ~/.claude/hooks/secret-scan.sh
# Should print JSON with permissionDecision=deny.
#
#   echo '{"tool_input":{"command":"ls -la"}}' | ~/.claude/hooks/secret-scan.sh
# Should print nothing and exit 0.

# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
# Write/Edit payloads are a persistence-to-disk vector for the same secret
# classes as argv, so the pattern scan covers all three fields (P1-1).
SCAN_TEXT=$(printf '%s' "$INPUT" | jq -r '(.tool_input.command // "") + "\n" + (.tool_input.content // "") + "\n" + (.tool_input.new_string // "")')

# Patterns use basic POSIX ERE (grep -E), no PCRE features.
# Each subpattern requires enough trailing characters to exclude placeholders
# and discussion references like "sk-ant-api03-..." or "whsec_REDACTED".
PATTERN='sk-ant-api03-[A-Za-z0-9_-]{50,}'
PATTERN+='|whsec_[A-Za-z0-9]{20,}'
PATTERN+='|sk_live_[A-Za-z0-9]{20,}'
PATTERN+='|sk_test_[A-Za-z0-9]{20,}'
PATTERN+='|rk_live_[A-Za-z0-9]{20,}'
PATTERN+='|rk_test_[A-Za-z0-9]{20,}'
PATTERN+='|ghp_[A-Za-z0-9]{30,}'
PATTERN+='|gho_[A-Za-z0-9]{30,}'
PATTERN+='|ghs_[A-Za-z0-9]{30,}'
PATTERN+='|ghu_[A-Za-z0-9]{30,}'
PATTERN+='|vcp_[A-Za-z0-9]{20,}'
PATTERN+='|\bre_[A-Za-z0-9_-]{30,}'
PATTERN+='|rnd_[A-Za-z0-9]{20,}'
PATTERN+='|xoxb-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxp-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxa-[A-Za-z0-9-]{40,}'
PATTERN+='|xoxs-[A-Za-z0-9-]{40,}'
PATTERN+='|AKIA[0-9A-Z]{16}'
PATTERN+='|ASIA[0-9A-Z]{16}'
PATTERN+='|SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{40,}'
PATTERN+='|-----BEGIN [A-Z ]*PRIVATE KEY-----'
PATTERN+='|\bAIza[0-9A-Za-z_-]{35}'

if printf '%s' "$SCAN_TEXT" | grep -qE "$PATTERN"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "secret-scan hook BLOCKED this tool call: the command or file payload contains a string matching a known secret pattern (API key, webhook secret, AWS access key, SendGrid key, GitHub token, SSH private key, or similar). Never pass secrets as command-line arguments. The argv is persisted to shell history, Claude Code transcripts, the permission-prompt UI, and process argument space. Correct patterns: (1) set the value via the vendor dashboard yourself, no CLI involvement; (2) load the value from a file outside the repo via an env var that is resolved at execution time so the plaintext never appears in the command string; (3) use a stdin-fed CLI mode if the vendor supports it."
    }
  }'
  exit 0
fi

# R-108: a credential-shaped literal is a finding even when it is fake.
# Secret scanners (GitGuardian on every PR of a public repository) flag the
# shape, not the validity: a fixture's fake `postgres://user:<password>@host`
# URI, with a made-up word in the placeholder's place, went red on 2026-09-17
# exactly as a real one would, and the branch had to be rewritten. Two shapes are denied in any Write or Edit payload and on
# argv: a URI whose userinfo carries a password, and a password/secret/token
# assignment carrying a literal value. A placeholder shape passes: a value
# that starts with `$`, `<`, `%`, or `{` (an env reference, an angle-bracket
# placeholder, a printf slot, a template), or that is one of the words
# scanners already discount (password, changeme, placeholder, example,
# redacted, dummy, xxx...). The fix is never a different fake: build the
# value at run time from parts (`printf '%s://%s:%s@%s'`), or write the
# placeholder.
PLACEHOLDER_VALUE='^([$<%{]|(password|passwd|changeme|placeholder|example|redacted|dummy|fake|secret|x+|\*+|\.\.\.)$)'
URI_WITH_PASSWORD='[a-z][a-z0-9+.-]*://[^/[:space:]:@"'"'"']+:[^@[:space:]"'"'"']+@'
credential_shape_hit() {
  local text="$1" match value
  # URI userinfo passwords: keep the password segment and test it for a
  # placeholder shape.
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    value=${match#*://}; value=${value#*:}; value=${value%@}
    printf '%s' "$value" | grep -qiE "$PLACEHOLDER_VALUE" || { printf 'a URI carrying a password (%s)' "${match%%:*}://user:...@"; return 0; }
  done < <(printf '%s' "$text" | grep -oE "$URI_WITH_PASSWORD" || true)
  # password/secret/token assignments with a literal value of six or more
  # characters: quoted, or a bare token of literal-looking characters that
  # ends at a delimiter (so `os.environ["DB_PASSWORD"]`, `getToken()`, and
  # `process.env.SESSION_SECRET!`, which continue into `[`, `(`, or `.`, are
  # code, not literals).
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    value=$(printf '%s' "$match" | sed -E 's/^[^=:]*[=:][[:space:]]*//; s/[[:space:],;)}]$//; s/^["'"'"']//; s/["'"'"']$//')
    printf '%s' "$value" | grep -qiE "$PLACEHOLDER_VALUE" || { printf 'a %s assignment with a literal value' "$(printf '%s' "$match" | grep -oiE '^[a-z_-]+')"; return 0; }
  done < <(printf '%s' "$text" | grep -oiE '(^|[^a-z_])(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|token)[[:space:]]*[=:][[:space:]]*("[^"[:space:]]{6,}"|'"'"'[^'"'"'[:space:]]{6,}'"'"'|[A-Za-z0-9_+/=!#-]{6,})([[:space:],;)}]|$)' | sed -E 's/^[^a-zA-Z_]//' || true)
  return 1
}
if HIT=$(credential_shape_hit "$SCAN_TEXT"); then
  jq -n --arg hit "$HIT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("secret-scan hook BLOCKED this tool call (R-108): it writes " + $hit + ", a credential-shaped literal. Secret scanners flag the shape whether or not the value is real, so a fake one still turns the PR red and forces a history rewrite. Build the value at run time from parts (printf with %s slots, a variable assembled in the fixture) or write a placeholder (<password>, ${DB_PASSWORD}, changeme); never a different-looking fake.")
    }
  }'
  exit 0
fi

# R-103: credential files are read-only. Block any command that creates,
# overwrites, appends to, moves, deletes, or edits a protected path
# (.env, .env.*, ~/.aws, ~/.ssh, ~/.gnupg, ~/.config/gh/hosts.yml).
# Throwaway fixtures under /tmp are exempt per the rule's Spec, so /tmp
# paths are stripped before scanning.
SAFE_CMD=$(printf '%s' "$CMD" | sed -E 's#(/private)?/tmp/[^[:space:]"'"'"']*##g')

HOMEDIRS='(~|\$HOME|/Users/[A-Za-z0-9._-]+)'
PROT="$HOMEDIRS/\.(aws|ssh|gnupg)(/[^[:space:]\"';|&]*)?"
PROT+="|$HOMEDIRS/\.config/gh/hosts\.yml"
PROT+="|(^|[[:space:]\"'=/])\.env(\.[A-Za-z0-9_-]+)?([[:space:]\"';|&]|$)"

# In-place editors are spelled several ways and the pattern used to match only
# one of them: `sed -i` as a bare token. That missed `sed -i.bak` (the portable
# spelling this repo's own fixtures use, which is how the gap stayed invisible),
# `sed --in-place`, and perl's `-i`/`-pi` entirely (2026-09-17 audit P2-6).
# `-[a-zA-Z]*i[a-zA-Z.]*` now also admits a suffix, `--in-place` is named, and
# perl is only a mutation when an in-place flag is present, so `perl -ne` stays
# a read.
SED_IN_PLACE='sed[[:space:]]+(-[a-zA-Z]*i[a-zA-Z.]*|--in-place(=[^[:space:]]*)?)'
PERL_IN_PLACE='perl[[:space:]]+([^[:space:]]+[[:space:]]+)*-[a-zA-Z]*i[a-zA-Z.]*'
MUTATE_VERBS="(rm|mv|cp|tee|shred|truncate|unlink|$SED_IN_PLACE|$PERL_IN_PLACE)"
MUTATION="(^|[;&|][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?$MUTATE_VERBS([[:space:]]+-[^[:space:]]+)*([[:space:]][^;|&]*)?($PROT)"
# The redirect target may carry a directory prefix: `> server/.env` is the same
# mutation as `> .env`, and PROT's .env branch opens with a single character
# class (which does include `/`), so without somewhere for the prefix to go the
# pattern could only ever match a credential file at the top level. The prefix
# run stops at whitespace, another redirect, and the command separators, so it
# cannot reach across into the next command (2026-09-17 audit P1-3; the
# Write/Edit branch below always handled nesting, which is what made the Bash
# branch's gap a discrepancy rather than a policy).
REDIRECT=">>?[[:space:]]*[^[:space:]>;|&]*($PROT)"

if printf '%s' "$SAFE_CMD" | grep -qE "$MUTATION" || printf '%s' "$SAFE_CMD" | grep -qE "$REDIRECT"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "secret-scan hook BLOCKED this command: it mutates a protected credential file (R-103). .env files, ~/.aws, ~/.ssh, ~/.gnupg, and gh hosts.yml are read-only; never create, overwrite, append to, move, or delete them. If a check needs an env-file fixture, write it to a uniquely named throwaway path under /tmp and clean that up instead. If the user explicitly directed this specific change, ask them to run the command themselves."
    }
  }'
  exit 0
fi

# R-103 (Write/Edit surface): a Write or Edit targeting a protected credential
# path is a mutation too; the Bash guard above only sees argv. /tmp fixture
# paths stay exempt per the rule's Spec.
if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
  case "$FILE" in
    /tmp/* | /private/tmp/*) ;;
    *)
      PROT_BASENAME='(^|/)\.env(\.[A-Za-z0-9_-]+)?$'
      PROT_DIR='/\.(aws|ssh|gnupg)(/|$)|/\.config/gh/hosts\.yml$'
      if printf '%s' "$FILE" | grep -qE "$PROT_BASENAME" || printf '%s' "$FILE" | grep -qE "$PROT_DIR"; then
        jq -n '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "secret-scan hook BLOCKED this file operation: it writes to a protected credential path (R-103). .env files, ~/.aws, ~/.ssh, ~/.gnupg, and gh hosts.yml are read-only; never create, overwrite, or edit them directly. If a check needs an env-file fixture, write it to a uniquely named throwaway path under /tmp and clean that up instead. If the user explicitly directed this specific change, ask them to apply it themselves."
          }
        }'
      fi ;;
  esac
fi

exit 0
