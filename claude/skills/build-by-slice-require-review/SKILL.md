---
name: build-by-slice-require-review
description: Use when building a feature as a series of PRs ("build this slice by slice", "start the slice", "next slice"). Plan the slices once, build each with the test-first loop, one PR per slice, and stop after each PR until the owner approves or merges it.
---

# Build by slice, require review

A feature ships as a short sequence of small PRs. The owner's approval of each PR is the gate between slices.

## 1. Plan once

- Split the feature into slices. Each slice delivers one working, testable piece, in the order the code needs them.
- For each slice, write a few lines:
  - what it does, as numbered acceptance criteria
  - the files it touches
  - its risk (`standard` or `high`)
  - how you will know it works
- Show the plan to the owner once. Start when they approve it. An approved plan settles its decisions; do not re-ask them per slice.

## 2. Build one slice

- Branch from the latest `main`, or from the previous slice's branch when this slice needs unmerged work.
- Run the `tdd-gated-dispatch` loop: RED by the other model, GREEN, one review, targeted verification.
- Open the PR. The body has:
  - the slice's criteria
  - `**Risk:**`
  - `## Verification`, with the RED commit, the GREEN commands, and anything checked by hand
  - `## Review`, with the reviewer, the range, and the findings with their dispositions
  - `## Security review`, for high risk

## 3. Stop for the owner

- Tell the owner the PR is ready, with its link, and stop. Do not start the next slice.
- Red CI on your own PR is yours to fix before you ask for approval.
- When the owner requests changes, make them on the same PR, rerun the affected checks, and stop again. Their feedback does not restart the slice.
- When they approve or merge, start the next slice from step 2.

## Notes

- **If the owner asks you to keep going without stopping,** build the remaining slices as a stack (each branched from the previous). Each one still gets its full loop. Leave the merges to the owner.
- **If a slice grows past its plan,** split it and tell the owner.
