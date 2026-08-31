#!/usr/bin/env bash
set -euo pipefail

server_image="${1:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
operator_image="${2:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
resources_version="${3:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
cluster="${KIND_CLUSTER_NAME:-keycloak-images-$$}"
delete_cluster="${KIND_DELETE_CLUSTER:-false}"
kustomization="tests/namespace-scoped/kustomization.yaml"

for tool in docker git kind kubectl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required" >&2
    exit 2
  }
done

temporary_directory="$(mktemp -d)"

diagnose_and_cleanup() {
  status=$?
  if [[ $status -ne 0 ]]; then
    kubectl -n keycloak get all,keycloaks.k8s.keycloak.org 2>/dev/null || true
    kubectl -n keycloak describe keycloak/test-kc 2>/dev/null || true
    kubectl -n keycloak logs deployment/keycloak-operator --tail=200 2>/dev/null || true
    kubectl -n keycloak logs statefulset/test-kc --tail=200 2>/dev/null || true
  fi
  if [[ "$delete_cluster" == "true" ]]; then
    kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_directory"
  exit "$status"
}
trap diagnose_and_cleanup EXIT

if kind get clusters | grep -Fxq "$cluster"; then
  echo "using existing Kind cluster: $cluster"
else
  delete_cluster=true
  kind create cluster --name "$cluster" --wait 120s
fi
kind load docker-image --name "$cluster" "$server_image" "$operator_image"

kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
sed \
  -e "s|?ref=[^[:space:]]*|?ref=${resources_version}|" \
  -e "s|ghcr.io/eminaktas/keycloak-operator:latest|${operator_image}|" \
  "$kustomization" > "${temporary_directory}/kustomization.yaml"
kubectl apply -k "$temporary_directory"
kubectl -n keycloak patch deployment keycloak-operator --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"keycloak-operator","imagePullPolicy":"IfNotPresent","env":[{"name":"KC_OPERATOR_KEYCLOAK_IMAGE_PULL_POLICY","value":"IfNotPresent"}]}]}}}}'
kubectl -n keycloak rollout status deployment/keycloak-operator --timeout=5m

kubectl apply -f tests/kind/postgres.yaml
kubectl -n keycloak rollout status statefulset/postgres-db --timeout=5m
kubectl apply -f tests/kind/keycloak.yaml
kubectl -n keycloak wait keycloak/test-kc \
  --for='jsonpath={.status.conditions[?(@.type=="Ready")].status}=true' \
  --timeout=10m
kubectl -n keycloak rollout status statefulset/test-kc --timeout=5m

actual_image="$(kubectl -n keycloak get statefulset test-kc -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "$actual_image" != "$server_image" ]]; then
  echo "operator deployed $actual_image, expected $server_image" >&2
  exit 1
fi

echo "operator/server pair test passed: $operator_image -> $server_image"
