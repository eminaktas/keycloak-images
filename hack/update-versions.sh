#!/usr/bin/env bash
set -euo pipefail

for tool in gh jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

catalog="config/versions.json"
updated="$(mktemp)"
next="$(mktemp)"
trap 'rm -f "$updated" "$next"' EXIT
cp "$catalog" "$updated"

tags="$(gh api --paginate --slurp 'repos/keycloak/keycloak/tags?per_page=100')"
resource_tags="$(gh api --paginate --slurp 'repos/keycloak/keycloak-k8s-resources/tags?per_page=100')"

while IFS= read -r track; do
  server_changed=false
  latest_entry="$(jq -ce --arg track "$track" '
    [.[][]
      | select(.name | startswith($track + "."))
      | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | {version: .name, commit: .commit.sha, parts: (.name | split(".") | map(tonumber))}]
    | max_by(.parts)
  ' <<<"$tags")"
  latest="$(jq -r '.version' <<<"$latest_entry")"
  current="$(jq -r --arg track "$track" '.streams[] | select(.track == $track) | .version' "$updated")"
  if [[ "$latest" != "$current" ]]; then
    commit="$(jq -r '.commit' <<<"$latest_entry")"
    jq --arg track "$track" --arg version "$latest" --arg commit "$commit" '
      .streams |= map(
        if .track == $track then
          .version = $version | .upstreamCommit = $commit | .revision = 0
        else . end
      )
    ' "$updated" >"$next"
    mv "$next" "$updated"
    next="$(mktemp)"
    server_changed=true
    echo "${track} Keycloak: ${current} -> ${latest}"
  fi

  latest_resources="$(jq -cer --arg track "$track" '
    [.[][]
      | select(.name | startswith($track + "."))
      | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | {version: .name, parts: (.name | split(".") | map(tonumber))}]
    | max_by(.parts)
    | .version
  ' <<<"$resource_tags")"
  current_resources="$(jq -r --arg track "$track" '.streams[] | select(.track == $track) | .resourcesVersion' "$updated")"
  if [[ "$latest_resources" != "$current_resources" ]]; then
    jq \
      --arg track "$track" \
      --arg resources_version "$latest_resources" \
      --argjson server_changed "$server_changed" '
        .streams |= map(
          if .track == $track then
            .resourcesVersion = $resources_version
            | if $server_changed then . else .revision += 1 end
          else . end
        )
      ' "$updated" >"$next"
    mv "$next" "$updated"
    next="$(mktemp)"
    echo "${track} Kubernetes resources: ${current_resources} -> ${latest_resources}"
  fi
done < <(jq -r '.streams[] | select(.active) | .track' "$catalog")

if ! cmp -s "$catalog" "$updated"; then
  mv "$updated" "$catalog"
  echo "updated ${catalog}"
else
  echo "all active Keycloak tracks are current"
fi
