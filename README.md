<!--
SPDX-FileCopyrightText: The jsonnet-oci-images Authors
SPDX-License-Identifier: 0BSD
-->

# Jsonnet OCI Images (JOI)

JOI packages Jsonnet libraries as OCI images so they can be consumed by
[jaas](https://github.com/metio/jaas) on Kubernetes — either mounted as image
volumes (standalone renderer) or pulled as Flux `OCIRepository` sources (operator
mode, via the [`joi` Helm chart](https://github.com/metio/helm-charts/tree/main/charts/joi)).
Each image is a **single filesystem layer** laid out exactly like a
`jb`/jsonnet-bundler `vendor/` tree, so the same import statement works locally
(`jsonnet -J vendor`) and in-cluster.

## Coverage

Every consumable library in the [jsonnet-libs](https://github.com/jsonnet-libs)
org plus [grafonnet](https://github.com/grafana/grafonnet) is published to
`ghcr.io/metio/joi-<org>-<repo>`. The full, auto-generated list is in
[`LIBRARIES.md`](LIBRARIES.md). Multi-version libraries (k8s-libsonnet,
cert-manager-libsonnet, grafonnet, …) ship **all upstream versions in one image**
plus a synthesized `latest` alias — pick one in the import path:

```jsonnet
local k = import 'github.com/jsonnet-libs/k8s-libsonnet/1.34/main.libsonnet';
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
```

## Image tags — `latest` vs a pinned snapshot

There are two independent axes. The **library version** is chosen in the import
path (above). The **image tag** chooses how the bundled vendor tree tracks
upstream:

- **`:latest`** (default) — the moving tag. It auto-updates whenever upstream
  changes, so an `OCIRepository` on `:latest` re-pulls the newest content on its
  interval. Best for "always current".
- **`:<YYYY.M.D>`** — an immutable dated snapshot (metio calendar convention,
  e.g. `:2026.6.16`). Each rebuild pushes one alongside `:latest`. A library is
  only rebuilt when its upstream SHA changes, so **each dated tag marks a
  distinct content version** — pin to one for reproducible renders that won't
  drift. List the available dates with any registry tool, e.g.
  `crane ls ghcr.io/metio/joi-grafana-grafonnet`.

Both tags point at the same multi-arch index, so pinning costs nothing extra.
For absolute immutability, pin by digest (`@sha256:…`), which `OCIRepository`
also supports.

## Zero-maintenance pipeline

There are no per-library files and no version numbers to maintain:

- **`Containerfile`** — one generic, parameterized builder for every library.
- **`hack/discover.sh`** — lists the jsonnet-libs org, filters to real libraries
  (a repo must ship a `main.libsonnet`), classifies single- vs multi-version,
  and records each library's current upstream **HEAD SHA** in `libraries.json`.
- **`hack/build-args.sh`** — enumerates a library's versions *at the pinned SHA*,
  so a newly published upstream version needs no edit.
- **`.github/workflows/libraries.yml`** — runs daily: refreshes the manifest and
  **rebuilds only the libraries whose upstream SHA changed** (or all, on demand).
  Each build is verified to be a single layer before it is pushed and signed.

A new upstream commit moves the SHA → the manifest changes → that one image
rebuilds. A brand-new jsonnet-libs repo is discovered automatically. No tags, no
manual version bumps, no Renovate.
