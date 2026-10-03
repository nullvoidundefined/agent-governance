#!/usr/bin/env bash
# security-ci-semgrep: with a Semgrep that reports a clean scan of every
# target, the security CI scan exits 0; with one that reports a finding, it
# exits 1. Guards the script against losing a helper it depends on.
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security-ci-semgrep.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO" "$WORK/bin"
git -C "$REPO" init -q
printf 'print(1)\n' > "$REPO/app.py"
git -C "$REPO" add app.py && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init
cat > "$WORK/bin/semgrep" <<'STUB'
#!/usr/bin/env bash
targets=(); seen=0
for a in "$@"; do [ "$seen" = 1 ] && targets+=("$a"); [ "$a" = "--" ] && seen=1; done
results='[]'
[ -n "${STUB_FINDING:-}" ] && results='[{"path":"app.py","start":{"line":1},"check_id":"x","extra":{"message":"m","severity":"ERROR"}}]'
jq -n --argjson r "$results" --args '{results:$r, errors:[], paths:{scanned:$ARGS.positional}}' "${targets[@]}"
[ -n "${STUB_FINDING:-}" ] && exit 1
exit 0
STUB
chmod +x "$WORK/bin/semgrep"
fail=0
run() { (cd "$REPO" && PATH="$WORK/bin:$PATH" SECURITY_CI_REGISTRY_CONFIGS= bash "$SCRIPT" --mode full >/dev/null 2>"$WORK/err"); }
run; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: clean scan exited $rc: $(head -3 "$WORK/err")"; fail=1; }
STUB_FINDING=1 run; rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: a finding exited $rc, expected 1: $(head -3 "$WORK/err")"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: security-ci-semgrep"
exit "$fail"
