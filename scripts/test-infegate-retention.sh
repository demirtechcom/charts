#!/bin/sh
set -eu

readonly chart=charts/infegate
readonly work_dir="$(mktemp -d)"
readonly container="infegate-retention-$$"

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

helm template infegate "${chart}" \
  --show-only templates/retention-configmap.yaml \
  --set-string publicUrl=https://ai.test.example \
  --set-string api.database.existingSecret=infegate-db \
  --set-string api.oidc.issuer=https://id.test.example \
  --set-string api.oidc.clientId=infegate \
  --set-string api.oidc.existingSecret=infegate-oidc \
  --set-string api.oidc.authorizationRule=true \
  --set-string api.runtime.existingSecret=infegate-runtime \
  --set api.audit.capturePayloads=true \
  --set api.audit.retention.enabled=true \
  > "${work_dir}/rendered.yaml"

helm template infegate "${chart}" \
  --show-only templates/retention-cronjob.yaml \
  --set-string publicUrl=https://ai.test.example \
  --set-string api.database.existingSecret=infegate-db \
  --set-string api.oidc.issuer=https://id.test.example \
  --set-string api.oidc.clientId=infegate \
  --set-string api.oidc.existingSecret=infegate-oidc \
  --set-string api.oidc.authorizationRule=true \
  --set-string api.runtime.existingSecret=infegate-runtime \
  --set api.audit.capturePayloads=true \
  --set api.audit.retention.enabled=true \
  > "${work_dir}/cronjob.yaml"
grep -q '^            runAsUser: 70$' "${work_dir}/cronjob.yaml"
grep -q '^            runAsGroup: 70$' "${work_dir}/cronjob.yaml"
grep -q '^                allowPrivilegeEscalation: false$' "${work_dir}/cronjob.yaml"
grep -q '^                readOnlyRootFilesystem: true$' "${work_dir}/cronjob.yaml"
grep -q '^                - name: PGDATABASE$' "${work_dir}/cronjob.yaml"
grep -q 'exec psql --file=/etc/infegate/retention.sql' "${work_dir}/cronjob.yaml"
! grep -q -- '--dbname' "${work_dir}/cronjob.yaml"

awk '
  /^  retention.sql: \|$/ { capture = 1; next }
  capture && /^---$/ { exit }
  capture { sub(/^    /, ""); print }
' "${work_dir}/rendered.yaml" > "${work_dir}/retention.sql"

docker run --detach --name "${container}" \
  --env POSTGRES_PASSWORD=test \
  --env POSTGRES_DB=infegate \
  postgres:18-alpine >/dev/null

attempt=0
until docker exec "${container}" psql --username postgres --dbname infegate \
  --tuples-only --command='SELECT 1' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if test "${attempt}" -ge 60; then
    docker logs "${container}" >&2
    exit 1
  fi
  sleep 1
done

docker exec --interactive "${container}" psql \
  --username postgres --dbname infegate --set ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE request_logs (
  id text PRIMARY KEY,
  completed_at timestamptz NOT NULL,
  has_payload boolean NOT NULL,
  attributes_json jsonb NOT NULL
);

CREATE TABLE request_log_payloads (
  log_id text PRIMARY KEY REFERENCES request_logs(id) ON DELETE CASCADE,
  request_prompt_json jsonb,
  response_completion_json jsonb
);

INSERT INTO request_logs (id, completed_at, has_payload, attributes_json) VALUES
  ('recent', CURRENT_TIMESTAMP - INTERVAL '29 days', true, '{"mcp.tool.arguments":{"safe":true},"route":"recent"}'),
  ('payload-expired', CURRENT_TIMESTAMP - INTERVAL '31 days', true, '{"mcp.tool.arguments":{"secret":true},"mcp.tool.result":"secret","mcp.tool.error":"secret","route":"kept"}'),
  ('metadata-expired', CURRENT_TIMESTAMP - INTERVAL '366 days', true, '{"route":"expired"}');

INSERT INTO request_log_payloads (log_id, request_prompt_json, response_completion_json) VALUES
  ('recent', '{"prompt":"recent"}', '{"completion":"recent"}'),
  ('payload-expired', '{"prompt":"expired"}', '{"completion":"expired"}'),
  ('metadata-expired', '{"prompt":"expired"}', '{"completion":"expired"}');
SQL

docker exec --interactive "${container}" psql \
  --username postgres --dbname infegate --set ON_ERROR_STOP=1 \
  < "${work_dir}/retention.sql"

docker exec --interactive "${container}" psql \
  --username postgres --dbname infegate --set ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF (SELECT count(*) FROM request_logs) <> 2 THEN
    RAISE EXCEPTION 'expected two metadata rows after retention';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM request_log_payloads WHERE log_id = 'recent') THEN
    RAISE EXCEPTION 'recent payload was removed';
  END IF;
  IF EXISTS (SELECT 1 FROM request_log_payloads WHERE log_id = 'payload-expired') THEN
    RAISE EXCEPTION 'expired payload was retained';
  END IF;
  IF EXISTS (SELECT 1 FROM request_logs WHERE id = 'metadata-expired') THEN
    RAISE EXCEPTION 'expired metadata was retained';
  END IF;
  IF EXISTS (
    SELECT 1 FROM request_logs
    WHERE id = 'payload-expired'
      AND (has_payload OR attributes_json ?| ARRAY['mcp.tool.arguments', 'mcp.tool.result', 'mcp.tool.error'])
  ) THEN
    RAISE EXCEPTION 'expired MCP payload was retained';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM request_logs
    WHERE id = 'payload-expired' AND attributes_json ->> 'route' = 'kept'
  ) THEN
    RAISE EXCEPTION 'non-payload metadata was removed early';
  END IF;
END
$$;
SQL

# Tuple identity changes even for an UPDATE that writes the same values.
# Compare it across runs so repeated payload cleanup must be a physical no-op.
docker exec "${container}" psql --username postgres --dbname infegate \
  --tuples-only --no-align --command='SELECT id, xmin, ctid FROM request_logs ORDER BY id' \
  > "${work_dir}/before-second-run.txt"
docker exec --interactive "${container}" psql \
  --username postgres --dbname infegate --set ON_ERROR_STOP=1 \
  < "${work_dir}/retention.sql" > "${work_dir}/second-run.txt"
cat "${work_dir}/second-run.txt"
docker exec "${container}" psql --username postgres --dbname infegate \
  --tuples-only --no-align --command='SELECT id, xmin, ctid FROM request_logs ORDER BY id' \
  > "${work_dir}/after-second-run.txt"
diff -u "${work_dir}/before-second-run.txt" "${work_dir}/after-second-run.txt"
grep -qx 'UPDATE 0' "${work_dir}/second-run.txt"
