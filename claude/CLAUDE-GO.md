---
paths:
  - "**/*.go"
  - "**/go.mod"
---

# Go Backend Conventions

The Go track. Read on demand for Go service work. Mirrors `CLAUDE-BACKEND.md` (the TypeScript/Node track) and `CLAUDE-PYTHON.md`; the universal rules in `CLAUDE.md` still apply, this file carries the Go-specific specifics and the analogs of the `[ts]`-tagged rules. Where a global rule collides with a Go toolchain requirement or a strong community idiom, the exception is stated here and in `rulebook/reference.md`.

## Stack

- HTTP: stdlib `net/http` with `chi` for routing; handlers keep the stdlib signature
- Data: PostgreSQL via `pgx`; SQL lives in repositories, parameterized only
- Migrations: `golang-migrate`, paired `.up.sql`/`.down.sql` files
- Validation: request structs decoded with `encoding/json`, validated explicitly at the handler edge
- Config: env vars parsed into a `Config` struct at startup; fail fast on missing values
- Testing: stdlib `testing` with `google/go-cmp`; table-driven; integration tests hit a real database
- Lint/format: `gofmt` + `goimports` (non-negotiable), `go vet`, `golangci-lint` for the enforcement tier
- Deps: one `go.mod` per project

## Directory Structure

```
cmd/
└── api/
    └── main.go                # flag/env parsing, wire dependencies, start server
internal/                      # all application code; unimportable from outside
├── config/                    # Config struct + Load()
├── domain/                    # core types and sentinel errors; imports nothing internal
├── handlers/                  # HTTP edge: decode, validate, delegate, encode
├── services/                  # business logic (R-306)
├── repositories/              # all SQL; returns domain types
├── clients/                   # one package per external provider (R-306)
└── server/                    # router assembly, middleware
migrations/                    # golang-migrate .up.sql/.down.sql pairs
```

No `pkg/` unless code is genuinely published for external import. No `src/`. `cmd/<binary-name>/` may be kebab-case (the binary name is the public artifact, R-312 exception); everything else is a short lowercase package name.

## Layer Responsibilities

| Layer | Does | Does NOT |
|---|---|---|
| **Handlers** | Decode, validate, call services, write status + JSON | Contain business logic, run SQL |
| **Services** | Business logic; orchestrate repositories and clients | Import `net/http` |
| **Repositories** | Parameterized SQL via pgx, return domain types | Know about HTTP, validate input |
| **Clients** | Wrap one external provider | Hold domain logic |
| **Domain** | Types, sentinel errors | Import any other internal package |

Dependencies flow one direction (R-303): `handlers -> services -> repositories`, `services -> clients`, everything may import `domain`. Enforced structurally by the compiler: lower packages never import higher ones.

## Naming

- Packages: short, lowercase, single-word, named for what they provide (`config`, `handlers`); never `util`, `common`, `helpers`, `base` (R-306 holds fully in Go). `db` is acceptable Go usage for the connection package (R-311 exception).
- Identifiers: `MixedCaps`/`mixedCaps`, never underscores. Exported names carry doc comments.
- Functions: verb + noun (`FetchUser`, `BuildResume`); constructors are `NewX`. Booleans read as predicates: `IsExpired`, `HasAccess` (R-316 holds).
- R-317 exception: Go's idiomatic short names are correct in small scopes: `err`, `ok`, `ctx`, `i`, one-letter receivers. Descriptive names still required for anything that lives beyond a screen.
- Files: `snake_case.go` by responsibility (`score_match.go`); `doc.go` for package docs.

## File Layout (analog of R-321 [ts])

1. Package doc comment (in `doc.go` or atop the primary file, R-320).
2. `package` clause.
3. Imports, three goimports groups: stdlib, third-party, module-local.
4. Constants (`UPPER_SNAKE` is NOT Go style: use `MixedCaps` consts), then `var` blocks, then types.
5. Constructor, then methods, then helpers, caller above callee.

## Handler Pattern

```go
func (h *JobHandler) GetJob(w http.ResponseWriter, r *http.Request) {
    id, err := strconv.Atoi(chi.URLParam(r, "jobID"))
    if err != nil {
        respondError(w, http.StatusBadRequest, "invalid job id")
        return
    }
    job, err := h.jobs.GetByID(r.Context(), id)
    if errors.Is(err, domain.ErrNotFound) {
        respondError(w, http.StatusNotFound, "job not found")
        return
    }
    if err != nil {
        respondInternal(w, err)
        return
    }
    respondJSON(w, http.StatusOK, job)
}
```

Handlers are thin: decode, validate, delegate, encode. Guard clauses with early returns (R-321's guards-first in Go form); happy path stays left-aligned.

## Error Handling

- Wrap with context: `fmt.Errorf("scoring job %d: %w", id, err)`; check with `errors.Is`/`errors.As`.
- Sentinel errors live in `domain` (`domain.ErrNotFound`); repositories translate driver errors into them.
- No `panic` outside `main` startup; no swallowed errors (`_ = err` needs a comment stating why).
- Handlers map domain errors to status codes; internals never leak into response bodies.

## Environment Validation

`internal/config.Load()` reads env into a typed `Config`, validates every required field, and returns an error that `main` treats as fatal. Business code takes `Config` (or narrower structs) by injection; never reads `os.Getenv` directly. Secrets stay off-path and out of logs (R-102).

## Migrations

Raw SQL pairs via golang-migrate; write defaults directly in SQL (`DEFAULT 'active'`, `DEFAULT now()`), so the R-328 quoting trap does not arise. Same staged approach for risky changes: additive, backfill, switch, cleanup; never a destructive one-shot against production (R-101).

## Testing (R-401 in Go form)

- R-313 exception (toolchain requirement): tests are co-located `*_test.go` files in the same package directory; a separate test tree breaks package-internal access and `go test ./...`. This is the documented override, not drift.
- Table-driven tests with subtests (`t.Run`); assert outputs with `go-cmp`, not mock-call counts.
- Integration tests hit a real database (dockerized or testcontainers); never mock the repository under test.
- One negative-input test per handler (R-406): oversized payload, injection attempt, malformed JSON.
- LLM consumers include one fixture test against a real captured response (`testdata/`).
- No `t.Skip` to suppress a failing test; fix it or delete it (R-401 item 9).

## Tooling (analog of Prettier/ESLint)

- `gofmt` + `goimports` on staged files pre-commit (R-408); `go vet` and the full test suite pre-push (R-509).
- Trust the pre-commit hooks; do not manually re-run them (R-510).

## Enforcement (analog of push-eslint-gate)

- `hook:push-golangci-gate` runs the bundled `~/.claude/enforce/golangci-enforce.yml` over the outgoing Go diff on `git push`, added lines only: `mnd` (R-324 magic numbers) and `nolintlint` (R-329 analog: every `//nolint` carries a specific linter and reason). Opt-in per repo via `enforce/gate-trusted-repos.txt`, because linting Go compiles the tree and compiling untrusted code is a code-execution surface (2026-07-31 security audit); fails open without golangci-lint or off the trust list.
- `hook:llm-rule-judge` judges `*.go` in the outgoing diff (R-315/R-316/R-317/R-318/R-322/R-325).
- `hook:structure-gate` scans `internal/`-, `cmd/`-, and `pkg/`-rooted Go trees: catch-alls deny; dir-case checks are waived for Go (lowercase packages, kebab binary names); `db/` blessed.
- Ternaries do not exist in Go, so R-327 is structurally satisfied.

## Observability (R-341 to R-346 in Go form)

- R-341: middleware reads `X-Request-Id` or mints one, writes it to the response, and stores it in `context.Context`; handlers and services log through `slog` with the ID taken from the context (`slog.With("request_id", id)`), never as a parameter threaded by hand.
- R-342: `slog` with structured attributes (`slog.Info("note loaded", "note_id", id)`), never `fmt.Println` or `log.Printf` with formatted values in service code; manual, no golangci linter is bundled for it.
- R-343: one `clients/analytics` package wraps the provider; event names are constants in `analytics/events.go`, never a literal at the call site.
- R-344: every error return is handled or wrapped with `%w`; `_ = err` and an empty `if err != nil {}` are defects; `errcheck` and `errorlint` in `enforce/golangci-enforce.yml` cover the unhandled-return and wrapping halves (the config is v2 schema; a v1 file was silently ignored by v2 binaries until 2026-09-04).
- R-345: `/health` and `/health/ready` on every service and worker, registered first.
- R-346: every client call uses a `context.WithTimeout`, logs provider, operation, duration, and outcome, and forwards the request ID on outbound HTTP.
