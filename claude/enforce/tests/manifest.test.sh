#!/usr/bin/env bash
# Validates the enforcement manifest: non-empty, required keys present, valid tiers,
# and closure against the rule files: every hook:/eslint:/ruff: named in a CLAUDE.md
# or rules/*.md Enforcement line has a manifest entry for that rule id, every
# manifest hook enforcer names a script that exists in hooks/, and ruff:* entries
# require the push-ruff-gate script and its bundled config to exist.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_CLAUDE="$(cd "$DIR/.." && pwd)"
jq -e '.rules | length > 0' "$DIR/manifest.json" >/dev/null
jq -e '[.rules[] | select((.id and .tier and .enforcer and .severity) | not)] | length == 0' "$DIR/manifest.json" >/dev/null
jq -e '[.rules[] | select(.tier as $t | ["regex","ast","llm-judge","advisory"] | index($t) | not)] | length == 0' "$DIR/manifest.json" >/dev/null
python3 - "$HOME_CLAUDE" <<'EOF'
import json, os, re, sys
home = sys.argv[1]
rule_text = ''
for f in ['rulebook/reference.md', 'rulebook/agents.md', 'rulebook/audits.md', 'rulebook/cost.md']:
    rule_text += open(os.path.join(home, f)).read()
manifest = json.load(open(os.path.join(home, 'enforce/manifest.json')))
manifest_ids = {r['id'] for r in manifest['rules']}
missing_entries = []
for rid, enforcement in re.findall(r'^(R-\d{3}).*?\n(?:  .*\n)*?  Enforcement: ([^\n]+)$', rule_text, re.M):
    if re.search(r'\b(hook|eslint|ruff):', enforcement) and rid not in manifest_ids:
        missing_entries.append((rid, enforcement))
assert not missing_entries, f'rules with hook/eslint/ruff enforcement but no manifest entry: {missing_entries}'
missing_hooks = []
for entry in manifest['rules']:
    m = re.match(r'hook:([\w-]+)$', entry['enforcer'])
    if m and not os.path.exists(os.path.join(home, 'hooks', m.group(1) + '.sh')):
        missing_hooks.append(entry['enforcer'])
assert not missing_hooks, f'manifest enforcers with no hook script: {missing_hooks}'
if any(entry['enforcer'].startswith('ruff:') for entry in manifest['rules']):
    for required in ['hooks/push-ruff-gate.sh', 'enforce/ruff-enforce.toml']:
        assert os.path.exists(os.path.join(home, required)), f'ruff:* manifest entries but {required} missing'
EOF
echo "manifest.test.sh PASS"
