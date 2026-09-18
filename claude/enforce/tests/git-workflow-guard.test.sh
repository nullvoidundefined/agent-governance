#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies git-workflow-guard.sh: asks before a push to main and before any PR
# merge (R-514), denies a non-squash merge (R-512) except a rebase of a PR
# labeled bundle whose every commit carries a Refs: trailer, and warns on a cross-cutting
# commit to main (R-511) and a surface-adding commit with no README (R-508),
# whose surface list covers every route the R-607 checklist triggers on.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
payload() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
decision() {
  local out
  out=$(payload "$1" "${2:-/x}" | "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
warning() { payload "$1" "${2:-/x}" | "$HOOK" 2>&1 >/dev/null; }
warns() {   # warns <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) return 0 ;; *) echo "expected a $1 warning for: $2" >&2; return 1 ;; esac
}
silent_on() {   # silent_on <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) echo "unexpected $1 warning for: $2" >&2; return 1 ;; *) return 0 ;; esac
}

# Bundle exception (R-512): `--rebase` passes only for a PR labeled `bundle`
# whose every commit carries a `Refs:` trailer, read from `gh pr view`. The gh
# call is stubbed through CLAUDE_GH_CMD so no fixture reaches GitHub.
STUB_DIR=$(mktemp -d)
# write_gh_stub: writes an executable gh stand-in that prints $2 as the
# `gh pr view` JSON and exits with status $3 (default 0).
write_gh_stub() {
  local stub_path="$STUB_DIR/$1"
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\nexit %s\n' "$2" "${3:-0}" >"$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}
# stubbed_decision: the hook's decision for command $1 with gh stubbed by $2.
stubbed_decision() {
  local out
  out=$(payload "$1" "$STUB_DIR" | CLAUDE_GH_CMD="$2" "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
# stubbed_reason: the hook's decision reason for command $1 with gh stubbed by $2.
stubbed_reason() {
  payload "$1" "$STUB_DIR" | CLAUDE_GH_CMD="$2" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
BUNDLE_OK=$(write_gh_stub bundle-ok '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Body.\n\nRefs: IAN-1\nCo-Authored-By: X <x@example.com>"},{"messageHeadline":"fix(b): two","messageBody":"Body.\n\nRefs: IAN-22"}]}')
NO_LABEL=$(write_gh_stub no-label '{"labels":[{"name":"enhancement"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(b): two","messageBody":"Refs: IAN-2"}]}')
MISSING_REFS=$(write_gh_stub missing-refs '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(b): two","messageBody":"No trailer here, Refs: IAN-2 inline only"}]}')
GH_FAILS=$(write_gh_stub gh-fails '' 1)
GH_GARBAGE=$(write_gh_stub gh-garbage 'not json')

[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$BUNDLE_OK")" = "ask" ]      # bundle + all Refs: past R-512, R-514 still asks
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$NO_LABEL")" = "deny" ]      # no bundle label
case "$(stubbed_reason 'gh pr merge 42 --rebase' "$NO_LABEL")" in *bundle*) ;; *) echo "no-label deny must name the bundle label" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$MISSING_REFS")" = "deny" ]  # one commit lacks a Refs: trailer line
case "$(stubbed_reason 'gh pr merge 42 --rebase' "$MISSING_REFS")" in *Refs:*) ;; *) echo "missing-refs deny must name the Refs: trailer" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$GH_FAILS")" = "deny" ]      # gh cannot answer: fail closed
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$GH_GARBAGE")" = "deny" ]    # unparseable answer: fail closed
[ "$(stubbed_decision 'gh pr merge --rebase' "$GH_FAILS")" = "deny" ]         # no PR number, gh still consulted
# The PR selector is the first positional argument, never a flag's value, and
# --repo is forwarded: this stub answers as a bundle only for `42 --repo o/r`.
SELECTOR_STUB="$STUB_DIR/selector"
printf '%s\n' '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"a","messageBody":"Refs: IAN-1"}]}' >"$STUB_DIR/bundle-ok.json"
printf '#!/usr/bin/env bash\n[ "$*" = "pr view 42 --repo o/r --json labels,commits" ] || exit 1\ncat "%s"\n' "$STUB_DIR/bundle-ok.json" >"$SELECTOR_STUB"
chmod +x "$SELECTOR_STUB"
[ "$(stubbed_decision 'gh pr merge --subject 7 -R o/r --rebase 42' "$SELECTOR_STUB")" = "ask" ]
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$SELECTOR_STUB")" = "deny" ]   # --repo dropped: a different PR
[ "$(stubbed_decision 'gh pr merge 42 --merge' "$BUNDLE_OK")" = "deny" ]      # merge commits stay denied, bundle or not
[ "$(stubbed_decision 'gh pr merge 42 --merge --rebase' "$BUNDLE_OK")" = "deny" ]  # --merge wins over a bundle --rebase
# Short and bundled flags carry the same strategy as the long ones.
[ "$(stubbed_decision 'gh pr merge 42 -r' "$NO_LABEL")" = "deny" ]           # -r is --rebase
[ "$(stubbed_decision 'gh pr merge 42 -dr' "$NO_LABEL")" = "deny" ]          # bundled with -d
[ "$(stubbed_decision 'gh pr merge 42 -r' "$BUNDLE_OK")" = "ask" ]           # -r on a real bundle
[ "$(stubbed_decision 'gh pr merge 42 -m' "$BUNDLE_OK")" = "deny" ]          # -m is --merge
[ "$(stubbed_decision 'gh pr merge 42 -dm' "$BUNDLE_OK")" = "deny" ]         # bundled with -d
# A cd or GH_REPO in the command moves the merge somewhere the hook's gh view
# does not look, so the bundle check cannot vouch for it.
[ "$(stubbed_decision 'cd ../other && gh pr merge 42 --rebase' "$BUNDLE_OK")" = "deny" ]
[ "$(stubbed_decision 'GH_REPO=o/other gh pr merge 42 --rebase' "$BUNDLE_OK")" = "deny" ]
[ "$(stubbed_decision 'GH_REPO=o/other gh pr merge 42 --squash' "$GH_FAILS")" = "ask" ]  # env prefix still reaches R-514
# Two commits naming the same ticket are one ticket's history, not a bundle.
SAME_TICKET=$(write_gh_stub same-ticket '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(a): wip","messageBody":"Refs: IAN-1"}]}')
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$SAME_TICKET")" = "deny" ]
# A gh that hangs is cut off and denied, never left for the hook timeout (an
# empty hook output is an allow).
SLOW_GH="$STUB_DIR/slow-gh"
printf '#!/usr/bin/env bash\nsleep 30\ncat "%s"\n' "$STUB_DIR/bundle-ok.json" >"$SLOW_GH"
chmod +x "$SLOW_GH"
SLOW_START=$(date +%s)
SLOW_OUT=$(payload 'gh pr merge 42 --rebase' "$STUB_DIR" | CLAUDE_GH_CMD="$SLOW_GH" CLAUDE_GH_TIMEOUT_SECONDS=1 "$HOOK" 2>/dev/null)
[ "$(printf '%s' "$SLOW_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
[ $(($(date +%s) - SLOW_START)) -lt 10 ] || { echo "a hung gh must be cut off at the deadline" >&2; exit 1; }
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$GH_FAILS")" = "ask" ]       # squash never consults gh
[ "$(decision 'gh pr merge 42 --merge')" = "deny" ]        # wrong strategy (R-512)
[ "$(decision 'gh pr merge 42 --squash')" = "ask" ]        # right strategy, still needs authorization (R-514)
[ "$(decision 'gh pr view 42')" = "none" ]                 # read-only gh call untouched

# Fixture repo on main, with a remote-free push and a feature branch to compare.
REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/src/routes" "$REPO/src/handlers" "$REPO/src/services"
: >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "chore: seed"

[ "$(decision 'git push' "$REPO")" = "ask" ]                    # implicit target is main (R-514)
[ "$(decision 'git push origin main' "$REPO")" = "ask" ]        # explicit target
[ "$(decision 'git push origin HEAD:main' "$REPO")" = "ask" ]   # refspec form
[ "$(decision 'git push origin HEAD' "$REPO")" = "ask" ]         # HEAD resolves to the checked-out branch
[ "$(decision 'git push origin refs/heads/main' "$REPO")" = "ask" ]     # fully qualified ref
[ "$(decision 'git push origin +main' "$REPO")" = "ask" ]               # force marker on the refspec
[ "$(decision "git -C $REPO push origin main" /tmp)" = "ask" ]          # -C form names the repo, not the cwd
# Every other shape that names a target repository (2026-09-18 audit, defect 4).
# The old extraction read `-C` alone, from the FIRST git invocation, with an
# unquoted path, so each of these was judged against the cwd instead.
[ "$(decision "git --work-tree $REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git --work-tree=$REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git -c core.pager=cat -C $REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git -C /nowhere fetch && git -C $REPO push origin main" /tmp)" = "ask" ]
QUOTED_REPO="$REPO with spaces"
cp -R "$REPO" "$QUOTED_REPO"
[ "$(decision "git -C \"$QUOTED_REPO\" push origin main" /tmp)" = "ask" ]
[ "$(decision 'git push origin feature/scoring' "$REPO")" = "ask" ] && exit 1  # a feature branch is not gated
# The governance repo is exempt wherever it lives: identity is the origin
# remote (repo-identity.sh), so the fixture builds a sandbox repo carrying the
# governance remote instead of depending on the real checkout's path (that
# path-coupled form went stale the first time the repo moved, 2026-09-17).
GOV_REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$GOV_REPO" init -q -b main
git -C "$GOV_REPO" remote add origin "https://github.com/nullvoidundefined/agent-governance.git"
[ "$(decision 'git push' "$GOV_REPO")" = "none" ]  # global repo exempt (by origin remote): R-106 owns its pushes

# R-511: five files across three directories staged on main.
for path in src/routes/jobs.ts src/routes/users.ts src/handlers/scoreJob.ts src/services/score.ts src/services/rank.ts; do
  : >"$REPO/$path"
done
git -C "$REPO" add src
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
# R-508: the staged routes are new surface and no README is staged.
warns R-508 'git commit -m "feat: scoring"' "$REPO"
# Staging the README silences R-508 but not R-511.
printf 'docs\n' >"$REPO/README.md"
git -C "$REPO" add README.md
silent_on R-508 'git commit -m "feat: scoring"' "$REPO"
warns R-511 'git commit -m "feat: scoring"' "$REPO"

# A path holding an apostrophe must not crash the advisory pass.
: >"$REPO/src/services/o'brien.ts"
git -C "$REPO" add "src/services/o'brien.ts"
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
git -C "$REPO" rm -q --cached "src/services/o'brien.ts"
rm -f "$REPO/src/services/o'brien.ts"

# A narrow commit on a feature branch warns about neither.
git -C "$REPO" commit -qm "feat: scoring"
git -C "$REPO" checkout -q -b feature/next
: >"$REPO/src/services/notify.ts"
git -C "$REPO" add src/services/notify.ts
[ -z "$(warning 'git commit -m "feat: notify"' "$REPO")" ]
git -C "$REPO" commit -qm "feat: notify"

# IAN-118: R-508 covers the Nuxt, Nitro, and FastAPI surfaces, and agrees with
# the R-607 checklist: every path the checklist's built-in triggers treat as a
# new route is a surface here too. A plain Vue component is not a surface.
# stage_only <path>: stages exactly one new file, nothing else.
stage_only() {
  mkdir -p "$REPO/$(dirname "$1")"; : >"$REPO/$1"; git -C "$REPO" add -- ":(literal)$1"
}
# unstage_path <path>: removes the file staged by stage_only.
unstage_path() {
  git -C "$REPO" rm -q --cached -- ":(literal)$1"; rm -f "$REPO/$1"
}
for surface in 'app/pages/index.vue' 'app/pages/trips/[id].vue' 'server/api/trips.get.ts' \
  'server/routes/health.ts' 'app/routers/trips.py' 'apps/client/web/app/pages/about.vue' \
  'app/trips/page.tsx' 'src/app/api/trips/route.ts'; do
  stage_only "$surface"
  warns R-508 'git commit -m "feat: surface"' "$REPO"
  unstage_path "$surface"
done
for non_surface in 'app/components/TripCard.vue' 'app/composables/useTrips.ts' 'app/services/trips.py'; do
  stage_only "$non_surface"
  silent_on R-508 'git commit -m "feat: component"' "$REPO"
  unstage_path "$non_surface"
done
# Parity: read the checklist's built-in triggers and require the guard to fire
# on each sample path any of them matches.
CHECKLIST_TRIGGERS=$(sed -n '/^BUILTIN_TRIGGERS=(/,/^)/p' "$CLAUDE_HARNESS_ROOT/enforce/require-feature-checklist.sh" | sed -n "s/^  '\(.*\)'$/\1/p")
TRIGGER_ARGS=()
while IFS= read -r trigger; do TRIGGER_ARGS+=(-e "$trigger"); done <<<"$CHECKLIST_TRIGGERS"
[ "${#TRIGGER_ARGS[@]}" -ge 10 ]
PARITY_CHECKED=0
for sample in 'app/pages/trips/index.vue' 'server/api/users/[id].post.ts' 'server/routes/feed.xml.ts' \
  'app/routers/users.py' 'src/routes/trips.ts' 'src/handlers/trips.js' 'app/(shop)/cart/page.jsx' \
  'src/app/api/health/route.js' 'app/components/Nav.vue'; do
  # A here-string, not a pipe: a SIGPIPE under pipefail would skip a sample.
  grep -qE "${TRIGGER_ARGS[@]}" <<<"$sample" || continue
  PARITY_CHECKED=$((PARITY_CHECKED + 1))
  stage_only "$sample"
  warns R-508 'git commit -m "feat: parity"' "$REPO"
  unstage_path "$sample"
done
[ "$PARITY_CHECKED" -eq 8 ]
rm -rf "$REPO"

echo "git-workflow-guard.test.sh PASS"
