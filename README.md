# DemirTech Helm Charts

Public Helm charts for installing DemirTech products on Kubernetes.

## Repository layout

Each chart lives at `charts/<chart>/` and owns its templates, defaults,
`values.schema.json`, tests, and documentation.

| Chart | Description |
| --- | --- |
| [Infegate](charts/infegate/README.md) | Standalone Infegate web interface |

## Validation

```sh
./scripts/check-charts.sh
actionlint .github/workflows/*.yaml
```

The chart check discovers every `Chart.yaml`, then runs strict Helm linting,
template rendering, values schema validation, chart-specific contract tests,
and kubeconform.

## OCI releases

Push a tag named `<chart>-v<chart-version>` after the matching chart version is
merged. The release workflow publishes only that chart to:

```text
oci://ghcr.io/demirtechcom/charts/<chart>
```

For example, `infegate-v0.1.0` publishes
`ghcr.io/demirtechcom/charts/infegate:0.1.0`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for chart conventions and checks.
