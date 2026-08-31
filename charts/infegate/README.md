# Infegate

This chart installs the standalone Infegate web interface as a Deployment,
ClusterIP Service, and optional ServiceAccount. It does not install or modify
agentgateway, an Ingress controller, certificates, or application API routes.

## Install

Install version `0.1.0` from the DemirTech OCI registry:

```sh
helm install infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version 0.1.0 \
  --namespace infegate \
  --create-namespace
```

The default release runs two replicas and exposes them through the `infegate`
Service on port 80. Readiness and liveness probes call `/healthz`. The container
runs without privilege escalation, with a read-only root filesystem and a
writable in-memory `/tmp` volume.

## Image digest pinning

The default image tag comes from the chart's `appVersion`. Production installs
should pin the verified multi-platform image by digest:

```yaml
image:
  repository: ghcr.io/demirtechcom/infegate
  digest: sha256:<64-hex-character-digest>
```

When `image.digest` is set, it takes precedence over `image.tag`. Keep the chart
version and image digest together in the deployment configuration so upgrades
and rollbacks are reproducible.

## Ingress routing

Create ingress routes outside this chart. Route `/ui` and `/ui/*` to the
Infegate Service on port 80. Route `/api`, `/cel`, and any agentgateway endpoints
to the agentgateway Service. Do not route `/` or other root paths to Infegate,
because its image intentionally serves only `/ui`, `/ui/*`, and `/healthz`.

## Private registries and offline mirrors

For a private GHCR package, create the registry Secret separately and reference
its existing name. Do not put registry credentials in Helm values:

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

For an offline installation, mirror the immutable image into the local registry
and override its repository while retaining the digest:

```yaml
image:
  repository: registry.internal.example/infegate
  digest: sha256:<64-hex-character-digest>
  pullPolicy: IfNotPresent
```

## Upgrade

Review the target chart release and image digest, then render and inspect the
change before upgrading:

```sh
helm template infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version <chart-version> \
  --set-string image.digest=sha256:<64-hex-character-digest>

helm upgrade infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version <chart-version> \
  --namespace infegate \
  --set-string image.digest=sha256:<64-hex-character-digest> \
  --wait
```

## Rollback

Rollback to the last known chart version and its recorded image digest. Pinning
both avoids silently selecting a changed tag:

```sh
helm upgrade infegate oci://ghcr.io/demirtechcom/charts/infegate \
  --version <previous-chart-version> \
  --namespace infegate \
  --set-string image.digest=sha256:<previous-64-hex-character-digest> \
  --wait
```

If the previous Helm revision already contains the required immutable digest,
`helm rollback infegate <revision> --namespace infegate --wait` is equivalent.

## Values

| Value | Default | Purpose |
| --- | --- | --- |
| `replicaCount` | `2` | Number of UI replicas |
| `image.repository` | `ghcr.io/demirtechcom/infegate` | Image repository or mirror |
| `image.tag` | `""` | Image tag, defaults to `appVersion` |
| `image.digest` | `""` | Immutable digest that overrides the tag |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy |
| `imagePullSecrets` | `[]` | Existing registry Secret names |
| `serviceAccount.create` | `true` | Create a dedicated ServiceAccount |
| `service.type` | `ClusterIP` | Kubernetes Service type |
| `service.port` | `80` | Service port targeting container port 8080 |
| `resources` | `{}` | Container requests and limits |
| `nodeSelector`, `tolerations`, `affinity` | empty | Pod scheduling controls |
| `topologySpreadConstraints` | `[]` | Pod topology distribution controls |

See `values.yaml` and `values.schema.json` for all supported values and their
validation constraints.
