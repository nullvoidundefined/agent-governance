#!/usr/bin/env bash
# Verifies the injected global-memory INDEX.md does not contradict
# settings.json on model routing (2026-09-16 audit P2-3: the index line
# claimed a Sonnet-everywhere default two commits after settings adopted
# `opusplan`; the corrected file was read-on-demand while the stale index
# reached every session). The index one-liner for the session-default memory
# must name the live settings model, so this drift class self-detects on the
# surface everybody sees.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_ROOT="$SCRIPT_DIR/../.."

SETTINGS_MODEL=$(jq -r '.model // ""' "$CLAUDE_ROOT/settings.json")
# A skip must still print PASS, because run-tests.sh requires that word and
# read this branch as a red suite whenever settings.json legitimately set no
# model, which means "use the default" (audit P3-3). This is the suite's skip
# convention: the word PASS, then SKIPPED and the reason.
[ -n "$SETTINGS_MODEL" ] || { echo "index-settings-sync.test.sh PASS (SKIPPED: settings.json sets no model, so there is no claim to contradict)"; exit 0; }

INDEX_LINE=$(grep 'feedback_default_sonnet_proactive_switch' "$CLAUDE_ROOT/global-memory/INDEX.md" | head -1)
[ -n "$INDEX_LINE" ] || { echo "FAIL: INDEX.md no longer lists the session-default memory"; exit 1; }

grep -qF "$SETTINGS_MODEL" <<< "$INDEX_LINE" || {
  echo "FAIL: INDEX.md session-default line does not name the settings model '$SETTINGS_MODEL'; the injected index has drifted from settings.json (P2-3)."
  exit 1
}

echo "index-settings-sync.test.sh PASS"
