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

`CORS_ORIGIN` gets its own parser in the same initializer, run in every environment: `rack-cors` is configured with `credentials: true`, and a wildcard or `null` origin there hands the session cookie's single-origin boundary to any caller.

```ruby
# UNSAFE_CORS_ORIGINS names the values that would open the credentialed API to any site.
UNSAFE_CORS_ORIGINS = Set["*", "null"]
# Accepts scheme://host[:port] for the two browser schemes; the host must start with a
# letter or digit, and the port alternatives exclude each scheme's default (443, 80) and
# cap at 65535, since a browser never sends a default port or an out-of-range one.
# \A and \z anchor the whole string; Ruby's ^ and $ match at every line break.
BROWSER_ORIGIN_PATTERN = /\A(https:\/\/[a-z0-9][a-z0-9.-]*(:(?:[1-9][0-9]?|[1-35-9][0-9]{2}|4[0-35-9][0-9]|44[0-24-9]|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?|http:\/\/[a-z0-9][a-z0-9.-]*(:(?:[1-9]|[1-79][0-9]|8[1-9]|[1-9][0-9]{2}|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?)\z/

# Returns "" for a blank value, meaning no cross-origin caller is allowed.
def parse_cors_origin(raw_value)
  origin = raw_value.to_s.strip
  return "" if origin.empty?
  raise "CORS_ORIGIN must name one concrete origin, not a wildcard or null" if UNSAFE_CORS_ORIGINS.include?(origin.downcase)
  raise "CORS_ORIGIN must be scheme://host[:port] exactly as a browser sends it" unless BROWSER_ORIGIN_PATTERN.match?(origin)

  origin
end

cors_origin = parse_cors_origin(ENV["CORS_ORIGIN"])
raise "CORS_ORIGIN is required in production" if Rails.env.production? && cors_origin.empty?
unless cors_origin.empty?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins cors_origin
      resource "*", headers: :any, methods: %i[get post put patch delete], credentials: true
    end
  end
end
```

```ruby
RSpec.describe "parse_cors_origin" do
  it "returns a real origin unchanged" do
    expect(parse_cors_origin("https://app.example.com")).to eq("https://app.example.com")
  end

  unsafe_values = [
    "*",
    "null",
    "https://a.example,https://b.example",
    "https://client.example/path",
    "https://name@client.example",
  ]

  unsafe_values.each do |unsafe_value|
    it "refuses #{unsafe_value.inspect}" do
      expect { parse_cors_origin(unsafe_value) }.to raise_error(/CORS_ORIGIN/)
    end
  end

  ["", "   "].each do |blank_value|
    it "returns an empty string for #{blank_value.inspect}" do
      expect(parse_cors_origin(blank_value)).to eq("")
    end
  end
end
```

## Session Store

`secure` on the session cookie names development and nothing else; a check tied to production instead sends the cookie over plain HTTP in staging.

```ruby
cookies.signed[:session_token] = {
  value: raw_token,
  httponly: true,
  secure: !Rails.env.development?,
  same_site: :lax,
  expires: 7.days.from_now,
}
```

```ruby
RSpec.describe "session cookie" do
  it "is Secure and HttpOnly in staging" do
    user = User.create!(email: "user@example.com", password: "changeme")
    allow(Rails).to receive(:env).and_return("staging".inquiry)
    https! # Rails withholds a Secure cookie from a plain-HTTP request
    post "/v1/auth/login", params: { email: user.email, password: "changeme" }

    set_cookie_lines = Array(response.headers["Set-Cookie"]).flat_map { |header| header.split("\n") }
    session_cookie = set_cookie_lines.find { |line| line.start_with?("session_token=") }
    expect(session_cookie).to match(/;\s*secure/i)
    expect(session_cookie).to match(/;\s*httponly/i)
  end
end
```

## Error Handling

`rescue_from` on `ApplicationController` maps domain errors (`ActiveRecord::RecordNotFound` -> 404, `ActiveRecord::RecordInvalid` -> 422) centrally. Never `rescue Exception`; rescue the narrowest class that can occur. No internals in response bodies.

## Logging

This section lives in `CLAUDE-OBSERVABILITY.md`, which loads on every backend file in every stack alongside this one.

## Observability (R-341 to R-346 in Rails form)

This section lives in `CLAUDE-OBSERVABILITY.md`, which loads on every backend file in every stack alongside this one.

## Containers (R-351 in Rails form)

- The Rails app, its Sidekiq or Solid Queue worker, and any scheduled job ship their image definition in the commit that creates them; a gem does not.
- Rails 7.1+ generates a multi-stage `Dockerfile` (`ruby:3.3-slim` builder and runtime, `bundle install` with `BUNDLE_DEPLOYMENT=1`, assets precompiled in the builder, `USER rails`); keep it, pin the base tag, and add `HEALTHCHECK` on `/health` (R-345) for the web image; the worker image is the same file with `CMD ["bundle", "exec", "sidekiq"]` as `Dockerfile.worker`.
- `.dockerignore` beside the Dockerfile: `.git`, `.env*`, `log/`, `tmp/`, `spec/`, `node_modules`; `RAILS_MASTER_KEY` and every secret arrive as run-time environment variables, never `COPY`-ed credentials.
- `docker-compose.yml` runs web, worker, Postgres, and Redis for local development and request specs that need the full stack.

## Testing (RSpec) (R-401 in Ruby form)

- Request specs over controller specs; assert status, body shape, and database effects, not mock-call counts.
- Real test database with transactional cleanup; never mock ActiveRecord in a model or query spec (the analog of mocking the pool).
- FactoryBot factories in `spec/factories/`; traits over duplicated factories.
- LLM consumers include one fixture spec against a real captured response.
- `spec/` mirrors `app/` (R-313); `*_spec.rb` never sits beside its source.
- No `skip`/`pending` to suppress a failing spec; fix it or delete it (R-401 item 9).

- Test runs (R-509): run the full suite in parallel with `parallel_tests` (`bundle exec parallel_rspec`), one test database per process (`TEST_ENV_NUMBER`). Turn ends, commits, and branch-level merges run only the affected specs: the changed `*_spec.rb` files plus the specs mirroring changed `app/` files (`spec/` mirrors `app/`, R-313). The full parallel run happens as the required CI check before any merge to `main`, not at pre-push (IAN-98). Adding `parallel_tests` is a new dependency and needs its R-331 justification.
## Tooling (analog of Prettier/ESLint)

- RuboCop (with rails/rspec plugins) is lint and formatter; `bundle exec rubocop -a` on staged files pre-commit (R-408); full sweep pre-push/CI (R-509).
- Trust the pre-commit hooks; do not manually re-run them (R-510).

## Enforcement (analog of push-eslint-gate)

- `hook:push-rubocop-gate` runs the bundled `~/.claude/enforce/rubocop-enforce.yml` over the outgoing Ruby diff on `git push`, added lines only: `Style/NestedTernaryOperator` (R-327), `Naming/MethodName`/`Naming/VariableName`/`Naming/ConstantName` (R-316/R-317 support). PATH-resolved RuboCop only, never `bundle exec` (the target repo's Gemfile is untrusted code; 2026-07-31 security audit); fails open without RuboCop.
- `ci:llm-rule-judge` (the `rule-judge` CI check) judges `*.rb` in each pull request's diff (R-315/R-316/R-317/R-325/R-334, the manifest's llm-judge tier).
- `hook:structure-gate` scans `app/`- and `lib/`-rooted Ruby trees: snake_case allowed, `lib/` and `db/` blessed; catch-alls, other abbreviations, and co-located specs deny.
- `hook:migration-defaults-guard` covers the Rails migration forms above.
