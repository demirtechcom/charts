# Infegate

This chart installs Infegate as one product with two independent workloads:
`infegate-api` runs the pinned agentgateway runtime and `infegate-ui` serves the
branded static interface. Both use an external PostgreSQL database. The chart
does not install PostgreSQL, CloudNativePG, an OIDC provider, certificates, or
an Ingress controller.

## Install

Infegate 1.0.0 supports clean installations only. Prepare three distinct
Secrets for the database URL, OIDC credentials, and runtime provider
credentials, then install with explicit audit retention behavior:

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

ingress:
  enabled: true
  className: nginx
  tls:
    existingSecret: infegate-tls
```

```sh
helm install infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version 1.0.0 --namespace infegate --create-namespace -f values.yaml
```

## Native OIDC

The API workload uses agentgateway's native OIDC Authorization Code flow. The
OIDC Secret must contain `client-secret` and a `cookie-secret` holding 32 random
bytes encoded as 64 hexadecimal characters. Register
`https://ai.customer.example/oauth/callback` with the identity provider.

Authentication alone does not grant administration access. Every install must
provide `api.oidc.authorizationRule`, a fail-closed CEL allow expression. `/ui`,
`/api`, and `/cel` share the same origin and encrypted session cookie.

## Virtual API keys

The `/v1` API always uses strict Bearer virtual API key authentication. Keys are
created in the UI and stored in PostgreSQL through hybrid configuration storage.
Use key metadata such as `name`, `owner`, and `team` to attribute audit and cost
records. API OAuth and JWT authentication are not enabled in 1.0.0.

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
forwarding.

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
rendered. Claude is the only supported subscription provider in 1.0.0.

## PostgreSQL

PostgreSQL is mandatory and is not bundled. CloudNativePG is recommended; its
`[cluster]-app` Secret already provides the default `uri` key expected by the
chart. The database URL is injected as `INFEGATE_DATABASE_URL` and the ConfigMap
contains only `$INFEGATE_DATABASE_URL`, so `/api/config` cannot expose the
credential. Both API replicas share hybrid configuration, logs, costs, and
virtual keys through this database.

Set `api.audit.capturePayloads: false` to retain metadata, usage, timing, and
cost without prompts or completions. Set it to `true` only when full content
retention is approved.

## Image digest pinning

Source `values.yaml` uses 1.0.0 tags. The published OCI chart is packaged with
the immutable UI and gateway digests produced by the Infegate release. Private
or offline installations may override each repository while retaining its
digest.

## Ingress routing

Built-in Ingress is disabled by default. When enabled, its single hostname is
derived from the required HTTPS `publicUrl` and an existing TLS Secret is
mandatory.

| Path | API service port |
| --- | ---: |
| `/v1` | 3000 |
| `/ui`, `/api`, `/cel`, `/oauth/callback` | 4000 |
| `/subscriptions/claude` when enabled | 3001 |

The UI Service remains cluster-internal. Root paths are not routed and return
404.

## Upgrade

Version 1.0.0 has no supported upgrade path from the UI-only 0.1.0 chart or an
independent agentgateway deployment. Install into a clean namespace with a
clean PostgreSQL database. For later releases, render and inspect the target
chart and its two digests before upgrading.

## Rollback

Rollback the chart and both recorded image digests together. Database schema
compatibility must be checked against the target release before rollback. A
Helm rollback does not modify PostgreSQL, OIDC, DNS, TLS, or runtime Secrets.
