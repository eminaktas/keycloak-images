#!/usr/bin/env bash
set -euo pipefail

jq -e '. as $catalog |
  .schema == 1 and
  (.registry | type == "string" and length > 0) and
  (.sourceRepository | type == "string" and length > 0) and
  (.architectures | sort == ["aarch64", "x86_64"]) and
  ([.streams[].track] | length == (unique | length)) and
  ([.streams[] | select(.active and .track == $catalog.latestTrack)] | length == 1) and
  (all(.streams[];
    . as $stream |
    ($stream.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    ($stream.version | startswith($stream.track + ".")) and
    ($stream.resourcesVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    ($stream.resourcesVersion | startswith($stream.track + ".")) and
    ($stream.upstreamCommit | test("^[0-9a-f]{40}$")) and
    ($stream.revision >= 0)
  ))
' config/versions.json >/dev/null

./hack/render.sh

./hack/matrix.sh tracks | jq -e '
  (.include | length) > 0 and
  all(.include[]; (.archs | type == "string" and length > 0))
' >/dev/null

./hack/matrix.sh packages | jq -e --argjson expected "$(
  jq '. as $catalog |
    ([.streams[] | select(.active)] | length) *
    ($catalog.architectures | length)
  ' config/versions.json
)" '
  (.include | length) == $expected and
  all(.include[];
    (.arch == "x86_64" and .runner == "ubuntu-24.04") or
    (.arch == "aarch64" and .runner == "ubuntu-24.04-arm")
  )
' >/dev/null

if grep -R -n --binary-files=without-match --include='*.yaml' '<<\.' _output; then
  echo "unrendered template value found" >&2
  exit 1
fi

while IFS= read -r track; do
  output="_output/${track}"
  server_image="${output}/keycloak.apko.yaml"
  operator_image="${output}/keycloak-operator.apko.yaml"

  for image in "$server_image" "$operator_image"; do
    grep -Fq -- "- \"@local ${output}/packages\"" "$image"
    grep -Fq -- "- ${output}/melange.rsa.pub" "$image"
  done
  grep -Fq -- '- keycloak-compat@local' "$server_image"
  grep -Fq -- '- keycloak-operator-compat@local' "$operator_image"

  if [[ -e "${output}/keycloak-operator.melange.yaml" ]]; then
    echo "obsolete standalone operator recipe found for ${track}" >&2
    exit 1
  fi

  for filename in pombump-deps.yaml pombump-properties.yaml; do
    if [[ -e "${output}/${filename}" ]]; then
      echo "obsolete pombump override found for ${track}: ${filename}" >&2
      exit 1
    fi
  done

  for filename in pom.patch deps.yaml properties.yaml; do
    source_file="bump/${track}/${filename}"
    rendered_file="${output}/${filename}"
    if [[ -f "$source_file" ]]; then
      cmp "$source_file" "$rendered_file"
    elif [[ -e "$rendered_file" ]]; then
      echo "unexpected optional build file: ${rendered_file}" >&2
      exit 1
    fi
  done

  recipe="${output}/keycloak.melange.yaml"
  if [[ -f "bump/${track}/pom.patch" ]]; then
    grep -Fq '      patches: pom.patch' "$recipe"
  elif grep -Fq '  - uses: patch' "$recipe"; then
    echo "unexpected patch pipeline for ${track}" >&2
    exit 1
  fi

  if [[ -f "bump/${track}/deps.yaml" || -f "bump/${track}/properties.yaml" ]]; then
    grep -Fq '      - omnibump' "$recipe"
    grep -Fq "      omnibump \\" "$recipe"
  elif grep -Fq 'omnibump' "$recipe"; then
    echo "unexpected omnibump configuration for ${track}" >&2
    exit 1
  fi

  if [[ -f "bump/${track}/deps.yaml" ]]; then
    grep -Fq -- '--deps deps.yaml' "$recipe"
  elif grep -Fq -- '--deps deps.yaml' "$recipe"; then
    echo "unexpected Omnibump dependency input for ${track}" >&2
    exit 1
  fi

  if [[ -f "bump/${track}/properties.yaml" ]]; then
    grep -Fq -- '--properties properties.yaml' "$recipe"
  elif grep -Fq -- '--properties properties.yaml' "$recipe"; then
    echo "unexpected Omnibump properties input for ${track}" >&2
    exit 1
  fi
done < <(jq -r '.streams[] | select(.active) | .track' config/versions.json)

if command -v melange >/dev/null; then
  source_repository="$(jq -r '.sourceRepository' config/versions.json)"
  while IFS= read -r recipe; do
    melange compile \
      --arch x86_64 \
      --git-repo-url "$source_repository" \
      "$recipe" >/dev/null
  done < <(find _output -mindepth 2 -maxdepth 2 -type f -name '*.melange.yaml' -print | sort)
fi

echo "repository definitions are valid"
