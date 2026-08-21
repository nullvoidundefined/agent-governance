#!/usr/bin/env bash
# content-gate.sh: deterministic content checks on the text a Write or Edit is
# about to introduce. Companion to structure-gate.sh, which checks the path.
# Three rules, one hook, one process spawn per edit:
#   R-401  no suppressed tests (.skip/.only/xit/pytest.mark.skip/t.Skip)
#   R-405  no weakening of a protection to make a failure pass (TLS, CORS, CSP,
#          bcrypt rounds); R-204 is the same move seen from the other side
#   R-302  no relative import escaping the repository root (projects are
#          independent repos; shared code ships as a versioned package)
# Per-edit, no Node spawn. Every check reads only the added text, so existing
# violations stay editable and only newly written ones are denied.
set -euo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write | Edit) ;; *) exit 0 ;; esac
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0
ADDED=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
[ -z "$ADDED" ] && exit 0

deny() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "content-gate" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Only source files carry these constructs. Shell, markdown, and config files
# (including this repo's own fixture tests, which quote the banned patterns as
# data) never reach a check.
case "$FILE" in
  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.py | *.rb | *.go) ;;
  *) exit 0 ;;
esac

BASE=$(basename "$FILE")
is_test=0
case "$BASE" in *.test.* | *.spec.* | test_*.py | *_test.py | *_spec.rb | *_test.go | conftest.py) is_test=1 ;; esac
case "$FILE" in */__tests__/* | */tests/* | */spec/* | */e2e/*) is_test=1 ;; esac

# R-401: a skipped or exclusive test is a test that cannot fail, which is the
# state the rule exists to prevent. Two shapes, two treatments. An exclusive
# test silences every other test in the file and has no legitimate committed
# form, so it is denied outright. A skip carries the rule's own carve-out
# (anti-pattern 8): a skip line naming a triage ID is a tracked deferral and
# passes; a bare one is the suppression the rule forbids.
if [ "$is_test" -eq 1 ]; then
  if printf '%s' "$ADDED" | grep -qE '\b(it|test|describe|context|suite)\.only\(|\b(fit|fdescribe)\('; then
    deny "This write marks a test exclusive (R-401). '.only' silences every other test in the file, and a committed .only silences them for everyone. Run the single file or the single name from the command line instead."
  fi
  SKIPS=$(printf '%s' "$ADDED" | grep -E '\b(it|test|describe|context|suite)\.(skip|fixme)\(|\b(xit|xtest|xdescribe)\(|@pytest\.mark\.skip\b|\bpytest\.skip\(|\bt\.Skipf?\(|,[[:space:]]*skip:[[:space:]]*true' || true)
  if [ -n "$SKIPS" ]; then
    UNTRACKED=$(printf '%s' "$SKIPS" | grep -vE '[A-Z][A-Z0-9]+-[0-9]+' || true)
    if [ -n "$UNTRACKED" ]; then
      deny "This write adds a skipped test with no triage ID (R-401). A test that cannot fail protects nothing: fix it, or delete it and re-add it when the capability exists. If the deferral is real, name the triage ID on the skip line so it is tracked rather than parked."
    fi
  fi
fi

# R-405: never weaken the protection that surfaced the failure. Test trees are
# exempt: a self-signed fixture server is a legitimate reason to relax TLS
# inside a test, and the rule is about production protections.
if [ "$is_test" -eq 0 ]; then
  QUOTE="['\"]"
  WEAKENING=$(printf '%s' "$ADDED" | grep -oE "rejectUnauthorized[[:space:]]*:[[:space:]]*false|NODE_TLS_REJECT_UNAUTHORIZED[[:space:]]*[=:][[:space:]]*$QUOTE?0|strictSSL[[:space:]]*:[[:space:]]*false|InsecureSkipVerify[[:space:]]*:[[:space:]]*true|verify[[:space:]]*=[[:space:]]*False|contentSecurityPolicy[[:space:]]*:[[:space:]]*false|csrf[A-Za-z]*[[:space:]]*:[[:space:]]*false|origin[[:space:]]*:[[:space:]]*$QUOTE\*$QUOTE|Access-Control-Allow-Origin$QUOTE?[[:space:]]*[:,][[:space:]]*$QUOTE\*$QUOTE" | head -1 || true)
  if [ -n "$WEAKENING" ]; then
    deny "This write weakens a protection ('$WEAKENING') rather than fixing what it caught (R-405/R-204). TLS verification, CORS origins, CSP, and CSRF are the gates that surface the real failure; disabling one converts a caught bug into a shipped one. Fix the certificate, the origin list, or the policy instead."
  fi
  ROUNDS=$(printf '%s' "$ADDED" | grep -oE 'bcrypt\.(hash|hashSync|genSalt|genSaltSync)\([^)]*,[[:space:]]*[0-9]\)|(SALT_ROUNDS|saltRounds|BCRYPT_ROUNDS)[[:space:]]*[=:][[:space:]]*[0-9][^0-9]' | head -1 || true)
  if [ -n "$ROUNDS" ]; then
    deny "This write sets a single-digit bcrypt cost factor ('$ROUNDS'), below the 10 minimum (R-405). Slow hashing is the protection; lowering the factor to speed a test or a login path is the weakening the rule names. Keep 10 or higher and make the test seed its fixtures directly."
  fi
fi

# R-302: each project is an independent git repo. A relative import climbing
# above the repository root reaches into a sibling checkout, which breaks the
# moment either repo moves. Shared code publishes as a versioned package.
case "$FILE" in
  *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs)
    dir="$(dirname "$FILE")"
    while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do dir="$(dirname "$dir")"; done
    TOP=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
    RELATIVE_DIR="${FILE#"$TOP"/}"
    RELATIVE_DIR=$(dirname "$RELATIVE_DIR")
    depth=0
    [ "$RELATIVE_DIR" != "." ] && depth=$(printf '%s' "$RELATIVE_DIR" | awk -F/ '{print NF}')
    while IFS= read -r specifier; do
      [ -z "$specifier" ] && continue
      climbs=$(printf '%s' "$specifier" | grep -oE '\.\./' | wc -l | tr -d ' ')
      if [ "$climbs" -gt "$depth" ]; then
        deny "The import '$specifier' climbs $climbs levels from a file $depth levels below the repository root, so it resolves outside this repo (R-302). Projects are independent git repos: publish the shared code as a versioned package and depend on it by name."
      fi
    done < <(printf '%s' "$ADDED" | grep -oE "['\"](\.\./)+[^'\"]*['\"]" | tr -d "'\"" || true)
    ;;
esac
exit 0
