---
name: build-by-slice-require-review
description: Use when building a feature as a series of PRs ("build this slice by slice", "start the slice", "next slice"). Each slice is one PR, and work stops after each PR until the owner approves or merges it.
---

# Build by slice, require review

A feature ships as a short sequence of small PRs. The only gate is the owner: after each PR, stop until they approve it.

## 1. Plan the slices

- Break the feature into slices that each deliver one working, testable piece, in the order the code needs them.
- Write the plan in a few lines per slice: what it does, the files it touches, how you'll know it works.
- Show the plan to the owner once. Start when they approve it.

## 2. Build one slice

- Branch from the latest `main` (or from the previous slice's branch if it hasn't merged yet and this slice needs it).
- Write the code and the tests it needs. Run the affected tests.
- Commit, push, and open a PR. The body says what the slice does, how it was tested, and anything the owner should look at.

## 3. Stop for the owner

- Tell the owner the PR is ready, with its link, and stop. Don't start the next slice.
- If they request changes, make them on the same PR and stop again.
- When they approve or merge it, start the next slice from step 2.

## Notes

- Fix red CI on your own PR before asking for approval; a red PR is not ready.
- If a slice turns out bigger than planned, split it and tell the owner.
- A reviewer subagent (`pr-reviewer`) is available when the owner asks for a second opinion; it is not required.
