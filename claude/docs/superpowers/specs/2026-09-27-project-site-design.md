# Project site and checksummed release

Tickets: IAN-477 (the site, the release, the deploy), IAN-478 (`sync.sh` installs from a release tarball).
Branch: `feat/project-site`. Tier: Standard. Mockup: the Claude Design canvas "agent-governance site" (desktop 1440 and mobile 390 artboards), approved by the owner on 2026-09-27.

## Goal

Publish a public landing page that presents agent-governance as a governance tool for generating code safely, and let a visitor download a pinned, checksummed release that installs without git. The page leads with security: the harness only ever takes permissions away from the agent and never grants one. Today the repository has no release, no site, and no way to install except cloning, and a `git archive` of it cannot install at all, because `sync.sh` needs `git ls-files`.

### Owner decisions (2026-09-27)

1. **Security message.** "It restricts. It never grants." The page makes four security claims, each true of the code today, and no others:
   - Hooks can only deny or ask; they never approve something the tool would otherwise refuse.
   - `sync.sh` writes only to `~/.claude`, `~/.cursor`, and `~/.codex`.
   - `sync.sh` removes a live file only when its manifest installed it, the source no longer ships it, and its content is unchanged since install (IAN-116).
   - No hook makes a network call. The one download during install is `npm ci` of the enforce dependencies from a pinned lockfile, and the page says so.
   There is no competitor comparison, and no claim that installing "changes nothing", because it writes the three folders above and runs `npm ci`.
2. **Hosting.** GitHub Pages, built from `site/` in this repository, deployed by a GitHub Actions workflow.
3. **Download.** A versioned GitHub Release (`v0.1.0` first) carrying the release archive and the release checksum. The page shows the checksum and a verify command.
4. **`site/` is never in the download.** `.gitattributes` marks `site/` `export-ignore`, and the release archive is built from `git archive`, which honors it.
5. **Build.** Hand-built HTML and CSS from the approved mockup, with no framework, tested with Playwright and axe.
6. **R-351.** `site/` carries a `Dockerfile` (nginx serving the site build), a `.dockerignore`, and a `docker-compose.yml`. The Playwright suite runs against that container, so the tested artifact is the served one. Pages publishes the same built files.
7. **Tarball install (IAN-478).** The release archive carries `RELEASE-FILES`. `sync.sh` reads it when its directory is not a git work tree and refuses to run when neither exists.

## Inputs

- `sync.sh`: its own directory, which is either a git checkout or an extracted release archive.
- `release/build-release-archive.sh <tag> <out-dir>`: a tag name and an output folder.
- `site/scripts/build-site.sh <version> <sha256>`: the release details, read by the site workflow from `gh release view` on the latest release.

## Outputs

- `sync.sh`: the three live folders, as today, or a `REFUSED:` line on stderr and a nonzero exit with no folder touched.
- `build-release-archive.sh`: `agent-governance-<tag>.tar.gz` and `agent-governance-<tag>.tar.gz.sha256` in `<out-dir>`, their paths on stdout.
- `build-site.sh`: `site/dist/`, the page with the release details substituted.
- The release workflow: a GitHub Release with both files attached.
- The site workflow: a GitHub Pages deployment at `https://nullvoidundefined.github.io/agent-governance/`.

## Acceptance criteria

`sync.sh` tarball mode (IAN-478), in `sync-tests/sync.test.sh`:

- B-1: `sync.sh` run from a `git archive` extract that holds a valid `RELEASE-FILES` installs exactly the listed `claude/`, `cursor/`, and `codex/` files into the three targets and exits 0.
- B-2: `sync.sh` run from a directory that is neither a git work tree nor holds `RELEASE-FILES` prints `REFUSED:` and exits nonzero, and all three targets are unchanged.
- B-3: `sync.sh` refuses, with all three targets unchanged, when any `RELEASE-FILES` line is absolute, contains a `..` component, is empty, or names a path missing from the extract. Each of the four cases is its own assertion.
- B-4: `sync.sh` run from a directory that holds both `.git` and `RELEASE-FILES` prints `REFUSED:`, exits nonzero, and leaves all three targets unchanged, because the source is ambiguous and git mode would skip every list check (PR 159 security review, round 2, finding 3; owner decision 2026-09-27). A checkout without `RELEASE-FILES` still lists files with `git ls-files`.

Release packaging, in `release-tests/build-release-archive.test.sh`:

- B-5: the release archive for a tag contains no path under `site/`, and its top-level folder is `agent-governance-<tag>/`.
- B-6: the archive's `RELEASE-FILES` lists exactly the archive's regular files and symlinks, excluding itself, sorted.
- B-7: `shasum -a 256 -c` on the release checksum passes from `<out-dir>`, and two builds of the same tag produce byte-identical archives.
- B-8: `sync.sh` from the extracted release archive installs into temporary targets and exits 0 (the end-to-end proof that a downloaded release installs).
- B-9: the script refuses a tag not matching `^v[0-9]+\.[0-9]+\.[0-9]+$` and a tag that does not exist, writing nothing to `<out-dir>`.

Site build, in `site/tests/e2e/build.spec.ts`:

- B-10: `build-site.sh` refuses a version not matching the tag pattern and a checksum that is not 64 lowercase hex characters, including values carrying `"`, `<`, or a newline, and writes no `dist/`.
- B-11: a successful build leaves no `{{` placeholder anywhere in `dist/`.

Site page, in `site/tests/e2e/page.spec.ts`, against the container:

- B-12: the download link's `href` is `https://github.com/nullvoidundefined/agent-governance/releases/download/<v>/agent-governance-<v>.tar.gz`, the page shows the injected checksum, and the verify command names the same archive.
- B-13: every network request the page makes is same-origin.
- B-14: the page carries a Content-Security-Policy meta whose `script-src` (or `default-src` when `script-src` is absent) is `'self'` with no `'unsafe-inline'`, and the container sends the same policy as a response header.
- B-15: axe reports zero violations at 1440 and 390 widths.
- B-16: at 390 width the document is no wider than the viewport.
- B-17: the page's rule counts (total, code-enforced, LLM-judged, advisory) equal the tier counts in `claude/enforce/manifest.json`.
- B-18: the page has exactly one `h1`, the four security-promise headings, and a skip link that moves focus to the main content.

## Invariants

- The release archive never contains `site/`.
- `sync.sh` never writes a target before every source file for all three targets has been resolved and validated.
- The deployed page never shows a placeholder or a checksum other than the one attached to the release it links.
- The page makes no request to any origin other than its own.

## Failure modes

- **Invalid `RELEASE-FILES` (R-406).** `sync.sh` refuses the whole run with a `REFUSED:` line naming the entry. Retry after re-downloading and re-verifying.
- **No git and no list.** `sync.sh` refuses with a message saying the directory is neither a checkout nor a release archive.
- **Invalid release details (R-406).** `build-site.sh` refuses, and the site workflow fails without deploying.
- **No release published yet.** The site workflow's `gh release view` fails, so the job fails rather than deploying placeholders.
- **Release upload fails midway.** `gh release create` either creates the release with both assets or fails; the workflow can be re-run on the same tag after deleting the partial release by hand.
- **Concurrent deploys.** The site workflow uses a `concurrency: pages` group with `cancel-in-progress: false`, so a second deploy queues.

## State transitions

None. The only state is the set of published releases, owned by GitHub.

## Non-goals

- A custom domain.
- Signing the release (Sigstore or GPG). The checksum proves the download matches the release, not who made it, and the page says exactly that.
- A docs site, a rule catalog page, or any second page.
- Auto-resync for tarball installs. A pinned release is updated by downloading the next one.
- Any change to `harness-sync.sh` or `hook-integrity-check.sh`. Both were read: the first exits silently in a local session with no git checkout, and the second compares files by hash, which works from an extract.
- Client-side JavaScript beyond an optional same-origin copy button.

## Dependencies

- Reuses `sync.sh`'s `sync_one` flow, changing only where the file list comes from, and `sync-tests/sync.test.sh`'s `run_sync` harness.
- `@playwright/test` and `@axe-core/playwright`, dev dependencies in `site/package.json` only, never in the release (it excludes `site/`). Justification (R-331): nothing in `claude/enforce/` drives a browser or audits accessibility, and the 100% accessibility requirement needs a real browser and an axe run.
- Fonts: Space Grotesk, IBM Plex Sans, and JetBrains Mono woff2 files under the SIL Open Font License, committed to `site/public/fonts/` with their license files.
- GitHub Actions: `actions/checkout`, `actions/upload-pages-artifact`, and `actions/deploy-pages`, each pinned by commit SHA.
- No migrations.

## Observability

- The site has no analytics, by design: it would contradict the page's own promise.
- `sync.sh` prints one line naming the mode it used (`source: git checkout` or `source: release archive RELEASE-FILES`) before syncing.
- The workflows' logs are the record of each release and deploy. No health endpoint (R-345 covers services and workers; this is a static page).

## Security

- `sync.sh` tarball mode is a security control: it decides which files land in `~/.claude`. B-3 feeds each check its insecure value. The PR needs the R-109 security review.
- The trust boundary for a download is the checksum, which the visitor checks against the release page. The page tells them to read `sync.sh` before running it.
- `build-site.sh` accepts only shape-checked values, so a tampered release name cannot inject markup (B-10).
- The site sets a strict CSP, `frame-ancestors 'none'` in the nginx header, `X-Content-Type-Options: nosniff`, and `Referrer-Policy: no-referrer`.
- GitHub Pages cannot set response headers, so the deployed site carries only the meta-tag CSP and `<meta name="referrer" content="no-referrer">`. `frame-ancestors 'none'` and `X-Content-Type-Options: nosniff` are sent by the nginx container alone, so the Pages deployment can be framed. The page is static, with no forms, sign-in, or scripts, so framing it can at most overlay its download link. The owner waived this gap on 2026-09-27 (PR 159 security review, finding 1).
- Workflow permissions are least-privilege per job: the release job holds `contents: write`; the site deploy job holds `pages: write` and `id-token: write`; the test job holds `contents: read`.
- The release job runs in the protected `release` environment, whose required reviewer is the owner, so no tag push publishes a release without the owner's approval (PR 159 security review, finding 5). The deploy job installs with `npm ci --ignore-scripts`, and the site image is pinned by digest (findings 3 and 4). `release/tests/workflow-hardening.test.sh` asserts all of these, plus SHA-pinned actions and per-job write permissions (finding 2).

### Deploy steps that need the owner's yes

1. Enabling GitHub Pages with source "GitHub Actions", which is a repository settings change.
2. Creating the `release` environment with the owner as required reviewer, which is a repository settings change.
3. Pushing the `v0.1.0` tag, which publishes a release on the public remote (R-106).
4. Merging the PR.

## Domain vocabulary

- release - a pushed `v*` tag and the GitHub Release the release workflow creates for it - chosen over: version, build, because GitHub's own noun avoids a second name for the same object.
- release archive - `agent-governance-<tag>.tar.gz`: `git archive` of the tag with `site/` excluded, plus `RELEASE-FILES`, under a top-level `agent-governance-<tag>/` folder - chosen over: tarball, package, because "package" suggests an npm package and "tarball" names the format rather than the thing.
- release checksum - `agent-governance-<tag>.tar.gz.sha256`: one `shasum -a 256` line naming the archive - chosen over: hash, digest, because the page's verify command uses `-c` on it, which checks a checksum file.
- release file list - `RELEASE-FILES`: one archive-relative path per line for every regular file and symlink in the archive except itself, sorted - chosen over: manifest, because `.sync-manifest` already means the installed-file hash list.
- site build - `site/dist/`: `site/public/` copied with the release details substituted - chosen over: bundle, because nothing is bundled.
- release details - the version and checksum substituted into the site build - chosen over: release metadata, because only these two values exist.
