#!/usr/bin/env bash
set -euo pipefail

mode="${1:-tracks}"
active_tracks="$(jq -c '[.streams[] | select(.active) | .track]' config/versions.json)"
selected_tracks="${2:-$active_tracks}"

if ! jq -en \
  --argjson active "$active_tracks" \
  --argjson selected "$selected_tracks" '
    ($selected | type) == "array" and
    ($selected | length) == ($selected | unique | length) and
    all($selected[]; type == "string") and
    (($selected - $active) | length) == 0
  ' >/dev/null; then
  echo "track selection must be a unique JSON array containing only active tracks" >&2
  exit 2
fi

case "$mode" in
  tracks)
    jq -c --argjson selected "$selected_tracks" '. as $catalog | {
      include: [.streams[] |
        select(.active) |
        .track as $track |
        select($selected | index($track)) |
        . + {
        archs: ($catalog.architectures | join(",")),
        latest: (.track == $catalog.latestTrack)
      }]
    }' config/versions.json
    ;;
  packages)
    jq -c --argjson selected "$selected_tracks" '. as $catalog | {
      include: [
        $catalog.streams[] |
        select(.active) |
        .track as $track |
        select($selected | index($track)) as $stream |
        $catalog.architectures[] as $arch |
        $stream + {
          arch: $arch,
          runner: (if $arch == "aarch64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end)
        }
      ]
    }' config/versions.json
  ;;
  *)
    echo "usage: $0 [tracks|packages] [selected-tracks-json]" >&2
    exit 2
    ;;
esac
