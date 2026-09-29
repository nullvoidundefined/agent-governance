#!/usr/bin/env bash
# Shard: fast
# Covers: hook:mcp-action-guard
# Test live group boundaries and helper response failures through the adapter.
# Only temporary helper copies and runtime homes are modified by this fixture.
set -euo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
python3 - "$REPO_TOP" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
failures = []


def check(condition, description):
    print(('PASS: ' if condition else 'FAIL: ') + description, flush=True)
    if not condition:
        failures.append(description)


class Fixture:
    """Run real adapters with isolated homes and replaceable helper copies.

    Each scenario gets synthetic asking hooks and its own state store. Calls
    have an external deadline, so broken response handling cannot hang tests.
    """
    def __init__(self, parent, name):
        self.base = parent / name
        self.home = self.base / 'home'
        self.work = self.base / 'work'
        self.work.mkdir(parents=True)
        self.claude = self.home / '.claude'
        (self.claude / 'hooks').mkdir(parents=True)
        (self.claude / 'enforce').mkdir()
        shutil.copy(root / 'claude/enforce/settings-permission-rules.sh', self.claude / 'enforce')
        (self.claude / 'settings.json').write_text('{"permissions":{"allow":[],"deny":[],"ask":[]}}')
        shutil.copytree(root / 'codex/hooks', self.base / 'adapter')
        self.adapter = self.base / 'adapter/codex-hook-adapter.sh'
        self.helper = self.base / 'adapter/approval-state.py'
        for name in ('first', 'second', 'unknown'):
            response = json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'ask', 'permissionDecisionReason': 'Approve exact action.'}})
            hook = self.claude / 'hooks' / (name + '.sh')
            hook.write_text('#!/bin/sh\ncat >/dev/null\ncat <<\'RESPONSE\'\n' + response + '\nRESPONSE\n')
            hook.chmod(0o700)

    def call(self, group=None, retry=False, prompt=False):
        event = dict(session_id='fixture-session', cwd=str(self.work), turn_id='approval-turn' if retry or prompt else 'original-turn')
        if prompt:
            event.update(hook_event_name='UserPromptSubmit', prompt='I approve')
        else:
            event.update(hook_event_name='PreToolUse', tool_use_id='retry' if retry else 'original',
                         tool_name='mcp__github__update_pull_request', tool_input={'body': 'Reviewed body.', 'pullNumber': 7})
        environment = {key: value for key, value in os.environ.items() if not key.startswith('CLAUDE_')}
        environment.update(HOME=str(self.home), CLAUDE_HOME=str(self.claude))
        process = subprocess.Popen(['bash', str(self.adapter), *([group] if group else [])],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=environment, start_new_session=True)
        try:
            output, _ = process.communicate(json.dumps(event), timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            return 'timeout'
        if process.returncode:
            return 'error'
        if not output.strip():
            return 'allow'
        try:
            parsed = json.loads(output)
            decision = parsed.get('hookSpecificOutput', {}).get('permissionDecision', '')
            return 'deny' if decision == 'deny' or parsed.get('decision') == 'block' else 'allow' if decision in ('', 'allow') else 'invalid'
        except (ValueError, AttributeError):
            return 'invalid'

    def grant(self):
        check(self.call('first') == 'deny', 'fresh request initially asks')
        self.call(prompt=True)


with tempfile.TemporaryDirectory(prefix='codex-approval-response.') as directory:
    parent = Path(directory)
    fixture = Fixture(parent, 'live-unknown-group')
    check(fixture.call('first') == 'deny', 'first group initially asks')
    check(fixture.call('second') == 'deny', 'second group initially asks')
    fixture.call(prompt=True)
    check(fixture.call('unknown', retry=True) == 'deny', 'unknown group denied while approved slots remain unused')
    check(fixture.call('first', retry=True) == 'allow', 'unknown group attempt preserves first approved slot')
    check(fixture.call('second', retry=True) == 'allow', 'unknown group attempt preserves second approved slot')

    # A stream of objects is not one response. The final object's true value
    # must not override an earlier false value through jq's exit semantics.
    fixture = Fixture(parent, 'multiple-responses')
    fixture.grant()
    fixture.helper.write_text('print(\'{"permitted":false}\')\nprint(\'{"permitted":true}\')\n')
    check(fixture.call('first', retry=True) == 'deny', 'multiple helper JSON documents cannot authorize a retry')

    # Restrict only the temporary helper process after granting consent. The
    # OS rejects its actual state write; the permission result is not mocked.
    fixture = Fixture(parent, 'persistence-failure')
    fixture.grant()
    actual_helper = fixture.helper.with_name('real-approval-state.py')
    fixture.helper.rename(actual_helper)
    fixture.helper.write_text(
        'import resource, runpy, signal\n'
        'from pathlib import Path\n'
        'signal.signal(signal.SIGXFSZ, signal.SIG_IGN)\n'
        'resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))\n'
        'runpy.run_path(str(Path(__file__).with_name("real-approval-state.py")), run_name="__main__")\n')
    check(fixture.call('first', retry=True) == 'deny', 'OS refusal to persist consumption denies the retry')

if failures:
    print('FAIL: scoped approval response contract has ' + str(len(failures)) + ' failing assertions')
    sys.exit(1)
print('PASS: scoped approval response contract')
PY
