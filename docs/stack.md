# Stack

This document lists what the project site and the release pipeline are built from, one entry per piece, grouped by layer (R-608). Its scope is the `site/` landing page and the `release/` packaging that IAN-477 added. The governance harness itself (the bash hooks, `claude/enforce/`, and its ESLint bundle) is not catalogued here yet; its prerequisites are listed in `README.md` under Install and in `claude/SETUP.md`.

Last updated: 2026-09-27 (IAN-477).

## Page

### HTML and CSS, no framework

- **Version:** HTML5 and CSS as supported by current evergreen browsers.
- **What it is:** a single hand-written page, `site/public/index.html`, styled by one stylesheet, `site/public/styles.css`.
- **Docs:** <https://developer.mozilla.org/en-US/docs/Web/HTML>
- **Role here:** the whole landing page.
- **Why chosen:** one static page needs no build framework, and plain HTML with no inline script or style is what lets the page carry a strict Content-Security-Policy (`script-src 'self'`, `style-src 'self'`) with nothing exempted.
- **Configured in:** `site/public/`.

### Space Grotesk, IBM Plex Sans, JetBrains Mono (via @fontsource)

- **Version:** `@fontsource/space-grotesk` 5.3.0, `@fontsource/ibm-plex-sans` 5.3.0, `@fontsource/jetbrains-mono` 5.3.0.
- **What it is:** npm packages that ship the woff2 font files of these three SIL Open Font License typefaces, with their license texts.
- **Docs:** <https://fontsource.org/docs/getting-started/introduction>
- **Role here:** the display face, the body face, and the monospace face from the approved design. `site/scripts/build-site.sh` copies six latin woff2 files into `dist/fonts/`.
- **Why chosen:** self-hosting the fonts means the page makes no third-party request, so a visit does not reach Google Fonts or any other origin. The page says the harness never phones home, and the page itself keeps the same promise.
- **Configured in:** `site/package.json` (dev dependencies), `site/scripts/build-site.sh` (the list of faces), `site/public/styles.css` (`@font-face` rules).

## Build

### bash build script

- **Version:** bash 3.2 or newer.
- **What it is:** `site/scripts/build-site.sh <version> <sha256>`, which copies `site/public/` to `site/dist/`, copies the fonts, and substitutes the release version and checksum.
- **Docs:** <https://www.gnu.org/software/bash/manual/>
- **Role here:** produces the site build that nginx serves and GitHub Pages publishes. It refuses a version that is not `vMAJOR.MINOR.PATCH` and a checksum that is not 64 lowercase hex characters, so a release name cannot inject markup.
- **Why chosen:** the build is a copy plus two substitutions, and the repository is already bash throughout.
- **Configured in:** `site/scripts/build-site.sh`.

### git archive (release packaging)

- **Version:** git 2.39 or newer (`--add-virtual-file`).
- **What it is:** `release/build-release-archive.sh <tag> <out-dir>`, which builds `agent-governance-<tag>.tar.gz` with `git archive` and writes its `.sha256`.
- **Docs:** <https://git-scm.com/docs/git-archive>
- **Role here:** the downloadable release. `site/` is `export-ignore` in `.gitattributes`, so it never ships, and the archive carries `RELEASE-FILES` for `sync.sh`'s release-archive mode.
- **Why chosen:** git honors `export-ignore` and writes the gzip itself, so one tag always yields byte-identical archives on the same git version.
- **Configured in:** `release/build-release-archive.sh`, `.gitattributes`.

## Serving

### nginx (nginxinc/nginx-unprivileged)

- **Version:** `nginxinc/nginx-unprivileged:1.27-alpine`.
- **What it is:** nginx packaged to run as a non-root user (uid 101) on port 8080.
- **Docs:** <https://github.com/nginxinc/docker-nginx-unprivileged>
- **Role here:** serves the site build in the container the tests run against. It sends the Content-Security-Policy header with `frame-ancestors 'none'`, plus `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`, which a meta tag cannot carry.
- **Why chosen:** R-351 makes the image the deploy unit, and the unprivileged variant avoids running the server as root.
- **Configured in:** `site/Dockerfile`, `site/nginx.conf`, `site/docker-compose.yml` (read-only root filesystem, port `SITE_PORT`, default 3000).

### GitHub Pages

- **Version:** the hosted service, deployed with the GitHub Actions source.
- **What it is:** GitHub's static hosting, serving the site at <https://nullvoidundefined.github.io/agent-governance/>.
- **Docs:** <https://docs.github.com/en/pages>
- **Role here:** the public host. Pages cannot set response headers, which is why the page carries its CSP as a meta tag as well.
- **Why chosen:** free, no new account, and it lives beside the repository the page describes.
- **Configured in:** `.github/workflows/site.yml`, and the repository's Pages settings (source: GitHub Actions).

## Testing

### Playwright

- **Version:** `@playwright/test` 1.63.0, Chromium.
- **What it is:** a browser automation and test runner.
- **Docs:** <https://playwright.dev/docs/intro>
- **Role here:** runs `site/tests/e2e/build.spec.ts` (the build script's refusals) and `site/tests/e2e/page.spec.ts` (download link, checksum, same-origin requests, CSP, layout at 390 pixels, manifest counts, headings, skip link) against the nginx container. `site/tests/site.test.sh` wraps the run so `tdd.sh` can lock it as a bash fixture.
- **Why chosen:** the checks need a real browser: request origins, response headers, focus order, and rendered width cannot be asserted from the HTML text.
- **Configured in:** `site/playwright.config.ts`, `site/package.json`.

### axe-core for Playwright

- **Version:** `@axe-core/playwright` 4.13.0.
- **What it is:** Deque's accessibility engine, run inside a Playwright page.
- **Docs:** <https://github.com/dequelabs/axe-core-npm/tree/develop/packages/playwright>
- **Role here:** B-15 requires zero violations at 1440 and 390 pixels wide, which covers the 100% accessibility requirement on every change.
- **Why chosen:** it is the engine Lighthouse's accessibility audit uses, so a zero-violation axe run tracks the Lighthouse score the owner requires.
- **Configured in:** `site/tests/e2e/page.spec.ts`.

## Continuous integration and release

### GitHub Actions

- **Version:** `actions/checkout` v7.0.1, `actions/setup-node` v7.0.0 (Node 22), `actions/upload-pages-artifact` v5.0.0, `actions/deploy-pages` v5.0.1, each pinned by full commit SHA.
- **What it is:** GitHub's workflow runner.
- **Docs:** <https://docs.github.com/en/actions>
- **Role here:** `release.yml` builds and publishes the release archive when a `v*.*.*` tag is pushed. `site.yml` tests the site on pull requests, then on `main`, on a published release, or by hand builds it with the latest release's version and checksum and deploys it to Pages. `enforce.yml` runs the release fixtures.
- **Why chosen:** it already runs this repository's CI. Pinning by SHA means a moved tag cannot change what runs.
- **Configured in:** `.github/workflows/release.yml`, `.github/workflows/site.yml`, `.github/workflows/enforce.yml`.
