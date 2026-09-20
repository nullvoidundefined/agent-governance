# Rewrite the root README as adoption-facing landing copy

**Ticket:** IAN-257
**Branch:** `claude/readme-landing-page-3e7d15`
**Tier:** standard

## Summary

The root `README.md` was written for someone already inside the repository. It opened with how
`sync.sh` decides whether to delete a live file, and it spent its remaining two paragraphs on the
distinction between the dotted project-config directories and the undotted payload directories, and
on which files under `codex/` are generated. Every sentence in it was true and useful, and none of
it answered the question a new reader actually arrives with, which is whether this harness is worth
adopting and what using it would feel like.

This replaces it with copy aimed at that reader: what the harness is for, stated as the class of
failure it prevents; how a feature travels from a request to a commit on `main` through the skills;
how the two skills that both look like "the one that builds things" differ; how the repository is
organized and why it is organized that way; and a section on what the harness deliberately does not
do. The contributor material is preserved rather than deleted, moved to a `## Working in this
repository` section near the bottom and expanded slightly with the generated-file rules that
previously lived only in `AGENTS.md`.

## What changed

One file, `README.md`, from 16 lines to 390.

The new structure, in order: a one-paragraph positioning statement and a three-line quick start; a
table of contents; **Why this exists**, which is the failure story from `claude/PROTOCOL.md`
together with that document's own honest accounting that six of the eleven layers are mechanical and
five are prose; **What you get**, a table of seven surfaces with a measured count for each;
**How a feature actually gets built**, six numbered steps naming the skill and the gate at each one;
**The two build skills, and how to tell them apart**, described below; **The four layers**, which
explains how to read a rule's enforcer tag; **Repository layout**, an annotated tree;
**One source, three tools**, on what the ports do and do not carry; **Install** and
**Verification**; **What this does not do**; and the relocated contributor section.

The section on the two build skills is the substantive addition. `build-by-slice-require-review` and
`tdd-gated-dispatch` have overlapping triggers, and their own frontmatter already cross-references
the ambiguity, which is a sign that a reader meeting them for the first time will guess wrong. The
README now frames them as an outer loop and an inner loop rather than as a choice: the outer loop
governs cadence and the two points where a human says yes, and the inner loop governs a single
behavior and who is permitted to write which files. A seven-row comparison table sits between the
two descriptions, and a closing paragraph states that step 4 of the outer loop is the inner loop, so
a reader does not leave thinking they have to pick one.

Every count in the document was taken from this checkout rather than from a summary document: 84
rule norm lines, 114 manifest entries across four tiers, 66 hook scripts, 18 skills, 13 agent roles,
12 convention tracks, and 123 shell fixtures. Every file path the document references was checked to
exist. The maintenance-tax figures in the closing section are quoted from
`docs/audits/2026-09-19-maintenance-tax.md` rather than estimated.

## Architectural decisions

**Replace the README rather than prepend to it.** The alternative considered and rejected was to
keep the existing contributor prose untouched and add the landing-page sections above it, which is
the lower-risk edit because it deletes nothing. It was rejected because the resulting file serves
two audiences in one scroll, and the contributor audience is the smaller of the two by a wide
margin: most readers of this repository will never contribute to it. A third option, a separate
`docs/LANDING.md` linked from the README, was rejected for the same reason in a different shape,
since it leaves the contributor document as the front door, which is the problem being fixed. The
owner chose the replacement explicitly on 2026-09-21. Reversing the decision means restoring the
two moved paragraphs to the top, which the git history makes cheap.

**Cite fixtures instead of asserting guard behavior.** The first draft claimed outright that you
cannot write production code before its failing test and cannot edit a test to make it pass. Both
claims are absolute statements about runtime behavior, and neither had been executed while writing
the document. The `documentation-create` skill names this exact failure, describing intent as
achieved behavior, as the one that three agents made independently when tested. Demonstrating the
claims directly would have meant running `tdd.sh open` in this worktree, which creates a real slice
lock and would have blocked this branch's own commits. The resolution was to state the behavior as
what the design does and then name the shell fixtures that drive the real guard and prove it
(`protected-path-guard.test.sh`, `tdd-red-green.test.sh`, and three others), which is checkable by
the reader without either of us taking it on trust. The alternative of simply softening the language
to "is intended to" was rejected as weaker than the evidence actually available.

**Keep the limitations section.** A "What this does not do" section on a landing page costs
adoption. It is here because the three things it names (hooks do not confine a spawned subprocess,
about a third of commits are harness self-maintenance, and roughly four fifths of the rules are one
person's workflow rather than a portable safety floor) are all documented inside the repository
already, in `claude/enforce/README.md` and the maintenance-tax audit. A reader who adopts the
harness and discovers them afterward has been misled by omission, and the repository's own criticism
audits exist precisely to prevent that posture. The section links to the documents rather than
restating them.

**Correct the doctor check names rather than repeat the setup document.** `claude/SETUP.md` lists
nine named checks and calls the fixture step `fixture-suites`. Checking `doctor.sh` itself showed
that the names it reports are a different set, so the README describes what the tool does and points
at `claude/enforce/README.md` for the authoritative list rather than reproducing a list that would
be wrong on the day a check is renamed.

## Testing

`claude/enforce/related-tests.sh README.md` returns no fixtures, which is correct: `README.md` is
not an input to any guard, and no fixture asserts anything about its contents. There is therefore no
test to write for this change, and adding one would mean asserting on prose, which R-401 item 9
already rules out as a test that cannot meaningfully fail.

What was verified instead, by running it:

- Every file path referenced in the document exists. Seventeen paths checked, all present.
- `sandbox.enabled` is `false` in `claude/settings.json:135`, as the limitations section states.
- `.github/workflows/enforce.yml` has a job named `fixtures` at line 38, and a `Translator port
  checks` step at line 145 that sources `claude/enforce/port-checks.sh`.
- `claude/enforce/tdd.sh` accepts exactly the seven subcommands the document lists, and its runner
  dispatch covers vitest, jest, shell, and pytest.
- The seven counts in the "What you get" table were each produced by a command over this checkout.
- The document contains no U+2014 (R-207), confirmed by byte-level grep.
- `documentation-create`'s `prose-flags.sh` advisory pass was run and its 28 candidate lines were
  each read; four led to the rewrites described above and the rest were counts immediately followed
  by their items.

The repository's own gates run on this branch as usual: both fixture suites in CI, and the R-509
turn-level verification gate locally.

## Reflection

**Time since implementation.** The prose being replaced was last touched on 2026-09-19 in `bde12cd`
(pull request #69), roughly two days before this change, and the file has been contributor-facing
since the monorepo split in September.

**What I understand now that I did not at the start.** The two build skills are not two ways of
doing the same thing with different amounts of ceremony, which is what their names suggest from the
outside. They are answers to two different questions that happen to be asked at the same moment in a
build: "who approves this, and in what size piece" and "who is allowed to write this file right
now." The reason they overlap in the trigger space is that a person asking either question says
something that sounds like "let's build this." Writing the comparison table is what made that
legible; before it, the draft kept sliding into describing `tdd-gated-dispatch` as the strict version
of `build-by-slice-require-review`, which is wrong in a way that would have taught the reader the
wrong model.

**What I got wrong first.** Two things. The first is the absolute-claims problem described in the
architectural decisions above, which I caught only because the skill's advisory script flagged the
lines and I checked them rather than dismissing the flags. Left alone it would have shipped a
landing page asserting guarantees I had not observed, on a repository whose entire premise is that
unverified assertions are the failure mode. The second is smaller and of the same family: I wrote
the doctor check list out of `claude/SETUP.md` without opening `doctor.sh`, and the list was wrong.
Both errors are the same error, which is trusting a summary document because it was written by the
same project it describes.
