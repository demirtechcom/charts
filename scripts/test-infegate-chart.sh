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

render > "${work_dir}/default.yaml"
grep -q 'name: infegate-api' "${work_dir}/default.yaml"
grep -q 'name: infegate-ui' "${work_dir}/default.yaml"
test "$(grep -c '^  replicas: 2$' "${work_dir}/default.yaml")" -eq 2
grep -q 'image: "ghcr.io/demirtechcom/infegate/gateway:1.0.3"' "${work_dir}/default.yaml"
grep -q 'image: "ghcr.io/demirtechcom/infegate/ui:1.0.3"' "${work_dir}/default.yaml"
grep -q 'url: \$INFEGATE_DATABASE_URL' "${work_dir}/default.yaml"
grep -q 'mode: hybrid' "${work_dir}/default.yaml"
grep -q 'llm: metadata' "${work_dir}/default.yaml"
grep -q 'mode: strict' "${work_dir}/default.yaml"
grep -q 'name: OIDC_COOKIE_SECRET' "${work_dir}/default.yaml"
test "$(grep -c 'path: /healthz/ready' "${work_dir}/default.yaml")" -eq 2
grep -q 'automountServiceAccountToken: false' "${work_dir}/default.yaml"
grep -q 'readOnlyRootFilesystem: true' "${work_dir}/default.yaml"
! grep -q 'kind: PodDisruptionBudget' "${work_dir}/default.yaml"
! grep -q 'containerPort: 3001' "${work_dir}/default.yaml"
! grep -q 'containerPort: 3002' "${work_dir}/default.yaml"
! grep -q '^    mcp:$' "${work_dir}/default.yaml"

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
  --set api.subscriptionPassthrough.providers.claude.enabled=true \
  --set-string api.subscriptionPassthrough.providers.claude.accessKeys[0].keyHashEnvVar=CLAUDE_TEAM_A_KEY_HASH \
  --set-string api.subscriptionPassthrough.providers.claude.accessKeys[0].metadata.name=team-a \
  > "${work_dir}/claude.yaml"
grep -q 'containerPort: 3001' "${work_dir}/claude.yaml"
grep -q 'pathPrefix: /subscriptions/claude' "${work_dir}/claude.yaml"
grep -q 'prefix: /' "${work_dir}/claude.yaml"
grep -q 'host: api.anthropic.com:443' "${work_dir}/claude.yaml"
grep -q 'name: x-infegate-key' "${work_dir}/claude.yaml"
grep -q 'keyHash: \$CLAUDE_TEAM_A_KEY_HASH' "${work_dir}/claude.yaml"

render --set ingress.enabled=true \
  --set-string ingress.tls.existingSecret=infegate-tls \
  --set api.subscriptionPassthrough.providers.claude.enabled=true \
  > "${work_dir}/ingress.yaml"
grep -q 'host: ai.customer.example' "${work_dir}/ingress.yaml"
for path in /v1 /ui /api /cel /oauth/callback /subscriptions/claude; do
  grep -q "path: ${path}" "${work_dir}/ingress.yaml"
done

render --set ingress.enabled=true \
  --set-string ingress.tls.existingSecret=infegate-tls \
  --set api.mcp.enabled=true \
  --set-string api.mcp.jwksUrl=https://id.customer.example/realms/infegate/protocol/openid-connect/certs \
  --set-string api.mcp.audiences[0]=infegate \
  --set-string 'api.mcp.authorizationRule="infegate-mcp-users" in jwt.groups' \
  > "${work_dir}/mcp-ingress.yaml"
grep -q 'path: /mcp' "${work_dir}/mcp-ingress.yaml"
grep -A8 'path: /mcp' "${work_dir}/mcp-ingress.yaml" | grep -q 'number: 3002'

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
if render --set api.subscriptionPassthrough.providers.openai.enabled=true >/dev/null 2>&1; then
  echo "unknown passthrough providers must fail schema validation" >&2
  exit 1
fi

readonly release_workflow=.github/workflows/release.yaml
readonly checkout='actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2'
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
  "## Ingress routing" "## Upgrade" "## Rollback"
do
  grep -Fqx "${heading}" "${chart}/README.md" || {
    echo "chart README must contain: ${heading}" >&2
    exit 1
  }
done
