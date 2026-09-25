#!/usr/bin/env bash
# Covers: hook:push-rubocop-gate
# Verifies the Ruby data-access checker (enforce/data-access/ruby_data_access.rb)
# directly, then once end to end through push-rubocop-gate.sh.
#
# R-361 (query per element):
#   1. Trip.find inside .each reports and names the loop.
#   2. Leg.where inside .map reports.
#   3. exec_query inside a while loop reports.
#   4. A query object's .call inside .each reports (both .call and .new.call).
#   5. The receiver of the iteration runs once and passes.
#   6. One set query grouped in memory passes.
#   7. Core constants in a loop (Time.now, JSON.parse) pass.
#   8. A helper method defined elsewhere is not followed (documented limit).
#   9. An allow comment with a reason suppresses; one without a reason does not.
#  10. spec/ paths are exempt.
# R-362 (slow work inside a transaction):
#  11. Faraday.post inside `transaction do` reports.
#  12. deliver_later inside the transaction reports.
#  13. deliver_later after the block, or inside after_commit, passes.
# Robustness:
#  14. An unparsable file is skipped without crashing, and bad usage exits 2.
# Gate:
#  15. An added N+1 line denies the push with R-361 in the reason, with
#      RuboCop stubbed through CLAUDE_RUBOCOP_CMD; a missing ruby fails open.
#
# Every clean case also asserts the checker printed a JSON array and nothing on
# stderr, so a crash cannot pass as "no findings".
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECKER="$CLAUDE_HARNESS_ROOT/enforce/data-access/ruby_data_access.rb"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-rubocop-gate.sh"

command -v ruby >/dev/null 2>&1 || { echo "FAIL: ruby is required to exercise the data-access checker"; exit 1; }
[ -f "$CHECKER" ] || { echo "FAIL: no checker at $CHECKER"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
mkdir -p app/services app/models app/queries spec/services

OUT=""
ERR=""
check() {
  local status=0
  OUT=$(ruby "$CHECKER" "$@" 2>"$TMP/stderr") || status=$?
  ERR=$(cat "$TMP/stderr")
  if [ "$status" -ne 0 ]; then echo "FAIL: checker exited $status on $*"; printf '%s\n' "$ERR"; exit 1; fi
  if ! printf '%s' "$OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "FAIL: checker did not print a JSON array for $*"; printf '%s\n%s\n' "$OUT" "$ERR"; exit 1
  fi
  if [ -n "$ERR" ]; then echo "FAIL: checker wrote to stderr for $*"; printf '%s\n' "$ERR"; exit 1; fi
}
expect_report() { # file line rule label
  check "$1"
  printf '%s' "$OUT" | jq -e --argjson l "$2" --arg r "$3" 'any(.[]; .line == $l and .rule == $r)' >/dev/null \
    || { echo "FAIL: $4 (expected $3 at line $2)"; printf '%s\n' "$OUT"; exit 1; }
}
expect_clean() { # file label
  check "$1"
  [ "$(printf '%s' "$OUT" | jq 'length')" = "0" ] || { echo "FAIL: $2"; printf '%s\n' "$OUT"; exit 1; }
}

# --- R-361 -----------------------------------------------------------------
cat > app/services/find_in_each.rb <<'RB'
# frozen_string_literal: true

class LoadTrips
  def call(trip_ids)
    trip_ids.each do |trip_id|
      Trip.find(trip_id)
    end
  end
end
RB
expect_report app/services/find_in_each.rb 6 R-361 "1: Trip.find inside .each must report"
printf '%s' "$OUT" | jq -e '.[0].message | test("Trip.find") and test("\\.each block")' >/dev/null \
  || { echo "FAIL: 1: the message must name the callee and the loop"; printf '%s\n' "$OUT"; exit 1; }
printf '%s' "$OUT" | jq -e '.[0].file == "app/services/find_in_each.rb"' >/dev/null \
  || { echo "FAIL: 1: file must be the path as given"; exit 1; }

cat > app/services/where_in_map.rb <<'RB'
# frozen_string_literal: true

class LegsByTrip
  def call(trips)
    trips.map { |trip| Leg.where(trip_id: trip.id).to_a }
  end
end
RB
expect_report app/services/where_in_map.rb 5 R-361 "2: Leg.where inside .map must report"

cat > app/models/queue_entry.rb <<'RB'
# frozen_string_literal: true

class QueueEntry < ApplicationRecord
  def self.drain(ids)
    while ids.any?
      connection.exec_query("DELETE FROM queue_entries WHERE id = $1", "drain", [ids.pop])
    end
  end
end
RB
expect_report app/models/queue_entry.rb 6 R-361 "3: exec_query inside a while loop must report"

cat > app/services/query_object_loop.rb <<'RB'
# frozen_string_literal: true

class ActiveTripsPerUser
  def call(users)
    users.each { |user| ActiveTripsQuery.new(user).call }
    users.each { |user| Trips::ActiveQuery.call(user: user) }
  end
end
RB
expect_report app/services/query_object_loop.rb 5 R-361 "4: a query object's .new(...).call inside .each must report"
expect_report app/services/query_object_loop.rb 6 R-361 "4: a query object's .call inside .each must report"

cat > app/services/receiver_once.rb <<'RB'
# frozen_string_literal: true

class OpenTripCount
  def call(user_id)
    count = 0
    Trip.where(user_id: user_id).each { |trip| count += 1 if trip.open? }
    Trip.where(user_id: user_id).find_each { |trip| trip.touch_later }
    count
  end
end
RB
expect_clean app/services/receiver_once.rb "5: the receiver of the iteration runs once and must not report"

cat > app/services/set_query.rb <<'RB'
# frozen_string_literal: true

class TripsWithLegs
  def call(trips)
    legs_by_trip_id = Leg.where(trip_id: trips.map(&:id)).group_by(&:trip_id)
    trips.map { |trip| [trip, legs_by_trip_id.fetch(trip.id, [])] }
  end
end
RB
expect_clean app/services/set_query.rb "6: one set query grouped in memory must not report"

cat > app/services/core_in_loop.rb <<'RB'
# frozen_string_literal: true

class StampPayloads
  STATUSES = %w[open closed].freeze

  def call(payloads)
    payloads.map do |payload|
      parsed = JSON.parse(payload)
      parsed["seen_at"] = Time.now.iso8601
      parsed["status"] = STATUSES.find { |status| status == parsed["status"] }
      Jobs::ScoreMatch.call(job: parsed)
      parsed
    end
  end
end
RB
expect_clean app/services/core_in_loop.rb "7: core constants, value constants, and services in a loop must not report"

cat > app/services/helper_elsewhere.rb <<'RB'
# frozen_string_literal: true

class LoadViaHelper
  def call(trip_ids)
    trip_ids.map { |trip_id| load_trip(trip_id) }
  end

  private

  def load_trip(trip_id)
    Trip.find(trip_id)
  end
end
RB
expect_clean app/services/helper_elsewhere.rb "8: a helper defined outside the loop is a documented limit and must not report"

cat > app/services/allowed.rb <<'RB'
# frozen_string_literal: true

class Backfill
  def call(batches)
    batches.each do |ids|
      # data-access-allow: one statement per 1000-row batch
      Trip.where(id: ids).update_all(archived: true)
    end
  end
end
RB
expect_clean app/services/allowed.rb "9: an allow comment with a reason must suppress"

cat > app/services/allowed_no_reason.rb <<'RB'
# frozen_string_literal: true

class Backfill
  def call(batches)
    batches.each do |ids|
      Trip.where(id: ids).update_all(archived: true) # data-access-allow:
    end
  end
end
RB
expect_report app/services/allowed_no_reason.rb 6 R-361 "9: an allow comment without a reason must not suppress"

cp app/services/find_in_each.rb spec/services/find_in_each_spec.rb
cp app/services/find_in_each.rb app/services/find_in_each_test.rb
expect_clean spec/services/find_in_each_spec.rb "10: spec/ paths must be exempt"
expect_clean app/services/find_in_each_test.rb "10: *_test.rb files must be exempt"

# --- R-362 -----------------------------------------------------------------
cat > app/services/book_trip.rb <<'RB'
# frozen_string_literal: true

class BookTrip
  def call(trip, user)
    ActiveRecord::Base.transaction do
      trip.update!(status: "booked")
      Faraday.post("https://payments.example.invalid/charges", { trip_id: trip.id })
      UserMailer.with(user: user).booking_confirmed.deliver_later
      Booking.create!(trip: trip, user: user)
    end
    UserMailer.with(user: user).booking_receipt.deliver_later
  end
end
RB
expect_report app/services/book_trip.rb 7 R-362 "11: Faraday.post inside transaction must report"
expect_report app/services/book_trip.rb 8 R-362 "12: deliver_later inside transaction must report"
[ "$(printf '%s' "$OUT" | jq 'length')" = "2" ] \
  || { echo "FAIL: 13: only the two calls inside the block may report (not the model write, not the mail after the block)"; printf '%s\n' "$OUT"; exit 1; }

cat > app/services/book_trip_after_commit.rb <<'RB'
# frozen_string_literal: true

class BookTrip
  def call(trip, user)
    ActiveRecord::Base.transaction do |transaction|
      trip.update!(status: "booked")
      transaction.after_commit { UserMailer.with(user: user).booking_confirmed.deliver_later }
    end
  end
end
RB
expect_clean app/services/book_trip_after_commit.rb "13: deliver_later inside after_commit must not report"

# --- Robustness --------------------------------------------------------------
printf 'class Broken\n  def call(\nend\n' > app/services/broken.rb
check app/services/broken.rb app/services/find_in_each.rb
[ "$(printf '%s' "$OUT" | jq 'length')" = "1" ] \
  || { echo "FAIL: 14: an unparsable file must be skipped while the next file is still checked"; printf '%s\n' "$OUT"; exit 1; }
status=0
ruby "$CHECKER" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "FAIL: 14: no arguments must exit 2, got $status"; exit 1; }

# --- Gate end to end -----------------------------------------------------------
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t && git config user.name t
mkdir -p app/services
printf '# frozen_string_literal: true\n\nclass LoadTrips\n  def call(trip_ids)\n    trip_ids.map { |trip_id| trip_id }\n  end\nend\n' > app/services/load_trips.rb
git add . && git commit -q -m init
cp "$TMP/app/services/find_in_each.rb" app/services/load_trips.rb
git add . && git commit -q -m "feat: load trips"
STUB="$TMP/rubocop-stub"
printf '#!/usr/bin/env bash\nprintf %%s %q\n' '{"files":[{"path":"app/services/load_trips.rb","offenses":[]}]}' > "$STUB"
chmod +x "$STUB"

GATE_OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$STUB" CLAUDE_FIRE_LOG=/dev/null "$HOOK")
printf '%s' "$GATE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: 15: an added N+1 line must deny the push; got: $GATE_OUT"; exit 1; }
printf '%s' "$GATE_OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("app/services/load_trips.rb:6 R-361")' >/dev/null \
  || { echo "FAIL: 15: the denial must name file:line and R-361; got: $GATE_OUT"; exit 1; }

# A RuboCop half that yields nothing usable must not silence the checker.
BROKEN_STUB="$TMP/rubocop-broken"
printf '#!/usr/bin/env bash\necho "rubocop exploded"\n' > "$BROKEN_STUB"
chmod +x "$BROKEN_STUB"
GATE_OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$BROKEN_STUB" CLAUDE_FIRE_LOG=/dev/null "$HOOK" 2>/dev/null)
printf '%s' "$GATE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: 15: the checker must still deny when the RuboCop half is unusable; got: $GATE_OUT"; exit 1; }

GATE_OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_RUBOCOP_CMD="$STUB" CLAUDE_RUBY_CMD="$TMP/no-such-ruby" CLAUDE_FIRE_LOG=/dev/null "$HOOK" 2>"$TMP/gate-stderr")
[ -z "$GATE_OUT" ] || { echo "FAIL: 15: a missing ruby must fail open; got: $GATE_OUT"; exit 1; }
grep -q "no ruby on PATH" "$TMP/gate-stderr" || { echo "FAIL: 15: a missing ruby must say so on stderr"; exit 1; }

echo "PASS: data-access-ruby.test.sh (R-361 and R-362 Ruby checker, push-rubocop-gate wiring)"
