#!/bin/sh
set -eu

: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

readonly cluster="infegate-${GITHUB_RUN_ID:-local}-$$"
readonly namespace="infegate-smoke-${GITHUB_RUN_ID:-local}-$$"
readonly port="$((20000 + $$ % 20000))"
port_forward_pid=

cleanup() {
  if test -n "${port_forward_pid}"; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  kubectl delete namespace "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

kind create cluster --name "${cluster}" --wait 120s
kubectl create namespace "${namespace}"
kubectl create secret docker-registry infegate-registry \
  --namespace "${namespace}" \
  --docker-server ghcr.io \
  --docker-username "${GHCR_USERNAME}" \
  --docker-password "${GHCR_TOKEN}"

helm upgrade --install infegate charts/infegate \
  --namespace "${namespace}" \
  --set 'imagePullSecrets[0].name=infegate-registry' \
  --wait \
  --timeout 5m

if ! kubectl rollout status deployment/infegate --namespace "${namespace}" --timeout 3m; then
  kubectl get all --namespace "${namespace}"
  kubectl describe pods --namespace "${namespace}"
  exit 1
fi

kubectl port-forward --namespace "${namespace}" service/infegate "${port}:80" \
  >"${TMPDIR:-/tmp}/infegate-port-forward-$$.log" 2>&1 &
port_forward_pid=$!

attempt=0
while test "${attempt}" -lt 30; do
  if curl --fail --silent --show-error "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/ui/")" = 200
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

cat "${TMPDIR:-/tmp}/infegate-port-forward-$$.log" >&2
exit 1
