---
paths:
  - "**/*.rb"
  - "**/Gemfile"
---

# Ruby on Rails Backend Conventions

The Ruby track. Read on demand for Rails API work. Mirrors `CLAUDE-BACKEND.md` (the TypeScript/Node track) and `CLAUDE-PYTHON.md`; the universal rules in `CLAUDE.md` still apply, this file carries the Ruby-specific specifics and the analogs of the `[ts]`-tagged rules.

## Stack

- Framework: Rails 7.x, API-only mode (`rails new --api`); JSON to the TS frontend tracks
- Server: Puma
- Data: PostgreSQL via ActiveRecord; complex reads may drop to `exec_query` inside models or query objects
- Migrations: ActiveRecord migrations in `db/migrate/`, guarded by `strong_migrations`
- Background jobs: ActiveJob with Sidekiq
- Serialization: `ActiveModel::Serializer` or plain `as_json` maps; one serializer per exposed model
- Config: Rails credentials for secrets, ENV validated at boot in an initializer
- Testing: RSpec + FactoryBot; request specs hit a real test database, not mocks
- Lint/format: RuboCop with `rubocop-rails` and `rubocop-rspec`; RuboCop is also the formatter
- Deps: one `Gemfile` per project

## Directory Structure

```
app/
├── controllers/               # thin HTTP edge; strong params, delegate, render
│   └── api/v1/jobs_controller.rb
├── models/                    # ActiveRecord: schema, validations, scopes, associations
│   └── job.rb
├── services/                  # business logic; one service object per operation (R-306)
│   └── jobs/
│       └── score_match.rb
├── clients/                   # wrappers around external SDKs/APIs (R-306)
│   └── stripe_client.rb
├── queries/                   # multi-model or complex read objects
├── serializers/               # response shaping, one per exposed model
├── jobs/                      # ActiveJob classes; thin, delegate to services
└── mailers/
config/                        # routes, initializers, credentials
db/migrate/                    # timestamped migrations
lib/                           # framework term of art: tasks, generators, code with no domain home
spec/                          # RSpec, mirrors app/ (R-313: spec/ tree, never co-located)
```

Rails is omakase: never rename or relocate the framework directories. `lib/` is blessed here as the Rails/Ruby term of art (R-306 exception); domain logic still goes to `app/services/`, not `lib/`.

## Layer Responsibilities

| Layer | Does | Does NOT |
|---|---|---|
| **Controllers** | Strong params, call a service or model, render serializer/JSON | Business logic, SQL, multi-step orchestration |
| **Services** | Business logic; orchestrate models, queries, clients | Know about request/response objects |
| **Models** | Persistence, validations, scopes, associations | Call services (no upward imports), talk HTTP |
| **Queries** | Complex or multi-model reads | Mutate state |
| **Clients** | Wrap one external provider | Hold domain logic |

Dependencies flow one direction (R-303): `controllers -> services -> models/queries`, and `services -> clients`. There is no separate repository layer: ActiveRecord models are the persistence layer; when a read outgrows a scope, it becomes a query object, not a fatter model.

## Naming

- Files and dirs: `snake_case.rb` matching the class name (`score_match.rb` defines `Jobs::ScoreMatch`), R-312 Ruby exception: snake_case directories.
- Service objects: `Verb + Noun` class with a single public `call` (the R-319 analog): `Jobs::ScoreMatch.call(job:)`.
- Predicate methods end in `?` (`expired?`, `admin?`); this is the Ruby analog of the `is`/`has` boolean prefix (R-316 exception): never `is_expired`.
- Bang methods (`save!`) reserved for raising variants.
- Constants: `UPPER_SNAKE` at class top; single-use literals stay beside their consumer (R-324).

## File Layout (analog of R-321 [ts])

1. `# frozen_string_literal: true`
2. File-header comment (R-320): what and why.
3. Class/module definition; `UPPER_SNAKE` constants first.
4. Public interface (for services: `call` only).
5. `private`, then helpers ordered caller above callee.

One class per file; the file path mirrors the namespace exactly.

## Controllers

```ruby
class Api::V1::JobsController < ApplicationController
  def show
    job = Job.find(params[:id])
    render json: JobSerializer.new(job)
  end

  def create
    result = Jobs::CreateJob.call(attributes: job_params)
    render json: JobSerializer.new(result), status: :created
  end

  private

  def job_params
    params.require(:job).permit(:title, :company, :url)
  end
end
```

Strong parameters always; never pass raw `params` down. Unexpected errors propagate to `rescue_from` handlers on `ApplicationController` (central domain-error -> status mapping); rescue specific errors locally only when the controller can add a useful message.

## Validation (analog of Zod-at-handler)

Validate at the edge: strong params for shape, model validations for domain invariants. One negative-input spec per endpoint (R-406): oversized payload, injection attempt, malformed encoding.

## Migrations (analog of R-328 [ts])

- Constant default: bare string or literal. `t.string :status, default: "active"`.
- SQL expression default: a lambda. `t.datetime :created_at, default: -> { "now()" }`; `t.uuid :id, default: -> { "gen_random_uuid()" }`.
- Never nested quotes (`default: "'active'"`) and never a SQL call as a bare string (`default: "now()"`).
- `strong_migrations` gem enforces the staged approach for risky changes: additive migration, backfill, switch, cleanup; never a destructive one-shot against production (R-101).

## Environment Validation

Secrets live in Rails credentials or ENV, never in code (R-102). An initializer asserts required ENV at boot and fails fast:

```ruby
%w[DATABASE_URL ANTHROPIC_API_KEY].each do |key|
  raise "missing ENV #{key}" if ENV[key].blank?
end
```

Never log a credential or `ENV` dump.

## Error Handling

`rescue_from` on `ApplicationController` maps domain errors (`ActiveRecord::RecordNotFound` -> 404, `ActiveRecord::RecordInvalid` -> 422) centrally. Never `rescue Exception`; rescue the narrowest class that can occur. No internals in response bodies.

## Logging

Structured logs via lograge (JSON). No secrets or PII (R-102, R-104). Tag request IDs; one log line per request in production.

## Testing (RSpec) (R-401 in Ruby form)

- Request specs over controller specs; assert status, body shape, and database effects, not mock-call counts.
- Real test database with transactional cleanup; never mock ActiveRecord in a model or query spec (the analog of mocking the pool).
- FactoryBot factories in `spec/factories/`; traits over duplicated factories.
- LLM consumers include one fixture spec against a real captured response.
- `spec/` mirrors `app/` (R-313); `*_spec.rb` never sits beside its source.
- No `skip`/`pending` to suppress a failing spec; fix it or delete it (R-401 item 9).

## Tooling (analog of Prettier/ESLint)

- RuboCop (with rails/rspec plugins) is lint and formatter; `bundle exec rubocop -a` on staged files pre-commit (R-408); full sweep pre-push/CI (R-509).
- Trust the pre-commit hooks; do not manually re-run them (R-510).

## Enforcement (analog of push-eslint-gate)

- `hook:push-rubocop-gate` runs the bundled `~/.claude/enforce/rubocop-enforce.yml` over the outgoing Ruby diff on `git push`, added lines only: `Style/NestedTernaryOperator` (R-327), `Naming/MethodName`/`Naming/VariableName`/`Naming/ConstantName` (R-316/R-317 support). Prefers `bundle exec rubocop` when the lockfile carries it; fails open without RuboCop.
- `hook:llm-rule-judge` judges `*.rb` in the outgoing diff (R-315/R-316/R-317/R-318/R-322/R-325).
- `hook:structure-gate` scans `app/`- and `lib/`-rooted Ruby trees: snake_case allowed, `lib/` and `db/` blessed; catch-alls, other abbreviations, and co-located specs deny.
- `hook:migration-defaults-guard` covers the Rails migration forms above.
