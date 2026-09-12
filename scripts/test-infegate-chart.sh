#!/bin/sh
set -eu

readonly chart=charts/infegate
readonly work_dir="$(mktemp -d)"

cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT INT TERM

render() {
  helm template infegate "${chart}" \
    --set-string publicUrl=https://ai.customer.example \
    --set-string api.database.existingSecret=infegate-db-app \
    --set-string api.oidc.issuer=https://id.customer.example/realms/infegate \
    --set-string api.oidc.clientId=infegate \
    --set-string api.oidc.existingSecret=infegate-oidc \
    --set-string 'api.oidc.authorizationRule=jwt.email.endsWith("@customer.example")' \
    --set-string api.runtime.existingSecret=infegate-runtime \
    --set api.audit.capturePayloads=false \
    "$@"
}

expect_render_failure() {
  expected_error=$1
  shift
  error_output="${work_dir}/render-error.txt"

  if render "$@" > "${error_output}" 2>&1; then
    echo "render unexpectedly succeeded: ${expected_error}" >&2
    exit 1
  fi
  grep -Fq "${expected_error}" "${error_output}" || {
    cat "${error_output}" >&2
    echo "render did not report: ${expected_error}" >&2
    exit 1
  }
}

render > "${work_dir}/default.yaml"
grep -q 'name: "infegate-api"' "${work_dir}/default.yaml"
grep -q 'name: "infegate-ui"' "${work_dir}/default.yaml"
! grep -q '^  replicas:' "${work_dir}/default.yaml"
test "$(grep -c '^kind: HorizontalPodAutoscaler$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^  minReplicas: 3$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^  maxReplicas: 30$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^          averageUtilization: 70$' "${work_dir}/default.yaml")" -eq 2
grep -q 'image: "ghcr.io/demirtechcom/infegate/gateway:1.0.6"' "${work_dir}/default.yaml"
grep -q 'image: "ghcr.io/demirtechcom/infegate/ui:1.0.6"' "${work_dir}/default.yaml"
grep -q 'url: \$INFEGATE_DATABASE_URL' "${work_dir}/default.yaml"
grep -q 'mode: hybrid' "${work_dir}/default.yaml"
grep -q 'llm: metadata' "${work_dir}/default.yaml"
! grep -qi 'cloudflare\|lovie' "${work_dir}/default.yaml"
grep -q 'mode: strict' "${work_dir}/default.yaml"
grep -q 'name: OIDC_COOKIE_SECRET' "${work_dir}/default.yaml"
test "$(grep -c 'path: /healthz/ready' "${work_dir}/default.yaml")" -eq 1
test "$(grep -c '^          startupProbe:$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^      terminationGracePeriodSeconds: 60$' "${work_dir}/default.yaml")" -eq 2
grep -q 'automountServiceAccountToken: false' "${work_dir}/default.yaml"
grep -q 'readOnlyRootFilesystem: true' "${work_dir}/default.yaml"
grep -q 'statsAddr: "0.0.0.0:15020"' "${work_dir}/default.yaml"
test "$(grep -c 'name: metrics' "${work_dir}/default.yaml")" -eq 2
grep -q 'containerPort: 15020' "${work_dir}/default.yaml"
test "$(grep -c '^kind: PodDisruptionBudget$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^  maxUnavailable: 1$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^      maxUnavailable: 0$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^      maxSurge: 1$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^      topologySpreadConstraints:$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^          topologyKey: topology.kubernetes.io/zone$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^          topologyKey: kubernetes.io/hostname$' "${work_dir}/default.yaml")" -eq 2
test "$(grep -c '^          whenUnsatisfiable: ScheduleAnyway$' "${work_dir}/default.yaml")" -eq 4
grep -q '^        checksum/config: "[a-f0-9]\{64\}"$' "${work_dir}/default.yaml"
grep -q '^              ephemeral-storage: 256Mi$' "${work_dir}/default.yaml"
grep -q '^              ephemeral-storage: 64Mi$' "${work_dir}/default.yaml"
! grep -q 'containerPort: 3001' "${work_dir}/default.yaml"
! grep -q 'containerPort: 3002' "${work_dir}/default.yaml"
! grep -q '^    mcp:$' "${work_dir}/default.yaml"
! grep -q '^kind: Gateway$' "${work_dir}/default.yaml"
! grep -q '^kind: HTTPRoute$' "${work_dir}/default.yaml"

render \
  --set api.autoscaling.enabled=false \
  --set ui.autoscaling.enabled=false \
  > "${work_dir}/autoscaling-disabled.yaml"
! grep -q '^kind: HorizontalPodAutoscaler$' "${work_dir}/autoscaling-disabled.yaml"
! grep -q '^  replicas:' "${work_dir}/autoscaling-disabled.yaml"

render \
  --set api.podDisruptionBudget.enabled=false \
  --set ui.podDisruptionBudget.enabled=false \
  --set api.defaultTopologySpread.enabled=false \
  --set ui.defaultTopologySpread.enabled=false \
  > "${work_dir}/ha-disabled.yaml"
! grep -q '^kind: PodDisruptionBudget$' "${work_dir}/ha-disabled.yaml"
! grep -q '^      topologySpreadConstraints:$' "${work_dir}/ha-disabled.yaml"

render --show-only templates/api-deployment.yaml \
  --set api.strategy.type=Recreate \
  > "${work_dir}/recreate.yaml"
grep -q '^    type: "Recreate"$' "${work_dir}/recreate.yaml"
! grep -q 'rollingUpdate:' "${work_dir}/recreate.yaml"

render --show-only templates/api-deployment.yaml \
  --set api.livenessProbe.type=httpGet \
  --set-string api.livenessProbe.httpGet.path=/healthz/live \
  --set-string api.livenessProbe.httpGet.port=readiness \
  > "${work_dir}/http-liveness.yaml"
grep -q '^              path: /healthz/live$' "${work_dir}/http-liveness.yaml"
test "$(grep -c '^            tcpSocket:$' "${work_dir}/http-liveness.yaml")" -eq 1

render \
  --set api.autoscaling.targetMemoryUtilizationPercentage=80 \
  --set api.autoscaling.behavior.scaleDown.stabilizationWindowSeconds=300 \
  > "${work_dir}/autoscaling-custom.yaml"
grep -q '^        name: memory$' "${work_dir}/autoscaling-custom.yaml"
grep -q '^          averageUtilization: 80$' "${work_dir}/autoscaling-custom.yaml"
grep -q '^      stabilizationWindowSeconds: 300$' "${work_dir}/autoscaling-custom.yaml"

render \
  --set api.podSecurityContext.runAsUser=10001 \
  --set api.podSecurityContext.runAsGroup=10001 \
  --set api.containerSecurityContext.runAsUser=10001 \
  --set ui.podSecurityContext.runAsUser=10002 \
  --set ui.podSecurityContext.runAsGroup=10002 \
  --set ui.containerSecurityContext.runAsUser=10002 \
  > "${work_dir}/security-context.yaml"
grep -q '^        runAsUser: 10001$' "${work_dir}/security-context.yaml"
grep -q '^        runAsGroup: 10001$' "${work_dir}/security-context.yaml"
grep -q '^            runAsUser: 10001$' "${work_dir}/security-context.yaml"
grep -q '^        runAsUser: 10002$' "${work_dir}/security-context.yaml"
grep -q '^        runAsGroup: 10002$' "${work_dir}/security-context.yaml"
grep -q '^            runAsUser: 10002$' "${work_dir}/security-context.yaml"

render --set api.metrics.enabled=false > "${work_dir}/metrics-disabled.yaml"
grep -q 'statsAddr: "off"' "${work_dir}/metrics-disabled.yaml"
! grep -q 'name: metrics' "${work_dir}/metrics-disabled.yaml"

render \
  --set api.mcp.enabled=true \
  --set-string api.mcp.jwksUrl=https://id.customer.example/realms/infegate/protocol/openid-connect/certs \
  --set-string api.mcp.audiences[0]=infegate \
  --set-string 'api.mcp.authorizationRule="infegate-mcp-users" in jwt.groups' \
  > "${work_dir}/mcp.yaml"
grep -q '^    mcp:$' "${work_dir}/mcp.yaml"
grep -q '^      port: 3002$' "${work_dir}/mcp.yaml"
grep -q '^      targets: \[\]$' "${work_dir}/mcp.yaml"
grep -q '^          mode: strict$' "${work_dir}/mcp.yaml"
grep -q '^            - infegate$' "${work_dir}/mcp.yaml"
grep -q 'issuer: "https://id.customer.example/realms/infegate"' "${work_dir}/mcp.yaml"
grep -q 'url: "https://id.customer.example/realms/infegate/protocol/openid-connect/certs"' "${work_dir}/mcp.yaml"
grep -q 'resource: "https://ai.customer.example/mcp"' "${work_dir}/mcp.yaml"
grep -q '^            - mcp-session-id$' "${work_dir}/mcp.yaml"
grep -Fq '\"infegate-mcp-users\" in jwt.groups' "${work_dir}/mcp.yaml"
grep -q 'containerPort: 3002' "${work_dir}/mcp.yaml"
grep -q 'name: mcp' "${work_dir}/mcp.yaml"

if render --set api.mcp.enabled=true >/dev/null 2>&1; then
  echo "enabled MCP must require JWT verification and authorization" >&2
  exit 1
fi

render --set api.audit.capturePayloads=true > "${work_dir}/payloads.yaml"
grep -q 'llm: full' "${work_dir}/payloads.yaml"

render \
  --set api.management.authenticationMode=externalJwt \
  --set-string api.oidc.issuer= \
  --set-string api.oidc.clientId= \
  --set-string api.oidc.existingSecret= \
  --set-string api.oidc.authorizationRule= \
  --set-string api.management.externalJwt.issuer=https://identity-proxy.customer.example \
  --set-string 'api.management.externalJwt.audiences[0]=$INFEGATE_ADMIN_AUDIENCE' \
  --set-string api.management.externalJwt.jwksUrl=https://identity-proxy.customer.example/.well-known/jwks.json \
  --set-string api.management.externalJwt.headerName=X-Forwarded-Jwt \
  --set-string 'api.management.externalJwt.authorizationRule=jwt.email != ""' \
  --set api.mcp.enabled=true \
  --set api.mcp.authenticationMode=externalJwt \
  --set-string api.mcp.issuer=https://identity-proxy.customer.example \
  --set-string api.mcp.headerName=X-Forwarded-Jwt \
  --set-string api.mcp.jwksUrl=https://identity-proxy.customer.example/.well-known/jwks.json \
  --set-string 'api.mcp.audiences[0]=$INFEGATE_MCP_AUDIENCE' \
  --set-string 'api.mcp.authorizationRule=jwt.email != ""' \
  --set api.audit.capturePayloads=true \
  --set api.audit.captureMcpPayloads=true \
  --set api.audit.retention.enabled=true \
  --set gateway.enabled=true \
  --set gateway.create=false \
  --set-string gateway.parentRef.name=shared-gateway \
  > "${work_dir}/external-jwt.yaml"
test "$(grep -c 'name: "X-Forwarded-Jwt"' "${work_dir}/external-jwt.yaml")" -eq 2
test "$(grep -c 'issuer: "https://identity-proxy.customer.example"' "${work_dir}/external-jwt.yaml")" -eq 2
grep -q '^            - \$INFEGATE_ADMIN_AUDIENCE$' "${work_dir}/external-jwt.yaml"
grep -q '^            - \$INFEGATE_MCP_AUDIENCE$' "${work_dir}/external-jwt.yaml"
grep -q 'url: "https://identity-proxy.customer.example/.well-known/jwks.json"' "${work_dir}/external-jwt.yaml"
test "$(grep -c 'requiredClaims: \[exp\]' "${work_dir}/external-jwt.yaml")" -eq 2
grep -q 'mcp.tool.arguments: mcp.tool.arguments' "${work_dir}/external-jwt.yaml"
grep -q 'mcp.tool.result: mcp.tool.result' "${work_dir}/external-jwt.yaml"
grep -q 'mcp.tool.error: mcp.tool.error' "${work_dir}/external-jwt.yaml"
grep -q '^kind: CronJob$' "${work_dir}/external-jwt.yaml"
grep -q '^kind: HTTPRoute$' "${work_dir}/external-jwt.yaml"
grep -q "INTERVAL '30 days'" "${work_dir}/external-jwt.yaml"
grep -q "INTERVAL '365 days'" "${work_dir}/external-jwt.yaml"
! grep -q '/oauth/callback' "${work_dir}/external-jwt.yaml"
! grep -q '/.well-known/oauth-' "${work_dir}/external-jwt.yaml"
! grep -q 'name: INFEGATE_OIDC_CLIENT_SECRET' "${work_dir}/external-jwt.yaml"
! grep -q 'name: OIDC_COOKIE_SECRET' "${work_dir}/external-jwt.yaml"
! grep -q 'keycloak: {}' "${work_dir}/external-jwt.yaml"

render \
  --set api.subscriptionPassthrough.providers.claude.enabled=true \
  --set api.audit.capturePayloads=true \
  --set-string api.subscriptionPassthrough.providers.claude.accessKeys[0].keyHashEnvVar=CLAUDE_TEAM_A_KEY_HASH \
  --set-string api.subscriptionPassthrough.providers.claude.accessKeys[0].metadata.name=team-a \
  > "${work_dir}/claude.yaml"
grep -q 'containerPort: 3001' "${work_dir}/claude.yaml"
grep -q 'llm: full' "${work_dir}/claude.yaml"
grep -q 'pathPrefix: /subscriptions/claude' "${work_dir}/claude.yaml"
grep -q 'prefix: /' "${work_dir}/claude.yaml"
grep -q '^              name: claude-subscription$' "${work_dir}/claude.yaml"
grep -q '^                anthropic: {}$' "${work_dir}/claude.yaml"
grep -q '^            policies:$' "${work_dir}/claude.yaml"
grep -q '^              ai:$' "${work_dir}/claude.yaml"
grep -q '^                routes:$' "${work_dir}/claude.yaml"
grep -q '^                  /v1/messages: messages$' "${work_dir}/claude.yaml"
grep -q '^                  /v1/messages/count_tokens: anthropicTokenCount$' "${work_dir}/claude.yaml"
grep -Fq '                  "*": passthrough' "${work_dir}/claude.yaml"
! grep -q 'host: api.anthropic.com:443' "${work_dir}/claude.yaml"
grep -q 'name: x-infegate-key' "${work_dir}/claude.yaml"
grep -q 'keyHash: "\$CLAUDE_TEAM_A_KEY_HASH"' "${work_dir}/claude.yaml"

render --set ingress.enabled=true \
  --set-string ingress.tls.existingSecret=infegate-tls \
  --set api.subscriptionPassthrough.providers.claude.enabled=true \
  > "${work_dir}/ingress.yaml"
grep -q 'host: "ai.customer.example"' "${work_dir}/ingress.yaml"
for path in /v1 /ui /api /cel /oauth/callback /subscriptions/claude; do
  grep -q "path: \"${path}\"" "${work_dir}/ingress.yaml"
done
grep -A8 'path: "/"$' "${work_dir}/ingress.yaml" | grep -q 'number: 80'
grep -A2 'path: "/"$' "${work_dir}/ingress.yaml" | grep -q 'pathType: Exact'

render \
  --set gateway.enabled=true \
  --set-string gateway.gatewayClassName=example-gateway \
  --set-string gateway.tls.existingSecret=infegate-tls \
  --set-string gateway.annotations.owner=platform \
  > "${work_dir}/managed-gateway.yaml"
test "$(grep -c '^kind: Gateway$' "${work_dir}/managed-gateway.yaml")" -eq 1
test "$(grep -c '^kind: HTTPRoute$' "${work_dir}/managed-gateway.yaml")" -eq 1
grep -q '^  gatewayClassName: "example-gateway"$' "${work_dir}/managed-gateway.yaml"
grep -q '^      hostname: "ai.customer.example"$' "${work_dir}/managed-gateway.yaml"
grep -q '^      port: 443$' "${work_dir}/managed-gateway.yaml"
grep -q '^      protocol: HTTPS$' "${work_dir}/managed-gateway.yaml"
grep -q '^[[:space:]]*name: "infegate-tls"$' "${work_dir}/managed-gateway.yaml"
grep -q '^    owner: platform$' "${work_dir}/managed-gateway.yaml"
grep -A5 '^  parentRefs:$' "${work_dir}/managed-gateway.yaml" | grep -q '^    - group: gateway.networking.k8s.io$'
grep -A5 '^  parentRefs:$' "${work_dir}/managed-gateway.yaml" | grep -q '^      kind: Gateway$'
grep -A5 '^  parentRefs:$' "${work_dir}/managed-gateway.yaml" | grep -q '^      name: "infegate"$'
grep -A5 '^  parentRefs:$' "${work_dir}/managed-gateway.yaml" | grep -q '^      sectionName: "https"$'

render \
  --set gateway.enabled=true \
  --set gateway.create=false \
  --set-string gateway.parentRef.name=shared-gateway \
  --set-string gateway.parentRef.namespace=gateway-system \
  --set-string gateway.parentRef.sectionName=https \
  > "${work_dir}/existing-gateway.yaml"
! grep -q '^kind: Gateway$' "${work_dir}/existing-gateway.yaml"
test "$(grep -c '^kind: HTTPRoute$' "${work_dir}/existing-gateway.yaml")" -eq 1
grep -A6 '^  parentRefs:$' "${work_dir}/existing-gateway.yaml" | grep -q '^      name: "shared-gateway"$'
grep -A6 '^  parentRefs:$' "${work_dir}/existing-gateway.yaml" | grep -q '^      namespace: "gateway-system"$'
grep -A6 '^  parentRefs:$' "${work_dir}/existing-gateway.yaml" | grep -q '^      sectionName: "https"$'

render \
  --set-string publicUrl=https://ai.customer.example:8443 \
  --set gateway.enabled=true \
  --set gateway.create=false \
  --set-string gateway.parentRef.name=shared-gateway \
  > "${work_dir}/existing-gateway-port.yaml"
grep -q '^    - "ai.customer.example"$' "${work_dir}/existing-gateway-port.yaml"
grep -q 'redirectURI: "https://ai.customer.example:8443/oauth/callback"' "${work_dir}/existing-gateway-port.yaml"

render \
  --set-string publicUrl=https://ai.customer.example \
  --set gateway.enabled=true \
  --set gateway.create=false \
  --set-string gateway.parentRef.name=shared-gateway \
  --set-string gateway.parentRef.namespace=gateway-system \
  --set api.subscriptionPassthrough.providers.claude.enabled=true \
  --set api.mcp.enabled=true \
  --set-string api.mcp.jwksUrl=https://id.customer.example/realms/infegate/protocol/openid-connect/certs \
  --set-string api.mcp.audiences[0]=infegate \
  --set-string 'api.mcp.authorizationRule="infegate-mcp-users" in jwt.groups' \
  > "${work_dir}/shared-gateway.yaml"
! grep -q '^kind: Gateway$' "${work_dir}/shared-gateway.yaml"
test "$(grep -c '^kind: HTTPRoute$' "${work_dir}/shared-gateway.yaml")" -eq 1
grep -q '^    - "ai.customer.example"$' "${work_dir}/shared-gateway.yaml"
grep -A6 '^  parentRefs:$' "${work_dir}/shared-gateway.yaml" | grep -q '^    - group: gateway.networking.k8s.io$'
grep -A6 '^  parentRefs:$' "${work_dir}/shared-gateway.yaml" | grep -q '^      kind: Gateway$'
grep -A6 '^  parentRefs:$' "${work_dir}/shared-gateway.yaml" | grep -q '^      name: "shared-gateway"$'
grep -A6 '^  parentRefs:$' "${work_dir}/shared-gateway.yaml" | grep -q '^      namespace: "gateway-system"$'
! grep -q 'sectionName:' "${work_dir}/shared-gateway.yaml"

assert_gateway_route() {
  path=$1
  path_type=$2
  service=$3
  port=$4
  route_block="${work_dir}/route-block.yaml"

  if test "${path}" = /; then
    grep -B2 -A8 'value: "/"$' "${work_dir}/shared-gateway.yaml" > "${route_block}"
  else
    grep -F -B2 -A8 "value: \"${path}\"" "${work_dir}/shared-gateway.yaml" > "${route_block}"
  fi
  grep -q "type: \"${path_type}\"" "${route_block}"
  grep -q "name: \"${service}\"" "${route_block}"
  grep -q "port: ${port}" "${route_block}"
}

assert_gateway_route /v1 PathPrefix infegate-api 3000
assert_gateway_route /ui PathPrefix infegate-api 4000
assert_gateway_route /api PathPrefix infegate-api 4000
assert_gateway_route /cel PathPrefix infegate-api 4000
assert_gateway_route /oauth/callback Exact infegate-api 4000
assert_gateway_route /subscriptions/claude PathPrefix infegate-api 3001
assert_gateway_route /.well-known/oauth-protected-resource/mcp Exact infegate-api 3002
assert_gateway_route /.well-known/oauth-authorization-server/mcp Exact infegate-api 3002
assert_gateway_route /mcp PathPrefix infegate-api 3002
assert_gateway_route / Exact infegate-ui 80
test "$(grep -c '^[[:space:]]*- group: ""$' "${work_dir}/shared-gateway.yaml")" -eq 10
test "$(grep -c '^          kind: Service$' "${work_dir}/shared-gateway.yaml")" -eq 10
test "$(grep -c '^          weight: 1$' "${work_dir}/shared-gateway.yaml")" -eq 10

render --set ingress.enabled=true \
  --set-string ingress.tls.existingSecret=infegate-tls \
  --set api.mcp.enabled=true \
  --set-string api.mcp.jwksUrl=https://id.customer.example/realms/infegate/protocol/openid-connect/certs \
  --set-string api.mcp.audiences[0]=infegate \
  --set-string 'api.mcp.authorizationRule="infegate-mcp-users" in jwt.groups' \
  > "${work_dir}/mcp-ingress.yaml"
grep -q 'path: "/mcp"' "${work_dir}/mcp-ingress.yaml"
grep -A2 'path: "/mcp"$' "${work_dir}/mcp-ingress.yaml" | grep -q 'pathType: Prefix'
grep -A8 'path: "/mcp"' "${work_dir}/mcp-ingress.yaml" | grep -q 'number: 3002'
for path in "/.well-known/oauth-protected-resource/mcp" "/.well-known/oauth-authorization-server/mcp"; do
  grep -q "path: \"${path}\"" "${work_dir}/mcp-ingress.yaml"
  grep -A2 "path: \"${path}\"" "${work_dir}/mcp-ingress.yaml" | grep -q 'pathType: ImplementationSpecific'
  grep -A8 "path: \"${path}\"" "${work_dir}/mcp-ingress.yaml" | grep -q 'number: 3002'
done
grep -A8 'path: "/"$' "${work_dir}/mcp-ingress.yaml" | grep -q 'number: 80'
! grep -q '/.well-known/oauth-' "${work_dir}/ingress.yaml"

readonly digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
render --set-string "api.image.digest=${digest}" --set-string "ui.image.digest=${digest}" \
  > "${work_dir}/digest.yaml"
grep -q "image: \"ghcr.io/demirtechcom/infegate/gateway@${digest}\"" "${work_dir}/digest.yaml"
grep -q "image: \"ghcr.io/demirtechcom/infegate/ui@${digest}\"" "${work_dir}/digest.yaml"

for missing in publicUrl api.database.existingSecret api.oidc.issuer api.oidc.clientId \
  api.oidc.existingSecret api.oidc.authorizationRule api.runtime.existingSecret
do
  if render --set-string "${missing}=" >/dev/null 2>&1; then
    echo "${missing} must be required" >&2
    exit 1
  fi
done

if helm template infegate "${chart}" >/dev/null 2>&1; then
  echo "required installation values must fail closed" >&2
  exit 1
fi
if render --set-string api.audit.capturePayloads=null >/dev/null 2>&1; then
  echo "api.audit.capturePayloads must be explicit" >&2
  exit 1
fi
if render --set-string api.oidc.existingSecret=infegate-db-app >/dev/null 2>&1; then
  echo "database, OIDC, and runtime Secrets must be distinct" >&2
  exit 1
fi
if render --set-string publicUrl=http://ai.customer.example >/dev/null 2>&1; then
  echo "publicUrl must be an HTTPS origin" >&2
  exit 1
fi
expect_render_failure "ingress.enabled and gateway.enabled cannot both be true" \
  --set ingress.enabled=true \
  --set-string ingress.tls.existingSecret=infegate-tls \
  --set gateway.enabled=true \
  --set-string gateway.gatewayClassName=example-gateway \
  --set-string gateway.tls.existingSecret=infegate-tls
expect_render_failure "gateway.gatewayClassName is required when creating a Gateway" \
  --set gateway.enabled=true \
  --set-string gateway.tls.existingSecret=infegate-tls
expect_render_failure "gateway.tls.existingSecret is required when creating a Gateway" \
  --set gateway.enabled=true \
  --set-string gateway.gatewayClassName=example-gateway
expect_render_failure "publicUrl port must be 443 when creating a Gateway" \
  --set-string publicUrl=https://ai.customer.example:8443 \
  --set gateway.enabled=true \
  --set-string gateway.gatewayClassName=example-gateway \
  --set-string gateway.tls.existingSecret=infegate-tls
expect_render_failure "publicUrl hostname must be a valid Gateway API hostname" \
  --set-string publicUrl=https://ai_customer.example \
  --set gateway.enabled=true \
  --set gateway.create=false \
  --set-string gateway.parentRef.name=shared-gateway
expect_render_failure "gateway.parentRef.name is required when using an existing Gateway" \
  --set gateway.enabled=true \
  --set gateway.create=false
expect_render_failure "api.management.externalJwt.issuer is required when management uses external JWT" \
  --set api.management.authenticationMode=externalJwt
expect_render_failure "api.mcp.issuer is required when MCP uses external JWT" \
  --set api.mcp.enabled=true \
  --set api.mcp.authenticationMode=externalJwt \
  --set-string api.mcp.jwksUrl=https://identity-proxy.customer.example/.well-known/jwks.json \
  --set-string api.mcp.audiences[0]=infegate \
  --set-string api.mcp.authorizationRule=true
expect_render_failure "api.audit.retention.metadataDays must be greater than payloadDays" \
  --set api.audit.retention.enabled=true \
  --set api.audit.retention.payloadDays=30 \
  --set api.audit.retention.metadataDays=30
for reserved_port in 3000 3001 3002 4000 15021; do
  expect_render_failure "api.metrics.port conflicts with a reserved Infegate listener port" \
    --set api.metrics.port="${reserved_port}"
done
expect_render_failure "api.autoscaling.minReplicas must not exceed maxReplicas" \
  --set api.autoscaling.minReplicas=5 \
  --set api.autoscaling.maxReplicas=4
if render \
  --set api.autoscaling.targetCPUUtilizationPercentage=null \
  --set api.autoscaling.targetMemoryUtilizationPercentage=null >/dev/null 2>&1; then
  echo "api autoscaling must require at least one utilization target" >&2
  exit 1
fi
expect_render_failure "ui.autoscaling.minReplicas must not exceed maxReplicas" \
  --set ui.autoscaling.minReplicas=5 \
  --set ui.autoscaling.maxReplicas=4
if render \
  --set ui.autoscaling.targetCPUUtilizationPercentage=null \
  --set ui.autoscaling.targetMemoryUtilizationPercentage=null >/dev/null 2>&1; then
  echo "ui autoscaling must require at least one utilization target" >&2
  exit 1
fi
if render --set api.subscriptionPassthrough.providers.openai.enabled=true >/dev/null 2>&1; then
  echo "unknown passthrough providers must fail schema validation" >&2
  exit 1
fi

readonly release_workflow=.github/workflows/release.yaml
readonly checkout='actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2'
grep -q '^version: 2.0.0$' "${chart}/Chart.yaml"
grep -q '^appVersion: "1.0.6"$' "${chart}/Chart.yaml"
if grep -Eq 'test "\$\{VERSION\}" = "[0-9]+\.[0-9]+\.[0-9]+"' "${release_workflow}"; then
  echo "chart release workflow must validate the dispatched version against Chart.yaml, not a hardcoded release" >&2
  exit 1
fi
grep -Fq "${checkout}" .github/workflows/check.yaml
grep -Fq "${checkout}" "${release_workflow}"
grep -Fq 'docker build --tag "${ui_image}" scripts/testdata/ui' scripts/smoke-infegate-chart.sh
if grep -Fq 'ghcr.io/demirtechcom/infegate:1.4.1-1' scripts/smoke-infegate-chart.sh; then
  echo "chart smoke tests must not depend on a private legacy Infegate image" >&2
  exit 1
fi
grep -Fq 'workflow_dispatch:' "${release_workflow}"
grep -Fq 'ui_digest:' "${release_workflow}"
grep -Fq 'gateway_digest:' "${release_workflow}"
grep -Fq 'source_release_id:' "${release_workflow}"
grep -Fq 'app_version:' "${release_workflow}"
grep -Fq 'APP_VERSION: ${{ inputs.app_version || inputs.version }}' "${release_workflow}"
grep -Fq 'CHART_VERSION: ${{ inputs.version }}' "${release_workflow}"
grep -Fq '= "${CHART_VERSION}"' "${release_workflow}"
grep -Fq '= "${APP_VERSION}"' "${release_workflow}"
grep -Fq -- '--arg tag "v${APP_VERSION}"' "${release_workflow}"
grep -Fq 'git/ref/tags/v${APP_VERSION}' "${release_workflow}"
grep -Fq 'secrets.RELEASE_APP_ID' "${release_workflow}"
grep -Fq 'secrets.RELEASE_APP_PRIVATE_KEY' "${release_workflow}"
grep -Fq 'SOURCE_TOKEN: ${{ steps.source-token.outputs.token }}' "${release_workflow}"
if grep -Fq 'Authorization: Bearer ${GITHUB_TOKEN}' "${release_workflow}"; then
  echo "Source release verification must not use the repository-scoped GITHUB_TOKEN" >&2
  exit 1
fi
grep -Fq 'helm push' "${release_workflow}"
grep -Fq 'Refusing to overwrite' "${release_workflow}"
if grep -Fq 'tags:' "${release_workflow}"; then
  echo "chart releases must not be triggered by tag pushes" >&2
  exit 1
fi

for heading in "## Install" "## Native OIDC" "## Virtual API keys" "## Claude Code" \
  "## Subscription passthrough" "## PostgreSQL" "## Image digest pinning" \
  "## Ingress routing" "## Gateway API routing" "## Upgrade" "## Rollback"
do
  grep -Fqx "${heading}" "${chart}/README.md" || {
    echo "chart README must contain: ${heading}" >&2
    exit 1
  }
done
