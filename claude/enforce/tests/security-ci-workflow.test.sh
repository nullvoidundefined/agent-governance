#!/usr/bin/env bash
# Covers: ci:security-workflow
# Verifies the structure of the security CI workflow and its self-caller
# (IAN-381, spec Part 7 addendum, components 4 and 6, criterion B-23):
#
#   .github/workflows/security.yml       the reusable workflow_call workflow
#   .github/workflows/security-self.yml  agent-governance calling it on PRs
#
# Both files live at the repository root, which is the parent of the harness
# root (<repo>/claude). The fixture parses each file with Ruby's YAML loader,
# has Ruby print one `key=value` fact per line, and compares every fact in
# bash against an exact expected value or a required minimum count, so a
# workflow that drops a guard, widens a permission, unpins an action, or
# interpolates an expression into a shell line fails with its own message.
#
# Ruby's YAML 1.1 loader reads the bare key `on` as boolean true, so the
# trigger map is read as `w[true] || w["on"]`. Ruby is required: when it is
# missing the fixture fails rather than skipping, because a skipped structure
# check would let an unsafe workflow through.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
REPO_ROOT=$(cd "$CLAUDE_HARNESS_ROOT/.." && pwd -P)
MAIN_WORKFLOW="$REPO_ROOT/.github/workflows/security.yml"
SELF_WORKFLOW="$REPO_ROOT/.github/workflows/security-self.yml"

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

finish() {
  if [ "$failures" -gt 0 ]; then
    echo "security-ci-workflow.test.sh FAIL ($failures)"
    exit 1
  fi
  echo "security-ci-workflow.test.sh PASS"
  exit 0
}

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# --- Preconditions -------------------------------------------------------------
[ -f "$MAIN_WORKFLOW" ] || report_failure "precondition: $MAIN_WORKFLOW does not exist"
[ -f "$SELF_WORKFLOW" ] || report_failure "precondition: $SELF_WORKFLOW does not exist"
command -v ruby >/dev/null 2>&1 || report_failure "precondition: ruby is not installed; the YAML structure check cannot run"
[ "$failures" -eq 0 ] || finish

# --- Fact extraction (Ruby) ----------------------------------------------------
# Prints one `key=value` line per fact. Every lookup tolerates a missing or
# wrongly typed node, so a malformed workflow yields wrong facts rather than a
# Ruby crash, and each wrong fact fails its own assertion below.
cat > "$WORK/facts.rb" <<'RUBY'
require 'yaml'
require 'json'

def emit(key, value) puts "#{key}=#{value}" end
def text(value) value.is_a?(String) ? value : '' end
def hash_or_empty(value) value.is_a?(Hash) ? value : {} end

def load_workflow(path, label)
  loaded = YAML.load(File.read(path))
  emit "#{label}_loaded", (loaded.is_a?(Hash) ? 'yes' : 'no')
  hash_or_empty(loaded)
rescue StandardError => err
  warn "#{label}: #{err.class}: #{err.message}"
  emit "#{label}_loaded", 'no'
  {}
end

def trigger_map(workflow) workflow.key?(true) ? workflow[true] : workflow['on'] end

def trigger_keys(triggers)
  case triggers
  when Hash then triggers.keys.map(&:to_s).sort.join(',')
  when Array then triggers.map(&:to_s).sort.join(',')
  when String then triggers
  else 'none'
  end
end

def permission_pairs(permissions)
  return ["INVALID:#{permissions.inspect}"] unless permissions.is_a?(Hash)
  permissions.map { |scope, level| "#{scope}:#{level}" }
end

def job_steps(job)
  steps = hash_or_empty(job)['steps']
  steps.is_a?(Array) ? steps.select { |step| step.is_a?(Hash) } : []
end

def yes_no(flag) flag ? 'yes' : 'no' end

main_path, self_path = ARGV
workflow = load_workflow(main_path, 'main')
triggers = trigger_map(workflow)
emit 'trigger_keys', trigger_keys(triggers)
workflow_call = triggers.is_a?(Hash) ? triggers['workflow_call'] : nil
has_inputs = workflow_call.is_a?(Hash) && !workflow_call['inputs'].nil?
emit 'workflow_call_inputs', (has_inputs ? 'present' : 'absent')
emit 'top_permissions', (workflow.key?('permissions') ? JSON.generate(workflow['permissions']) : 'absent')

jobs = hash_or_empty(workflow['jobs'])
job = ->(name) { hash_or_empty(jobs[name]) }
all_steps = jobs.values.flat_map { |each_job| job_steps(each_job) }

uses_values = all_steps.map { |step| step['uses'] }.compact.map(&:to_s)
emit 'uses_total', uses_values.size
emit 'uses_pinned', uses_values.count { |value| value.start_with?('./') || value =~ /\A[^@]+@[0-9a-f]{40}\z/ }

head_ref = '${{ github.event.pull_request.head.sha || github.sha }}'
checkouts = all_steps.select { |step| text(step['uses']).start_with?('actions/checkout@') }
emit 'checkout_total', checkouts.size
emit 'checkout_persist_false', checkouts.count { |step| hash_or_empty(step['with'])['persist-credentials'] == false }
checkout_refs = checkouts.map { |step| hash_or_empty(step['with']) }.select { |with| with.key?('ref') }.map { |with| with['ref'] }
emit 'checkout_ref_present', checkout_refs.size
emit 'checkout_ref_exact', checkout_refs.count { |ref| ref == head_ref }

run_values = all_steps.map { |step| step['run'] }.compact.map(&:to_s)
emit 'run_total', run_values.size
emit 'run_with_expression', run_values.count { |run| run.include?('${{') }

emit 'jobs_total', jobs.size
emit 'jobs_with_permissions', jobs.count { |_name, each_job| each_job.is_a?(Hash) && each_job.key?('permissions') }
other_scopes = jobs.reject { |name, _job| name == 'codeql' }.flat_map do |_name, each_job|
  hash_or_empty(each_job).key?('permissions') ? permission_pairs(each_job['permissions']) : []
end
emit 'noncodeql_scopes', other_scopes.uniq.sort.join(',')
emit 'codeql_permissions', permission_pairs(job.call('codeql')['permissions']).sort.join(',')

emit 'required_jobs', %w[semgrep languages codeql codeql-skipped].select { |name| jobs[name].is_a?(Hash) }.join(',')
emit 'semgrep_name', text(job.call('semgrep')['name'])
emit 'codeql_name', text(job.call('codeql')['name'])
emit 'codeql_needs_languages', yes_no(Array(job.call('codeql')['needs']).map(&:to_s).include?('languages'))
matrix = hash_or_empty(hash_or_empty(job.call('codeql')['strategy'])['matrix'])
emit 'codeql_matrix_language', text(matrix['language'])

emit 'codeql_if', text(job.call('codeql')['if'])
emit 'codeql_skipped_if', text(job.call('codeql-skipped')['if'])
emit 'codeql_skipped_notice', yes_no(job_steps(job.call('codeql-skipped')).any? { |step| text(step['run']).include?('::notice::') })

harness_markers = ['nullvoidundefined/agent-governance', '[0-9a-f]{40}', '$RUNNER_TEMP/harness']
%w[semgrep languages].each do |name|
  first_step = job_steps(job.call(name)).first || {}
  refuses = text(first_step['if']) == "github.event_name == 'pull_request_target'" && text(first_step['run']).include?('exit 2')
  emit "#{name}_first_step_refuses", yes_no(refuses)
  harness = job_steps(job.call(name)).any? do |step|
    env = hash_or_empty(step['env'])
    env['HARNESS_REPOSITORY'] == '${{ job.workflow_repository }}' &&
      env['HARNESS_SHA'] == '${{ job.workflow_sha }}' &&
      harness_markers.all? { |marker| text(step['run']).include?(marker) }
  end
  emit "#{name}_harness_step", yes_no(harness)
end

semgrep_steps = job_steps(job.call('semgrep'))
emit 'semgrep_install', yes_no(semgrep_steps.any? { |step| text(step['run']).include?('semgrep==1.178.0') })
scan_markers = ['security-ci-semgrep.sh', '--mode pr --base "$BASE_SHA"', '--mode full']
scan_step = semgrep_steps.any? do |step|
  env = hash_or_empty(step['env'])
  scan_markers.all? { |marker| text(step['run']).include?(marker) } &&
    env['BASE_SHA'] == '${{ github.event.pull_request.base.sha }}' &&
    env['EVENT_NAME'] == '${{ github.event_name }}'
end
emit 'semgrep_scan_step', yes_no(scan_step)

languages_outputs = hash_or_empty(job.call('languages')['outputs'])
emit 'languages_outputs_list', (text(languages_outputs['list']).empty? ? 'absent' : 'present')
emit 'languages_list_step', yes_no(job_steps(job.call('languages')).any? do |step|
  text(step['run']).include?('security-ci-codeql-languages.sh') && text(step['run']).include?('GITHUB_OUTPUT')
end)

action_refs = ->(prefix) { uses_values.map { |value| value[/\A#{Regexp.escape(prefix)}@(.*)\z/, 1] }.compact.uniq.sort.join(',') }
emit 'codeql_init_refs', action_refs.call('github/codeql-action/init')
emit 'codeql_analyze_refs', action_refs.call('github/codeql-action/analyze')

self_workflow = load_workflow(self_path, 'self')
emit 'self_trigger_keys', trigger_keys(trigger_map(self_workflow))
self_jobs = hash_or_empty(self_workflow['jobs'])
emit 'self_job_count', self_jobs.size
self_job = hash_or_empty(self_jobs.values.first)
emit 'self_job_uses', text(self_job['uses'])
self_permissions =
  if self_job.key?('permissions') then permission_pairs(self_job['permissions']).sort.join(',')
  elsif self_workflow.key?('permissions') then permission_pairs(self_workflow['permissions']).sort.join(',')
  else 'absent'
  end
emit 'self_permissions', self_permissions
RUBY

FACTS=$(ruby "$WORK/facts.rb" "$MAIN_WORKFLOW" "$SELF_WORKFLOW")
ruby_status=$?
[ "$ruby_status" -eq 0 ] || report_failure "ruby fact extraction exited $ruby_status"

# fact <key>: prints the value Ruby emitted for the key, or nothing.
fact() {
  printf '%s\n' "$FACTS" | awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'
}

# expect_fact <label> <key> <expected>: the fact must equal the expected value.
expect_fact() {
  local label="$1" key="$2" expected="$3" actual
  actual=$(fact "$key")
  [ "$actual" = "$expected" ] || report_failure "$label: $key must be [$expected]; got [$actual]"
}

# expect_count_at_least <label> <key> <minimum>: the fact must be an integer
# no smaller than the minimum.
expect_count_at_least() {
  local label="$1" key="$2" minimum="$3" actual
  actual=$(fact "$key")
  case "$actual" in
    ''|*[!0-9]*) report_failure "$label: $key must be a count of at least $minimum; got [$actual]"; return ;;
  esac
  [ "$actual" -ge "$minimum" ] || report_failure "$label: $key must be at least $minimum; got $actual"
}

# expect_same_count <label> <key> <total key>: every counted item must pass,
# so the passing count must equal the total count.
expect_same_count() {
  local label="$1" key="$2" total_key="$3" actual total
  actual=$(fact "$key"); total=$(fact "$total_key")
  [ -n "$total" ] && [ "$actual" = "$total" ] \
    || report_failure "$label: $key must equal $total_key ($total); got [$actual]"
}

expect_fact "security.yml parses" main_loaded yes
expect_fact "security-self.yml parses" self_loaded yes

# --- 1. workflow_call only, no inputs ------------------------------------------
expect_fact "1 trigger" trigger_keys workflow_call
expect_fact "1 no inputs" workflow_call_inputs absent

# --- 2. empty top-level permissions --------------------------------------------
expect_fact "2 top-level permissions" top_permissions '{}'

# --- 3. every uses pinned to a 40-character SHA or local -----------------------
expect_count_at_least "3 uses count" uses_total 3
expect_same_count "3 every uses pinned" uses_pinned uses_total

# --- 4. checkouts: no persisted credentials, head SHA ref ----------------------
expect_count_at_least "4 checkout count" checkout_total 2
expect_same_count "4 persist-credentials false" checkout_persist_false checkout_total
expect_count_at_least "4 caller checkout reads the head SHA" checkout_ref_present 1
expect_same_count "4 every checkout ref is the head SHA" checkout_ref_exact checkout_ref_present

# --- 5. no expression inside run lines -----------------------------------------
expect_count_at_least "5 run step count" run_total 4
expect_fact "5 no \${{ in run" run_with_expression 0

# --- 6. job permissions --------------------------------------------------------
expect_count_at_least "6 job count" jobs_total 4
expect_same_count "6 every job declares permissions" jobs_with_permissions jobs_total
noncodeql_scopes=$(fact noncodeql_scopes)
case "$noncodeql_scopes" in
  ''|'contents:read') ;;
  *) report_failure "6 non-codeql jobs must grant at most contents:read; got [$noncodeql_scopes]" ;;
esac
expect_fact "6 codeql permissions" codeql_permissions 'actions:read,contents:read,security-events:write'

# --- 7. job set, names, matrix -------------------------------------------------
expect_fact "7 required jobs" required_jobs 'semgrep,languages,codeql,codeql-skipped'
expect_fact "7 semgrep job name" semgrep_name semgrep
expect_fact "7 codeql job name" codeql_name 'codeql (${{ matrix.language }})'
expect_fact "7 codeql needs languages" codeql_needs_languages yes
expect_fact "7 codeql matrix language" codeql_matrix_language '${{ fromJSON(needs.languages.outputs.list) }}'

# --- 8. CodeQL skipped only on a private repository, with a notice -------------
expect_fact "8 codeql if" codeql_if '${{ !github.event.repository.private }}'
expect_fact "8 codeql-skipped if" codeql_skipped_if '${{ github.event.repository.private }}'
expect_fact "8 codeql-skipped notice" codeql_skipped_notice yes

# --- 9. pull_request_target refused first --------------------------------------
expect_fact "9 semgrep refuses pull_request_target first" semgrep_first_step_refuses yes
expect_fact "9 languages refuses pull_request_target first" languages_first_step_refuses yes

# --- 10. harness checkout from job.workflow_repository at job.workflow_sha -----
expect_fact "10 semgrep harness checkout" semgrep_harness_step yes
expect_fact "10 languages harness checkout" languages_harness_step yes

# --- 11. Semgrep install and scan ----------------------------------------------
expect_fact "11 semgrep 1.178.0 install" semgrep_install yes
expect_fact "11 semgrep scan step" semgrep_scan_step yes

# --- 12. languages output ------------------------------------------------------
expect_fact "12 languages outputs.list" languages_outputs_list present
expect_fact "12 languages list step" languages_list_step yes

# --- 13. CodeQL init and analyze on the same SHA -------------------------------
init_refs=$(fact codeql_init_refs)
analyze_refs=$(fact codeql_analyze_refs)
printf '%s' "$init_refs" | grep -Eq '^[0-9a-f]{40}$' \
  || report_failure "13 codeql-action/init must be used at exactly one 40-character SHA; got [$init_refs]"
[ -n "$init_refs" ] && [ "$analyze_refs" = "$init_refs" ] \
  || report_failure "13 codeql-action/analyze must use the init SHA [$init_refs]; got [$analyze_refs]"

# --- 14. security-self.yml triggers on pull_request only -----------------------
expect_fact "14 self trigger" self_trigger_keys pull_request

# --- 15. security-self.yml calls the local workflow with exact permissions -----
expect_fact "15 self job count" self_job_count 1
expect_fact "15 self job uses" self_job_uses './.github/workflows/security.yml'
expect_fact "15 self permissions" self_permissions 'actions:read,contents:read,security-events:write'

finish
