#!/usr/bin/env bash
# SPDX-FileCopyrightText: The jsonnet-oci-images Authors
# SPDX-License-Identifier: 0BSD
#
# Print the generic Containerfile build args for one libraries.json entry (JSON
# on stdin or $1). Version subdirs are enumerated from the repo's git tree AT
# THE PINNED SHA, so a newly published upstream version is picked up with no
# manifest or pipeline edit. Output is KEY=VALUE lines (append to $GITHUB_ENV).
#
#   echo '<entry>' | hack/build-args.sh
set -euo pipefail

entry="$(cat "${1:-/dev/stdin}")"
name="$(jq -r .name <<<"$entry")"
org="$(jq -r .org <<<"$entry")"
repo="$(jq -r .repo <<<"$entry")"
branch="$(jq -r .branch <<<"$entry")"
sha="$(jq -r .sha <<<"$entry")"
kind="$(jq -r .kind <<<"$entry")"
base="github.com/${org}/${repo}"

api() { curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/$1"; }
# Version subdirs of $1 (a path prefix, "" = repo root) that hold a main.libsonnet.
versions_under() {
  local prefix="$1"
  api "repos/${org}/${repo}/git/trees/${sha}?recursive=1" \
    | jq -r '.tree[]?.path' \
    | sed -n "s#^${prefix}\([^/]*\)/main\.libsonnet\$#\1#p" \
    | grep -vE '^(_|\.)' | sort -uV
}

echo "IMAGE=ghcr.io/metio/joi-${org}-${repo}"
echo "JB_REF=${sha}"

case "$kind" in
  single)
    echo "JB_PKGS=${base}"
    echo "COPY_PATH=${base}"
    ;;
  multi)
    mapfile -t vers < <(versions_under "")
    pkgs=(); for v in "${vers[@]}"; do pkgs+=("${base}/${v}"); done
    newest="${vers[-1]}"
    echo "JB_PKGS=${pkgs[*]}"
    echo "COPY_PATH=${base}"
    echo "LATEST_DIR=${base}/latest"
    echo "LATEST_TARGET=${base}/${newest}/main.libsonnet"
    ;;
  grafonnet-gen)
    mapfile -t vers < <(versions_under "gen/")
    pkgs=(); for v in "${vers[@]}"; do pkgs+=("${base}/gen/${v}"); done
    # newest grafonnet-vX by the numeric suffix
    newest="$(printf '%s\n' "${vers[@]}" | sed 's/^grafonnet-v//' | sort -V | tail -1)"
    echo "JB_PKGS=${pkgs[*]}"
    echo "COPY_PATH=${base}/gen"
    echo "LATEST_DIR=${base}/gen/grafonnet-latest"
    echo "LATEST_TARGET=${base}/gen/grafonnet-v${newest}/main.libsonnet"
    ;;
  *)
    echo "build-args: unknown kind '${kind}' for ${name}" >&2; exit 1;;
esac
