#!/usr/bin/env bash
# Shard: slow
# Covers: hook:mcp-action-guard
# Run the real adapter against isolated runtime homes. Fabricated events test
# consent transitions and fault handling, not runtime event authenticity.
set -euo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
python3 - "$REPO_TOP" <<'PY'
import concurrent.futures
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
failures = []


def check(condition, description):
    print(('PASS: ' if condition else 'FAIL: ') + description, flush=True)
    if not condition:
        failures.append(description)


class Fixture:
    """Provide one private HOME, workspace, and real-adapter copy per scenario.

    Copying the adapter and its neighboring helpers lets fault tests remove or
    replace a helper without editing production files. Each call has an outer
    deadline so a missing internal timeout becomes a bounded assertion failure.
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
        self.hook('first')
        self.hook('second')
        self.hook('third')

    def hook(self, name, decision='ask', reason='Approve exact fixture action.'):
        response = json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': decision, 'permissionDecisionReason': reason}})
        path = self.claude / 'hooks' / (name + '.sh')
        path.write_text('#!/bin/sh\ncat >/dev/null\ncat <<\'RESPONSE\'\n' + response + '\nRESPONSE\n')
        path.chmod(0o700)

    def event(self, use='original', turn='original-turn'):
        return dict(hook_event_name='PreToolUse', session_id='fixture-session', turn_id=turn,
                    cwd=str(self.work), tool_use_id=use, tool_name='mcp__github__update_pull_request',
                    tool_input=dict(owner='fixture', repo='demo', pullNumber=7, body='Reviewed body.', labels=['one', 'two']))

    def call(self, event, group=()):
        environment = {key: value for key, value in os.environ.items() if not key.startswith('CLAUDE_')}
        environment.update(HOME=str(self.home), CLAUDE_HOME=str(self.claude))
        process = subprocess.Popen(['bash', str(self.adapter), *group], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env=environment, start_new_session=True)
        try:
            output, _ = process.communicate(json.dumps(event), timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            return 'timeout', ''
        if process.returncode != 0:
            return 'error', output
        if not output.strip():
            return 'allow', output
        try:
            parsed = json.loads(output)
            decision = parsed.get('hookSpecificOutput', {}).get('permissionDecision', '')
            return ('deny' if decision == 'deny' or parsed.get('decision') == 'block' else 'allow' if decision in ('', 'allow') else 'invalid'), output
        except (ValueError, AttributeError):
            return 'invalid', output

    def prompt(self, text='I approve', turn='approval-turn'):
        return self.call(dict(hook_event_name='UserPromptSubmit', session_id='fixture-session',
                              turn_id=turn, cwd=str(self.work), prompt=text))

    def ask(self, group=('first',), event=None):
        return self.call(event or self.event(), group)

    def grant(self):
        check(self.ask()[0] == 'deny', 'fresh request is denied')
        self.prompt()

    def retry(self, use='retry', group=('first',)):
        return self.call(self.event(use, 'approval-turn'), group)

    def states(self):
        return list((self.claude / '.codex-approvals').glob('*.json'))


with tempfile.TemporaryDirectory(prefix='codex-approval-security.') as directory:
    parent = Path(directory)
    # Exact payload binding includes string contents and array order. A grant
    # for one runtime identity cannot authorize a different identity or tool.
    changes = {
        'body': lambda e: e['tool_input'].update(body='Different body.'),
        'string-whitespace': lambda e: e['tool_input'].update(body='Reviewed  body.'),
        'array-order': lambda e: e['tool_input'].update(labels=['two', 'one']),
        'session': lambda e: e.update(session_id='other-session'),
        'directory': lambda e: e.update(cwd=str(parent)),
        'tool': lambda e: e.update(tool_name='mcp__github__create_issue'),
    }
    for name, change in changes.items():
        fixture = Fixture(parent, name)
        fixture.grant()
        event = fixture.event('changed', 'approval-turn')
        change(event)
        check(fixture.call(event, ('first',))[0] == 'deny', name + ' change cannot consume consent')

    for field in ('session_id', 'turn_id', 'cwd', 'tool_use_id', 'tool_name'):
        fixture = Fixture(parent, 'missing-' + field)
        fixture.grant()
        event = fixture.event('missing', 'approval-turn')
        event.pop(field)
        check(fixture.call(event, ('first',))[0] == 'deny', 'missing ' + field + ' fails closed')

    fixture = Fixture(parent, 'reason')
    fixture.grant()
    fixture.hook('first', reason='Approve different effect.')
    check(fixture.retry()[0] == 'deny', 'changed asking reason invalidates consent')

    for index, phrase in enumerate(('Do not approve', 'The text says "I approve"', 'I approve this and something else', 'continue')):
        fixture = Fixture(parent, 'cancel-' + str(index))
        fixture.grant()
        fixture.prompt(phrase, 'cancel-turn')
        check(fixture.retry()[0] == 'deny', 'nonapproval prompt revokes existing consent: ' + phrase)

    fixture = Fixture(parent, 'prompt-replay')
    fixture.grant()
    check(fixture.retry()[0] == 'allow', 'first approved retry succeeds before replay test')
    fixture.ask(event=fixture.event('later-request', 'later-turn'))
    fixture.prompt()
    check(fixture.retry('later-retry')[0] == 'deny', 'duplicate prompt cannot approve later request')

    fixture = Fixture(parent, 'hard-deny')
    fixture.grant()
    fixture.hook('first', decision='deny')
    check(fixture.retry()[0] == 'deny', 'hard deny overrides matching consent')
    fixture.hook('first')
    check(fixture.retry('after-deny')[0] == 'deny', 'hard deny revokes matching consent permanently')

    fixture = Fixture(parent, 'ambiguous')
    fixture.ask()
    other = fixture.event('other-request')
    other['tool_input']['body'] = 'Other reviewed body.'
    fixture.ask(event=other)
    fixture.prompt()
    check(fixture.retry()[0] == 'deny', 'bare approval cannot choose between distinct requests')

    fixture = Fixture(parent, 'explicit-id')
    _, output = fixture.ask()
    other = fixture.event('other-request')
    other['tool_input']['body'] = 'Other reviewed body.'
    fixture.ask(event=other)
    # Accept opaque identifiers without imposing a digest format. The denial
    # must expose the exact command the user can supply to select a request.
    match = re.search(r'\bapprove\s+([A-Za-z0-9_-]{8,})', output, re.IGNORECASE)
    check(match is not None, 'denial exposes approve <request-id> for explicit selection')
    if match:
        fixture.prompt('approve ' + match.group(1))
        check(fixture.retry()[0] == 'allow', 'explicit request ID selects one ambiguous request')
        other.update(tool_use_id='other-retry', turn_id='approval-turn')
        check(fixture.call(other, ('first',))[0] == 'deny', 'explicit approval does not authorize other request')

    fixture = Fixture(parent, 'concurrent')
    fixture.grant()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda use: fixture.retry(use)[0], ['retry-one', 'retry-two']))
    check(sorted(results) == ['allow', 'deny'], 'concurrent retry IDs cannot share one grant')

    fixture = Fixture(parent, 'groups')
    fixture.ask(('first',))
    fixture.ask(('second',))
    fixture.prompt()
    check(fixture.retry('reserved-retry', ('first',))[0] == 'allow', 'one approval covers first group in original snapshot')
    check(fixture.retry('different-retry', ('second',))[0] == 'deny', 'other retry ID cannot steal reserved group slot')
    check(fixture.retry('reserved-retry', ('second',))[0] == 'allow', 'reserved retry can consume second approved group')
    check(fixture.retry('reserved-retry', ('first',))[0] == 'deny', 'each approved group slot is single-use')
    check(fixture.retry('reserved-retry', ('third',))[0] == 'deny', 'group absent from approved snapshot is denied')

    # Inspect only the documented private store. Faults change fixture state,
    # never production state. Expiry ages timestamp values without prescribing
    # the surrounding request schema or forcing a ten-minute real-time sleep.
    for fault in ('malformed', 'permissions', 'symlink', 'expired', 'lock-held'):
        fixture = Fixture(parent, 'state-' + fault)
        fixture.grant()
        states = fixture.states()
        check(bool(states), 'private state exists for ' + fault + ' fault test')
        if not states:
            continue
        state = states[0]
        held = None
        if fault == 'malformed':
            state.write_text('{not-json')
        elif fault == 'permissions':
            state.chmod(0o666)
        elif fault == 'symlink':
            target = fixture.base / 'linked-state'
            state.rename(target)
            state.symlink_to(target)
        elif fault == 'expired':
            def age(value):
                if isinstance(value, dict):
                    return {key: age(item) for key, item in value.items()}
                if isinstance(value, list):
                    return [age(item) for item in value]
                if isinstance(value, (int, float)) and abs(value - time.time()) < 1200:
                    return value - 1201
                return value
            state.write_text(json.dumps(age(json.loads(state.read_text()))))
        else:
            locks = list(state.parent.glob('*.lock'))
            check(bool(locks), 'stable session lock exists')
            if not locks:
                continue
            held = locks[0].open('r+')
            fcntl.flock(held, fcntl.LOCK_EX)
        try:
            check(fixture.retry()[0] == 'deny', fault + ' state produces bounded explicit denial')
        finally:
            if held:
                held.close()

    for fault in ('missing', 'crash', 'malformed', 'hang'):
        fixture = Fixture(parent, 'helper-' + fault)
        fixture.grant()
        helper = fixture.base / 'adapter/approval-state.py'
        if fault == 'missing':
            helper.unlink()
        elif fault == 'crash':
            helper.write_text('raise RuntimeError("fixture failure")\n')
        elif fault == 'malformed':
            helper.write_text('print("not-json")\n')
        else:
            helper.write_text('import time\ntime.sleep(60)\n')
        check(fixture.retry()[0] == 'deny', fault + ' helper produces bounded explicit denial')

if failures:
    print('FAIL: scoped approval security contract has ' + str(len(failures)) + ' failing assertions')
    sys.exit(1)
print('PASS: scoped approval security contract')
PY
