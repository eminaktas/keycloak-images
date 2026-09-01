#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="${repository_root}/hack/select-tracks.sh"
temporary_root="$(mktemp -d)"

cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

new_case() {
  local name="$1"
  case_repository="${temporary_root}/${name}"
  mkdir -p "${case_repository}/config"
  cp "${repository_root}/config/versions.json" "${case_repository}/config/versions.json"
  git -C "$case_repository" init -q
  git -C "$case_repository" config user.email tests@example.invalid
  git -C "$case_repository" config user.name Tests
  git -C "$case_repository" config commit.gpgsign false
  git -C "$case_repository" add config/versions.json
  git -C "$case_repository" commit -qm baseline
  base_revision="$(git -C "$case_repository" rev-parse HEAD)"
}

update_catalog() {
  local filter="$1"
  jq "$filter" \
    "${case_repository}/config/versions.json" \
    >"${case_repository}/config/versions.next.json"
  mv \
    "${case_repository}/config/versions.next.json" \
    "${case_repository}/config/versions.json"
  git -C "$case_repository" add config/versions.json
}

assert_selection() {
  local scope="$1"
  local expected="$2"
  local actual
  actual="$(cd "$case_repository" && "$selector" "$scope" "$base_revision")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

new_case one_stream
update_catalog '.streams |= map(if .track == "26.7" then .revision += 1 else . end)'
assert_selection release '["26.7"]'

new_case two_streams
update_catalog '.streams |= map(if .track == "26.4" or .track == "26.7" then .revision += 1 else . end)'
assert_selection release '["26.4","26.7"]'

new_case global_catalog_value
update_catalog '.registry += "/mirror"'
assert_selection release '["26.4","26.6","26.7"]'

new_case latest_track
update_catalog '.latestTrack = "26.6"'
assert_selection release '["26.6"]'

new_case deactivated_track
update_catalog '.streams |= map(if .track == "26.4" then .active = false else . end)'
assert_selection release '[]'

new_case track_override
mkdir -p "${case_repository}/bump/26.7"
printf '%s\n' 'packages: []' >"${case_repository}/bump/26.7/deps.yaml"
git -C "$case_repository" add bump/26.7/deps.yaml
assert_selection release '["26.7"]'

new_case shared_template
mkdir -p "${case_repository}/templates"
printf '%s\n' 'changed' >"${case_repository}/templates/keycloak.apko.yaml.tmpl"
git -C "$case_repository" add templates/keycloak.apko.yaml.tmpl
assert_selection release '["26.4","26.6","26.7"]'

new_case presubmit_test
mkdir -p "${case_repository}/tests/kind"
printf '%s\n' 'changed' >"${case_repository}/tests/kind/keycloak.yaml"
git -C "$case_repository" add tests/kind/keycloak.yaml
assert_selection presubmit '["26.4","26.6","26.7"]'
assert_selection release '[]'

new_case workflow_only
mkdir -p "${case_repository}/.github/workflows"
printf '%s\n' 'changed' >"${case_repository}/.github/workflows/release.yaml"
git -C "$case_repository" add .github/workflows/release.yaml
assert_selection presubmit '[]'
assert_selection release '[]'

new_case missing_base
actual="$(cd "$case_repository" && "$selector" release 0000000000000000000000000000000000000000 2>/dev/null)"
if [[ "$actual" != '["26.4","26.6","26.7"]' ]]; then
  echo "expected safe fallback to select every active track, got ${actual}" >&2
  exit 1
fi

track_matrix="$(cd "$repository_root" && ./hack/matrix.sh tracks '["26.7"]')"
package_matrix="$(cd "$repository_root" && ./hack/matrix.sh packages '["26.7"]')"
jq -e '[.include[].track] == ["26.7"]' <<<"$track_matrix" >/dev/null
jq -e \
  '[.include[] | {track, arch}] == [
    {track: "26.7", arch: "x86_64"},
    {track: "26.7", arch: "aarch64"}
  ]' <<<"$package_matrix" >/dev/null

if (cd "$repository_root" && ./hack/matrix.sh tracks '["missing"]' >/dev/null 2>&1); then
  echo "matrix accepted an inactive or unknown track" >&2
  exit 1
fi

echo "changed-track selection is valid"
