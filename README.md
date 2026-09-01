# DemirTech Helm Charts

Public Helm charts for installing DemirTech products on Kubernetes.

## Repository layout

Each chart lives at `charts/<chart>/` and owns its templates, defaults,
`values.schema.json`, tests, and documentation.

| Chart | Description |
| --- | --- |
| [Infegate](charts/infegate/README.md) | Infegate API and standalone management UI |

## Validation

```sh
./scripts/check-charts.sh
actionlint .github/workflows/*.yaml
```

The chart check discovers every `Chart.yaml`, then runs strict Helm linting,
template rendering, values schema validation, chart-specific contract tests,
and kubeconform.

## OCI releases

The Infegate GitHub Release workflow dispatches chart publication with the
verified UI digest, gateway digest, source commit, and source release identity.
Tag pushes do not publish charts. The idempotent workflow publishes to:

```text
oci://ghcr.io/demirtechcom/charts/<chart>
```

The source chart keeps image digests empty. Only the temporary packaged copy
receives release digests, and an existing artifact is never overwritten.

See [CONTRIBUTING.md](CONTRIBUTING.md) for chart conventions and checks.
