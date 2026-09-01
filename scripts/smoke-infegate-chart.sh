#!/bin/sh
set -eu

readonly script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
readonly repository_dir="${script_dir%/scripts}"
cd "${repository_dir}"

: "${GHCR_USERNAME:?GHCR_USERNAME is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

readonly cluster="infegate-${GITHUB_RUN_ID:-local}-$$"
readonly namespace="infegate-smoke-${GITHUB_RUN_ID:-local}-$$"
readonly api_port="$((20000 + $$ % 10000))"
readonly ui_port="$((30000 + $$ % 10000))"
ui_repository=ghcr.io/demirtechcom/infegate
ui_tag=1.4.1-1
api_forward_pid=
ui_forward_pid=

cleanup() {
  for pid in "${api_forward_pid}" "${ui_forward_pid}"; do
    if test -n "${pid}"; then kill "${pid}" >/dev/null 2>&1 || true; fi
  done
  kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

kind create cluster --name "${cluster}" --wait 120s
if test -n "${INFEGATE_SMOKE_UI_IMAGE:-}"; then
  ui_repository="${INFEGATE_SMOKE_UI_IMAGE%:*}"
  ui_tag="${INFEGATE_SMOKE_UI_IMAGE##*:}"
  kind load docker-image "${INFEGATE_SMOKE_UI_IMAGE}" --name "${cluster}"
fi
kubectl create namespace "${namespace}"
kubectl create secret docker-registry infegate-registry --namespace "${namespace}" \
  --docker-server ghcr.io --docker-username "${GHCR_USERNAME}" --docker-password "${GHCR_TOKEN}"

kubectl create secret generic infegate-db --namespace "${namespace}" \
  --from-literal=uri=postgres://infegate:infegate@postgres:5432/infegate
kubectl create secret generic infegate-oidc --namespace "${namespace}" \
  --from-literal=client-secret=infegate-secret \
  --from-literal=cookie-secret=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
kubectl create secret generic infegate-runtime --namespace "${namespace}" \
  --from-literal=SMOKE_PROVIDER_KEY=unused

kubectl create deployment postgres --namespace "${namespace}" --image=postgres:17-alpine
kubectl set env deployment/postgres --namespace "${namespace}" \
  POSTGRES_USER=infegate POSTGRES_PASSWORD=infegate POSTGRES_DB=infegate
kubectl expose deployment postgres --namespace "${namespace}" --port=5432

kubectl create configmap keycloak-realm --namespace "${namespace}" \
  --from-file=infegate-realm.json=scripts/testdata/keycloak-realm.json
kubectl apply --namespace "${namespace}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.3.3
          args: ["start-dev", "--import-realm"]
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              value: admin
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              value: admin
          ports:
            - containerPort: 8080
          readinessProbe:
            tcpSocket:
              port: 8080
          volumeMounts:
            - name: realm
              mountPath: /opt/keycloak/data/import
              readOnly: true
      volumes:
        - name: realm
          configMap:
            name: keycloak-realm
EOF
kubectl expose deployment keycloak --namespace "${namespace}" --port=8080

kubectl rollout status deployment/postgres --namespace "${namespace}" --timeout=3m
kubectl rollout status deployment/keycloak --namespace "${namespace}" --timeout=5m

helm upgrade --install infegate charts/infegate --namespace "${namespace}" \
  --set-string publicUrl=https://ai.test.example \
  --set-string api.database.existingSecret=infegate-db \
  --set-string api.oidc.issuer=http://keycloak:8080/realms/infegate \
  --set-string api.oidc.clientId=infegate \
  --set-string api.oidc.existingSecret=infegate-oidc \
  --set-string 'api.oidc.authorizationRule=jwt.email.endsWith("@test.example")' \
  --set-string api.runtime.existingSecret=infegate-runtime \
  --set api.audit.capturePayloads=false \
  --set-string api.image.repository=ghcr.io/agentgateway/agentgateway \
  --set-string api.image.tag=v1.5.0 \
  --set-string "ui.image.repository=${ui_repository}" \
  --set-string "ui.image.tag=${ui_tag}" \
  --set 'imagePullSecrets[0].name=infegate-registry'

for deployment in infegate-api infegate-ui; do
  if ! kubectl rollout status "deployment/${deployment}" --namespace "${namespace}" --timeout=5m; then
    kubectl get all --namespace "${namespace}"
    kubectl describe pods --namespace "${namespace}"
    kubectl logs --namespace "${namespace}" "deployment/${deployment}" --all-containers --tail=200 || true
    exit 1
  fi
done

kubectl port-forward --namespace "${namespace}" service/infegate-api "${api_port}:4000" \
  >"${TMPDIR:-/tmp}/infegate-api-forward-$$.log" 2>&1 &
api_forward_pid=$!
kubectl port-forward --namespace "${namespace}" service/infegate-ui "${ui_port}:80" \
  >"${TMPDIR:-/tmp}/infegate-ui-forward-$$.log" 2>&1 &
ui_forward_pid=$!

attempt=0
while test "${attempt}" -lt 60; do
  ui_status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${ui_port}/ui/" || true)"
  api_status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${api_port}/ui/" || true)"
  if test "${ui_status}" = 200 && test "${api_status}" = 302; then
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

cat "${TMPDIR:-/tmp}/infegate-api-forward-$$.log" >&2
cat "${TMPDIR:-/tmp}/infegate-ui-forward-$$.log" >&2
exit 1
