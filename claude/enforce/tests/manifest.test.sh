#!/usr/bin/env bash
# Validates the enforcement manifest: non-empty, required keys present, valid tiers.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
jq -e '.rules | length > 0' "$DIR/manifest.json" >/dev/null
jq -e '[.rules[] | select((.id and .tier and .enforcer and .severity) | not)] | length == 0' "$DIR/manifest.json" >/dev/null
jq -e '[.rules[] | select(.tier as $t | ["regex","ast","llm-judge","advisory"] | index($t) | not)] | length == 0' "$DIR/manifest.json" >/dev/null
echo "manifest.test.sh PASS"
