---
name: Mock third-party services behind abstractions
description: Wrap external SaaS in service interfaces with mocks; track real wiring in TODO_BEFORE_LAUNCH.md
type: feedback
---

Wrap all third-party service integrations (analytics, monitoring, feature flags, payment processors, LLM providers, email, SMS) in a service abstraction with a mock implementation for dev. Track "wire up the real service before launch" in a `TODO_BEFORE_LAUNCH.md` file at repo root.

**Why:** Avoids coupling to specific vendors during development. Keeps the app runnable without external accounts, keys, or quota. Defers vendor lock-in decisions. Enables deterministic testing without hitting real APIs. Related to the "mock external APIs in E2E" rule: E2E tests must mock outbound third-party calls; a separate nightly real-API smoke suite proves live wiring.

**How to apply:**
- When a design calls for PostHog, DataDog, Segment, LaunchDarkly, Twilio, Resend, Stripe, SerpApi, Google Places, Amadeus, ElevenLabs, etc., create a service interface (`AnalyticsService`, `NotificationService`, etc.) with a mock implementation that logs to console.
- Add a line item to `TODO_BEFORE_LAUNCH.md` for the real integration, including: vendor, env vars required, how to get credentials, which interface method implementations need replacing.
- E2E tests use the mock. Nightly real-API smoke suite (separate, gated behind env flag) uses the real implementation.
