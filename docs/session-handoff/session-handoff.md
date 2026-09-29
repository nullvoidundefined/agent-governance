# Session handoff

## Last commit

- Last verified source commit: bb45a97f0620e35e69a2444f2ee5ac5f9a6a0aa1,
  retained by the published keep/governance-verified-scope tag. Its R-001 scope
  fixture and rule consistency checks pass. Subsequent changes update this handoff.
- IAN-501 tracks publication and deployment on release/governance-conventions.
- This branch includes IAN-495, IAN-498, IAN-499, and IAN-500, rebased onto the
  newer build-fast change on main. Generated manifests were regenerated during
  integration; the newer build-fast source and exports are preserved.

## Production state verified

- The owner-authorized local sync installed both convention updates into the live
  Claude, Cursor, and Codex configurations. The isolated worktree is the sync source.
- The generated Codex payload matches the changed Claude source.
- The finite registry retains all 57 approved verbs with the same membership,
  banned synonyms, and layer bindings. Each approved verb now has a definition.

## Session metrics

- IAN-499 is an instruction-only Standard task, estimated at 10 minutes. Rule
  consistency, all eight affected skill frontmatters, and both generated tool
  exports pass. No hook implementation, enforcement code, or hook registration changed.
- IAN-495 is a Standard documentation and registry-data task, estimated at 15 minutes.
- IAN-498 is a Standard convention update, estimated at 10 minutes. Rule consistency
  and generated Codex payload checks pass.
- Verification covers generated-payload consistency, lexicon/spec consistency,
  existing naming-rule fixtures, and complete verb-definition coverage.
- No production enforcement logic or dependencies changed.

## What shipped

- IAN-499 adds an applicability check before session and task procedures. All coding
  work, including simple programming questions, remains governed in every app.
  Ordinary non-coding questions skip development ceremony, and mixed requests govern
  the coding portion. Pending task state and action protections remain in force.
- Cursor exports are regenerated from the same canonical source, including the
  previously committed verb meanings and thorough-commenting requirements.
- The committed changes add verbMeanings to enforce/lexicon.json. IAN-501 tracks
  the branch publication and remaining review and release steps.
- R-316 defines retrieval, remote retrieval, string formatting, creation, updates,
  deletion, and the requirement to name returned representations explicitly.
- Codex AGENTS.md and its generated fingerprint were regenerated from source.
- The linter still checks membership and syntactic naming. Semantic intent remains
  a judge/review responsibility; the documentation explicitly states this limit.
- R-320 now explicitly requires thorough explanations across frontend and backend
  code, including function contracts, algorithms, state transitions, side effects,
  edge cases, UI behavior, and backend consistency and failure handling.
- Functions longer than roughly ten implementation lines generally require a
  comprehensive plain-English explanation of their purpose and execution steps.
- Header checks remain unchanged. Explanation quality requires manual review;
  comment counts do not establish compliance.

## Pending work

- Preserve the unresolved work and operational constraints in the
  [previous handoff](https://github.com/nullvoidundefined/agent-governance/blob/keep/governance-pre-release-handoff/docs/session-handoff/session-handoff.md).
  That retained record is the continuation reference for all earlier pending items,
  including IAN-381 security work and IAN-456 guard evasions. This delivery did not
  investigate, close, supersede, or waive those items. Reconcile each with its live
  tracker ticket before acting; retain its recorded constraints until resolved.
- Monitor IAN-499 during normal coding reviews and handoffs for any drop in coding
  quality. Watch for misclassified coding requests, skipped tests or required reviews,
  and task state lost during non-coding detours. File evidence-backed regressions and
  fix the scope decision without weakening coding requirements. Real-world quality
  impact remains unverified; do not add a new workflow to ordinary questions.
- The owner selected Command Line Tools and the system Git launcher now works.
  Naming fixtures and generated-payload consistency checks pass again.
- IAN-495, IAN-498, IAN-499, IAN-500, and IAN-501 await the normal review and merge
  workflow. Keep the tickets open until delivery is completed.
- Local deployment uses sync.sh. Public versioned releases use the protected
  release environment after a version tag is pushed; owner approval is required.

## Recommended next session

- Inspect IAN-501 for the current PR, verification, and deployment status.
- The owner authorized pushing, merging, and public release, and approved a Codex
  reviewer after Claude reached its weekly limit. Complete the current-head review
  and green CI before merging. IAN-503 records the corrected R-001 wording fixture.
