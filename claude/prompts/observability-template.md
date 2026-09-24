# {{PROJECT}} Observability

The catalog of everything this application can dispatch: analytics events,
structured log events, error codes, error-tracker reports, request IDs,
health checks, and metrics.

Last updated: {{DATE}} (observability catalog created)

<!--
R-608: this file lists what the code can emit, one row per item, so a reader
can answer "what fires when" without reading the code. Update it in the same
task that adds, renames, or removes any item below, and rewrite the Last
updated line with the date and what changed. A removed item loses its row.
The registries are the sources of truth: analytics/events.* (R-343), the
error-code registry, and the logger calls (R-342). Leave a section with no
rows as "None." rather than deleting its heading. Never write a secret or
PII value into an example (R-104).
-->

## Analytics events

Registry: `<path to analytics/events.*>`. Client: `<path to clients/analytics>`.

| Event | Side | Trigger | Properties | Identity key |
| ----- | ---- | ------- | ---------- | ------------ |

None.

## Log events

Logger: `<path to the logger module>`. Every line carries `request_id` (or
`jobId` in a worker).

| Event | Level | Emitted when | Fields |
| ----- | ----- | ------------ | ------ |

None.

## Error codes

Registry: `<path to the error-code registry>`.

| Code | HTTP status | Fires when | Reported to tracker |
| ---- | ----------- | ---------- | ------------------- |

None.

## Error tracker

- **Provider:** <name, or none>
- **Tags:** <the tags set on every report, such as request_id, user id hash, release, environment>
- **Scrubbing:** <the fields and headers removed or masked before a report leaves the process>
- **Sampling:** <error and trace sample rates>

## Request ID propagation

<The path an ID takes: the inbound `X-Request-Id` header or the minted ID,
where it is bound to the request context, the response header that echoes it,
the log field that carries it, and the outbound calls and jobs it is
forwarded to (R-341, R-346).>

## Health endpoints

| Endpoint | Kind | Checks | Degraded response |
| -------- | ---- | ------ | ----------------- |
| `GET /health` | liveness | none | never degrades |
| `GET /health/ready` | readiness | <dependencies> | 503 with the failing check |

## Metrics

None.
