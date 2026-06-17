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

## Consuming a library

The image reference and the Jsonnet import path are **two different strings** —
get both right:

| | Pattern | grafonnet example |
|---|---|---|
| **Image** | `ghcr.io/metio/joi-<org>-<repo>` | `ghcr.io/metio/joi-grafana-grafonnet` |
| **Import** | `github.com/<org>/<repo>/…` | `github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet` |

The easiest way to consume these in-cluster is the
[`joi` Helm chart](https://github.com/metio/helm-charts/tree/main/charts/joi),
which renders the pair below for every enabled library. To wire one by hand in
**operator mode** — an `OCIRepository` plus a `JsonnetLibrary` that a snippet
references in `spec.libraries`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: grafonnet
spec:
  interval: 1h
  url: oci://ghcr.io/metio/joi-grafana-grafonnet
  ref:
    tag: latest
---
apiVersion: jaas.metio.wtf/v1
kind: JsonnetLibrary
metadata:
  name: grafonnet
spec:
  sourceRef:
    kind: OCIRepository
    name: grafonnet
# no path: the whole single-layer vendor tree is the library root
```

For the **standalone HTTP renderer**, mount the same image as a library volume
via the jaas chart's `additionalLibraries` map instead:

```yaml
additionalLibraries:
  grafonnet: ghcr.io/metio/joi-grafana-grafonnet:latest
```

Either way the snippet imports by the full vendor path shown in the table above.

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
manual version bumps, and **no Renovate for library versions** — the SHA-based
detection makes it unnecessary. (Renovate, via the org-wide
[`metio/renovate-config`](https://github.com/metio/renovate-config) preset this
repo's `renovate.json` extends, still keeps the repo's own infrastructure fresh:
GitHub Actions and the `Containerfile` builder base. It has no say over the
library content.)
