#!/usr/bin/env bash
# semgrep-rule-pack: each rule in empty-catch.yml and dockerfile-image-contract.yml
# flags the code its acceptance criteria name and leaves the safe forms alone.
# Fixtures live only in heredocs here so the repo's own CI scan never sees them.
# A finding is compared as "<id suffix>:<line>"; Semgrep must report no errors.
set -uo pipefail
RULES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../semgrep" && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [ -n "${CLAUDE_SEMGREP_CMD:-}" ]; then SG=($CLAUDE_SEMGREP_CMD)
elif command -v semgrep >/dev/null 2>&1; then SG=(semgrep)
elif command -v uvx >/dev/null 2>&1; then SG=(uvx semgrep)
else echo "FAIL: no semgrep (set CLAUDE_SEMGREP_CMD, install semgrep, or install uvx)"; exit 1; fi
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
fail=0

# expect NAME RULE_FILE FIXTURE_DIR FILE_NAME EXPECTED  (EXPECTED: space-separated suffix:line, may be empty)
expect() {
  local name=$1 rule=$2 dir=$3 file=$4 want got out
  want=$(printf '%s\n' $5 | sort)
  out=$(cd "$dir" && "${SG[@]}" --metrics=off --disable-version-check --json --config "$RULES/$rule" "$file" 2>"$WORK/err")
  if ! got=$(printf '%s' "$out" | jq -r '(.errors | length) as $e | if $e > 0 then "ERRORS:\($e)" else (.results[] | "\(.check_id | split(".") | last):\(.start.line)") end' 2>/dev/null | sort); then
    echo "FAIL: $name: semgrep gave no JSON: $(head -c 300 "$WORK/err")"; fail=1; return
  fi
  if [ "$got" = "$want" ]; then echo "PASS: $name"
  else echo "FAIL: $name: want [$(echo $want)] got [$(echo $got)] $(head -c 200 "$WORK/err")"; fail=1; fi
}
fx() { mkdir -p "$WORK/$1"; cat > "$WORK/$1/$2"; }  # fx DIR FILE < content

# A1-A4: TS and JS share one body; lines 1-3 flagged, 4 and 6 not.
TS_BODY='try { f() } catch {}
try { f() } catch (e) {}
try { f() } catch (e) { /* ignore */ }
try { f() } catch (err) { logger.error({ err }); throw err; }
function h() { try { f() } catch { return null; } }'
for ext in ts js; do
  fx "empty-$ext" "case.$ext" <<<"$TS_BODY"
  expect "A1-A4 empty-catch .$ext" empty-catch.yml "$WORK/empty-$ext" "case.$ext" "empty-catch:1 empty-catch:2 empty-catch:3"
done

# A5-A6: finding is on the except line.
fx empty-py case.py <<'PY'
try:
    f()
except:
    pass
try:
    f()
except Exception:
    pass
try:
    f()
except ValueError as e:
    ...
def g(default):
    try:
        f()
    except ValueError:
        return default
try:
    f()
except Exception as e:
    log.exception(e)
    raise
PY
expect "A5-A6 empty-except .py" empty-catch.yml "$WORK/empty-py" case.py "empty-except:3 empty-except:7 empty-except:11"

# B: Dockerfiles, one per directory, named Dockerfile.
DIGEST=$(printf 'a%.0s' {1..64})
DF=dockerfile-image-contract.yml
df() { fx "$1" Dockerfile; }  # df DIR < content
df_expect() { expect "$1" "$DF" "$WORK/$2" Dockerfile "$3"; }

df b1 <<'D'
FROM node:latest
USER node
CMD ["node"]
D
df_expect "B1 :latest flagged" b1 "unpinned-base-image:1"

df b2 <<'D'
FROM node
USER node
CMD ["node"]
D
df_expect "B2 untagged flagged" b2 "unpinned-base-image:1"

df b3 <<D
FROM node:22.11-alpine AS a
FROM node@sha256:$DIGEST AS b
FROM scratch
USER node
CMD ["x"]
D
df_expect "B3 tag, digest, scratch not flagged" b3 ""

df b4 <<'D'
FROM node:22 AS build
RUN true
FROM build
USER node
CMD ["node"]
D
df_expect "B4 earlier stage alias not flagged" b4 ""

df b5a <<'D'
FROM node:22
CMD ["node"]
D
df_expect "B5 CMD without USER flagged" b5a "runs-as-root:2"

df b5b <<'D'
FROM node:22
ENTRYPOINT ["node"]
D
df_expect "B5 ENTRYPOINT without USER flagged" b5b "runs-as-root:2"

df b6a <<'D'
FROM node:22
USER root
CMD ["node"]
D
df_expect "B6 USER root flagged" b6a "runs-as-root:3"

df b6b <<'D'
FROM node:22
USER 0
CMD ["node"]
D
df_expect "B6 USER 0 flagged" b6b "runs-as-root:3"

df b6c <<'D'
FROM node:22
USER node
USER root
CMD ["node"]
D
df_expect "B6 last USER root flagged" b6c "runs-as-root:4"

df b7 <<'D'
FROM node:22
USER node
CMD ["node"]
D
df_expect "B7 USER node not flagged" b7 ""

# Review round 1 edge cases (added after RED, with the fix commit).
fx empty-py-edges case.py <<'PY'
try:
    f()
except (A, B):  # why

    # still nothing
    pass
try:
    f()
except A:
    pass
    cleanup()
try:
    f()
except B: pass
PY
expect "R1 except edges: comment+blank body, pass then statement, inline" empty-catch.yml "$WORK/empty-py-edges" case.py "empty-except:3 empty-except:14"

df r1a <<'D'
FROM --platform=$BUILDPLATFORM node
USER node
CMD ["node"]
D
df_expect "R1 --platform untagged flagged" r1a "unpinned-base-image:1"

df r1b <<'D'
FROM node:latest AS x
USER node
CMD ["node"]
D
df_expect "R1 :latest with alias flagged" r1b "unpinned-base-image:1"

df r1c <<'D'
FROM node:22 AS build
FROM build AS final
USER node
CMD ["node"]
D
df_expect "R1 alias reused with new alias not flagged" r1c ""

df r1d <<'D'
FROM node:22
CMD node app.js
D
df_expect "R1 shell-form CMD without USER flagged" r1d "runs-as-root:2"

df r1e <<'D'
FROM node:22
USER root
USER node
USER root
CMD ["node"]
D
df_expect "R1 root, node, root then CMD flagged" r1e "runs-as-root:5"

df r1f <<'D'
FROM node:22
HEALTHCHECK CMD curl -f http://localhost/ || exit 1
USER node
CMD ["node"]
D
df_expect "R1 HEALTHCHECK CMD before USER not flagged" r1f ""

exit "$fail"
