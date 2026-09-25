#!/usr/bin/env bash
# Shard: slow
# Covers: hook:push-golangci-gate
# Verifies the Go data-access checker (enforce/data-access/go/main.go) that
# push-golangci-gate.sh runs for R-361 and R-362. The checker is built once
# with the local go toolchain (stdlib only, no network); a build failure, a
# crash, or output that is not a JSON array fails the fixture, so it can never
# pass vacuously.
#
# R-361 (a query in a loop):
#   1. A repository call in a range body reports.
#   2. pool.Query in a three-clause for body reports.
#   3. A goroutine literal calling QueryRow inside a loop reports.
#   4. A query in the range expression runs once and passes.
#   5. One = ANY($1) query, then a loop over its rows, passes.
#   6. SendBatch set up in a loop, and reading the batch results, passes.
#   7. A call that is not data access, inside a loop, passes.
#   8. A helper declared elsewhere and called in a loop is not followed.
#   9. data-access-allow with a reason suppresses; without a reason it does not.
#  10. _test.go files are exempt.
#
# R-362 (transactions):
#  11. pool.Exec inside a BeginFunc callback reports.
#  12. tx.Exec inside the callback passes.
#  13. A repository call that receives tx passes.
#  14. http.Get inside a BeginFunc callback reports.
#
# Robustness:
#  15. An unparsable file does not crash the checker and yields no findings.
#  16. No arguments exits 2.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECKER_SRC="$CLAUDE_HARNESS_ROOT/enforce/data-access/go/main.go"
GO="${CLAUDE_GO_CMD:-go}"
command -v "$GO" >/dev/null 2>&1 || { echo "FAIL: no go toolchain ($GO) to build the data-access checker"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Build from the checker's own directory so no surrounding module or GOFLAGS
# changes how it compiles, and forbid a toolchain download (no network).
(cd "$(dirname "$CHECKER_SRC")" && GOFLAGS="" GOWORK=off GOTOOLCHAIN=local "$GO" build -o "$TMP/checker" main.go) \
  || { echo "FAIL: the data-access checker does not compile"; exit 1; }
cd "$TMP"
mkdir -p internal/services internal/repositories

LAST=""
# Runs the checker on one file; a non-zero exit or non-array output fails.
check() {
  local status=0
  LAST=$("$TMP/checker" "$1" 2>&1) || status=$?
  [ "$status" -eq 0 ] || { echo "FAIL: checker exited $status on $1"; printf '%s\n' "$LAST"; exit 1; }
  jq -e 'type == "array"' <<< "$LAST" >/dev/null 2>&1 || { echo "FAIL: checker output on $1 is not a JSON array"; printf '%s\n' "$LAST"; exit 1; }
}
# expect_report <file> <rule> <line> <description>
expect_report() {
  check "$1"
  jq -e --arg rule "$2" --argjson line "$3" 'any(.[]; .rule == $rule and .line == $line)' <<< "$LAST" >/dev/null \
    || { echo "FAIL: $4"; echo "--- findings ---"; printf '%s\n' "$LAST"; exit 1; }
}
# expect_clean <file> <description>
expect_clean() {
  check "$1"
  [ "$(jq 'length' <<< "$LAST")" -eq 0 ] || { echo "FAIL: $2"; echo "--- findings ---"; printf '%s\n' "$LAST"; exit 1; }
}

# --- R-361 -----------------------------------------------------------------
cat > internal/services/range_repo.go <<'GO'
package services

func (s *TripService) ListTrips(ctx context.Context, tripIDs []string) ([]domain.Trip, error) {
	trips := make([]domain.Trip, 0, len(tripIDs))
	for _, tripID := range tripIDs {
		trip, err := s.tripRepository.GetTrip(ctx, tripID)
		if err != nil {
			return nil, err
		}
		trips = append(trips, trip)
	}
	return trips, nil
}
GO
expect_report internal/services/range_repo.go R-361 6 "a repository call in a range body must report"

cat > internal/repositories/three_clause.go <<'GO'
package repositories

func (r *JobRepository) Touch(ctx context.Context, ids []int64) error {
	for i := 0; i < len(ids); i++ {
		rows, err := r.pool.Query(ctx, "SELECT id FROM jobs WHERE id = $1", ids[i])
		if err != nil {
			return err
		}
		rows.Close()
	}
	return nil
}
GO
expect_report internal/repositories/three_clause.go R-361 5 "pool.Query in a three-clause for body must report"

cat > internal/services/goroutine.go <<'GO'
package services

func (s *JobService) Load(ctx context.Context, ids []int64) {
	var wg sync.WaitGroup
	for _, id := range ids {
		wg.Add(1)
		go func(jobID int64) {
			defer wg.Done()
			var name string
			_ = s.pool.QueryRow(ctx, "SELECT name FROM jobs WHERE id = $1", jobID).Scan(&name)
		}(id)
	}
	wg.Wait()
}
GO
expect_report internal/services/goroutine.go R-361 10 "a goroutine literal calling QueryRow in a loop must report (parallel N+1 is still N+1)"

cat > internal/repositories/range_expr.go <<'GO'
package repositories

func (r *JobRepository) Names(ctx context.Context) []string {
	var names []string
	for _, job := range r.mustList(r.pool.Query(ctx, "SELECT id, name FROM jobs LIMIT $1", maxPageSize)) {
		names = append(names, job.Name)
	}
	return names
}
GO
expect_clean internal/repositories/range_expr.go "a query in the range expression runs once and must pass"

cat > internal/repositories/any_query.go <<'GO'
package repositories

func (r *LegRepository) ListLegsByTripIDs(ctx context.Context, tripIDs []string) (map[string][]domain.Leg, error) {
	rows, err := r.pool.Query(ctx, "SELECT id, trip_id FROM legs WHERE trip_id = ANY($1) ORDER BY id", tripIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	legsByTrip := make(map[string][]domain.Leg, len(tripIDs))
	for rows.Next() {
		var leg domain.Leg
		if err := rows.Scan(&leg.ID, &leg.TripID); err != nil {
			return nil, err
		}
		legsByTrip[leg.TripID] = append(legsByTrip[leg.TripID], leg)
	}
	return legsByTrip, rows.Err()
}
GO
expect_clean internal/repositories/any_query.go "one ANY(\$1) query then a loop over rows must pass"

cat > internal/repositories/batch.go <<'GO'
package repositories

func (r *JobRepository) Archive(ctx context.Context, ids []int64) error {
	batch := &pgx.Batch{}
	for _, id := range ids {
		batch.Queue("UPDATE jobs SET archived = true WHERE id = $1", id)
	}
	results := r.pool.SendBatch(ctx, batch)
	defer results.Close()
	for range ids {
		if _, err := results.Exec(); err != nil {
			return err
		}
	}
	return nil
}
GO
expect_clean internal/repositories/batch.go "SendBatch set up in a loop and its results read in a loop must pass"

cat > internal/services/not_data.go <<'GO'
package services

func Titles(jobs []domain.Job, r *http.Request) []string {
	titles := make([]string, 0, len(jobs))
	for _, job := range jobs {
		titles = append(titles, strings.ToUpper(job.Title)+r.URL.Query().Get("suffix"))
	}
	return titles
}
GO
expect_clean internal/services/not_data.go "a call that is not data access, in a loop, must pass"

cat > internal/services/helper.go <<'GO'
package services

func (s *JobService) loadOne(ctx context.Context, id int64) (domain.Job, error) {
	return s.jobRepository.Get(ctx, id)
}

func (s *JobService) LoadAll(ctx context.Context, ids []int64) {
	for _, id := range ids {
		_, _ = s.loadOne(ctx, id)
	}
	fetch := func(id int64) (domain.Job, error) { return s.jobRepository.Get(ctx, id) }
	_ = fetch
}
GO
expect_clean internal/services/helper.go "a helper declared elsewhere, and a literal only assigned, must not be followed (documented limit)"

cat > internal/services/allow.go <<'GO'
package services

func (s *JobService) Drain(ctx context.Context) {
	for {
		// data-access-allow: keyset batching, one query per 1000 rows
		n, _ := s.jobRepository.DeleteBatch(ctx, 1000)
		if n == 0 {
			return
		}
	}
}
GO
expect_clean internal/services/allow.go "data-access-allow with a reason must suppress"

cat > internal/services/allow_noreason.go <<'GO'
package services

func (s *JobService) Drain(ctx context.Context) {
	for {
		// data-access-allow:
		n, _ := s.jobRepository.DeleteBatch(ctx, 1000)
		if n == 0 {
			return
		}
	}
}
GO
expect_report internal/services/allow_noreason.go R-361 6 "data-access-allow without a reason must not suppress"

cat > internal/services/range_repo_test.go <<'GO'
package services

func TestLoad(t *testing.T) {
	for _, id := range ids {
		_, _ = repo.Get(ctx, id)
	}
}
GO
expect_clean internal/services/range_repo_test.go "_test.go files must be exempt"

# --- R-362 -----------------------------------------------------------------
cat > internal/services/tx_pool.go <<'GO'
package services

func (s *TransferService) Move(ctx context.Context, from, to string, amount int64) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - $2 WHERE id = $1", from, amount); err != nil {
			return err
		}
		_, err := s.pool.Exec(ctx, "UPDATE accounts SET balance = balance + $2 WHERE id = $1", to, amount)
		return err
	})
}
GO
expect_report internal/services/tx_pool.go R-362 8 "pool.Exec inside a BeginFunc callback must report"
[ "$(jq '[.[] | select(.rule == "R-362")] | length' <<< "$LAST")" -eq 1 ] \
  || { echo "FAIL: tx.Exec inside the BeginFunc callback must pass"; printf '%s\n' "$LAST"; exit 1; }

cat > internal/services/tx_clean.go <<'GO'
package services

func (s *TripService) Create(ctx context.Context, trip domain.Trip) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "INSERT INTO trips (id) VALUES ($1)", trip.ID); err != nil {
			return err
		}
		return s.legRepository.CreateLegs(ctx, tx, trip.Legs)
	})
}
GO
expect_clean internal/services/tx_clean.go "tx.Exec and a repository call receiving tx must pass"

cat > internal/services/tx_http.go <<'GO'
package services

import "net/http"

func (s *OrderService) Place(ctx context.Context, order domain.Order) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "INSERT INTO orders (id) VALUES ($1)", order.ID); err != nil {
			return err
		}
		resp, err := http.Get("https://example.com/notify")
		if err != nil {
			return err
		}
		return resp.Body.Close()
	})
}
GO
expect_report internal/services/tx_http.go R-362 10 "http.Get inside a BeginFunc callback must report"

# --- Robustness --------------------------------------------------------------
printf 'package services\n\nfunc broken( {\n' > internal/services/broken.go
expect_clean internal/services/broken.go "an unparsable file must be skipped without a crash"

STATUS=0
"$TMP/checker" >/dev/null 2>&1 || STATUS=$?
[ "$STATUS" -eq 2 ] || { echo "FAIL: no arguments must exit 2 (got $STATUS)"; exit 1; }

# --- Gate end to end ------------------------------------------------------------
# push-golangci-gate.sh runs the checker on the changed .go files and denies an
# added N+1 line, whether or not golangci-lint runs, and fails open with a note
# when the go toolchain is missing.
GATE="$CLAUDE_HARNESS_ROOT/hooks/push-golangci-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
GATE_REPO=$(mktemp -d)
(
  cd "$GATE_REPO"
  git init -q
  git switch -q -c main 2>/dev/null || git checkout -q -b main
  git config user.email t@t
  git config user.name t
  git commit -q --allow-empty -m init
  mkdir -p internal/services
  cat > internal/services/trips.go <<'GO'
package services

func (s *TripService) ListTrips(ctx context.Context, tripIDs []string) ([]domain.Trip, error) {
	trips := make([]domain.Trip, 0, len(tripIDs))
	for _, tripID := range tripIDs {
		trip, err := s.tripRepository.GetTrip(ctx, tripID)
		if err != nil {
			return nil, err
		}
		trips = append(trips, trip)
	}
	return trips, nil
}
GO
  git add .
  git commit -q -m "feat: list trips"
)
GOLANGCI_STUB=$(mktemp)
printf '#!/usr/bin/env bash\necho %s\n' "'{\"Issues\":[]}'" > "$GOLANGCI_STUB"
chmod +x "$GOLANGCI_STUB"

GATE_OUT=$(cd "$GATE_REPO" && printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$GOLANGCI_STUB" "$GATE" 2>/dev/null)
printf '%s' "$GATE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: the gate must deny an added N+1 line (got: $GATE_OUT)"; exit 1; }
printf '%s' "$GATE_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'internal/services/trips.go:6 R-361' \
  || { echo "FAIL: the deny reason must name the file, line, and R-361 (got: $GATE_OUT)"; exit 1; }

# Untrusted repo, no golangci override: golangci-lint is skipped by the trust
# gate, and the checker, which only parses, still denies.
(cd "$GATE_REPO" && git remote add origin https://example.com/untrusted/repo.git)
UNTRUSTED_OUT=$(cd "$GATE_REPO" && printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$GATE" 2>/dev/null)
printf '%s' "$UNTRUSTED_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: the checker must still deny in a repo golangci-lint does not trust (got: $UNTRUSTED_OUT)"; exit 1; }

# No go toolchain: the checker half is skipped with a note and the push is allowed.
NO_GO_ERR=$(cd "$GATE_REPO" && printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$GOLANGCI_STUB" CLAUDE_GO_CMD=/nonexistent/go "$GATE" 2>&1 1>/dev/null)
NO_GO_OUT=$(cd "$GATE_REPO" && printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_GOLANGCI_CMD="$GOLANGCI_STUB" CLAUDE_GO_CMD=/nonexistent/go "$GATE" 2>/dev/null)
grep -q "did not build" <<< "$NO_GO_ERR" || { echo "FAIL: a missing go toolchain must leave a stderr note (got: $NO_GO_ERR)"; exit 1; }
[ -z "$NO_GO_OUT" ] || { echo "FAIL: a missing go toolchain must fail open (got: $NO_GO_OUT)"; exit 1; }
rm -rf "$GATE_REPO" "$GOLANGCI_STUB"

echo "PASS: data-access-go.test.sh (R-361 and R-362 Go checker, push-golangci-gate wiring)"
