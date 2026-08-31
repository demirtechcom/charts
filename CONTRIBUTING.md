# Contributing

## Chart conventions

- Put each chart in `charts/<chart>` and keep the directory name equal to
  `Chart.yaml`'s `name`.
- Use SemVer for `version` and the packaged application's version for
  `appVersion`.
- Include `values.schema.json`; every public value must have a schema entry and
  a useful description.
- Support immutable image digests in addition to tags.
- Keep credentials out of values and templates. Reference an existing Secret.
- Add Helm lint and template cases, kubeconform validation, chart-testing, and
  a kind smoke test before the first release.
- Document required Kubernetes capabilities and upgrade considerations in the
  chart README.

## Pull requests

Run `./scripts/check-charts.sh` and `actionlint .github/workflows/*.yaml` before
opening a pull request. A chart release is a separate tag after its pull request
is merged.
