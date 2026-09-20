# R-334's separator follows the engine's case convention

Ticket: IAN-175. Branch: `refactor/r334-engine-case-convention`. Tier: standard.

## Summary

R-334 fixes how a compound identifier is built: the base noun comes first, the aggregate root is repeated by every entity inside the aggregate, and the words are joined with underscores. The word-order half of that rule is about meaning and is worth enforcing everywhere. The separator half is about typography, and it was written as though PostgreSQL and Python were the only places a name can live. This change keeps the first half exactly as it was and makes the second half follow whatever the engine or the language already uses.

The concrete trigger was the MongoDB convention track (IAN-173, blocked on this PR): a Mongo collection called `tripLegs` and a Postgres table called `trip_legs` are the same name under any sensible reading of R-334, but the rule as written called one of them a defect, and the CI rule judge, which reads `.js` and `.ts`, would have agreed with the rule rather than with the reader.

## What changed

- `claude/CLAUDE.md`: the R-334 norm line now says the word order is fixed while the separator follows the case convention of the engine or language the name lives in, and it carries both example forms (`trip_legs` in Postgres, `tripLegs` in MongoDB) in place of the two underscore-only examples.
- `claude/rulebook/reference.md`: a new Spec bullet states the split between word order and separator and lists the conventions per engine and language; the forms-by-layer bullet notes that the `snake_case` forms transliterate; the foreign-key bullet now names both `{referenced_table_singular}_id` and `{referencedEntitySingular}Id`; the Enforcement paragraph tells the judge to read the name's engine case convention, so a camelCase name is not judged against the underscore form.
- `claude/enforce/tests/r334-engine-case-rule-text.test.sh`: a new fixture, modelled on `wall-time-rule-text.test.sh`, asserting each of those literals in `CLAUDE.md`, in `rulebook/reference.md`, and in the generated Cursor port, and forbidding the stale wording in each place rather than only requiring the new.
- The regenerated Codex and Cursor ports, and the one new line in `claude/enforce/hook-hashes.txt`.

## Architectural decisions

**Amend the rule rather than exempt the engine.** The alternative was to leave R-334 alone and write the MongoDB track with an exemption ("R-334 does not apply to document stores"). That was rejected because the part of R-334 that matters most, the aggregate root appearing in every name inside the aggregate, is exactly the part a document store needs; an exemption would have dropped the meaning rule to avoid the typography rule.

**Amend it in its own PR rather than inside the split.** The owner's call, and the right one: a rule change buried in a twelve-file documentation split gets reviewed as part of the split, not on its own merits. The split's spec now records that it depends on this PR.

**Forbid the stale wording, not only require the new.** A fixture that only greps for the new sentence passes on a file that says both things. Each assertion here has a matching `forbidIn` or `forbidText`, so a half-applied amendment fails.

**Keep the judge as the enforcer.** No deterministic gate can decide whether `tripLegs` carries its aggregate root without the project's glossary, which is why R-334 is an `llm-judge` rule in the first place. This change adds nothing to the judge's payload, which carries only the rule set, the diff, and the project vocabulary: the Spec it already receives now names the convention per engine and per language, and the changed file's extension carries the language. The review caught an earlier draft of this paragraph claiming a new input that does not exist.

## Testing

`bash claude/enforce/tests/r334-engine-case-rule-text.test.sh` passes, and failed before the amendment with `FAIL: CLAUDE.md R-334 norm line does not say that the separator follows the case convention of the engine or language the name lives in`. The RED was certified through `tdd.sh red` (failure class: assertion, 95 tests passing outside the named one) and the GREEN through `tdd.sh green` against the same baseline. `run-tests.sh --affected`, `node translate/codex.mjs --check`, `node translate/cursor.mjs --check`, and `hook-integrity-check.sh` all pass after a rebase onto #89.

## Reflection

Two things this took longer to see than it should have.

The first is that the rule's two halves were doing different jobs. Reading R-334 as a single rule about naming made the MongoDB question look like a conflict between the rule and an ecosystem, which invites an exemption. Reading it as a rule about word order that happens to also specify a separator made the amendment obvious and small: one clause, one bullet, and a sentence for the judge.

The second is procedural. The first attempt at proving the RED failed twice for reasons that had nothing to do with the test: a new fixture has no line in the integrity manifest, which turns a different fixture red, which makes `tdd.sh red` refuse to certify anything; and `hook-latency.test.sh` is a timing fixture that fails when two suites run at once, which is what happens when a second RED run is launched while the first is still going. Neither failure was in the code under test. The lesson worth keeping is that `tdd.sh red` exits 0 when it refuses to certify, so the exit status is not the verdict; the printed `RED:` line is.

The third is that the review caught this document, not only the code. An earlier draft of the decisions section said the amendment "gives the judge one more input", and the Enforcement paragraph in the rule itself said the judge is told the engine convention. Neither was true: the judge payload carries the rule set, the diff, and the project vocabulary, and nothing else. Writing a sentence about an enforcer is as capable of drifting from the enforcer as code is, which is the case R-516 is built around and the reason the fixture now asserts the corrected wording.

Time since implementation: written in the same session as the change, roughly forty minutes after the slice opened.
