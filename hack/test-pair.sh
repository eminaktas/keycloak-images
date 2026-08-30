#!/usr/bin/env bash
set -euo pipefail

server_image="${1:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
operator_image="${2:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
resources_version="${3:?usage: test-pair.sh <server-image> <operator-image> <resources-version>}"
cluster="${KIND_CLUSTER_NAME:-keycloak-images-$$}"
delete_cluster="${KIND_DELETE_CLUSTER:-false}"
resources="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${resources_version}/kubernetes"

for tool in curl docker kind kubectl; do
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
for crd in keycloaks.k8s.keycloak.org-v1.yml keycloakrealmimports.k8s.keycloak.org-v1.yml; do
  kubectl apply -f "${resources}/${crd}"
done
for crd in keycloakoidcclients.k8s.keycloak.org-v1.yml keycloaksamlclients.k8s.keycloak.org-v1.yml; do
  destination="${temporary_directory}/${crd}"
  if curl --fail --silent --show-error --location --output "$destination" "${resources}/${crd}"; then
    kubectl apply -f "$destination"
  else
    echo "optional CRD is not present in Keycloak resources ${resources_version}: ${crd}"
  fi
done
kubectl apply -f "${resources}/kubernetes.yml"

kubectl -n keycloak set image deployment/keycloak-operator \
  keycloak-operator="$operator_image"
kubectl -n keycloak set env deployment/keycloak-operator \
  RELATED_IMAGE_KEYCLOAK- \
  KC_OPERATOR_KEYCLOAK_IMAGE_PULL_POLICY=IfNotPresent
kubectl -n keycloak patch deployment keycloak-operator --type=strategic \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"keycloak-operator","imagePullPolicy":"IfNotPresent"}]}}}}'
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
