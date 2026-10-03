---
paths:
  - "**/*.go"
  - "**/go.mod"
---

# Go Backend Conventions

Stack: stdlib `net/http` with `chi` (handlers keep the stdlib signature), PostgreSQL via `pgx` (parameterized only), `golang-migrate` with paired `.up.sql`/`.down.sql`, request structs decoded with `encoding/json` and validated explicitly, env parsed into a `Config` struct at startup, stdlib `testing` with `google/go-cmp`, `gofmt` + `goimports`, `go vet`, one `go.mod` per project.

## Layout

```
cmd/<binary>/main.go   # parse flags/env, wire dependencies, start server
internal/{config,domain,handlers,services,repositories,clients,server}
migrations/
```

- No `pkg/` unless code is published for external import. No `src/`. `cmd/<binary>` may be kebab-case; every other package is short and lowercase.
- Handlers decode, validate, call services, and write status plus JSON. No business logic or SQL.
- Services hold business logic and never import `net/http`.
- Repositories run parameterized pgx SQL, return domain types, and know nothing about HTTP.
- Clients wrap one external provider. `domain` holds types and sentinel errors and imports no other internal package.
- Dependencies flow `handlers -> services -> repositories`, `services -> clients`; everything may import `domain`.

## Naming and files

- Packages: single lowercase word named for what it provides. Never `util`, `common`, `helpers` or `base`. `db` is fine for the connection package.
- `MixedCaps`/`mixedCaps`, no underscores, including constants (not `UPPER_SNAKE`). Exported names carry doc comments.
- Functions are verb plus noun (`FetchUser`); constructors `NewX`; booleans read as predicates (`IsExpired`). Short names (`err`, `ok`, `ctx`, `i`, one-letter receivers) are fine in small scopes.
- Files are `snake_case.go` by responsibility; `doc.go` for package docs.
- File order: package doc, `package`, imports in three goimports groups (stdlib, third-party, module-local), consts, vars, types, constructor, methods, helpers (caller above callee).

## Handlers and errors

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

- Guard clauses with early returns; keep the happy path left-aligned.
- Wrap errors with context (`fmt.Errorf("scoring job %d: %w", id, err)`) and check with `errors.Is`/`errors.As`.
- Sentinel errors live in `domain`; repositories translate driver errors into them. Handlers map domain errors to status codes and never leak internals into response bodies.
- No `panic` outside `main` startup. No swallowed errors; `_ = err` needs a comment saying why.

## Config and security

- `config.Load()` reads env into a typed `Config`, validates every required field, and returns an error `main` treats as fatal. Business code takes `Config` by injection and never calls `os.Getenv`. Never log secrets.
- Parse `CORS_ORIGIN` inside `Load()` in every environment: trim, return `""` for blank, reject `*`, `null`, lists, paths and userinfo, require `scheme://host[:port]`, and make it required in production. `go-chi/cors` treats an empty `AllowedOrigins` as allow-all, so with a blank origin install no CORS middleware at all. With `AllowCredentials: true` a wildcard hands the session cookie to any site.
- Session cookie: `HttpOnly: true`, `Secure: cfg.Environment != "development"` (not a production check, which leaves staging on plain HTTP), `SameSite: http.SameSiteLaxMode`, `Path: "/"`.
- Migrations: write defaults directly in SQL (`DEFAULT 'active'`, `DEFAULT now()`). Risky changes are staged (additive, backfill, switch, cleanup), never a destructive one-shot against production.

## Containers

- Every `cmd/<artifact>/main.go` ships a Dockerfile in the commit that creates it (`Dockerfile.<artifact>` when the module builds more than one). Libraries ship none.
- Multi-stage: `golang:1.23` builder with `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/<artifact> ./cmd/<artifact>`, runtime `gcr.io/distroless/static:nonroot` with only the binary. Distroless cannot shell out, so use the platform's `/health` probe and note that in a comment above `ENTRYPOINT`.
- `.dockerignore` excludes `.git`, `.env*`, `*_test.go`, `testdata/`. Configuration is run-time environment variables, never build arguments. `docker-compose.yml` runs the service with its dependencies.

## Testing

- Tests are co-located `*_test.go` files in the same package directory (Go toolchain requirement).
- Table-driven tests with `t.Run`; assert outputs with `go-cmp`, not mock-call counts.
- Integration tests hit a real database (dockerized or testcontainers); never mock the repository under test.
- One negative-input test per handler (oversized payload, injection attempt, malformed JSON). A security control gets a test feeding it the insecure value (unsafe `CORS_ORIGIN` refused; staging cookie is `Secure`).
- LLM consumers get one fixture test against a real captured response in `testdata/`. Never `t.Skip` to hide a failing test.
- Mark independent tests `t.Parallel()` and avoid shared globals. Locally test changed packages and their dependents; CI runs `go test ./...`. Run `gofmt` and `goimports` on changed files.
