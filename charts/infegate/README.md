# Infegate

This chart installs Infegate as one product with two independent workloads:
`infegate-api` runs the pinned agentgateway runtime and `infegate-ui` serves the
branded static interface. Both use an external PostgreSQL database. The chart
does not install PostgreSQL, a database operator, an OIDC provider, certificates, or
an Ingress or Gateway API controller, or Gateway API CRDs.

## Install

Chart 2.0.0 packages Infegate 1.0.6. Prepare separate Secrets for the database
URL and runtime provider credentials. Native OIDC also needs its own Secret.
Choose the authentication mode and audit behavior explicitly:

```yaml
publicUrl: https://ai.customer.example

api:
  database:
    existingSecret: infegate-db-app
  oidc:
    issuer: https://id.customer.example/realms/infegate
    clientId: infegate
    existingSecret: infegate-oidc
    authorizationRule: 'jwt.email.endsWith("@customer.example")'
  runtime:
    existingSecret: infegate-runtime
  audit:
    capturePayloads: false
  mcp:
    enabled: true
    jwksUrl: https://id.customer.example/realms/infegate/protocol/openid-connect/certs
    audiences:
      - infegate
    authorizationRule: '"infegate-mcp-users" in jwt.groups'

ingress:
  enabled: true
  className: nginx
  tls:
    existingSecret: infegate-tls
```

```sh
helm install infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version 2.0.0 --namespace infegate --create-namespace -f values.yaml
```

## Native OIDC

The API workload uses agentgateway's native OIDC Authorization Code flow. The
OIDC Secret must contain `client-secret` and a `cookie-secret` holding 32 random
bytes encoded as 64 hexadecimal characters. Register
`https://ai.customer.example/oauth/callback` with the identity provider.

Authentication alone does not grant administration access. Every install must
provide `api.oidc.authorizationRule`, a fail-closed CEL allow expression. `/ui`,
`/api`, and `/cel` share the same origin and encrypted session cookie.

## External JWT

Set `api.management.authenticationMode: externalJwt` when an edge proxy owns
the login flow. Infegate then validates the token again at the origin, including
its signature, issuer, audience, and required expiry claim. OIDC credentials
and `/oauth/callback` are omitted in this mode.

Configure the issuer, audience, JWKS endpoint, and header used by the upstream
identity-aware proxy:

```yaml
api:
  management:
    authenticationMode: externalJwt
    externalJwt:
      issuer: https://identity-proxy.customer.example
      audiences:
        - "$INFEGATE_ADMIN_AUDIENCE"
      jwksUrl: https://identity-proxy.customer.example/.well-known/jwks.json
      headerName: X-Forwarded-Jwt
      authorizationRule: 'jwt.email != ""'
```

Put audience values in the runtime Secret and reference their environment
variables as shown. This keeps deployment-specific identifiers out of
the values file and avoids repeating the administrator email list at the
origin.

## Virtual API keys

The `/v1` API always uses strict Bearer virtual API key authentication. Keys are
created in the UI and stored in PostgreSQL through hybrid configuration storage.
Use key metadata such as `name`, `owner`, and `team` to attribute audit and cost
records. API OAuth and JWT authentication are not enabled in 1.0.x.

## Claude Code

The default Claude Code integration uses a configured Anthropic provider and an
Infegate virtual key. The real provider credential remains in the runtime
Secret:

```sh
export ANTHROPIC_BASE_URL=https://ai.customer.example
export ANTHROPIC_AUTH_TOKEN=<infegate-virtual-key>
claude
```

## Subscription passthrough

The optional Claude subscription route is fixed to
`/subscriptions/claude/*` and `api.anthropic.com`. It cannot be pointed at an
arbitrary host. The user's subscription credential remains in `Authorization`;
Infegate authentication uses `x-infegate-key` and removes that header before
forwarding. Subscription requests use the same PostgreSQL audit log and
management UI as `/v1` requests. `api.audit.capturePayloads: false` stores only
metadata, usage, timing, and cost; `true` also stores prompts and completions.

Store only `sha256:<hex>` hashes in the runtime Secret and reference their
environment variable names:

```yaml
api:
  subscriptionPassthrough:
    providers:
      claude:
        enabled: true
        accessKeys:
          - keyHashEnvVar: CLAUDE_TEAM_A_KEY_HASH
            metadata:
              name: team-a
              owner: platform-team
```

When Claude passthrough is disabled, port 3001 and its Ingress route are not
rendered. Claude is the only supported subscription provider in 1.0.x.

## PostgreSQL

PostgreSQL is mandatory and is not bundled. Provide its connection URI in the
Secret key selected by `api.database.key`, which defaults to `uri`. The database
URL is injected as `INFEGATE_DATABASE_URL` and the ConfigMap
contains only `$INFEGATE_DATABASE_URL`, so `/api/config` cannot expose the
credential. Both API replicas share hybrid configuration, logs, costs, and
virtual keys through this database.

Size PostgreSQL for the API connection ceiling before raising autoscaling
limits. The upper bound is `api.autoscaling.maxReplicas` multiplied by
`api.database.maxConnections`, which is 150 connections with chart defaults.
Reserve additional capacity for operators, migrations, retention, and other
database clients.

Set `api.audit.capturePayloads: false` to retain metadata, usage, timing, and
cost without prompts or completions. Set it to `true` only when full content
retention is approved.

Set `api.audit.captureMcpPayloads: true` to record MCP tool arguments, results,
and errors. The default sensitive-header list redacts authorization headers,
cookies, Infegate keys, and common provider API-key headers
from trace and debug output.

The optional retention CronJob deletes LLM and MCP payloads before deleting
their metadata:

```yaml
api:
  audit:
    retention:
      enabled: true
      schedule: "17 3 * * *"
      payloadDays: 30
      metadataDays: 365
```

Retention only changes the online database. Backups can preserve deleted rows
until their own retention window expires.

The retention container runs as PostgreSQL's standard UID and GID 70 by
default. Override `api.audit.retention.podSecurityContext.runAsUser` and
`runAsGroup` when the selected image uses different numeric IDs. The database
URI is passed through `PGDATABASE`, so it does not appear in the process command
line.

## Metrics

Prometheus metrics are enabled by default on the API Service's named `metrics`
port at `15020`. Set `api.metrics.enabled: false` to render `statsAddr: off` and
remove the metrics ports from the Deployment and Service. The metric names and
labels follow the bundled agentgateway version. Scrapers should drop sensitive
or unbounded labels such as user, email, API key, and request ID.

## MCP

Set `api.mcp.enabled: true` to enable PostgreSQL-backed MCP configuration in
hybrid mode. The chart renders an empty target catalog so MCP servers remain
managed through Infegate instead of an unrestricted raw gateway configuration.
MCP listens on the dedicated internal port 3002 and is published at `/mcp` when
Ingress or Gateway API routing is enabled. The default `nativeOAuth` mode uses
the OIDC issuer and publishes the MCP discovery routes. The `externalJwt` mode
expects an upstream OAuth service, reads its
signed assertion from the configured header, and does not expose Infegate's
native discovery routes. Both modes verify the configured JWKS and audience and
require an explicit `api.mcp.authorizationRule`.

## Autoscaling and pod placement

API and UI HorizontalPodAutoscalers are enabled by default with three minimum and
30 maximum replicas. Both use a 70 percent CPU utilization target and require
Kubernetes resource metrics, normally provided by Metrics Server. Configure
CPU, memory, and HPA scaling behavior independently under `api.autoscaling` and
`ui.autoscaling`. The default policy scales up immediately by up to 100 percent
or four pods per minute and stabilizes scale-down for five minutes.

Set `autoscaling.enabled: false` to let another controller or an operator manage
replica counts. The Deployments do not render `spec.replicas` in either mode, so
GitOps reconciliation does not overwrite the active scaler.

Each workload spreads its replicas across zones and nodes by default and exposes
`nodeSelector`, `affinity`, `tolerations`, and `topologySpreadConstraints` for
additional placement rules. Disable the generated constraints with
`defaultTopologySpread.enabled: false`. A PodDisruptionBudget permits one
unavailable replica, while rolling updates permit one surge pod and no
unavailable pods. `podSecurityContext` and
`containerSecurityContext` are also configurable independently for API and UI.
Their defaults require a non-root process, the runtime-default seccomp profile,
no privilege escalation, a read-only root filesystem, and no Linux
capabilities.

Startup, readiness, and liveness probes are configured separately. API
liveness checks only the local listener so a database outage does not restart
every replica. Both workloads use a 60 second termination grace period. Resource
defaults include memory and ephemeral-storage limits; CPU limits are omitted to
avoid throttling latency-sensitive requests. The chart supports Kubernetes
1.30 and newer.

Each probe has a `type` discriminator: `httpGet`, `tcpSocket`, `exec`, or
`grpc`. The chart renders only the selected handler, so changing a probe type
does not combine the new handler with defaults left behind by Helm value
merging. Deployment strategy behaves the same way: setting `strategy.type` to
`Recreate` omits the default `rollingUpdate` block.

## Image digest pinning

Source `values.yaml` uses 1.0.6 tags. The published OCI chart is packaged with
the immutable UI and gateway digests produced by the Infegate release. Private
or offline installations may override each repository while retaining its
digest.

## Ingress routing

Built-in Ingress is disabled by default. When enabled, its single hostname is
derived from the required HTTPS `publicUrl` and an existing TLS Secret is
mandatory.

| Path | Service | Port |
| --- | --- | ---: |
| `/` | UI | 80 |
| `/v1` | API | 3000 |
| `/mcp` when enabled | API | 3002 |
| `/.well-known/oauth-protected-resource/mcp` with native MCP OAuth | API | 3002 |
| `/.well-known/oauth-authorization-server/mcp` with native MCP OAuth | API | 3002 |
| `/ui`, `/api`, `/cel` | API | 4000 |
| `/oauth/callback` with native management OIDC | API | 4000 |
| `/subscriptions/claude` when enabled | API | 3001 |

The exact root path serves the public Infegate landing page. The UI Service
remains cluster-internal, unknown root paths return 404, and the management UI
continues through the OIDC-protected API listener.

## Gateway API routing

Gateway API routing is disabled by default and cannot be enabled together with
Ingress. The HTTPRoute uses the same hostname and paths listed above. It uses
`Exact` matching for `/` and the two MCP discovery paths, and `PathPrefix` for
all other paths.

To create a Gateway with an HTTPS listener, provide the GatewayClass and an
existing TLS Secret:

```yaml
gateway:
  enabled: true
  create: true
  gatewayClassName: envoy-gateway
  tls:
    existingSecret: infegate-tls
```

To attach only the HTTPRoute to an existing Gateway, set `create: false` and
provide its name. The namespace and listener section name are optional:

```yaml
gateway:
  enabled: true
  create: false
  parentRef:
    name: shared-gateway
    namespace: gateway-system
    sectionName: https
```

The cluster must already have the Gateway API CRDs and a controller. See the
[Gateway API HTTP routing guide](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/)
and [TLS configuration guide](https://gateway-api.sigs.k8s.io/guides/user-guides/tls/)
for the resources and listener model used by the chart.

## Upgrade

Chart 2.0.0 removes `api.replicaCount` and `ui.replicaCount`. Remove those keys
from existing values and configure each workload under `autoscaling`. Rename
`api.audit.retention.securityContext` to `podSecurityContext` and move
container-only settings such as `allowPrivilegeEscalation`, capabilities, and
`readOnlyRootFilesystem` to `containerSecurityContext`.

During an upgrade from 1.x, Helm removes the old Deployment replica field before
the new HPA reconciles its minimum. This can briefly reduce a workload to one
replica. Perform the upgrade during a controlled window and verify both HPAs
have reached `minReplicas` before ending the window. Native
OIDC remains the default, so no authentication migration is required. New
installations require a clean namespace and PostgreSQL database. Render and
inspect the target chart and its two image digests before upgrading.

## Rollback

Rollback the chart and both recorded image digests together. Database schema
compatibility must be checked against the target release before rollback. A
Helm rollback does not modify PostgreSQL, OIDC, DNS, TLS, or runtime Secrets.
