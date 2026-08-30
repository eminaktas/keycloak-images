#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: smoke-server.sh <server-image>}"
container="keycloak-images-smoke-$$"

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$container" \
  --publish 127.0.0.1::9000 \
  --env KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  --env KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  --env KC_HEALTH_ENABLED=true \
  "$image" start-dev >/dev/null

port="$(docker port "$container" 9000/tcp | sed -E 's/.*:([0-9]+)$/\1/' | head -1)"
for _ in $(seq 1 90); do
  if curl --silent --show-error --fail "http://127.0.0.1:${port}/health/ready" >/dev/null 2>&1; then
    echo "server smoke test passed: $image"
    exit 0
  fi
  sleep 2
done

docker logs "$container" >&2
echo "server did not become ready: $image" >&2
exit 1
