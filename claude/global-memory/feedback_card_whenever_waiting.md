---
name: feedback-card-whenever-waiting
description: Any turn that ends waiting on the user (approval, review, a decision, information) ends with an AskUserQuestion card, never a prose request
metadata:
  type: feedback
---

Whenever a turn pauses for the user, it ends with an `AskUserQuestion` card rather than a request written in prose. This covers every kind of wait: approving a spec, a design section, or a plan; reviewing a file; choosing between options; supplying a value, a credential location, or any other information; and confirming before a gated action. It applies in every project and every session.

**Why:** stated 2026-09-26 in doppelscript, after Claude ended a turn with "Reply 'approved' or with changes" in prose at the brainstorming spec-review gate, while earlier questions in the same session had used cards. A prose ask is easy to miss and gives no one-click answer; the card is the signal that the session is blocked on the user.

**How to apply:**

- Before ending any turn that needs the user to act, check: is there a card? If not, add one.
- Review gates get a card too: options like "Approved, continue" / "Changes needed" (the user types details through the automatic "Other" option).
- Open-ended information requests still get a card: offer the likely answers as options and rely on "Other" for free text.
- Keep the surrounding message short; the card carries the question, so do not also restate it as a prose ask.
- A turn that ends with work complete and nothing required from the user needs no card.
- One question per card and one card per turn still hold ([[feedback_ask_judgment_calls]], R-211).
