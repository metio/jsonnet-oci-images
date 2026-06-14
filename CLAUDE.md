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
- `.github/workflows/libraries.yml` — runs daily: refresh the manifest, rebuild
  **only** the libraries whose SHA changed, enforce the single-layer gate, push
  `:latest`, cosign-sign.

**The SHA in the manifest IS the change detector.** When upstream pushes a
commit, `discover.sh` records the new SHA, the manifest diff triggers a rebuild
of exactly that library. This is what replaced Renovate **for tracking library
versions** — do not re-introduce a Renovate manager that pins library tags/SHAs.
(The org-preset Renovate managing GitHub Actions / the base image is fine and
unrelated.)

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
