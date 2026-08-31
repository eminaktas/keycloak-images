#!/usr/bin/env bash
set -euo pipefail

server_image="${1:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
operator_image="${2:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
resources_version="${3:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
cluster="${KIND_CLUSTER_NAME:-keycloak-images-$$}"
delete_cluster="${KIND_DELETE_CLUSTER:-false}"
legacy_kustomization="tests/namespace-scoped/legacy-kustomization.yaml"

for tool in docker git kind kubectl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required" >&2
    exit 2
  }
done

temporary_directory="$(mktemp -d)"
resources_repository="${temporary_directory}/keycloak-k8s-resources"
resources_directory="${resources_repository}/kubernetes"

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

git clone --depth 1 --branch "$resources_version" --single-branch \
  https://github.com/keycloak/keycloak-k8s-resources.git \
  "$resources_repository"

if [[ ! -f "${resources_directory}/kustomization.yml" && \
      ! -f "${resources_directory}/kustomization.yaml" ]]; then
  cp "$legacy_kustomization" "${resources_directory}/kustomization.yaml"
fi

if kind get clusters | grep -Fxq "$cluster"; then
  echo "using existing Kind cluster: $cluster"
else
  delete_cluster=true
  kind create cluster --name "$cluster" --wait 120s
fi
kind load docker-image --name "$cluster" "$server_image" "$operator_image"

kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "$resources_directory"
kubectl -n keycloak set image deployment/keycloak-operator keycloak-operator="$operator_image"
kubectl -n keycloak set env deployment/keycloak-operator RELATED_IMAGE_KEYCLOAK-
kubectl -n keycloak patch deployment keycloak-operator --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"keycloak-operator","imagePullPolicy":"IfNotPresent","env":[{"name":"KC_OPERATOR_KEYCLOAK_IMAGE_PULL_POLICY","value":"IfNotPresent"}]}]}}}}'
kubectl -n keycloak rollout status deployment/keycloak-operator --timeout=5m

kubectl apply -f tests/kind/postgres.yaml
kubectl -n keycloak rollout status statefulset/postgres-db --timeout=5m
kubectl apply -f tests/kind/keycloak.yaml
kubectl -n keycloak wait --for=condition=Ready keycloak/test-kc --timeout=10m
kubectl -n keycloak rollout status statefulset/test-kc --timeout=5m

actual_image="$(kubectl -n keycloak get statefulset test-kc -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "$actual_image" != "$server_image" ]]; then
  echo "operator deployed $actual_image, expected $server_image" >&2
  exit 1
fi

echo "operator/server pair test passed: $operator_image -> $server_image"
