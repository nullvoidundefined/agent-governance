---
name: Never bypass TLS/SSL to make a deploy work
description: Security must never be compromised to unblock a deployment. No rejectUnauthorized:false
type: feedback
---

Never set `ssl: { rejectUnauthorized: false }`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, or any other TLS bypass to make a DB connection work. If SSL fails, investigate the certificate; do not disable verification.

The correct pg Pool SSL pattern:
```typescript
ssl: isProduction()
  ? { rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED !== "false" }
  : { rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED === "true" },
```
This defaults to strict TLS in production. Any deviation is a bug, not a configuration option.

**Why:** User discovered `ssl: { rejectUnauthorized: false }` in multiple production database pool configs and was emphatic: "we should NEVER undermine security to facilitate a deploy." This triggered a full portfolio-wide security audit.

**How to apply:**
- When writing or reviewing any pg Pool / DB client config, use the pattern above.
- When debugging SSL/TLS failures, treat "disable verification" as NEVER an acceptable fix. Investigate the root cause (missing CA cert, wrong hostname, self-signed cert, etc.).
- Applies to all DB clients and any other TLS-authenticated service.
