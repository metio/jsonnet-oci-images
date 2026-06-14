#!/usr/bin/env bash
# SPDX-FileCopyrightText: The jsonnet-oci-images Authors
# SPDX-License-Identifier: 0BSD
#
# Discover every consumable Jsonnet library in the jsonnet-libs org (plus the
# grafana/grafonnet special case) and emit libraries.json — the manifest the
# build workflow matrices over. Run in CI with GITHUB_TOKEN.
#
# A repo is a library when it ships consumable jsonnet: a root main.libsonnet
# (single-version), version subdirs each with main.libsonnet (multi-version),
# or any .libsonnet at all (e.g. docsonnet). Generators/docs/playgrounds have
# none and are skipped. Versions are NOT recorded — the build enumerates them at
# the pinned SHA. Each entry also carries its transitive dependency `closure`
# (other JOI library names it imports, read from jsonnetfile.json) so the joi
# chart can auto-enable a library's dependencies.
set -euo pipefail

api() { curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"; }
raw() { curl -fsSL "https://raw.githubusercontent.com/$1"; } # not API-rate-limited

SKIP="k8s ecosystem playground jsonnet-training-course"
repos_json="$(for p in 1 2 3 4; do api "orgs/jsonnet-libs/repos?per_page=100&page=$p"; done | jq -s 'add | map(select(.archived==false and .fork==false))')"
emit=()

classify() { # paths  ->  kind|skip
  local paths="$1"
  if echo "$paths" | grep -qE '^[^/]+/main\.libsonnet$' \
     && echo "$paths" | grep -E '^[^/]+/main\.libsonnet$' | grep -qvE '^(_|\.|docs/)'; then
    echo "$paths" | grep -qx 'main.libsonnet' || { echo multi; return; }
  fi
  echo "$paths" | grep -qx 'main.libsonnet' && { echo single; return; }
  echo "$paths" | grep -q '\.libsonnet$' && { echo single; return; }
  echo skip
}

# Direct dependency library names from a repo's jsonnetfile.json (root if present,
# else the newest version subdir's). Maps each dep's git remote to its repo name.
direct_deps() { # org repo sha paths
  local org="$1" repo="$2" sha="$3" paths="$4" jf
  jf="$(echo "$paths" | grep -x 'jsonnetfile.json' || true)"
  [ -n "$jf" ] || jf="$(echo "$paths" | grep -E '/jsonnetfile\.json$' | sort -V | tail -1 || true)"
  [ -n "$jf" ] || { echo '[]'; return; }
  raw "${org}/${repo}/${sha}/${jf}" 2>/dev/null \
    | jq -c '[.dependencies[]?.source.git.remote // empty
             | sub("\\.git$";"") | sub("^https?://github.com/";"") | split("/")[1]]
             | unique' 2>/dev/null || echo '[]'
}

add() { # name org repo branch kind paths
  local sha; sha="$(api "repos/${2}/${3}/commits/${4}" | jq -r '.sha')"
  local deps; deps="$(direct_deps "$2" "$3" "$sha" "$6")"
  emit+=("$(jq -nc --arg name "$1" --arg org "$2" --arg repo "$3" \
      --arg source "https://github.com/${2}/${3}" --arg branch "$4" \
      --arg sha "$sha" --arg kind "$5" --argjson deps "$deps" \
      '{name:$name, org:$org, repo:$repo, source:$source, branch:$branch, sha:$sha, kind:$kind, directdeps:$deps}')")
}

while IFS=$'\t' read -r name branch; do
  case " $SKIP " in *" $name "*) continue;; esac
  tree="$(api "repos/jsonnet-libs/${name}/git/trees/${branch}?recursive=1")" || continue
  paths="$(echo "$tree" | jq -r '.tree[]?.path' 2>/dev/null)"
  kind="$(classify "$paths")"
  [ "$kind" = skip ] && { echo "skip (no jsonnet): $name" >&2; continue; }
  add "$name" jsonnet-libs "$name" "$branch" "$kind" "$paths"
done < <(echo "$repos_json" | jq -r '.[] | "\(.name)\t\(.default_branch)"')

# grafonnet: grafana org, gen/grafonnet-vX layout.
gbranch="$(api repos/grafana/grafonnet | jq -r '.default_branch')"
gtree="$(api "repos/grafana/grafonnet/git/trees/${gbranch}?recursive=1" | jq -r '.tree[]?.path')"
add grafonnet grafana grafonnet "$gbranch" grafonnet-gen "$gtree"

# Resolve each library's transitive closure over directdeps, keep only deps that
# are themselves discovered JOI libraries, drop the raw directdeps.
printf '%s\n' "${emit[@]}" | jq -s '
  (map({key:.name, value:(.directdeps // [])}) | from_entries) as $g
  | def closure($n):
      def grow($a): ([$a[] | $g[.] // []] | add) as $m | ($a + $m | unique) as $x
        | if $x == $a then $a else grow($x) end;
      (grow([$n]) - [$n]);
    map(. + {closure: ([closure(.name)[] | select($g[.] != null)] | sort)} | del(.directdeps))
  | sort_by(.name)
'
