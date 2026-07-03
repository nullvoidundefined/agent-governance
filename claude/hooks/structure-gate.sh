#!/usr/bin/env bash
# structure-gate.sh: deterministic path checks for directory case (R-312) and
# banned catch-all directory names (R-306/R-304). Per-edit, no Node spawn.
set -euo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

BANNED='^(lib|utils|helpers|common|core|misc|shared|db)$'
IFS='/' read -ra PARTS <<< "$FILE"
in_src=0
in_app=0
for seg in "${PARTS[@]}"; do
  [ "$seg" = "src" ] && in_src=1 && continue
  [ "$in_src" -eq 0 ] && continue
  [[ "$seg" == *.* ]] && continue
  [[ "$seg" =~ ^__.*__$ ]] && continue
  [[ "$seg" =~ ^\(.*\)$ ]] && continue
  [ "$seg" = "app" ] && in_app=1 && continue
  if [[ "$seg" =~ $BANNED ]]; then
    deny "Directory '$seg' is a banned catch-all (R-306/R-304). Use services/, clients/, or a domain folder."
  fi
  if [[ "$seg" == *-* || "$seg" == *_* ]]; then
    [ "$in_app" -eq 1 ] && continue
    deny "Directory '$seg' must be camelCase, not kebab/snake (R-312)."
  fi
done
exit 0
