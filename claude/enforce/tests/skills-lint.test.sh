#!/usr/bin/env bash
# skills-lint.test.sh: closure and hygiene of the user-authored skills under
# skills/*/SKILL.md (2026-09-17 skills audit, finding X-2). Every property here
# was checked by hand for that audit and none had a guard, so any of them could
# regress silently. The lint is a function run twice: over the real tree, which
# must pass, and over a sandbox carrying one deliberately broken skill, which
# must fail on every property, so the test proves the checks fire rather than
# proving the tree happens to be clean.
#
# Properties (one FAIL line each):
#   1. frontmatter opens the file, closes, carries name == directory and a
#      non-empty description; description plus when_to_use stays under the
#      1,536-character listing truncation.
#   2. every `~/.claude/<path>` a skill cites exists, or is gitignored by design
#      (the skill is expected to say so; known-issues does).
#   3. every R-NNN a skill cites has a Spec block in one of the four rulebook
#      files (the 2026-07-31 P3 "no ID-closure guard for R-7xx/8xx/9xx").
#   4. no U+2014 (R-207); the hook catches a Write, not a merge or a port.
#   5. every superpowers:<name> is one the README's plugin line lists.
#   6. every docs/<path> a skill writes to or reads from is one of the canonical
#      locations, spelled the same way everywhere.
#   7. structure-conventions: the rule ids its description advertises are the
#      rule ids its body carries.
#   8. cursor/skills/<name>/SKILL.md, when a cursor tree is reachable, equals
#      its source with the provenance comment line removed (audit X-1).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
REAL_CLAUDE="${CLAUDE_SKILLS_CLAUDE_DIR:-$CLAUDE_HARNESS_ROOT}"
# The cursor tree sits beside claude/ in the monorepo. CI symlinks the
# checkout's claude/ at ~/.claude, so the symlink's parent is the repo root;
# a synced (copied) ~/.claude carries the stamp sync.sh writes instead.
resolve_repo_root() {
  local claude_dir="$1"
  if [ -n "${CLAUDE_SKILLS_REPO_ROOT:-}" ]; then printf '%s' "$CLAUDE_SKILLS_REPO_ROOT"; return; fi
  if [ -f "$claude_dir/.sync-source" ]; then cat "$claude_dir/.sync-source"; return; fi
  dirname "$(readlink -f "$claude_dir")"
}

CANONICAL_DOCS_PATHS='docs/audits/
docs/superpowers/specs/
docs/superpowers/plans/
docs/superpowers/backlog.md
docs/slices/
docs/feature-list/features.md
docs/user-stories/
docs/query-params.md
docs/stack.md
docs/observability.md
docs/session-handoff/session-handoff.md
docs/spec.md
docs/lexicon.md'

MAX_DESCRIPTION=1536

# lint_skills <claude_dir> <repo_root>: prints one "FAIL: ..." line per
# violation and returns 1 when any fired.
lint_skills() {
  local claude_dir="$1" repo_root="$2" failed=0
  local skills_dir="$claude_dir/skills" rulebook="$claude_dir/rulebook"
  local rule_ids allowed_superpowers
  rule_ids=$(cat "$rulebook"/reference.md "$rulebook"/agents.md "$rulebook"/audits.md "$rulebook"/cost.md 2>/dev/null \
    | grep -oE '^R-[0-9]{3}( \[[a-z]+\])?:' | grep -oE 'R-[0-9]{3}' | sort -u)
  allowed_superpowers=$(grep -E '^- `superpowers`:' "$claude_dir/README.md" 2>/dev/null | grep -oE '`[a-z-]+`' | tr -d '`' | sort -u)
  local skill name dir body front desc when_to_use
  for skill in "$skills_dir"/*/SKILL.md; do
    [ -e "$skill" ] || continue
    dir=$(basename "$(dirname "$skill")")
    # A live skills directory can also hold skills this repo does not ship
    # (a marketplace or harness-installed skill lands in ~/.claude/skills too).
    # Those are not user-authored content this repo governs, and linting them
    # would make the verdict depend on the machine rather than the checkout,
    # so skip any skill with no counterpart in the repo's own skills tree.
    if [ -d "$repo_root/claude/skills" ] && [ ! -e "$repo_root/claude/skills/$dir/SKILL.md" ]; then
      continue
    fi
    # 1. frontmatter
    if [ "$(head -1 "$skill")" != "---" ]; then
      echo "FAIL: $dir: SKILL.md does not open with a frontmatter block"; failed=1; continue
    fi
    local end
    end=$(awk 'NR>1 && /^---$/ {print NR; exit}' "$skill")
    if [ -z "$end" ]; then
      echo "FAIL: $dir: frontmatter never closes"; failed=1; continue
    fi
    front=$(sed -n "2,$((end-1))p" "$skill")
    body=$(tail -n +"$((end+1))" "$skill")
    name=$(printf '%s\n' "$front" | sed -nE 's/^name:[[:space:]]*//p' | head -1)
    desc=$(printf '%s\n' "$front" | sed -nE 's/^description:[[:space:]]*//p' | head -1)
    when_to_use=$(printf '%s\n' "$front" | sed -nE 's/^when_to_use:[[:space:]]*//p' | head -1)
    [ "$name" = "$dir" ] || { echo "FAIL: $dir: frontmatter name '$name' is not the directory name"; failed=1; }
    [ -n "$desc" ] || { echo "FAIL: $dir: frontmatter has no description"; failed=1; }
    if [ $(( ${#desc} + ${#when_to_use} )) -gt "$MAX_DESCRIPTION" ]; then
      echo "FAIL: $dir: description plus when_to_use is $(( ${#desc} + ${#when_to_use} )) characters; the skill listing truncates at $MAX_DESCRIPTION"; failed=1
    fi
    # 2. tilde paths
    local cited rel
    for cited in $(grep -oE '~/\.claude/[A-Za-z0-9_./-]+' "$skill" | sort -u); do
      rel="${cited#'~/.claude/'}"; rel="${rel%/}"
      if [ ! -e "$claude_dir/$rel" ]; then
        if [ -f "$claude_dir/.gitignore" ] && grep -qxF "$rel" "$claude_dir/.gitignore"; then
          continue   # gitignored by design; the skill is expected to say so
        fi
        echo "FAIL: $dir: cites $cited, which does not exist under the claude tree"; failed=1
      fi
    done
    # 3. rule ids
    local rid
    for rid in $(grep -oE 'R-[0-9]{3}' "$skill" | sort -u); do
      grep -qx "$rid" <<< "$rule_ids" || { echo "FAIL: $dir: cites $rid, which has no Spec block in rulebook/"; failed=1; }
    done
    # 4. em dash
    if grep -q $'\xe2\x80\x94' "$skill"; then
      echo "FAIL: $dir: contains U+2014 (R-207)"; failed=1
    fi
    # 5. superpowers names
    local sp
    for sp in $(grep -oE 'superpowers:[a-z-]+' "$skill" | sed 's/^superpowers://' | sort -u); do
      grep -qx "$sp" <<< "$allowed_superpowers" || { echo "FAIL: $dir: names superpowers:$sp, which README.md's plugin line does not list"; failed=1; }
    done
    # 6. docs paths: a cited path passes when it is a canonical entry, sits
    #    under a canonical directory, or is an ancestor directory of one
    #    (skills say "docs/superpowers/" when they mean both trees under it).
    local dp ok canon
    for dp in $(grep -oE '(^|[^A-Za-z0-9_./-])docs/[A-Za-z0-9_./-]+' "$skill" | sed -E 's/^[^d]*//; s/\.\.\.$//; s#/$##' | sort -u); do
      ok=0
      while IFS= read -r canon; do
        [ -z "$canon" ] && continue
        canon="${canon%/}"
        case "$dp" in "$canon"|"$canon"/*) ok=1 ;; esac
        case "$canon" in "$dp"/*) ok=1 ;; esac
      done <<< "$CANONICAL_DOCS_PATHS"
      [ "$ok" -eq 1 ] || { echo "FAIL: $dir: writes or reads $dp, which is not a canonical docs/ location (see CANONICAL_DOCS_PATHS in skills-lint.test.sh)"; failed=1; }
    done
    # 7. structure-conventions description versus body
    if [ "$dir" = "structure-conventions" ]; then
      local advertised carried
      advertised=$(printf '%s' "$desc" | grep -oE 'R-[0-9]{3}( to R-[0-9]{3})?' | while read -r span; do
        if grep -q ' to ' <<< "$span"; then
          seq "$(printf '%s' "$span" | sed -E 's/^R-([0-9]{3}) to R-([0-9]{3})$/\1/')" "$(printf '%s' "$span" | sed -E 's/^R-([0-9]{3}) to R-([0-9]{3})$/\2/')" | sed 's/^/R-/'
        else printf '%s\n' "$span"; fi
      done | sort -u)
      carried=$(printf '%s\n' "$body" | grep -oE '^R-[0-9]{3}' | sort -u)
      if [ "$advertised" != "$carried" ]; then
        echo "FAIL: $dir: description advertises [$(printf '%s' "$advertised" | tr '\n' ' ')] but the body carries [$(printf '%s' "$carried" | tr '\n' ' ')]"; failed=1
      fi
    fi
    # 8. cursor copy (SKILL.md body, and any scripts/ directory byte for byte);
    #    in a git checkout the copy must also be tracked, since cursor/.gitignore
    #    is an allowlist and an unlisted copy passes here while CI's checkout
    #    lacks it (2026-09-17, ticket-lifecycle).
    local cursor_copy="$repo_root/cursor/skills/$dir/SKILL.md"
    if [ -d "$repo_root/cursor/skills" ]; then
      if [ ! -f "$cursor_copy" ]; then
        echo "FAIL: $dir: no cursor/skills/$dir/SKILL.md copy"; failed=1
      elif ! diff -q "$skill" <(grep -vE '^<!-- (Cloned from|GENERATED by|Hand-ported)' "$cursor_copy") >/dev/null; then
        echo "FAIL: $dir: cursor/skills/$dir/SKILL.md has drifted from claude/skills/$dir/SKILL.md (re-clone it; the provenance comment line is ignored)"; failed=1
      elif git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git -C "$repo_root" ls-files --error-unmatch "cursor/skills/$dir/SKILL.md" >/dev/null 2>&1; then
        echo "FAIL: $dir: cursor/skills/$dir/SKILL.md exists but is not tracked (cursor/.gitignore is an allowlist; add the skill's lines)"; failed=1
      fi
      if [ -d "$skills_dir/$dir/scripts" ] && ! diff -rq "$skills_dir/$dir/scripts" "$repo_root/cursor/skills/$dir/scripts" >/dev/null 2>&1; then
        echo "FAIL: $dir: cursor/skills/$dir/scripts/ differs from claude/skills/$dir/scripts/ (re-copy the directory)"; failed=1
      fi
    fi
  done
  return $failed
}

# --- real tree: must pass ----------------------------------------------------
REAL_ROOT=$(resolve_repo_root "$REAL_CLAUDE")
REAL_OUT=$(lint_skills "$REAL_CLAUDE" "$REAL_ROOT" 2>&1) || {
  printf '%s\n' "$REAL_OUT"
  exit 1
}
[ -d "$REAL_ROOT/cursor/skills" ] && CURSOR_NOTE="cursor copies checked" || CURSOR_NOTE="no cursor tree reachable, copy check skipped"

# --- sandbox: one broken skill, every property must fire ---------------------
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/claude/skills/broken" "$SB/claude/skills/clean" "$SB/claude/rulebook" "$SB/cursor/skills/broken" "$SB/cursor/skills/clean"
printf 'R-001: a rule.\n  Enforcement: manual\n' > "$SB/claude/rulebook/reference.md"
: > "$SB/claude/rulebook/agents.md"; : > "$SB/claude/rulebook/audits.md"; : > "$SB/claude/rulebook/cost.md"
printf -- '- `superpowers`: provides `brainstorming` and `writing-plans`.\n' > "$SB/claude/README.md"
printf 'KNOWN-ISSUES.md\n' > "$SB/claude/.gitignore"
cat > "$SB/claude/skills/clean/SKILL.md" <<'EOF'
---
name: clean
description: A clean skill citing R-001, superpowers:brainstorming, ~/.claude/KNOWN-ISSUES.md, and docs/audits/YYYY-MM-DD-x.md.
---
# Clean
EOF
{ head -4 "$SB/claude/skills/clean/SKILL.md"; echo '<!-- Cloned from claude/skills/clean/SKILL.md. -->'; tail -n +5 "$SB/claude/skills/clean/SKILL.md"; } > "$SB/cursor/skills/clean/SKILL.md"
LONG=$(printf 'x%.0s' $(seq 1 1600))
cat > "$SB/claude/skills/broken/SKILL.md" <<EOF
---
name: wrong-name
description: $LONG
---
# Broken
Cites ~/.claude/enforce/nothing.sh and R-999 and superpowers:nonexistent and docs/elsewhere/file.md.
An em dash: $(printf '\xe2\x80\x94').
EOF
printf -- '---\nname: wrong-name\ndescription: drifted\n---\n<!-- Cloned from claude/skills/broken/SKILL.md. -->\n# Different body\n' > "$SB/cursor/skills/broken/SKILL.md"

SB_OUT=$(lint_skills "$SB/claude" "$SB" 2>&1) && { echo "FAIL: sandbox with a broken skill was reported clean"; exit 1; }
fail=0
expect() { grep -qF "$1" <<< "$SB_OUT" || { echo "FAIL: sandbox did not report: $1"; fail=1; }; }
expect "broken: frontmatter name 'wrong-name' is not the directory name"
expect "broken: description plus when_to_use is 1600 characters"
expect "broken: cites ~/.claude/enforce/nothing.sh"
expect "broken: cites R-999"
expect "broken: contains U+2014"
expect "broken: names superpowers:nonexistent"
expect "broken: writes or reads docs/elsewhere/file.md"
expect "broken: cursor/skills/broken/SKILL.md has drifted"
if grep -q '^FAIL: clean:' <<< "$SB_OUT"; then
  echo "FAIL: sandbox reported the clean skill (gitignored path, README-listed superpowers name, canonical docs path):"; printf '%s\n' "$SB_OUT" | grep '^FAIL: clean:'; fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# 9. A skill that exists in the live skills directory but not in the repo's own
#    skills tree is a foreign install (marketplace, harness), so the lint leaves
#    it alone rather than letting the machine's contents decide the verdict.
mkdir -p "$SB/live/skills/foreign" "$SB/live/rulebook"
cp "$SB/claude/rulebook"/*.md "$SB/live/rulebook/"
cp "$SB/claude/README.md" "$SB/claude/.gitignore" "$SB/live/"
cat > "$SB/live/skills/foreign/SKILL.md" <<EOF
---
name: not-the-directory-name
description: A foreign skill the repo does not ship, citing R-999 and superpowers:nonexistent.
---
# Foreign
An em dash: $(printf '\xe2\x80\x94').
EOF
FOREIGN_OUT=$(lint_skills "$SB/live" "$SB" 2>&1) || {
  echo "FAIL: a skill absent from the repo's skills tree was linted anyway:"; printf '%s\n' "$FOREIGN_OUT"; exit 1
}
if grep -q 'foreign' <<< "$FOREIGN_OUT"; then
  echo "FAIL: the lint reported a foreign skill it should have skipped:"; printf '%s\n' "$FOREIGN_OUT"; exit 1
fi


echo "skills-lint.test.sh PASS ($(ls -d "$REAL_CLAUDE"/skills/*/ | wc -l | tr -d ' ') skills lint clean, $CURSOR_NOTE, 9 sandbox properties fire)"
