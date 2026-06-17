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

# Retry transient failures — 5xx (including 504 gateway timeouts on the large
# recursive-tree endpoint), 429 rate limits, and connection blips. --retry-delay 0
# selects curl's exponential backoff and lets it honor a Retry-After header; the
# old fixed 2s delay ignored Retry-After and burned the whole budget in seconds.
# --retry-all-errors also retries non-standard error responses; --retry-max-time
# bounds the per-call retry window so a sustained outage can't hang the daily run.
# A genuinely-gone repo (persistent 404) still fails after the retries and is
# dropped as intended. On a final failure the wrappers name the exact URL and
# curl exit code, so a 504 says which request timed out.
RETRY=(--retry 6 --retry-all-errors --retry-delay 0 --retry-max-time 120)
api() {
  local url="https://api.github.com/$1" rc=0
  curl -fsSL "${RETRY[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$url" || rc=$?
  [ "$rc" -eq 0 ] || { echo "FETCH FAILED (curl $rc): $url" >&2; return "$rc"; }
}
raw() { # not API-rate-limited
  local url="https://raw.githubusercontent.com/$1" rc=0
  curl -fsSL "${RETRY[@]}" "$url" || rc=$?
  [ "$rc" -eq 0 ] || { echo "FETCH FAILED (curl $rc): $url" >&2; return "$rc"; }
}

SKIP="k8s ecosystem playground jsonnet-training-course"
repos_json="$(for p in 1 2 3 4; do api "orgs/jsonnet-libs/repos?per_page=100&page=$p"; done | jq -s 'add | map(select(.archived==false and .fork==false))')"
emit=()

# name -> upstream GitHub description, captured once so the spaces/punctuation in
# descriptions never have to flow through the tab-separated read loop below. The
# final assembly jq merges this onto each freshly-discovered entry by name.
descmap="$(echo "$repos_json" | jq 'map({key:.name, value:(.description // "")}) | from_entries')"
gdesc="$(api repos/grafana/grafonnet | jq -r '.description // ""')" || gdesc=""
descmap="$(echo "$descmap" | jq --arg d "$gdesc" '. + {grafonnet:$d}')"

classify() { # paths  ->  kind|skip
  local paths="$1" toplevel
  # Match against here-strings, never `echo "$paths" | grep -q`: under
  # `set -o pipefail` a `grep -q` that early-exits on its first match closes the
  # pipe while echo is still writing, so echo dies with SIGPIPE and the whole
  # pipeline reports failure even though grep DID match. For a large repo
  # (k8s-libsonnet ships thousands of paths) that misreads the match as "no
  # match", so the library is wrongly classified `skip` and never built. A
  # here-string has no upstream writer process to receive SIGPIPE.
  #
  # Top-level version dirs each holding main.libsonnet (X/main.libsonnet),
  # excluding _private/.dot/docs prefixes -> multi-version. Capture the matches
  # first (read fully, no early exit) so the prefix check runs on that small set
  # without another large pipe.
  toplevel="$(grep -E '^[^/]+/main\.libsonnet$' <<<"$paths" || true)"
  if [ -n "$toplevel" ] && grep -qvE '^(_|\.|docs/)' <<<"$toplevel"; then
    grep -qx 'main.libsonnet' <<<"$paths" || { echo multi; return; }
  fi
  grep -qx 'main.libsonnet' <<<"$paths" && { echo single; return; }
  grep -q '\.libsonnet$' <<<"$paths" && { echo single; return; }
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
  echo "discover + $1 ($5)" >&2
  local sha; sha="$(api "repos/${2}/${3}/commits/${4}" | jq -r '.sha')"
  local deps; deps="$(direct_deps "$2" "$3" "$sha" "$6")"
  emit+=("$(jq -nc --arg name "$1" --arg org "$2" --arg repo "$3" \
      --arg source "https://github.com/${2}/${3}" --arg branch "$4" \
      --arg sha "$sha" --arg kind "$5" --argjson deps "$deps" \
      '{name:$name, org:$org, repo:$repo, source:$source, branch:$branch, sha:$sha, kind:$kind, directdeps:$deps}')")
}

while IFS=$'\t' read -r name branch; do
  case " $SKIP " in *" $name "*) continue;; esac
  # A swallowed tree fetch drops the library from this run's fresh discovery.
  # The superset merge below only preserves libraries already in the manifest, so
  # a library that has never once been discovered (the fetch failed on its very
  # first run) is invisible forever — log loudly so a persistent miss is greppable
  # rather than silent.
  tree="$(api "repos/jsonnet-libs/${name}/git/trees/${branch}?recursive=1")" \
    || { echo "DROP (tree fetch failed after retries): $name" >&2; continue; }
  # GitHub caps a recursive tree at ~100k entries / 7 MB and sets truncated=true.
  # A version-dir main.libsonnet sorts after that library's whole _gen/** subtree,
  # so truncation hides exactly the path classify() keys on and would misclassify a
  # large multi-version library as single — or drop it. The org's biggest libraries
  # (e.g. k8s-libsonnet) are the ones at risk, so refuse a partial tree and let the
  # superset merge keep the last good entry instead of replacing it with a wrong one.
  if [ "$(echo "$tree" | jq -r '.truncated' 2>/dev/null || echo false)" = true ]; then
    echo "DROP (truncated tree, cannot classify reliably): $name" >&2
    continue
  fi
  paths="$(echo "$tree" | jq -r '.tree[]?.path' 2>/dev/null)"
  kind="$(classify "$paths")"
  [ "$kind" = skip ] && { echo "skip (no jsonnet): $name" >&2; continue; }
  add "$name" jsonnet-libs "$name" "$branch" "$kind" "$paths"
done < <(echo "$repos_json" | jq -r '.[] | "\(.name)\t\(.default_branch)"')

# grafonnet: grafana org, gen/grafonnet-vX layout. Guarded so a transient fetch
# failure skips grafonnet for this run — the superset merge below preserves its
# last manifest entry — instead of aborting the whole refresh.
if gbranch="$(api repos/grafana/grafonnet | jq -r '.default_branch')" \
   && gtree="$(api "repos/grafana/grafonnet/git/trees/${gbranch}?recursive=1" | jq -r '.tree[]?.path')"; then
  add grafonnet grafana grafonnet "$gbranch" grafonnet-gen "$gtree"
else
  echo "DROP (grafonnet fetch failed): grafonnet" >&2
fi

echo "discovered ${#emit[@]} libraries this run (fresh; before superset merge with the committed manifest)" >&2

# Never drop a library. An archived or transiently-unreachable upstream stops
# producing new SHAs, but its last-built image stays pullable, so the library is
# still consumable — keep it in the manifest. Fresh discovery wins per name
# (updated SHA/closure); any library in the committed manifest this run did not
# rediscover is preserved verbatim. The output is therefore always a superset of
# OLD_MANIFEST, so a transient discovery failure can never silently remove a
# published library (and the joi chart's sync, which mirrors this, can't either).
# To retire a library for good, delete its entry from libraries.json by hand:
# discovery won't resurrect it, since it's neither freshly found nor in the file.
OLD_MANIFEST="${OLD_MANIFEST:-libraries.json}"
old_json='[]'
[ -f "$OLD_MANIFEST" ] && old_json="$(cat "$OLD_MANIFEST")"

# Resolve each library's transitive closure over directdeps, keep only deps that
# are themselves discovered JOI libraries, drop the raw directdeps, then union in
# any preserved old-only entries (already in final shape, no directdeps).
printf '%s\n' "${emit[@]}" | jq -s --argjson old "$old_json" --argjson desc "$descmap" '
  (map({key:.name, value:(.directdeps // [])}) | from_entries) as $g
  | def closure($n):
      def grow($a): ([$a[] | $g[.] // []] | add) as $m | ($a + $m | unique) as $x
        | if $x == $a then $a else grow($x) end;
      (grow([$n]) - [$n]);
    (map(. + {closure: ([closure(.name)[] | select($g[.] != null)] | sort),
              description: ($desc[.name] // .description // "")} | del(.directdeps))) as $fresh
  | ($fresh | map(.name)) as $names
  | $fresh + [ $old[] | select(.name as $n | $names | index($n) | not) ]
  | sort_by(.name)
'
