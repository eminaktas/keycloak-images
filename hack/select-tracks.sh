#!/usr/bin/env bash
set -euo pipefail

scope="${1:-}"
base="${2:-}"
catalog="config/versions.json"

if [[ "$scope" != "presubmit" && "$scope" != "release" ]] || [[ -z "$base" ]]; then
  echo "usage: $0 <presubmit|release> <base-revision>" >&2
  exit 2
fi

all_active_tracks() {
  jq -c '[.streams[] | select(.active) | .track]' "$catalog"
}

fallback_to_all() {
  echo "could not safely determine changed tracks; selecting every active track" >&2
  all_active_tracks
  exit 0
}

if [[ ! "$base" =~ [^0] ]]; then
  fallback_to_all
fi

previous_catalog="$(mktemp)"
changed_paths="$(mktemp)"
candidates="$(mktemp)"
trap 'rm -f "$previous_catalog" "$changed_paths" "$candidates"' EXIT

git show "${base}:${catalog}" >"$previous_catalog" 2>/dev/null || fallback_to_all
git diff --no-renames --name-only "$base" -- >"$changed_paths" 2>/dev/null || fallback_to_all
jq -e . "$previous_catalog" >/dev/null 2>&1 || fallback_to_all

build_all=false
catalog_changed=false

while IFS= read -r path; do
  case "$path" in
    "$catalog")
      catalog_changed=true
      ;;
    bump/*)
      relative="${path#bump/}"
      track="${relative%%/*}"
      if [[ -n "$track" && "$relative" == */* ]]; then
        printf '%s\n' "$track" >>"$candidates"
      else
        build_all=true
      fi
      ;;
    templates/* | hack/render.sh | cosign.pub | melange.rsa.pub)
      build_all=true
      ;;
    .github/actions/build-pair/* | hack/smoke-server.sh | hack/test-pair.sh | \
      hack/vulnerability-report.jq | tests/kind/* | tests/cluster-wide/* | \
      tests/namespace-scoped/*)
      if [[ "$scope" == "presubmit" ]]; then
        build_all=true
      fi
      ;;
  esac
done <"$changed_paths"

if [[ "$build_all" == "true" ]]; then
  all_active_tracks
  exit 0
fi

if [[ "$catalog_changed" == "true" ]]; then
  if ! catalog_selection="$(jq -nce \
    --slurpfile previous "$previous_catalog" \
    --slurpfile current "$catalog" '
      ($previous[0]) as $before |
      ($current[0]) as $after |
      if (($before | del(.streams, .latestTrack)) !=
          ($after | del(.streams, .latestTrack))) then
        {all: true, tracks: []}
      else
        {all: false, tracks: (
          [
            $after.streams[] as $stream |
            select($stream.active) |
            ($before.streams | map(select(.track == $stream.track)) | .[0]) as $old |
            select($old != $stream) |
            $stream.track
          ] +
          (if $before.latestTrack != $after.latestTrack
           then [$after.latestTrack]
           else []
           end) |
          unique
        )}
      end
    ' 2>/dev/null)"; then
    fallback_to_all
  fi

  if [[ "$(jq -r '.all' <<<"$catalog_selection")" == "true" ]]; then
    all_active_tracks
    exit 0
  fi

  jq -r '.tracks[]' <<<"$catalog_selection" >>"$candidates"
fi

candidate_json="$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$candidates")"

jq -c --argjson candidates "$candidate_json" '
  [
    .streams[] |
    select(.active) |
    .track as $track |
    select($candidates | index($track)) |
    $track
  ]
' "$catalog"
