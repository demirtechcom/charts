#!/bin/sh
set -eu

readonly chart=charts/infegate
readonly work_dir="$(mktemp -d)"

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
