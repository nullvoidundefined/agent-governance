#!/usr/bin/env bash
# Covers: ci:security-workflow
# Verifies the structure of the security CI workflow and its self-caller
# (IAN-381, spec Part 7 addendum, components 4 and 6, criteria B-23, B-28,
# B-29, B-30, B-34, B-35, and B-36), and the hash-pinned Semgrep requirements
# file claude/enforce/security-ci-semgrep-requirements.txt that the workflow
# installs from (B-36):
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
# Three steps are executed rather than only inspected. The languages job's
# visibility step (B-35) is extracted and run against a stub `gh`, so the
# fixture sees that only the exact answers true and false reach GITHUB_OUTPUT.
# The first step of the semgrep and languages jobs is an event allowlist
# (B-29): its own `run` text is extracted and run under each event name. The
# harness-fetch step (B-30) is extracted and run against a stub `git` that
# logs every call, so the fixture sees whether a refused repository or SHA
# ever reached a fetch, and that the ancestry check against agent-governance
# `main` runs before the pinned commit is fetched, except when
# agent-governance calls itself.
#
# Ruby's YAML 1.1 loader reads the bare key `on` as boolean true, so the
# trigger map is read as `w[true] || w["on"]`. Ruby is required: when it is
# missing the fixture fails rather than skipping, because a skipped structure
# check would let an unsafe workflow through.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
# The workflows live at the repository root, outside the harness tree. CI runs
# this fixture through the $HOME/.claude symlink, whose parent is the runner's
# home rather than the checkout, so the root comes from git, which resolves
# the fixture's own directory to the checkout it sits in (as
# translate-codex.test.sh does).
REPO_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
MAIN_WORKFLOW="$REPO_ROOT/.github/workflows/security.yml"
SELF_WORKFLOW="$REPO_ROOT/.github/workflows/security-self.yml"

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

# finish_test: prints the verdict and exits 1 on any failure, 0 otherwise.
finish_test() {
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
[ "$failures" -eq 0 ] || finish_test

# --- Fact extraction (Ruby) ----------------------------------------------------
# Prints one `key=value` line per fact. Every lookup tolerates a missing or
# wrongly typed node, so a malformed workflow yields wrong facts rather than a
# Ruby crash, and each wrong fact fails its own assertion below.
cat > "$WORK/facts.rb" <<'RUBY'
require 'yaml'
require 'json'

def emit_fact(key, value) puts "#{key}=#{value}" end
def read_text(value) value.is_a?(String) ? value : '' end
def coerce_hash(value) value.is_a?(Hash) ? value : {} end

def load_workflow(path, label)
  loaded = YAML.load(File.read(path))
  emit_fact "#{label}_loaded", (loaded.is_a?(Hash) ? 'yes' : 'no')
  coerce_hash(loaded)
rescue StandardError => err
  warn "#{label}: #{err.class}: #{err.message}"
  emit_fact "#{label}_loaded", 'no'
  {}
end

def read_trigger_map(workflow) workflow.key?(true) ? workflow[true] : workflow['on'] end

def list_trigger_keys(triggers)
  case triggers
  when Hash then triggers.keys.map(&:to_s).sort.join(',')
  when Array then triggers.map(&:to_s).sort.join(',')
  when String then triggers
  else 'none'
  end
end

def list_permission_pairs(permissions)
  return ["INVALID:#{permissions.inspect}"] unless permissions.is_a?(Hash)
  permissions.map { |scope, level| "#{scope}:#{level}" }
end

def list_job_steps(job)
  steps = coerce_hash(job)['steps']
  steps.is_a?(Array) ? steps.select { |step| step.is_a?(Hash) } : []
end

def format_yes_no(flag) flag ? 'yes' : 'no' end

main_path, self_path = ARGV
workflow = load_workflow(main_path, 'main')
triggers = read_trigger_map(workflow)
emit_fact 'trigger_keys', list_trigger_keys(triggers)
workflow_call = triggers.is_a?(Hash) ? triggers['workflow_call'] : nil
has_inputs = workflow_call.is_a?(Hash) && !workflow_call['inputs'].nil?
emit_fact 'workflow_call_inputs', (has_inputs ? 'present' : 'absent')
emit_fact 'top_permissions', (workflow.key?('permissions') ? JSON.generate(workflow['permissions']) : 'absent')

jobs = coerce_hash(workflow['jobs'])
find_job = ->(name) { coerce_hash(jobs[name]) }
all_steps = jobs.values.flat_map { |each_job| list_job_steps(each_job) }

uses_values = all_steps.map { |step| step['uses'] }.compact.map(&:to_s)
emit_fact 'uses_total', uses_values.size
emit_fact 'uses_pinned', uses_values.count { |value| value.start_with?('./') || value =~ /\A[^@]+@[0-9a-f]{40}\z/ }

head_ref = '${{ github.event.pull_request.head.sha || github.sha }}'
checkouts = all_steps.select { |step| read_text(step['uses']).start_with?('actions/checkout@') }
emit_fact 'checkout_total', checkouts.size
emit_fact 'checkout_persist_false', checkouts.count { |step| coerce_hash(step['with'])['persist-credentials'] == false }
checkout_refs = checkouts.map { |step| coerce_hash(step['with']) }.select { |with| with.key?('ref') }.map { |with| with['ref'] }
emit_fact 'checkout_ref_present', checkout_refs.size
emit_fact 'checkout_ref_exact', checkout_refs.count { |ref| ref == head_ref }

run_values = all_steps.map { |step| step['run'] }.compact.map(&:to_s)
emit_fact 'run_total', run_values.size
emit_fact 'run_with_expression', run_values.count { |run| run.include?('${{') }

emit_fact 'jobs_total', jobs.size
emit_fact 'jobs_with_permissions', jobs.count { |_name, each_job| each_job.is_a?(Hash) && each_job.key?('permissions') }
other_scopes = jobs.reject { |name, _job| name == 'codeql' }.flat_map do |_name, each_job|
  coerce_hash(each_job).key?('permissions') ? list_permission_pairs(each_job['permissions']) : []
end
emit_fact 'noncodeql_scopes', other_scopes.uniq.sort.join(',')
emit_fact 'codeql_permissions', list_permission_pairs(find_job.call('codeql')['permissions']).sort.join(',')

emit_fact 'required_jobs', %w[semgrep languages codeql codeql-skipped].select { |name| jobs[name].is_a?(Hash) }.join(',')
emit_fact 'semgrep_name', read_text(find_job.call('semgrep')['name'])
emit_fact 'codeql_name', read_text(find_job.call('codeql')['name'])
emit_fact 'codeql_needs_languages', format_yes_no(Array(find_job.call('codeql')['needs']).map(&:to_s).include?('languages'))
matrix = coerce_hash(coerce_hash(find_job.call('codeql')['strategy'])['matrix'])
emit_fact 'codeql_matrix_language', read_text(matrix['language'])

emit_fact 'codeql_if', read_text(find_job.call('codeql')['if'])
emit_fact 'codeql_skipped_if', read_text(find_job.call('codeql-skipped')['if'])
emit_fact 'codeql_skipped_notice', format_yes_no(list_job_steps(find_job.call('codeql-skipped')).any? { |step| read_text(step['run']).include?('::notice::') })

harness_markers = ['nullvoidundefined/agent-governance', '[0-9a-f]{40}', '$RUNNER_TEMP/harness']
allowlist_markers = %w[pull_request push schedule workflow_dispatch] + ['exit 2']
%w[semgrep languages].each do |name|
  first_step = list_job_steps(find_job.call(name)).first || {}
  emit_fact "#{name}_first_step_has_if", format_yes_no(first_step.key?('if'))
  emit_fact "#{name}_first_step_name", read_text(first_step['name'])
  emit_fact "#{name}_first_step_event_env", read_text(coerce_hash(first_step['env'])['EVENT_NAME'])
  emit_fact "#{name}_first_step_markers", format_yes_no(allowlist_markers.all? { |marker| read_text(first_step['run']).include?(marker) })
  harness = list_job_steps(find_job.call(name)).any? do |step|
    env = coerce_hash(step['env'])
    env['HARNESS_REPOSITORY'] == '${{ job.workflow_repository }}' &&
      env['HARNESS_SHA'] == '${{ job.workflow_sha }}' &&
      harness_markers.all? { |marker| read_text(step['run']).include?(marker) }
  end
  emit_fact "#{name}_harness_step", format_yes_no(harness)
end

semgrep_steps = list_job_steps(find_job.call('semgrep'))
scan_markers = ['security-ci-semgrep.sh', '--mode pr --base "$BASE_SHA"', '--mode full']
scan_step = semgrep_steps.any? do |step|
  env = coerce_hash(step['env'])
  scan_markers.all? { |marker| read_text(step['run']).include?(marker) } &&
    env['BASE_SHA'] == '${{ github.event.pull_request.base.sha }}' &&
    env['EVENT_NAME'] == '${{ github.event_name }}'
end
emit_fact 'semgrep_scan_step', format_yes_no(scan_step)

languages_outputs = coerce_hash(find_job.call('languages')['outputs'])
emit_fact 'languages_outputs_list', (read_text(languages_outputs['list']).empty? ? 'absent' : 'present')
emit_fact 'languages_list_step', format_yes_no(list_job_steps(find_job.call('languages')).any? do |step|
  read_text(step['run']).include?('security-ci-codeql-languages.sh') && read_text(step['run']).include?('GITHUB_OUTPUT')
end)
derive_step = list_job_steps(find_job.call('languages')).find do |step|
  read_text(step['run']).include?('security-ci-codeql-languages.sh')
end || {}
emit_fact 'languages_derive_event_env', read_text(coerce_hash(derive_step['env'])['EVENT_NAME'])
emit_fact 'languages_derive_modes', format_yes_no(['--mode pr', '--mode full'].all? { |marker| read_text(derive_step['run']).include?(marker) })
derive_env = coerce_hash(derive_step['env'])
emit_fact 'languages_derive_default_branch_env', read_text(derive_env['DEFAULT_BRANCH'])
emit_fact 'languages_derive_git_ref_env', read_text(derive_env['GIT_REF'])
emit_fact 'languages_derive_ref_args', format_yes_no(['--ref "$GIT_REF"', '--default-branch "$DEFAULT_BRANCH"'].all? { |marker| read_text(derive_step['run']).include?(marker) })

emit_fact 'languages_outputs_is_private', read_text(languages_outputs['is_private'])
visibility_step = list_job_steps(find_job.call('languages')).find { |step| step['id'] == 'visibility' } || {}
emit_fact 'languages_visibility_step', (visibility_step.empty? ? 'absent' : 'present')
emit_fact 'languages_visibility_gh_token_env', read_text(coerce_hash(visibility_step['env'])['GH_TOKEN'])
emit_fact 'codeql_skipped_needs_languages', format_yes_no(Array(find_job.call('codeql-skipped')['needs']).map(&:to_s).include?('languages'))
all_ifs = jobs.values.map { |each_job| coerce_hash(each_job)['if'] } + all_steps.map { |step| step['if'] }
emit_fact 'ifs_reading_payload_private', all_ifs.count { |condition| condition.to_s.include?('github.event.repository.private') }
env_values = (jobs.values.map { |each_job| coerce_hash(each_job)['env'] } + all_steps.map { |step| step['env'] })
  .flat_map { |env| coerce_hash(env).values.map(&:to_s) }
emit_fact 'payload_default_branch_reads', (run_values + env_values).count { |text| text.include?('github.event.repository.default_branch') }

requirements_marker = '-r "$RUNNER_TEMP/harness/claude/enforce/security-ci-semgrep-requirements.txt"'
install_step = semgrep_steps.find { |step| read_text(step['run']).include?('security-ci-semgrep-requirements.txt') } || {}
install_run = read_text(install_step['run'])
emit_fact 'semgrep_install_step', (install_step.empty? ? 'absent' : 'present')
['python3 -m venv', '--require-hashes', '--no-deps', requirements_marker].each_with_index do |marker, index|
  emit_fact "semgrep_install_marker_#{index}", format_yes_no(install_run.include?(marker))
end
emit_fact 'semgrep_install_github_path', format_yes_no(install_run.lines.any? { |line| line.include?('/bin') && line =~ />>\s*"?\$\{?GITHUB_PATH\}?"?/ })
emit_fact 'run_with_pipx_semgrep', run_values.count { |run| run.include?('pipx install semgrep') }

list_action_refs = ->(prefix) { uses_values.map { |value| value[/\A#{Regexp.escape(prefix)}@(.*)\z/, 1] }.compact.uniq.sort.join(',') }
emit_fact 'codeql_init_refs', list_action_refs.call('github/codeql-action/init')
emit_fact 'codeql_analyze_refs', list_action_refs.call('github/codeql-action/analyze')
init_step = list_job_steps(find_job.call('codeql')).find do |step|
  read_text(step['uses']).start_with?('github/codeql-action/init@')
end || {}
emit_fact 'codeql_init_build_mode', read_text(coerce_hash(init_step['with'])['build-mode'])

self_workflow = load_workflow(self_path, 'self')
emit_fact 'self_trigger_keys', list_trigger_keys(read_trigger_map(self_workflow))
self_jobs = coerce_hash(self_workflow['jobs'])
emit_fact 'self_job_count', self_jobs.size
self_job = coerce_hash(self_jobs.values.first)
emit_fact 'self_job_uses', read_text(self_job['uses'])
self_permissions =
  if self_job.key?('permissions') then list_permission_pairs(self_job['permissions']).sort.join(',')
  elsif self_workflow.key?('permissions') then list_permission_pairs(self_workflow['permissions']).sort.join(',')
  else 'absent'
  end
emit_fact 'self_permissions', self_permissions
RUBY

# --- Step extraction (Ruby) ----------------------------------------------------
# extract_run.rb <workflow> <job> <first|harness|id:<step id>> <out file>:
# writes the `run` text of the job's first step, of its step whose env names
# both HARNESS_REPOSITORY and HARNESS_SHA, or of its step with the given `id`,
# to the out file; exits 3 when that step or its run text is missing.
cat > "$WORK/extract_run.rb" <<'RUBY'
require 'yaml'

workflow_path, job_name, selector, out_path = ARGV
workflow = YAML.load(File.read(workflow_path))
jobs = workflow.is_a?(Hash) && workflow['jobs'].is_a?(Hash) ? workflow['jobs'] : {}
job = jobs[job_name].is_a?(Hash) ? jobs[job_name] : {}
steps = job['steps'].is_a?(Array) ? job['steps'].select { |step| step.is_a?(Hash) } : []
chosen_step =
  if selector == 'first' then steps.first
  elsif selector.start_with?('id:') then steps.find { |step| step['id'] == selector.sub('id:', '') }
  else
    steps.find do |step|
      step['env'].is_a?(Hash) && step['env'].key?('HARNESS_REPOSITORY') && step['env'].key?('HARNESS_SHA')
    end
  end
run_text = chosen_step.is_a?(Hash) ? chosen_step['run'] : nil
exit 3 unless run_text.is_a?(String) && !run_text.empty?
File.write(out_path, run_text)
RUBY

FACTS=$(ruby "$WORK/facts.rb" "$MAIN_WORKFLOW" "$SELF_WORKFLOW")
ruby_status=$?
[ "$ruby_status" -eq 0 ] || report_failure "ruby fact extraction exited $ruby_status"

# read_fact <key>: prints the value Ruby emitted for the key, or nothing.
read_fact() {
  printf '%s\n' "$FACTS" | awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'
}

# expect_fact <label> <key> <expected>: the fact must equal the expected value.
expect_fact() {
  local label="$1" key="$2" expected="$3" actual
  actual=$(read_fact "$key")
  [ "$actual" = "$expected" ] || report_failure "$label: $key must be [$expected]; got [$actual]"
}

# expect_count_at_least <label> <key> <minimum>: the fact must be an integer
# no smaller than the minimum.
expect_count_at_least() {
  local label="$1" key="$2" minimum="$3" actual
  actual=$(read_fact "$key")
  case "$actual" in
    ''|*[!0-9]*) report_failure "$label: $key must be a count of at least $minimum; got [$actual]"; return ;;
  esac
  [ "$actual" -ge "$minimum" ] || report_failure "$label: $key must be at least $minimum; got $actual"
}

# expect_same_count <label> <key> <total key>: every counted item must pass,
# so the passing count must equal the total count.
expect_same_count() {
  local label="$1" key="$2" total_key="$3" actual total
  actual=$(read_fact "$key"); total=$(read_fact "$total_key")
  [ -n "$total" ] && [ "$actual" = "$total" ] \
    || report_failure "$label: $key must equal $total_key ($total); got [$actual]"
}

# extract_step_run <job> <first|harness> <out file>: writes the chosen step's
# run text to the out file; reports a failure and returns 1 when it is missing.
extract_step_run() {
  local job_name="$1" selector="$2" out_file="$3"
  ruby "$WORK/extract_run.rb" "$MAIN_WORKFLOW" "$job_name" "$selector" "$out_file" && return 0
  report_failure "$job_name: no $selector step with a run text to execute"
  return 1
}

# run_step_script <script> <env assignments...>: runs an extracted run text the
# way GitHub Actions runs a bash step (bash --noprofile --norc -eo pipefail),
# with an empty environment except PATH, HOME, and the given assignments, and
# prints the exit status. Output goes to $WORK/step.out.
run_step_script() {
  local script="$1"
  shift
  env -i PATH="$PATH" HOME="$WORK" "$@" \
    bash --noprofile --norc -eo pipefail "$script" > "$WORK/step.out" 2>&1
  printf '%s' "$?"
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
noncodeql_scopes=$(read_fact noncodeql_scopes)
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

# --- 8. CodeQL skipped only on a private repository, with a notice (B-35) ------
# Visibility comes from the languages job's API read, never from the event
# payload, which a schedule event lacks: a missing payload field must not read
# as "not private" or as "private".
expect_fact "8 codeql if" codeql_if "\${{ needs.languages.outputs.is_private == 'false' }}"
expect_fact "8 codeql-skipped if" codeql_skipped_if "\${{ needs.languages.outputs.is_private == 'true' }}"
expect_fact "8 codeql-skipped needs languages" codeql_skipped_needs_languages yes
expect_fact "8 codeql-skipped notice" codeql_skipped_notice yes
expect_fact "8 no if reads github.event.repository.private" ifs_reading_payload_private 0
expect_fact "8 languages outputs.is_private" languages_outputs_is_private '${{ steps.visibility.outputs.is_private }}'
expect_fact "8 languages has a visibility step" languages_visibility_step present
expect_fact "8 visibility step GH_TOKEN env" languages_visibility_gh_token_env '${{ github.token }}'

# --- 8a. the visibility step, executed against a stub gh (B-35) ----------------
# One API read (B-34, B-35) answers both the visibility and the default
# branch. The stub logs each argument on its own line to $STUB_GH_LOG, prints
# two lines, $STUB_PRIVATE then $STUB_DEFAULT_BRANCH (default main), and exits
# $STUB_GH_EXIT (default 0). The step must write exactly `is_private=<true or
# false>` and `default_branch=<name>` to GITHUB_OUTPUT. On any other
# visibility answer, an empty default branch, a default branch holding a space
# or starting with `-`, or a failed API call, it must exit 2 and write neither
# line, so neither CodeQL job's `if` can match and the deriver never runs.
GH_STUB_BIN="$WORK/gh-stub-bin"
mkdir -p "$GH_STUB_BIN"
cat > "$GH_STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_GH_LOG"
printf '%s\n' "$STUB_PRIVATE"
printf '%s\n' "${STUB_DEFAULT_BRANCH-main}"
exit "${STUB_GH_EXIT:-0}"
STUB
chmod +x "$GH_STUB_BIN/gh"
# Built at run time so no credential-shaped literal sits in this file (R-108).
stub_gh_credential="fixture-$$"

# run_visibility_step <script> <STUB_PRIVATE> <STUB_DEFAULT_BRANCH>
# <STUB_GH_EXIT>: runs the extracted visibility step with the stub gh first on
# PATH and a fresh GITHUB_OUTPUT. Sets VISIBILITY_STATUS, and the paths
# VISIBILITY_OUTPUT_FILE, VISIBILITY_GH_LOG, and VISIBILITY_STEP_OUTPUT.
run_visibility_step() {
  local script="$1" stub_private="$2" stub_default_branch="$3" stub_gh_exit="$4" run_dir
  run_dir=$(mktemp -d "$WORK/visibility.XXXXXX")
  VISIBILITY_OUTPUT_FILE="$run_dir/github_output"
  VISIBILITY_GH_LOG="$run_dir/gh.log"
  VISIBILITY_STEP_OUTPUT="$run_dir/step.out"
  : > "$VISIBILITY_OUTPUT_FILE"
  : > "$VISIBILITY_GH_LOG"
  env -i PATH="$GH_STUB_BIN:$PATH" HOME="$WORK" RUNNER_TEMP="$run_dir" \
    GITHUB_OUTPUT="$VISIBILITY_OUTPUT_FILE" GITHUB_REPOSITORY=acme/app \
    GH_TOKEN="$stub_gh_credential" STUB_GH_LOG="$VISIBILITY_GH_LOG" \
    STUB_PRIVATE="$stub_private" STUB_DEFAULT_BRANCH="$stub_default_branch" \
    STUB_GH_EXIT="$stub_gh_exit" \
    bash --noprofile --norc -eo pipefail "$script" > "$VISIBILITY_STEP_OUTPUT" 2>&1
  VISIBILITY_STATUS=$?
}

visibility_script="$WORK/visibility.sh"
if extract_step_run languages id:visibility "$visibility_script"; then
  # Accepted answers: each case is <visibility>:<default branch>. The two
  # output lines may come in either order, so both sides are sorted.
  for accepted_case in 'false:main' 'true:trunk'; do
    visibility_answer="${accepted_case%%:*}"
    default_branch_answer="${accepted_case#*:}"
    run_visibility_step "$visibility_script" "$visibility_answer" "$default_branch_answer" 0
    label="8a visibility [$visibility_answer], default branch [$default_branch_answer]"
    [ "$VISIBILITY_STATUS" = 0 ] \
      || report_failure "$label: step must exit 0; got $VISIBILITY_STATUS ($(cat "$VISIBILITY_STEP_OUTPUT"))"
    expected_output=$(printf '%s\n' "is_private=$visibility_answer" "default_branch=$default_branch_answer" | sort)
    actual_output=$(sort "$VISIBILITY_OUTPUT_FILE")
    [ "$actual_output" = "$expected_output" ] \
      || report_failure "$label: GITHUB_OUTPUT must hold exactly the lines is_private=$visibility_answer and default_branch=$default_branch_answer; got [$(cat "$VISIBILITY_OUTPUT_FILE")]"
    grep -qx 'api' "$VISIBILITY_GH_LOG" \
      || report_failure "$label: gh must be called with the argument api; argv: [$(cat "$VISIBILITY_GH_LOG")]"
    grep -Fq 'repos/acme/app' "$VISIBILITY_GH_LOG" \
      || report_failure "$label: gh must be called for repos/acme/app; argv: [$(cat "$VISIBILITY_GH_LOG")]"
    grep -qx -- '--jq' "$VISIBILITY_GH_LOG" \
      || report_failure "$label: gh must be called with --jq; argv: [$(cat "$VISIBILITY_GH_LOG")]"
  done

  # Fail closed: each case is <visibility>|<default branch>|<gh exit status>.
  for refused_case in 'false||0' 'maybe|main|0' '|main|0' 'false|main|1' 'false|bad name|0' 'false|-x|0'; do
    IFS='|' read -r visibility_answer default_branch_answer gh_exit_status <<< "$refused_case"
    run_visibility_step "$visibility_script" "$visibility_answer" "$default_branch_answer" "$gh_exit_status"
    label="8a visibility [$visibility_answer], default branch [$default_branch_answer], gh exit $gh_exit_status"
    [ "$VISIBILITY_STATUS" = 2 ] \
      || report_failure "$label: step must exit 2; got $VISIBILITY_STATUS ($(cat "$VISIBILITY_STEP_OUTPUT"))"
    [ "$(grep -c 'is_private=' "$VISIBILITY_OUTPUT_FILE")" = 0 ] \
      || report_failure "$label: GITHUB_OUTPUT must hold no is_private line; got [$(cat "$VISIBILITY_OUTPUT_FILE")]"
    [ "$(grep -c 'default_branch=' "$VISIBILITY_OUTPUT_FILE")" = 0 ] \
      || report_failure "$label: GITHUB_OUTPUT must hold no default_branch line; got [$(cat "$VISIBILITY_OUTPUT_FILE")]"
  done
fi

# --- 9. an event allowlist runs first in semgrep and languages (B-29) ----------
# The step has no `if`, so it runs on every event; it reads the event name from
# env and exits 2 on anything outside the four supported events.
for job_name in semgrep languages; do
  expect_fact "9 $job_name first step has no if" "${job_name}_first_step_has_if" no
  expect_fact "9 $job_name first step name" "${job_name}_first_step_name" 'Allow only the supported events'
  expect_fact "9 $job_name first step EVENT_NAME env" "${job_name}_first_step_event_env" '${{ github.event_name }}'
  expect_fact "9 $job_name first step names the events and exit 2" "${job_name}_first_step_markers" yes
done

# --- 9a. the allowlist step, executed (B-29) -----------------------------------
for job_name in semgrep languages; do
  allowlist_script="$WORK/allowlist-$job_name.sh"
  extract_step_run "$job_name" first "$allowlist_script" || continue
  for allowed_event in pull_request push schedule workflow_dispatch; do
    allowlist_status=$(run_step_script "$allowlist_script" EVENT_NAME="$allowed_event")
    [ "$allowlist_status" = 0 ] \
      || report_failure "9a $job_name allowlist must exit 0 on $allowed_event; got $allowlist_status ($(cat "$WORK/step.out"))"
  done
  for refused_event in pull_request_target issue_comment ''; do
    allowlist_status=$(run_step_script "$allowlist_script" EVENT_NAME="$refused_event")
    [ "$allowlist_status" = 2 ] \
      || report_failure "9a $job_name allowlist must exit 2 on event [$refused_event]; got $allowlist_status"
  done
done

# --- 10. harness checkout from job.workflow_repository at job.workflow_sha -----
expect_fact "10 semgrep harness checkout" semgrep_harness_step yes
expect_fact "10 languages harness checkout" languages_harness_step yes

# --- 10a. the harness step, executed against a stub git (B-30) -----------------
# The stub logs its argv, one line per call, to $STUB_GIT_LOG; answers
# `rev-parse HEAD` with $HARNESS_SHA; exits $STUB_IS_ANCESTOR for any call
# naming merge-base; creates the directory `git init` names; and exits 0
# otherwise. No network or real repository is touched.
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GIT_LOG"
argument_count=$#
if [ "$argument_count" -ge 2 ]; then
  next_to_last="${@:$((argument_count - 1)):1}"
  last_argument="${@:$argument_count:1}"
  if [ "$next_to_last" = rev-parse ] && [ "$last_argument" = HEAD ]; then
    printf '%s\n' "$HARNESS_SHA"
    exit 0
  fi
fi
for argument in "$@"; do
  case "$argument" in
    *merge-base*) exit "${STUB_IS_ANCESTOR:-0}" ;;
  esac
done
for argument in "$@"; do
  if [ "$argument" = init ]; then
    mkdir -p "${@:$argument_count:1}"
    break
  fi
done
exit 0
STUB
chmod +x "$STUB_BIN/git"

VALID_SHA=$(printf 'a%.0s' $(seq 1 40))
SHORT_SHA=$(printf 'a%.0s' $(seq 1 39))
HARNESS_OWNER_REPOSITORY="nullvoidundefined/agent-governance"

# run_harness_step <script> <harness repository> <harness sha> <caller
# repository> <is-ancestor status>: runs the extracted harness step with the
# stub git first on PATH and a fresh RUNNER_TEMP. Sets HARNESS_STATUS,
# HARNESS_GIT_LOG (the path of the stub's call log), and HARNESS_STEP_OUTPUT
# (the path of the step's combined stdout and stderr).
run_harness_step() {
  local script="$1" harness_repository="$2" harness_sha="$3" caller_repository="$4" is_ancestor="$5"
  local runner_temp
  runner_temp=$(mktemp -d "$WORK/runner.XXXXXX")
  HARNESS_GIT_LOG="$runner_temp.gitlog"
  HARNESS_STEP_OUTPUT="$runner_temp.out"
  : > "$HARNESS_GIT_LOG"
  env -i PATH="$STUB_BIN:$PATH" HOME="$WORK" RUNNER_TEMP="$runner_temp" \
    HARNESS_REPOSITORY="$harness_repository" HARNESS_SHA="$harness_sha" \
    GITHUB_REPOSITORY="$caller_repository" STUB_IS_ANCESTOR="$is_ancestor" \
    STUB_GIT_LOG="$HARNESS_GIT_LOG" \
    bash --noprofile --norc -eo pipefail "$script" > "$HARNESS_STEP_OUTPUT" 2>&1
  HARNESS_STATUS=$?
}

# count_log_lines <fixed string> [second fixed string]: prints how many stub
# git calls contain the string, or both strings when two are given.
count_log_lines() {
  if [ "$#" -eq 2 ]; then
    grep -F -- "$1" "$HARNESS_GIT_LOG" | grep -cF -- "$2"
  else
    grep -cF -- "$1" "$HARNESS_GIT_LOG"
  fi
}

# find_first_log_line <fixed string> [second fixed string]: prints the line
# number of the first stub git call containing the string (and the second
# string when given), or nothing.
find_first_log_line() {
  if [ "$#" -eq 2 ]; then
    grep -nF -- "$1" "$HARNESS_GIT_LOG" | grep -F -- "$2" | head -n 1 | cut -d: -f1
  else
    grep -nF -- "$1" "$HARNESS_GIT_LOG" | head -n 1 | cut -d: -f1
  fi
}

# expect_refused_before_fetch <label>: the last harness run must exit 2 with no
# fetch at all.
expect_refused_before_fetch() {
  local label="$1"
  [ "$HARNESS_STATUS" = 2 ] || report_failure "$label: harness step must exit 2; got $HARNESS_STATUS"
  [ "$(count_log_lines fetch)" = 0 ] \
    || report_failure "$label: no git fetch may run; log: [$(cat "$HARNESS_GIT_LOG")]"
}

for job_name in semgrep languages; do
  harness_script="$WORK/harness-$job_name.sh"
  extract_step_run "$job_name" harness "$harness_script" || continue

  # 1. A repository other than agent-governance is refused before any fetch.
  run_harness_step "$harness_script" evil/agent-governance "$VALID_SHA" acme/app 0
  expect_refused_before_fetch "10a.1 $job_name foreign harness repository"

  # 2. A 39-character SHA is refused before any fetch.
  run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" "$SHORT_SHA" acme/app 0
  expect_refused_before_fetch "10a.2 $job_name 39-character SHA"

  # 3. An empty SHA is refused before any fetch.
  run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" '' acme/app 0
  expect_refused_before_fetch "10a.3 $job_name empty SHA"

  # 3a-3d. The SHA check is anchored at both ends: 41 hex characters, 40 hex
  #        characters with a trailing or leading `x`, and a branch name are each
  #        refused with an ::error line before any fetch.
  for malformed_sha in "${VALID_SHA}a" "${VALID_SHA}x" "x${VALID_SHA}" main; do
    run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" "$malformed_sha" acme/app 0
    label="10a.3 $job_name malformed SHA [$malformed_sha]"
    expect_refused_before_fetch "$label"
    [ -f "$HARNESS_GIT_LOG" ] || report_failure "$label: the stub git log must exist"
    grep -Fq '::error::' "$HARNESS_STEP_OUTPUT" \
      || report_failure "$label: the step must print an ::error:: line; got [$(cat "$HARNESS_STEP_OUTPUT")]"
  done

  # 4. A SHA that is not an ancestor of agent-governance main is refused: the
  #    ancestry check runs, and the pinned commit is never fetched or checked out.
  run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" "$VALID_SHA" acme/app 1
  label="10a.4 $job_name SHA not on main"
  [ "$HARNESS_STATUS" = 2 ] || report_failure "$label: harness step must exit 2; got $HARNESS_STATUS"
  [ "$(count_log_lines 'merge-base --is-ancestor')" -ge 1 ] \
    || report_failure "$label: a merge-base --is-ancestor call must run; log: [$(cat "$HARNESS_GIT_LOG")]"
  [ "$(count_log_lines fetch "$VALID_SHA")" = 0 ] \
    || report_failure "$label: the pinned SHA must never be fetched; log: [$(cat "$HARNESS_GIT_LOG")]"
  [ "$(count_log_lines checkout)" = 0 ] \
    || report_failure "$label: nothing may be checked out; log: [$(cat "$HARNESS_GIT_LOG")]"

  # 5. A SHA on main passes: ancestry check, then the fetch of the SHA, then
  #    the checkout, in that order.
  run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" "$VALID_SHA" acme/app 0
  label="10a.5 $job_name SHA on main"
  [ "$HARNESS_STATUS" = 0 ] \
    || report_failure "$label: harness step must exit 0; got $HARNESS_STATUS; log: [$(cat "$HARNESS_GIT_LOG")]"
  merge_base_line=$(find_first_log_line merge-base)
  fetch_sha_line=$(find_first_log_line fetch "$VALID_SHA")
  checkout_line=$(find_first_log_line checkout)
  if [ -z "$merge_base_line" ] || [ -z "$fetch_sha_line" ] || [ -z "$checkout_line" ]; then
    report_failure "$label: merge-base, fetch of the SHA, and checkout must each run; got lines [$merge_base_line] [$fetch_sha_line] [$checkout_line]; log: [$(cat "$HARNESS_GIT_LOG")]"
  elif ! { [ "$merge_base_line" -lt "$fetch_sha_line" ] && [ "$fetch_sha_line" -lt "$checkout_line" ]; }; then
    report_failure "$label: order must be merge-base ($merge_base_line) < fetch of the SHA ($fetch_sha_line) < checkout ($checkout_line)"
  fi

  # 6. agent-governance calling itself skips the ancestry check (its PR head is
  #    not on main yet) and fetches the SHA.
  run_harness_step "$harness_script" "$HARNESS_OWNER_REPOSITORY" "$VALID_SHA" "$HARNESS_OWNER_REPOSITORY" 1
  label="10a.6 $job_name self-call"
  [ "$HARNESS_STATUS" = 0 ] \
    || report_failure "$label: harness step must exit 0; got $HARNESS_STATUS; log: [$(cat "$HARNESS_GIT_LOG")]"
  [ "$(count_log_lines fetch "$VALID_SHA")" -ge 1 ] \
    || report_failure "$label: the SHA must be fetched; log: [$(cat "$HARNESS_GIT_LOG")]"
  [ "$(count_log_lines merge-base)" = 0 ] \
    || report_failure "$label: no merge-base call may run; log: [$(cat "$HARNESS_GIT_LOG")]"
done

# --- 11. Semgrep install and scan ----------------------------------------------
# B-36: Semgrep and every dependency install into a venv from the harness's
# hash-pinned requirements file, so the verdict never depends on what PyPI
# serves that day; pipx resolved dependencies unpinned.
expect_fact "11 semgrep install step reads the requirements file" semgrep_install_step present
expect_fact "11 semgrep install runs python3 -m venv" semgrep_install_marker_0 yes
expect_fact "11 semgrep install passes --require-hashes" semgrep_install_marker_1 yes
expect_fact "11 semgrep install passes --no-deps" semgrep_install_marker_2 yes
expect_fact "11 semgrep install reads the harness requirements file" semgrep_install_marker_3 yes
expect_fact "11 semgrep install appends the venv bin to GITHUB_PATH" semgrep_install_github_path yes
expect_fact "11 no pipx install semgrep" run_with_pipx_semgrep 0
expect_fact "11 semgrep scan step" semgrep_scan_step yes

# --- 11a. the hash-pinned requirements file (B-36) -----------------------------
SEMGREP_REQUIREMENTS="$REPO_ROOT/claude/enforce/security-ci-semgrep-requirements.txt"
if [ ! -f "$SEMGREP_REQUIREMENTS" ]; then
  report_failure "11a $SEMGREP_REQUIREMENTS does not exist"
else
  grep -Eq '^semgrep==1\.178\.0([^0-9]|$)' "$SEMGREP_REQUIREMENTS" \
    || report_failure "11a the requirements file must pin semgrep==1.178.0"
  requirement_hash_count=$(grep -oE -- '--hash=sha256:[0-9a-f]{64}' "$SEMGREP_REQUIREMENTS" | wc -l | tr -d ' ')
  [ "$requirement_hash_count" -ge 20 ] \
    || report_failure "11a the requirements file must carry at least 20 --hash=sha256: entries; got $requirement_hash_count"
  # Every requirement must carry at least one hash, on its own line or on the
  # continuation lines before the next requirement.
  unhashed_requirements=$(awk '
    /^[a-z0-9][a-z0-9._-]*==/ {
      if (current != "" && !hashed) print current
      current = $1; hashed = 0
    }
    /--hash=sha256:/ { hashed = 1 }
    END { if (current != "" && !hashed) print current }
  ' "$SEMGREP_REQUIREMENTS")
  requirement_count=$(grep -cE '^[a-z0-9][a-z0-9._-]*==' "$SEMGREP_REQUIREMENTS")
  [ "$requirement_count" -ge 1 ] || report_failure "11a the requirements file must list at least one requirement"
  [ -z "$unhashed_requirements" ] \
    || report_failure "11a every requirement must carry a --hash=sha256: entry; unhashed: [$unhashed_requirements]"
fi

# --- 12. languages output ------------------------------------------------------
expect_fact "12 languages outputs.list" languages_outputs_list present
expect_fact "12 languages list step" languages_list_step yes
# B-28: the deriver runs in PR mode on pull requests and full mode otherwise,
# reading the event name from env.
expect_fact "12 languages derive step EVENT_NAME env" languages_derive_event_env '${{ github.event_name }}'
expect_fact "12 languages derive step passes both modes" languages_derive_modes yes
# B-34: full mode lists go only on the default branch, so the derive step
# passes the ref and the default branch through env.
expect_fact "12 languages derive step DEFAULT_BRANCH env" languages_derive_default_branch_env '${{ steps.visibility.outputs.default_branch }}'
# The event payload lacks the repository on a schedule event, so the default
# branch comes from the visibility step's API read, never from the payload.
expect_fact "12 no run or env reads github.event.repository.default_branch" payload_default_branch_reads 0
expect_fact "12 languages derive step GIT_REF env" languages_derive_git_ref_env '${{ github.ref }}'
expect_fact "12 languages derive step passes --ref and --default-branch" languages_derive_ref_args yes

# --- 13. CodeQL init and analyze on the same SHA -------------------------------
init_refs=$(read_fact codeql_init_refs)
analyze_refs=$(read_fact codeql_analyze_refs)
printf '%s' "$init_refs" | grep -Eq '^[0-9a-f]{40}$' \
  || report_failure "13 codeql-action/init must be used at exactly one 40-character SHA; got [$init_refs]"
[ -n "$init_refs" ] && [ "$analyze_refs" = "$init_refs" ] \
  || report_failure "13 codeql-action/analyze must use the init SHA [$init_refs]; got [$analyze_refs]"
# B-28: only Go autobuilds, and Go reaches the matrix only in full mode.
expect_fact "13 codeql init build-mode" codeql_init_build_mode "\${{ matrix.language == 'go' && 'autobuild' || 'none' }}"

# --- 14. security-self.yml triggers on pull_request only -----------------------
expect_fact "14 self trigger" self_trigger_keys pull_request

# --- 15. security-self.yml calls the local workflow with exact permissions -----
expect_fact "15 self job count" self_job_count 1
expect_fact "15 self job uses" self_job_uses './.github/workflows/security.yml'
expect_fact "15 self permissions" self_permissions 'actions:read,contents:read,security-events:write'

finish_test
