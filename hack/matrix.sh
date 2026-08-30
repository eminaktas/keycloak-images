#!/usr/bin/env bash
set -euo pipefail

mode="${1:-tracks}"

case "$mode" in
  tracks)
    jq -c '. as $catalog | {
      include: [.streams[] | select(.active) | . + {
        archs: ($catalog.architectures | join(",")),
        latest: (.track == $catalog.latestTrack)
      }]
    }' config/versions.json
    ;;
  packages)
    jq -c '. as $catalog | {
      include: [
        $catalog.streams[] | select(.active) as $stream |
        $catalog.architectures[] as $arch |
        $stream + {
          arch: $arch,
          runner: (if $arch == "aarch64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end)
        }
      ]
    }' config/versions.json
    ;;
  *)
    echo "usage: $0 [tracks|packages]" >&2
    exit 2
    ;;
esac
