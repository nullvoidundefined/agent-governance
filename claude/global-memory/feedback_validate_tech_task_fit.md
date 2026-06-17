---
name: feedback_validate_tech_task_fit
description: When a learning goal is paired with a product idea, validate that the technology fits the task and data on day one, before building
metadata:
  type: feedback
---

When the user pairs a **learning goal** ("I want to learn X") with a **product idea** ("let's build Y"), validate that the technology actually fits the task and the data BEFORE building anything. Do not assume the product is a good vehicle for the learning.

**Why:** A project meant to teach vector databases was built as a recommender whose real queries were reasoning/intent tasks (identify-an-item-from-a-fuzzy-description, compositional multi-constraint "vibe" requests). Those are LLM strengths and embedding weaknesses, so vector search was the wrong primary tool and lost to a plain LLM call. The mismatch surfaced only after weeks of work, and the user concluded they had been building under a false pretense. The miss was not flagging the technology-vs-task mismatch at kickoff.

**How to apply:** At the start of any "learn <technology> by building <product>" request, ask whether the product's core task plays to the technology's strengths, and say so immediately if it does not. For vector databases specifically, the good fit is *find-similar over a large corpus with a measurable ground truth*; reasoning, intent, and lookup tasks belong to an LLM. Separate "the product the user wants" from "the thing that teaches the technology" when they pull apart, and propose either an LLM-first product or a different, technology-native learning project rather than bending one into the other. Related: [[feedback_model_routing]].
