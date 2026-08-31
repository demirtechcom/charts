#!/bin/sh
set -eu

readonly chart=charts/infegate
readonly work_dir="$(mktemp -d)"

for heading in \
  "## Install" \
  "## Image digest pinning" \
  "## Ingress routing" \
  "## Private registries and offline mirrors" \
  "## Upgrade" \
  "## Rollback"
do
  grep -Fqx "$heading" "${chart}/README.md" || {
    echo "chart README must contain: $heading" >&2
    exit 1
  }
done

cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

helm template infegate "${chart}" > "${work_dir}/default.yaml"

grep -q '^  replicas: 2$' "${work_dir}/default.yaml"
grep -q 'image: "ghcr.io/demirtechcom/infegate:1.4.1-1"' "${work_dir}/default.yaml"
grep -q 'containerPort: 8080' "${work_dir}/default.yaml"
grep -q 'port: 80' "${work_dir}/default.yaml"
test "$(grep -c 'path: /healthz' "${work_dir}/default.yaml")" -eq 2
grep -q 'automountServiceAccountToken: false' "${work_dir}/default.yaml"
grep -q 'readOnlyRootFilesystem: true' "${work_dir}/default.yaml"
grep -q 'mountPath: /tmp' "${work_dir}/default.yaml"

readonly digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
helm template infegate "${chart}" --set-string "image.digest=${digest}" > "${work_dir}/digest.yaml"
grep -q "image: \"ghcr.io/demirtechcom/infegate@${digest}\"" "${work_dir}/digest.yaml"
if grep -q 'image: "ghcr.io/demirtechcom/infegate:1.4.1-1"' "${work_dir}/digest.yaml"; then
  echo "digest-pinned render must not use the image tag" >&2
  exit 1
fi

if helm template infegate "${chart}" --set replicaCount=0 >/dev/null 2>&1; then
  echo "replicaCount=0 must fail schema validation" >&2
  exit 1
fi

if helm template infegate "${chart}" --set-string image.digest=sha256:bad >/dev/null 2>&1; then
  echo "malformed image digest must fail schema validation" >&2
  exit 1
fi

for workflow in .github/workflows/check.yaml .github/workflows/release.yaml; do
  grep -Fq "runs-on: \${{ vars.CI_RUNNER || 'ubuntu-latest' }}" "${workflow}"
done
grep -Fq 'ct lint --config ct.yaml' .github/workflows/check.yaml
grep -Fq 'packages: read' .github/workflows/check.yaml
grep -Fq 'GIT_CONFIG_VALUE_0=/workdir' .github/workflows/check.yaml
grep -Fq 'scripts/smoke-infegate-chart.sh' .github/workflows/check.yaml
if grep -Fq '  --wait' scripts/smoke-infegate-chart.sh; then
  echo "smoke test must use rollout status as its only workload wait" >&2
  exit 1
fi
grep -Fq 'tags:' .github/workflows/release.yaml
