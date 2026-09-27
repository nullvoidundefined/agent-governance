#!/usr/bin/env bash
# workflow-hardening.test.sh: the release and site workflows and the site
# image stay hardened (PR 159 security review, findings 2 to 4). Every `uses:`
# is pinned to a 40-hex commit SHA; the top-level permission is contents:
# read; contents: write appears only on release.yml's release job and pages:
# write or id-token: write only on site.yml's deploy job; no run block
# interpolates `${{ }}`; the deploy job installs with --ignore-scripts; and
# the site Dockerfile pins its base image by sha256 digest. Each check is also
# fed a hardened file broken in exactly one way and must reject it, so a
# checker that stopped checking cannot pass.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

cat > "$TMP/check.rb" <<'RUBY'
require "yaml"
# check.rb <release.yml> <site.yml> <Dockerfile>: prints one line per
# violation and exits 1 when there is any.
release_path, site_path, dockerfile_path = ARGV
problems = []
allowed_writes = {
  [release_path, "release"] => %w[contents],
  [site_path, "deploy"] => %w[pages id-token],
}
[release_path, site_path].each do |path|
  workflow = YAML.safe_load(File.read(path), aliases: false)
  top = workflow["permissions"]
  problems << "#{path}: top-level permissions are not {contents: read}" unless top == { "contents" => "read" }
  (workflow["jobs"] || {}).each do |job_name, job|
    writes = (job["permissions"] || {}).select { |_, level| level == "write" }.keys
    extra = writes - allowed_writes.fetch([path, job_name], [])
    problems << "#{path}: job #{job_name} holds write on #{extra.join(', ')}" unless extra.empty?
    (job["steps"] || []).each do |step|
      uses = step["uses"]
      if uses && !uses.start_with?("./") && uses !~ /@[0-9a-f]{40}\z/
        problems << "#{path}: job #{job_name} uses #{uses}, not pinned to a commit SHA"
      end
      run = step["run"].to_s
      problems << "#{path}: job #{job_name} interpolates ${{ }} inside run" if run.include?("${{")
      if path == site_path && job_name == "deploy" && run =~ /npm ci/ && run !~ /--ignore-scripts/
        problems << "#{path}: deploy job runs npm ci without --ignore-scripts"
      end
    end
  end
end
File.readlines(dockerfile_path).grep(/^\s*FROM\s/i).each do |line|
  problems << "#{dockerfile_path}: #{line.strip} is not pinned by sha256 digest" unless line =~ /@sha256:[0-9a-f]{64}\b/
end
puts problems
exit(problems.empty? ? 0 : 1)
RUBY

RELEASE="$REPO_ROOT/.github/workflows/release.yml"
SITE="$REPO_ROOT/.github/workflows/site.yml"
DOCKERFILE="$REPO_ROOT/site/Dockerfile"

# The real files pass.
ruby "$TMP/check.rb" "$RELEASE" "$SITE" "$DOCKERFILE" > "$TMP/real.out" 2>&1 || { cat "$TMP/real.out"; fail "the committed workflows or Dockerfile are not hardened"; }

# assertRejected(label, release, site, dockerfile, expected): the checker
# refuses a copy broken in one way and names the problem.
assertRejected() {
  if ruby "$TMP/check.rb" "$2" "$3" "$4" > "$TMP/mutant.out" 2>&1; then fail "$1: the checker accepted it"; fi
  grep -q "$5" "$TMP/mutant.out" || { cat "$TMP/mutant.out"; fail "$1: the checker did not name '$5'"; }
}

sed -E 's#actions/checkout@[0-9a-f]{40}#actions/checkout@v7#' "$RELEASE" > "$TMP/release-tag.yml"
assertRejected "a tag-pinned action" "$TMP/release-tag.yml" "$SITE" "$DOCKERFILE" "not pinned to a commit SHA"

awk '/^  test:/{print; print "    permissions:"; print "      contents: write"; next} {print}' "$SITE" > "$TMP/site-write.yml"
assertRejected "a test job with contents: write" "$RELEASE" "$TMP/site-write.yml" "$DOCKERFILE" "job test holds write on contents"

sed 's#bash release/build-release-archive.sh "$GITHUB_REF_NAME" dist#bash release/build-release-archive.sh "${{ github.ref_name }}" dist#' "$RELEASE" > "$TMP/release-expr.yml"
assertRejected "an expression inside run" "$TMP/release-expr.yml" "$SITE" "$DOCKERFILE" 'interpolates \${{ }} inside run'

sed 's#npm ci --ignore-scripts#npm ci#' "$SITE" > "$TMP/site-scripts.yml"
assertRejected "a deploy npm ci that runs scripts" "$RELEASE" "$TMP/site-scripts.yml" "$DOCKERFILE" "without --ignore-scripts"

sed -E 's#^FROM ([^@]+)@sha256:[0-9a-f]{64}#FROM \1#' "$DOCKERFILE" > "$TMP/Dockerfile.tag"
assertRejected "a tag-only base image" "$RELEASE" "$SITE" "$TMP/Dockerfile.tag" "not pinned by sha256 digest"

sed 's#^  contents: read#  contents: write#' "$RELEASE" > "$TMP/release-top.yml"
assertRejected "a top-level contents: write" "$TMP/release-top.yml" "$SITE" "$DOCKERFILE" "top-level permissions"

echo "workflow-hardening.test.sh PASS"
