#!/usr/bin/env bash
# Verifies content-gate.sh denies suppressed tests (R-401), weakened protections
# (R-405), and repo-escaping relative imports (R-302), and allows the legitimate
# neighbours of each.
set -euo pipefail
HOOK="$HOME/.claude/hooks/content-gate.sh"
payload() { jq -nc --arg f "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}'; }
deny() { payload "$1" "$2" | "$HOOK" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; }
allow() { [ -z "$(payload "$1" "$2" | "$HOOK")" ]; }

# R-401: a test that cannot fail protects nothing.
deny  /x/src/__tests__/auth.test.ts 'it.only("signs in", () => {});'
deny  /x/src/__tests__/auth.test.ts 'describe.skip("auth", () => {});'
deny  /x/src/__tests__/auth.test.ts 'xit("signs in", () => {});'
deny  /x/tests/test_auth.py '@pytest.mark.skip
def test_login(): pass'
deny  /x/internal/services/score_test.go 'func TestScore(t *testing.T) { t.Skip("flaky") }'
allow /x/src/__tests__/auth.test.ts 'it.skip("signs in", () => {}); // JOB-412 pending the session refactor'   # tracked deferral (anti-pattern 8 carve-out)
deny  /x/src/__tests__/auth.test.ts 'it.skip("signs in", () => {}); // flaky, revisit later'                   # untracked skip
allow /x/src/__tests__/auth.test.ts 'it("signs in", async () => { expect(await signIn()).toBe(true); });'
allow /x/tests/test_auth.py '@pytest.mark.skipif(sys.platform == "win32", reason="posix only")
def test_login(): pass'
allow /x/src/services/queue/drainQueue.ts 'export function drainQueue() { return items.skip(1); }'  # not a test path
allow /x/enforce/tests/fixture.sh 'it.only("x")'                                                    # not a source extension

# R-405: never disable the protection that surfaced the failure.
deny  /x/src/clients/paymentProvider.ts 'const agent = new https.Agent({ rejectUnauthorized: false });'
deny  /x/src/config/cors.ts 'export const corsOptions = { origin: "*" };'
deny  /x/src/middleware/security.ts 'app.use(helmet({ contentSecurityPolicy: false }));'
deny  /x/src/services/auth/hashPassword.ts 'const hash = await bcrypt.hash(password, 4);'
deny  /x/app/clients/payment.py 'response = requests.post(url, verify=False)'
allow /x/src/services/auth/hashPassword.ts 'const hash = await bcrypt.hash(password, 12);'
allow /x/src/config/cors.ts 'export const corsOptions = { origin: ["https://app.example.com"] };'
allow /x/src/middleware/security.ts 'app.use(helmet({ contentSecurityPolicy: true }));'
allow /x/src/__tests__/clients/paymentProvider.test.ts 'const agent = new https.Agent({ rejectUnauthorized: false });'  # test tree exempt

# R-302: a relative import may not climb out of the repository.
REPO_FIXTURE=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$REPO_FIXTURE/src/services/jobs"
git -C "$REPO_FIXTURE" init -q
deny  "$REPO_FIXTURE/src/services/scoreJob.ts" 'import { schema } from "../../../other-project/src/schema";'
deny  "$REPO_FIXTURE/src/services/jobs/scoreJob.ts" 'const shared = require("../../../../shared/dist/index.js");'
allow "$REPO_FIXTURE/src/services/scoreJob.ts" 'import { schema } from "../../types/schema";'
allow "$REPO_FIXTURE/src/services/scoreJob.ts" 'import { toScore } from "./toScore";'
allow "$REPO_FIXTURE/src/services/scoreJob.ts" 'import { schema } from "@repo/schemas";'
rm -rf "$REPO_FIXTURE"

echo "content-gate.test.sh PASS"
