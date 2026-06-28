# SPDX-FileCopyrightText: The jsonnet-oci-images Authors
# SPDX-License-Identifier: 0BSD

# Generic, parameterized builder for every Jsonnet-OCI-Image. The discovery
# workflow passes the jb install targets + the subtree to publish, so there is
# one Containerfile for all libraries and zero per-library files to maintain.
#
#   JB_PKGS      space-separated jb packages to install (without @main), e.g.
#                "github.com/jsonnet-libs/k8s-libsonnet/1.34 .../1.35"
#   COPY_PATH    the library's own subtree under vendor/ to publish (deps are
#                excluded — they ship as their own JOI images, the operator
#                importer resolves cross-library), e.g.
#                "github.com/jsonnet-libs/k8s-libsonnet"
#   LATEST_DIR   optional synthesized "latest" alias dir (the grafonnet trick),
#                e.g. "github.com/jsonnet-libs/k8s-libsonnet/latest"
#   LATEST_TARGET  what that alias imports, e.g.
#                "github.com/jsonnet-libs/k8s-libsonnet/1.35/main.libsonnet"
#   JB_REF       optional commit SHA (or ref) to pin every install to. Empty
#                tracks the upstream default branch; the discovery workflow
#                records each upstream's current HEAD SHA in libraries.json and
#                threads it through here, so a new upstream commit produces a
#                new, reproducible build (there is no Renovate for library
#                versions — discovery is the source of truth).
ARG JB_PKGS
ARG COPY_PATH
ARG LATEST_DIR=""
ARG LATEST_TARGET=""
ARG JB_REF=""

# The builder only emits arch-independent Jsonnet text, so pin it to the native
# build platform ($BUILDPLATFORM). A multi-arch push then runs jb exactly once
# (no QEMU emulation per target arch); only the empty scratch runtime stage below
# takes $TARGETPLATFORM, which is what stamps each manifest's architecture.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:latest@sha256:32c0e6e5c4f6707717051091b4d0b077464a679eaab563e11474efc5328e2aa5 AS jb
RUN go install -a github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest

ARG JB_PKGS
ARG LATEST_DIR
ARG LATEST_TARGET
ARG JB_REF
WORKDIR /src
RUN /go/bin/jb init && \
    for pkg in ${JB_PKGS}; do \
      if [ -n "${JB_REF}" ]; then /go/bin/jb install "${pkg}@${JB_REF}"; \
      else /go/bin/jb install "${pkg}"; fi; \
    done
# Synthesize the rolling "latest" alias so consumers can import a pinned version
# OR "latest" and not care — the same trick grafonnet uses.
RUN if [ -n "${LATEST_DIR}" ]; then \
      mkdir -p "/src/vendor/${LATEST_DIR}" && \
      printf "import '%s'\n" "${LATEST_TARGET}" > "/src/vendor/${LATEST_DIR}/main.libsonnet"; \
    fi

# Single COPY of the library's own subtree = exactly one layer (required so the
# image works as both an image-volume mount and a Flux OCIRepository source).
FROM scratch
ARG COPY_PATH
COPY --from=jb /src/vendor/${COPY_PATH} /${COPY_PATH}