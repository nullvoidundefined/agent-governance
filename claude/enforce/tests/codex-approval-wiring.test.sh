#!/usr/bin/env bash
# Shard: fast
# Covers: hook:mcp-action-guard
# Verify generated prompt registration and delivery of its real helper through
# release sync. All installation targets are temporary; no live sync is run.
set -euo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/codex-approval-wiring.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
failure=0
node --input-type=module - "$REPO_TOP" <<'JS' || failure=1
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
const root = process.argv[2];
const { renderHooksConfig } = await import(pathToFileURL(path.join(root, 'translate/render-codex-hooks.mjs')));
const readJson = relative => JSON.parse(fs.readFileSync(path.join(root, relative), 'utf8'));
let failures = 0;
function check(condition, message) {
  console.log(`${condition ? 'PASS' : 'FAIL'}: ${message}`);
  if (!condition) failures += 1;
}
const adapter = '~/.codex/hooks/codex-hook-adapter.sh';
const portMap = readJson('translate/codex-port-map.json');
const syntheticMap = { ...portMap, events: { ...portMap.events, UserPromptSubmit: 'UserPromptSubmit' } };
const settings = {
  PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: '~/.claude/hooks/fixture-guard.sh', timeout: 17, statusMessage: 'Checking fixture.' }] }],
  UserPromptSubmit: [{ hooks: [{ type: 'command', command: '~/.claude/hooks/fixture-prompt.sh', timeout: 23 }] }],
};
const rendered = JSON.parse(renderHooksConfig(settings, syntheticMap).content).hooks;
check(isDeepStrictEqual(rendered.PreToolUse, [{ matcher: 'Bash', hooks: [{ type: 'command', command: `${adapter} fixture-guard`, timeout: 17, statusMessage: 'Checking fixture.' }] }]), 'existing tool group retains matcher, command, timeout and status');
const promptGroups = rendered.UserPromptSubmit ?? [];
check(promptGroups.some(group => isDeepStrictEqual(group, { hooks: [{ type: 'command', command: `${adapter} fixture-prompt`, timeout: 23 }] })), 'existing prompt hook group survives unchanged');
const isApprovalListener = hook => hook.type === 'command' && hook.command?.trim() === adapter;
check(promptGroups.flatMap(group => group.hooks ?? []).filter(isApprovalListener).length === 1, 'one adapter-only approval listener is added alongside existing prompt hooks');
const emptyRendered = JSON.parse(renderHooksConfig({}, portMap).content).hooks;
check((emptyRendered.UserPromptSubmit ?? []).flatMap(group => group.hooks ?? []).filter(isApprovalListener).length === 1, 'approval listener exists when canonical settings have no prompt hooks');

const generated = readJson('codex/hooks.json');
const actualSettings = readJson('claude/settings.json').hooks;
check(isDeepStrictEqual(generated, JSON.parse(renderHooksConfig(actualSettings, portMap).content)), 'checked-in hook configuration matches the renderer');
check((generated.hooks.UserPromptSubmit ?? []).flatMap(group => group.hooks ?? []).filter(isApprovalListener).length === 1, 'checked-in configuration delivers prompt events to approval adapter');
const helper = 'hooks/approval-state.py';
check(portMap.hand_authored.includes(helper), 'port map preserves the hand-authored approval helper');
const ignoreLines = fs.readFileSync(path.join(root, 'codex/.gitignore'), 'utf8').split('\n');
check(ignoreLines.includes('!/hooks/') && ignoreLines.includes(`!/${helper}`), 'generated Git allowlist retains the helper');
const manifest = readJson('codex/.claude-port.json');
check(manifest.classes?.[helper] === 'hand-authored-mapped', 'generated manifest classifies helper as hand-authored');
check(manifest.hand_authored?.includes(helper), 'generated manifest lists helper for retention');
process.exitCode = failures ? 1 : 0;
JS

# Reuse the release fixture's minimal archive shape. Without package manifests
# sync performs no dependency installation. Every target and HOME is isolated.
mkdir -p "$SANDBOX/source/claude" "$SANDBOX/source/cursor" "$SANDBOX/source/codex/hooks" "$SANDBOX/home"
cp "$REPO_TOP/sync.sh" "$SANDBOX/source/sync.sh"
cp "$REPO_TOP/codex/hooks.json" "$SANDBOX/source/codex/hooks.json"
cp "$REPO_TOP/codex/hooks/codex-hook-adapter.sh" "$SANDBOX/source/codex/hooks/"
cp "$REPO_TOP/codex/hooks/approval-state.py" "$SANDBOX/source/codex/hooks/"
printf '%s\n' sync.sh codex/hooks.json codex/hooks/codex-hook-adapter.sh codex/hooks/approval-state.py > "$SANDBOX/source/RELEASE-FILES"
if HOME="$SANDBOX/home" SYNC_CLAUDE_HOME="$SANDBOX/live/claude" SYNC_CURSOR_HOME="$SANDBOX/live/cursor" SYNC_CODEX_HOME="$SANDBOX/live/codex" \
  bash "$SANDBOX/source/sync.sh" > "$SANDBOX/sync.log" 2>&1; then
  if cmp -s "$REPO_TOP/codex/hooks/approval-state.py" "$SANDBOX/live/codex/hooks/approval-state.py"; then
    printf 'PASS: real release sync installs identical approval helper\n'
  else
    printf 'FAIL: real release sync loses or changes approval helper\n'
    failure=1
  fi
  if jq -e '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.type == "command" and .command == "~/.codex/hooks/codex-hook-adapter.sh")] | length == 1' "$SANDBOX/live/codex/hooks.json" >/dev/null; then
    printf 'PASS: installed hook configuration registers approval prompt listener\n'
  else
    printf 'FAIL: installed hook configuration omits approval prompt listener\n'
    failure=1
  fi
else
  printf 'FAIL: isolated release sync failed\n'
  tail -10 "$SANDBOX/sync.log"
  failure=1
fi
exit "$failure"
