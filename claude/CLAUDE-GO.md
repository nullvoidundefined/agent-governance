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

`CORS_ORIGIN` goes through its own parser inside `config.Load()`, in every environment: the CORS middleware sends `Access-Control-Allow-Credentials: true`, and a wildcard or `null` origin there hands the session cookie's single-origin boundary to any caller.

```go
// internal/config/config.go

// Config holds the settings Load reads; the real struct carries every required field.
type Config struct {
    Environment string
    CORSOrigin  string
}

// Load reads the environment once; an unsafe CORS_ORIGIN stops the process at startup.
func Load() (Config, error) {
    corsOrigin, err := parseCORSOrigin(os.Getenv("CORS_ORIGIN"))
    if err != nil {
        return Config{}, err
    }
    environment := os.Getenv("ENVIRONMENT")
    if environment == "production" && corsOrigin == "" {
        return Config{}, errors.New("CORS_ORIGIN is required in production")
    }
    return Config{Environment: environment, CORSOrigin: corsOrigin}, nil
}

// unsafeCORSOrigins names the values that would open the credentialed API to any site.
var unsafeCORSOrigins = map[string]bool{"*": true, "null": true}

// browserOriginPattern accepts scheme://host[:port] for the two browser schemes; the host
// must start with a letter or digit, and the port alternatives exclude each scheme's
// default (443, 80) and cap at 65535, since a browser never sends a default or out-of-range port.
var browserOriginPattern = regexp.MustCompile(`^(https://[a-z0-9][a-z0-9.-]*(:(?:[1-9][0-9]?|[1-35-9][0-9]{2}|4[0-35-9][0-9]|44[0-24-9]|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?|http://[a-z0-9][a-z0-9.-]*(:(?:[1-9]|[1-79][0-9]|8[1-9]|[1-9][0-9]{2}|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?)$`)

// parseCORSOrigin returns "" for a blank value, meaning no cross-origin caller is allowed.
func parseCORSOrigin(raw string) (string, error) {
    origin := strings.TrimSpace(raw)
    if origin == "" {
        return "", nil
    }
    if unsafeCORSOrigins[strings.ToLower(origin)] {
        return "", fmt.Errorf("CORS_ORIGIN must name one concrete origin, not a wildcard or null")
    }
    if !browserOriginPattern.MatchString(origin) {
        return "", fmt.Errorf("CORS_ORIGIN must be scheme://host[:port] exactly as a browser sends it")
    }
    return origin, nil
}

// internal/server/cors.go

// newCORSMiddleware passes cfg.CORSOrigin, parsed by Load, to go-chi/cors. go-chi/cors reads
// an empty AllowedOrigins as allow-all, so a blank origin installs no CORS middleware at all.
func newCORSMiddleware(cfg config.Config) func(http.Handler) http.Handler {
    if cfg.CORSOrigin == "" {
        return func(next http.Handler) http.Handler { return next }
    }
    return cors.Handler(cors.Options{
        AllowedOrigins:   []string{cfg.CORSOrigin},
        AllowCredentials: true,
    })
}
```

```go
func TestParseCORSOriginReturnsRealOriginUnchanged(t *testing.T) {
    got, err := parseCORSOrigin("https://app.example.com")
    if err != nil {
        t.Fatalf("parseCORSOrigin(%q) = %v, want nil error", "https://app.example.com", err)
    }
    if got != "https://app.example.com" {
        t.Errorf("parseCORSOrigin(%q) = %q, want it unchanged", "https://app.example.com", got)
    }
}

func TestParseCORSOriginRefusesUnsafeValues(t *testing.T) {
    unsafeValues := []string{
        "*",
        "null",
        "https://a.example,https://b.example",
        "https://client.example/path",
        "https://name@client.example",
    }
    for _, unsafeValue := range unsafeValues {
        if _, err := parseCORSOrigin(unsafeValue); err == nil {
            t.Errorf("parseCORSOrigin(%q) = nil error, want refusal", unsafeValue)
        }
    }
}

func TestParseCORSOriginReturnsEmptyForBlankValue(t *testing.T) {
    for _, blankValue := range []string{"", "   "} {
        got, err := parseCORSOrigin(blankValue)
        if err != nil {
            t.Errorf("parseCORSOrigin(%q) = %v, want nil error", blankValue, err)
        }
        if got != "" {
            t.Errorf("parseCORSOrigin(%q) = %q, want \"\"", blankValue, got)
        }
    }
}

// Load is the one function that reads the environment, so this is the one test that sets it.
func TestLoadRequiresCORSOriginInProduction(t *testing.T) {
    t.Setenv("ENVIRONMENT", "production")
    t.Setenv("CORS_ORIGIN", "")
    _, err := Load()
    if err == nil {
        t.Error("Load() with a blank CORS_ORIGIN in production = nil error, want a refusal")
    }
}
```

## Session Store

The session cookie's `Secure` flag names development and nothing else; a flag tied to a production check sends the cookie over plain HTTP in staging.

```go
// setSessionCookie writes the session cookie, Secure in every environment but development.
func setSessionCookie(w http.ResponseWriter, cfg config.Config, rawToken string) {
    http.SetCookie(w, &http.Cookie{
        Name:     sessionCookieName,
        Value:    rawToken,
        HttpOnly: true,
        Secure:   cfg.Environment != "development",
        SameSite: http.SameSiteLaxMode,
        Path:     "/",
        MaxAge:   int(sessionTTL.Seconds()),
    })
}
```

```go
func TestSessionCookieIsSecureInStaging(t *testing.T) {
    cfg := config.Config{Environment: "staging"}
    rr := httptest.NewRecorder()
    setSessionCookie(rr, cfg, "raw_token")

    cookies := rr.Result().Cookies()
    if len(cookies) != 1 {
        t.Fatalf("got %d cookies, want 1", len(cookies))
    }
    cookie := cookies[0]
    if !cookie.Secure {
        t.Errorf("cookie.Secure = false, want true in staging")
    }
    if !cookie.HttpOnly {
        t.Errorf("cookie.HttpOnly = false, want true in staging")
    }
}
```

## Migrations

Raw SQL pairs via golang-migrate; write defaults directly in SQL (`DEFAULT 'active'`, `DEFAULT now()`), so the R-328 quoting trap does not arise. Same staged approach for risky changes: additive, backfill, switch, cleanup; never a destructive one-shot against production (R-101).

## Testing (R-401 in Go form)

- R-313 exception (toolchain requirement): tests are co-located `*_test.go` files in the same package directory; a separate test tree breaks package-internal access and `go test ./...`. This is the documented override, not drift.
- Table-driven tests with subtests (`t.Run`); assert outputs with `go-cmp`, not mock-call counts.
- Integration tests hit a real database (dockerized or testcontainers); never mock the repository under test.
- One negative-input test per handler (R-406): oversized payload, injection attempt, malformed JSON.
- LLM consumers include one fixture test against a real captured response (`testdata/`).
- No `t.Skip` to suppress a failing test; fix it or delete it (R-401 item 9).

- Test runs (R-509): `go test` already runs packages in parallel; mark independent tests `t.Parallel()` and keep them free of shared globals so they can run in parallel. Turn ends, commits, and branch-level merges test only the packages containing changed files plus every package that depends on one of them: find the changed packages with `go list -f '{{.ImportPath}} {{.Dir}}' ./...` against the changed directories, then list each package's dependencies with `go list -f '{{.ImportPath}} {{join .Deps " "}}' ./...` and keep the packages whose dependency list contains a changed package (`.Deps` lists what a package imports, so the selection is the reverse lookup, not the command's output as printed); the full `go test ./...` runs as the required CI check before any merge to `main`, not at pre-push (IAN-98).
## Tooling (analog of Prettier/ESLint)

- `gofmt` + `goimports` on staged files pre-commit (R-408); `go vet` through the golangci push gate, and the full test suite in CI (R-509).
- Trust the pre-commit hooks; do not manually re-run them (R-510).

## Enforcement (analog of push-eslint-gate)

- `hook:push-golangci-gate` runs the bundled `~/.claude/enforce/golangci-enforce.yml` over the outgoing Go diff on `git push`, added lines only: `mnd` (R-324 magic numbers) and `nolintlint` (R-329 analog: every `//nolint` carries a specific linter and reason). Opt-in per repo via `enforce/gate-trusted-repos.txt`, because linting Go compiles the tree and compiling untrusted code is a code-execution surface (2026-07-31 security audit); fails open without golangci-lint or off the trust list.
- `ci:llm-rule-judge` (the `rule-judge` CI check) judges `*.go` in each pull request's diff (R-315/R-316/R-317/R-325/R-334, the manifest's llm-judge tier).
- `hook:structure-gate` scans `internal/`-, `cmd/`-, and `pkg/`-rooted Go trees: catch-alls deny; dir-case checks are waived for Go (lowercase packages, kebab binary names); `db/` blessed.
- Ternaries do not exist in Go, so R-327 is structurally satisfied.

## Containers (R-351 in Go form)

- Every `cmd/<artifact>/main.go` ships its `Dockerfile` in the commit that creates it (`Dockerfile` for the single artifact, `Dockerfile.<artifact>` when the module builds more than one); a library module does not.
- Multi-stage: a `golang:1.23` builder runs `go build -trimpath -ldflags="-s -w" -o /out/<artifact> ./cmd/<artifact>` with `CGO_ENABLED=0`; the runtime stage is `gcr.io/distroless/static:nonroot` (already non-root, `USER nonroot` stated anyway) and copies only the binary.
- `HEALTHCHECK` cannot shell out in distroless; the platform healthcheck on `/health` (R-345) is the probe, and the Dockerfile documents that in a comment above `ENTRYPOINT`.
- `.dockerignore` beside the Dockerfile: `.git`, `.env*`, `*_test.go`, `testdata/`; configuration is environment variables at run time, never a build argument.
- `docker-compose.yml` runs the service with its dependencies for local development and integration tests (the same Postgres the testcontainers path uses).

## Observability (R-341 to R-346 in Go form)

This section lives in `CLAUDE-OBSERVABILITY.md`, which loads on every backend file in every stack alongside this one.
