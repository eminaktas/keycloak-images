#!/usr/bin/env bash
set -euo pipefail

catalog="config/versions.json"
track="${1:-}"
server_reference="${2:-}"
local_root="${3:-}"

if [[ -z "$track" ]]; then
  while IFS= read -r active_track; do
    "$0" "$active_track" "" "$local_root"
  done < <(jq -r '.streams[] | select(.active) | .track' "$catalog")
  exit
fi

stream="$(jq -ce --arg track "$track" '.streams[] | select(.track == $track)' "$catalog")" || {
  echo "unknown Keycloak track: $track" >&2
  exit 2
}

version="$(jq -r '.version' <<<"$stream")"
revision="$(jq -r '.revision' <<<"$stream")"
commit="$(jq -r '.upstreamCommit' <<<"$stream")"
java_version="$(jq -r '.javaVersion' <<<"$stream")"
registry="$(jq -r '.registry' "$catalog")"
source_repository="$(jq -r '.sourceRepository' "$catalog")"
server_reference="${server_reference:-${registry}/keycloak:${version}-r${revision}}"
output="_output/${track}"
local_root="${local_root:-${output}}"
customization_dir="bump/${track}"
mkdir -p "$output"

optional_build_files=(
  pom.patch
  deps.yaml
  properties.yaml
)

for filename in "${optional_build_files[@]}"; do
  source_file="${customization_dir}/${filename}"
  rendered_file="${output}/${filename}"
  if [[ -f "$source_file" ]]; then
    cp "$source_file" "$rendered_file"
  else
    rm -f "$rendered_file"
  fi
done

# Remove legacy override names left by renders from before the Omnibump
# migration. Other generated artifacts and signing keys remain untouched.
for filename in pombump-deps.yaml pombump-properties.yaml; do
  rm -f "${output}/${filename}"
done

emit_patch_pipeline() {
  [[ -f "${customization_dir}/pom.patch" ]] || return 0
  printf '%s\n' \
    '  - uses: patch' \
    '    with:' \
    '      patches: pom.patch'
}

has_omnibump_overrides() {
  [[ -f "${customization_dir}/deps.yaml" || -f "${customization_dir}/properties.yaml" ]]
}

emit_omnibump_environment_package() {
  has_omnibump_overrides || return 0
  printf '%s\n' '      - omnibump'
}

emit_omnibump_pipeline() {
  local deps_file="${customization_dir}/deps.yaml"
  local properties_file="${customization_dir}/properties.yaml"

  has_omnibump_overrides || return 0

  printf '%s\n' \
    '  - name: Apply Maven dependency overrides with Omnibump' \
    '    runs: |' \
    "      omnibump \\" \
    "        --language java \\"
  if [[ -f "$deps_file" ]]; then
    if [[ -f "$properties_file" ]]; then
      printf '%s\n' "        --deps deps.yaml \\"
    else
      printf '%s\n' '        --deps deps.yaml'
    fi
  fi
  if [[ -f "$properties_file" ]]; then
    printf '%s\n' '        --properties properties.yaml'
  fi
}

render_template() {
  local template="$1"
  local destination="$2"

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '<<.PatchPipeline>>') emit_patch_pipeline ;;
      '<<.OmnibumpEnvironmentPackage>>') emit_omnibump_environment_package ;;
      '<<.OmnibumpPipeline>>') emit_omnibump_pipeline ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < <(
    sed \
      -e "s|<<\.Version>>|${version}|g" \
      -e "s|<<\.Revision>>|${revision}|g" \
      -e "s|<<\.UpstreamCommit>>|${commit}|g" \
      -e "s|<<\.JavaVersion>>|${java_version}|g" \
      -e "s|<<\.LocalRoot>>|${local_root}|g" \
      -e "s|<<\.ServerReference>>|${server_reference}|g" \
      -e "s|<<\.SourceRepository>>|${source_repository}|g" \
      "$template"
  ) >"$destination"
}

for template in templates/*.tmpl; do
  destination="${output}/$(basename "${template%.tmpl}")"
  render_template "$template" "$destination"
done

# The operator is produced by keycloak.melange.yaml as a subpackage. Remove a
# stale recipe left by older checkouts so it cannot accidentally be built twice.
rm -f "${output}/keycloak-operator.melange.yaml"

echo "rendered Keycloak ${version} in ${output}"
