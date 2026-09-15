# Dockerization Rule (R-351)

Design doc. Status: approved 2026-09-05 by the maintainer's request ("a rule that all new projects are Dockerized from the start, that is, a Docker container for any deployable artifact"), implemented the same day.

## Motivation

`CLOUD-DEPLOYMENT.md` had described a per-service Dockerfile strategy (`Dockerfile` for the API, `Dockerfile.worker` for the worker, one image shared by cron services) and `CLAUDE-BACKEND.md` referenced it from the worker pattern, but nothing required a Dockerfile to exist. A new service could reach its first deploy on a platform buildpack, and the container arrived later as a retrofit, if at all. The rule makes the image the deploy unit from the commit that creates the artifact.

## Rule (within the R-3xx architecture block, as R-35x Deployment)

- **R-351** Every deployable artifact is Dockerized from its first commit: one Dockerfile per artifact, a `.dockerignore` beside it, a `docker-compose.yml` that runs it with its dependencies, and the image as the deploy unit on every platform. Libraries and shared packages are exempt. Existing projects adopt at their next deploy-surface change.

The Spec fixes the image contract: multi-stage build, pinned base image, non-root user, `HEALTHCHECK` on `/health` (R-345), no secret in the image, CI builds every image as a required check.

## Components

- `hooks/dockerfile-reminder.sh` (PostToolUse Write|Edit, advisory). An artifact marker (service or worker entry file, `package.json` with a `start` script, Next or Vite config, platform deploy config) written with no Dockerfile between its directory and the repo root reminds; a Dockerfile found with no `.dockerignore` beside it reminds; a written Dockerfile with no `USER` or an unpinned `FROM` reminds. Stage aliases, `scratch`, and digest pins are not unpinned.
- Manifest row: R-351, `advisory`, `hook:dockerfile-reminder`, severity `warn`.
- `settings.json`: registered in the PostToolUse `Write|Edit` chain beside `observability-reminder.sh`.
- Convention files: `CLAUDE-BACKEND.md` (Containers, with the monorepo Dockerfile pattern), `CLAUDE-PYTHON.md`, `CLAUDE-GO.md`, `CLAUDE-RUBY.md`, `CLAUDE-FRONTEND-NEXT.md`, `CLAUDE-FRONTEND-VITE.md`, and `CLOUD-DEPLOYMENT.md` bind the existing Dockerfile strategy to the rule.

Not decided mechanically, and said so: whether a compose file exists and runs every artifact, whether CI builds the image, whether the platform deploys from the Dockerfile rather than a buildpack, and whether a repository's entry file lives somewhere the marker list does not name. The reminder is silent on tests, fixtures, vendored trees, build output, and library packages.

## Testing

`enforce/tests/dockerfile-reminder.test.sh`: the entry-file reminder and its silence once a root Dockerfile and `.dockerignore` exist, the `.dockerignore`-only reminder, `package.json` with and without a `start` script, a deploy config, a per-app Dockerfile satisfying the walk-up, Dockerfile content (unpinned `latest`, untagged image, missing `USER`, and the clean multi-stage file), stage aliases and digest pins, and the out-of-scope paths.

## Domain vocabulary

- deployable artifact - anything that runs or is served somewhere other than the developer's machine: an API service, a worker, a cron job, a frontend server, a static site - chosen over: service, app because a cron job is neither and a static site is not a service, and the rule has to cover all of them.
- artifact marker - the file whose creation proves an artifact exists: its entry file, its `start` script, its framework build config, or its platform deploy config - chosen over: entry point because a `railway.toml` marks an artifact without being one's entry point.
- image definition - the `Dockerfile` (or `Containerfile`) that builds the artifact's container image - chosen over: container config because compose files and platform files also configure containers and are not the thing the rule requires.
- image contract - the Spec's fixed properties of every image: multi-stage, pinned base, non-root user, healthcheck, no baked-in secret - chosen over: Dockerfile conventions because the contract is what CI and the reminder check, not a style.
- deploy unit - the built image, the one thing that moves from CI to the platform - chosen over: build artifact because that phrase already names `dist/` output in `CLAUDE-BACKEND.md`.
- pinned base image - a `FROM` whose image carries a version tag or a digest, never `latest` and never untagged - chosen over: versioned image because a digest pin is not a version.
