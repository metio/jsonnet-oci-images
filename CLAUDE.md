<!--
SPDX-FileCopyrightText: The jsonnet-oci-images Authors
SPDX-License-Identifier: 0BSD
-->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

JOI (Jsonnet-OCI-Images) packages Jsonnet libraries as OCI images so
[jaas](https://github.com/metio/jaas) can consume them on Kubernetes. Every
image is **`FROM scratch`**, laid out exactly like a `jb`/jsonnet-bundler
`vendor/` tree (`/github.com/<org>/<repo>/…`), and published to
**`ghcr.io/metio/joi-<org>-<repo>`**. Because the layout matches `jb`, the same
import statement works locally (`jsonnet -J vendor`) and in-cluster.

The images are **dual-consumable**, which drives the two hard invariants below:

- **image-volume mount** — the JaaS chart's `additionalLibraries`/`snippets`
  pull these as OCI volumes (standalone HTTP renderer, high-DX local dev, no
  cluster), and
- **Flux `OCIRepository` source** — a `JsonnetLibrary` with a `sourceRef` to an
  `OCIRepository` (in-cluster operator mode), surfaced by the
  [`joi` chart](https://github.com/metio/helm-charts/tree/main/charts/joi).

## How it's built — zero-maintenance auto-discovery

There is **one generic `Containerfile`** for every library and **no per-library
files, no hardcoded versions, no git tags/SHAs to bump by hand**, and **no
Renovate for library versions** (the org-wide `metio/renovate-config` preset
that `renovate.json` extends still manages this repo's *infrastructure* deps —
GitHub Actions, the builder base image — but never the library content). The
pipeline:

- `hack/discover.sh` — lists the [jsonnet-libs](https://github.com/jsonnet-libs)
  org (+ grafonnet), filters out anything that isn't a real library (needs a
  `main.libsonnet`), classifies single-version / multi-version / grafonnet-gen,
  records each library's current upstream **HEAD SHA**, and computes the
  transitive dependency **closure** from each `jsonnetfile.json`. Output:
  `libraries.json` (the manifest, the single source of truth).
- `hack/build-args.sh` — turns one manifest entry into the `Containerfile` build
  args, enumerating version subdirectories **at the pinned SHA** so new upstream
  versions need no edit.
- `hack/gen-readme.sh` — regenerates `LIBRARIES.md` from the manifest.
- `.github/workflows/libraries.yml` — the **only** workflow. Runs daily: refresh
  the manifest, rebuild **only** the libraries whose SHA changed, enforce the
  single-layer gate, push `:latest` + a dated tag, cosign-sign.

**The SHA in the manifest IS the change detector.** When upstream pushes a
commit, `discover.sh` records the new SHA, the manifest diff triggers a rebuild
of exactly that library. This is what replaced Renovate **for tracking library
versions** — do not re-introduce a Renovate manager that pins library tags/SHAs.
(The org-preset Renovate managing GitHub Actions / the base image is fine and
unrelated.)

## CI — the build pipeline plus a small PR gate

`libraries.yml` is the build/release pipeline (below). A second, deliberately
tiny `verify.yml` runs on `pull_request` only and exists so PRs — notably
Renovate's base-image and GitHub-Actions bumps, plus any Containerfile change —
carry a green status that branch protection / auto-merge can require (the build
pipeline only runs on cron/dispatch, so without this a PR had no check at all).
It lints the one generic `Containerfile` with **hadolint** (config in
`.hadolint.yaml`: `failure-threshold: warning`, `DL3007` ignored because the
`golang:latest` base is Renovate-digest-pinned) and the workflows with
**actionlint** (which also shellchecks the `run:` blocks), behind a single
`all-green` aggregate that is the only check to mark required. This keeps
Containerfile-only and workflow-only PRs auto-mergeable with zero manual work.

`libraries.yml` is the build pipeline; it both validates and releases. It fires
on a daily `cron` and on `workflow_dispatch` (an `all: true` input forces a
rebuild of every library instead of only the changed set). Permissions:
`contents: write` (commit the refreshed manifest), `packages: write` (push to
ghcr.io), `id-token: write` (cosign keyless).

- **`discover` job** (single runner) — runs `hack/discover.sh` to regenerate the
  manifest, diffs it against the committed `libraries.json`, and on any change
  commits the refreshed `libraries.json` + regenerated `LIBRARIES.md` back to the
  repo (as `github-actions[bot]`). It computes the **changed set** (entries whose
  SHA differs from the old manifest, or new ones; everything when forced) and
  emits it as the build matrix, plus an `any` flag and the shared dated calver
  tag (`date +'%Y.%-m.%-d'`, computed once so the whole matrix shares one date).
- **`build` job** (matrix over the changed libraries, `fail-fast: false`,
  bounded `max-parallel`, gated on `discover.any == 'true'`) — computes build
  args via `hack/build-args.sh`, builds, **validates**, then pushes and signs.

## Validation layers

There is **no separate test suite**, and the only lint is the small PR gate
above (hadolint + actionlint via `verify.yml`); there is no
yamllint/markdownlint/typos/reuse job. The repo is bash + `jq` + a
generic `Containerfile`; correctness is otherwise enforced by the build itself across three
layers, all inside the `build` job:

1. **The build must succeed.** `jb init` + `jb install` of every `JB_PKGS` target
   at the pinned `JB_REF` has to resolve — a library whose `jsonnetfile.json` or
   version subtree can't be vendored fails the build, so a broken/renamed upstream
   surfaces as a red matrix cell rather than a bad push.
2. **Single-layer gate** (the load-bearing check). The image is first built
   locally (`load: true, push: false, provenance: false, sbom: false`) and a
   shell step asserts `docker image inspect --format '{{ len .RootFS.Layers }}'`
   equals `1`, failing the cell otherwise. Only after this passes does the second
   `build-push-action` step build the multi-arch index and push it. Keeping
   `provenance`/`sbom` off on **both** the verify and the push step is part of the
   invariant — buildx attestations would add manifest entries / layers that defeat
   the single-layer guarantee.
3. **Manifest integrity is self-defending.** `discover.sh` is additive-only (the
   output is always a superset of the committed manifest; `curl --retry-all-errors`
   absorbs transient upstream blips), so a flaky discovery run can never silently
   drop a still-published library from the build set — there is no test guarding
   this because the script's superset property makes the failure mode impossible.

To exercise the gate locally, build a single non-native platform to an
`oci-archive` and inspect that the config declares the target arch and the
manifest has exactly one layer (see **Local builds**).

## Invariants — do not break

- **Single filesystem layer per image** (CI-gated: `docker image inspect …
  RootFS.Layers` must equal 1). A Flux `OCIRepository` with no `layerSelector`
  extracts only the first layer, so a multi-layer image would silently drop
  content. The scratch stage uses a single `COPY` of the library's **own**
  subtree — dependencies are excluded (they ship as their own JOI images; the
  jaas operator's importer cross-resolves them).
- **Multi-arch** (`linux/amd64,arm64,arm/v7,ppc64le,riscv64,s390x` — the metio-wide
  set). The content is arch-independent Jsonnet text, so the builder stage is
  pinned `FROM --platform=$BUILDPLATFORM …` and a multi-arch build runs `jb`
  exactly once with **no QEMU**; only the empty `scratch` runtime stage takes
  `$TARGETPLATFORM`, which stamps each manifest's architecture. Each per-arch
  manifest is still exactly one layer.
- **Library-version selection happens in the import path, not the tag.**
  Multi-version libraries (k8s-libsonnet `1.32`…, grafonnet `gen/grafonnet-vX`)
  ship **all** versions in one image plus a synthesized `latest` alias dir whose
  `main.libsonnet` re-imports the newest version (the "grafonnet trick",
  generalized). Consumers pin a version in the import path or import `latest`.
- **The image tag is a separate axis: `:latest` + a dated calver tag.** Every
  (re)build pushes the moving `:latest` AND an immutable `:<YYYY.M.D>` snapshot
  (the metio calendar convention; the date is computed once per run in the
  `discover` job and shared across the matrix). Since a library is only rebuilt
  when its upstream SHA changes, each dated tag marks a distinct content version
  — between changes the content is byte-identical. Both tags point at the same
  multi-arch index. Users pin `:latest` for auto-update, a dated tag for
  reproducibility, or a digest for absolute immutability.

## Build args (passed by the workflow per library)

| Arg | Meaning |
|---|---|
| `JB_PKGS` | space-separated `jb install` targets (no `@ref`) |
| `COPY_PATH` | the library's own subtree under `vendor/` to publish |
| `LATEST_DIR` / `LATEST_TARGET` | optional synthesized `latest` alias dir + what it imports |
| `JB_REF` | optional commit SHA to pin every install to (empty tracks the default branch — note upstreams vary: some default `master`, some `main`) |

## Release / publish

Releasing is the tail of the `build` job — there is no separate release workflow
and no GitHub Release object; **the published images are the release.**

- **Where.** Each library publishes to `ghcr.io/metio/joi-<org>-<repo>` (the
  `IMAGE` env var that `build-args.sh` prints). Auth is the workflow's
  `GITHUB_TOKEN` via `docker/login-action` against `ghcr.io`.
- **Versioning is calendar-based**, not semver and not git-tag-driven. Every
  successful build pushes two tags at the same multi-arch index: the moving
  `:latest` and an immutable `:<YYYY.M.D>` snapshot (the metio calver convention;
  the date is the `discover` job's shared value). A library is only rebuilt when
  its upstream SHA moves, so each dated tag marks a genuinely distinct content
  version — between rebuilds the content is byte-identical.
- **OCI labels** stamp `org.opencontainers.image.source` (this repo) and
  `org.opencontainers.image.revision` (the upstream library's HEAD SHA from the
  manifest), so a pushed image is traceable back to the exact upstream commit it
  was vendored from.
- **Signing is cosign keyless** (`sigstore/cosign-installer` + `cosign sign
  --yes <IMAGE>@<digest>` against the digest the push step output, using the
  `id-token: write` OIDC identity — Fulcio/Rekor, no long-lived keys, no GPG).
  This matches the metio-wide keyless-signing convention.

## Coupling rule

Adding a new image requires **both** (1) it builds single-layer (CI-gated) and
(2) it appears in `charts/joi/values.yaml` in the
[helm-charts](https://github.com/metio/helm-charts) repo so it becomes an
importable JaaS library. The second half is automated: `helm-charts`'
`sync-joi.yml` regenerates the chart's values from JOI's published
`libraries.json` daily.

## Local builds

This repo is build-only (no Go, no `.ilo.rc` — just `Containerfile` + bash +
`jq`). To reproduce an image locally with Podman/Docker buildx, pass the build
args by hand (long-form image references throughout, e.g.
`docker.io/library/golang:latest`). To verify a multi-arch build cross-compiles
with no emulation, build a single non-native platform (`--platform linux/arm64`)
to an `oci-archive` and inspect that the config declares the target arch and the
manifest has one layer.

## Licensing / REUSE

0BSD, REUSE-compliant. Every file carries an SPDX header (`Containerfile`/shell
via `#`, markdown via `<!-- -->`). `LIBRARIES.md` is generated — edit
`hack/gen-readme.sh`, not the table.
