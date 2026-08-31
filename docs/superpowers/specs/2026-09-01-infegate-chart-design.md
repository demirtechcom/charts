# Infegate Helm Chart Design

## Objective

Ship the first public Infegate Helm chart as a small, complete installation of
the standalone Infegate UI image. The chart owns only the UI Deployment and its
cluster-local Service. It does not deploy agentgateway, add a sidecar, or own an
environment's ingress routing.

The first chart version is `0.1.0`. Its application version is `1.4.1-1`.

## Workload boundary

The chart renders these namespaced resources:

- ServiceAccount with API token automount disabled
- Deployment running the Infegate Nginx image on container port `8080`
- ClusterIP Service exposing port `80`

Ingress is deliberately excluded. The environment owner must route `/ui` and
`/ui/*` to the Infegate Service while routing `/api`, `/cel`, and other gateway
paths to agentgateway. Keeping that route split outside this chart avoids hidden
coupling to an ingress controller or an agentgateway release name.

## Image contract

Values expose repository, tag, digest, pull policy, and existing image pull
Secret names. The default repository is
`ghcr.io/demirtechcom/infegate`, and the default tag matches `appVersion`.

When a digest is set, the rendered image reference uses
`repository@digest` and ignores the tag. This makes immutable production pins
possible without making a digest mandatory for local evaluation. The schema
requires digests to match `sha256:<64 lowercase hexadecimal characters>`.

The chart never creates registry credentials. Offline and private-registry
installations provide an existing image pull Secret and may override the image
repository with their mirror.

## Runtime and security

The Deployment uses the image's unprivileged runtime and applies these defaults:

- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- all Linux capabilities dropped
- `seccompProfile.type: RuntimeDefault`
- read-only root filesystem
- ServiceAccount token automount disabled

The image constructs its runtime UI under `/tmp`, so the pod mounts an
`emptyDir` at `/tmp`. This is the only writable filesystem path the chart adds.

Readiness and liveness probes both call `/healthz` on the named HTTP container
port. Readiness starts sooner than liveness so a new pod can become eligible
without being restarted during normal startup.

## Availability and resources

The default replica count is two because the UI is stateless and is expected to
remain available during ordinary rollout and node maintenance. The first chart
does not render a PodDisruptionBudget. Adding policy and values for a disruption
budget without a demonstrated operational need would expand the public contract
without improving the initial installation.

Resource requests and limits are configurable but empty by default. The chart
does not invent capacity values without measurements. It also excludes an HPA;
autoscaling belongs in a later version after measured workload signals exist.

Deployment updates use Kubernetes' rolling-update defaults. Revision history,
pod annotations, pod labels, node selection, affinity, topology spread,
tolerations, and priority class are exposed through typed values where they are
normal operational extension points.

## Values and schema

Every public value appears in `values.schema.json` with a description and type.
Unknown top-level values are rejected. User-provided labels and annotations are
allowed as string maps. Selector labels remain chart-owned and cannot be
overridden.

Template helpers provide deterministic names and standard Helm application
labels. Names are truncated to Kubernetes' 63-character DNS label limit.

## Tests and validation

The repository check remains the shared entry point. The first chart adds:

- strict `helm lint`
- default and digest-pinned template rendering
- schema rejection tests for malformed digest and invalid replica count
- kubeconform validation for every rendered case
- chart-testing lint configuration
- a kind smoke test that creates a temporary namespace, supplies a GHCR pull
  Secret from the CI token, installs the chart, waits for rollout, checks
  `/healthz`, and removes the namespace

The smoke test runs only in CI where registry credentials are available. It
requires the Infegate GHCR package to grant this repository's Actions token read
access. It performs no production or persistent cluster mutation. If package
access is not configured, the smoke job fails explicitly instead of silently
skipping the image proof.

Both check and release workflows use the repository's `CI_RUNNER` value with
`ubuntu-latest` as fallback. This keeps chart delivery available when hosted
runner billing is unavailable and exercises kind natively on the arm64 fallback
runner.

## Release and documentation

The chart README documents installation from OCI, digest pinning, probes,
security defaults, ingress route ownership, private registry mirrors, upgrades,
and rollback to a prior chart version plus image digest.

After the chart PR is merged, the operator creates tag `infegate-v0.1.0`. The
existing release workflow verifies the tag against `Chart.yaml` and publishes
`oci://ghcr.io/demirtechcom/charts/infegate:0.1.0`. No `latest` chart version is
published.

## Explicit exclusions

- agentgateway Deployment, Service, configuration, or sidecar
- Ingress or Gateway API resources
- Secrets or registry credentials
- HorizontalPodAutoscaler
- PodDisruptionBudget
- NetworkPolicy with environment-specific selectors
- Kubernetes installation or production deployment
- Helm umbrella chart
