# Infegate Helm Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a production-safe `infegate` Helm chart that installs the standalone Infegate UI Deployment and Service and can be validated on amd64 or arm64 CI runners.

**Architecture:** The chart owns only namespaced UI workload resources and exposes environment integration through typed values. Shell contract tests render the real chart and assert image, security, probe, service, and schema behavior before a kind smoke test installs the private image into a disposable cluster.

**Tech Stack:** Helm 3, Kubernetes `apps/v1` and `v1`, JSON Schema draft-07, kubeconform, chart-testing, kind, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-01-infegate-chart-design.md`

## Global Constraints

- Chart version is `0.1.0`; `appVersion` and default image tag are `1.4.1-1`.
- Render only ServiceAccount, Deployment, and Service.
- Do not render Ingress, agentgateway resources, PDB, HPA, NetworkPolicy, or Secrets.
- Default to two replicas, container port `8080`, Service port `80`, and `/healthz` probes.
- Prefer `repository@digest` whenever `image.digest` is non-empty.
- Keep the root filesystem read-only and mount an `emptyDir` only at `/tmp`.
- Use `CI_RUNNER` with `ubuntu-latest` fallback in check and release workflows.

---

### Task 1: Core chart and render contract

**Files:**
- Create: `charts/infegate/Chart.yaml`
- Create: `charts/infegate/values.yaml`
- Create: `charts/infegate/templates/_helpers.tpl`
- Create: `charts/infegate/templates/serviceaccount.yaml`
- Create: `charts/infegate/templates/deployment.yaml`
- Create: `charts/infegate/templates/service.yaml`
- Create: `charts/infegate/templates/NOTES.txt`
- Create: `scripts/test-infegate-chart.sh`

**Interfaces:**
- Consumes: Helm CLI and values under `.image`, `.service`, `.probes`, and `.serviceAccount`.
- Produces: `infegate.fullname`, `infegate.labels`, `infegate.selectorLabels`, `infegate.serviceAccountName`, and `infegate.image` template helpers plus a runnable chart contract test.

- [ ] **Step 1: Write the failing render contract**

Create `scripts/test-infegate-chart.sh` with `set -eu`. Render defaults into a temporary file and assert with `grep` that the output contains `replicas: 2`, image `ghcr.io/demirtechcom/infegate:1.4.1-1`, ports `80` and `8080`, both `/healthz` probes, `automountServiceAccountToken: false`, `readOnlyRootFilesystem: true`, and `/tmp`. Render again with `--set-string image.digest=sha256:aaaa...` and assert the digest reference is present while the tagged reference is absent. Add a trap that removes the temporary directory.

- [ ] **Step 2: Run the contract and verify it fails**

Run: `./scripts/test-infegate-chart.sh`

Expected: FAIL because `charts/infegate/Chart.yaml` does not exist.

- [ ] **Step 3: Implement chart metadata and helpers**

Create `Chart.yaml` with `apiVersion: v2`, `name: infegate`, `type: application`, `version: 0.1.0`, `appVersion: "1.4.1-1"`, and Apache-2.0 metadata. Implement helpers using standard `app.kubernetes.io/*` labels and 63-character truncation. Implement `infegate.image` as:

```gotemplate
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end -}}
```

- [ ] **Step 4: Implement Deployment, ServiceAccount, Service, and defaults**

Use a Deployment selector owned by `infegate.selectorLabels`. Set pod token automount false, pod and container security contexts, named `http` port `8080`, `/healthz` HTTP probes, resources, scheduling values, `/tmp` emptyDir, and optional pull Secrets. Render a ClusterIP Service with named port `http`, default port `80`, and target `http`. Render the ServiceAccount only when `.Values.serviceAccount.create` is true.

- [ ] **Step 5: Run the render contract**

Run: `./scripts/test-infegate-chart.sh`

Expected: PASS with no output except Helm warnings.

- [ ] **Step 6: Commit**

```bash
git add charts/infegate scripts/test-infegate-chart.sh
git commit -m "feat: add Infegate Helm chart"
```

---

### Task 2: Typed values and negative validation

**Files:**
- Create: `charts/infegate/values.schema.json`
- Modify: `scripts/test-infegate-chart.sh`
- Modify: `scripts/check-charts.sh`

**Interfaces:**
- Consumes: every public key in `charts/infegate/values.yaml`.
- Produces: a draft-07 schema that rejects unknown top-level keys, replica counts below one, malformed digests, invalid service ports, and invalid pull policies.

- [ ] **Step 1: Extend the test with failing schema cases**

Add commands that require these two renders to fail:

```sh
if helm template infegate charts/infegate --set replicaCount=0 >/dev/null 2>&1; then
  echo "replicaCount=0 must fail schema validation" >&2
  exit 1
fi
if helm template infegate charts/infegate --set-string image.digest=sha256:bad >/dev/null 2>&1; then
  echo "malformed image digest must fail schema validation" >&2
  exit 1
fi
```

- [ ] **Step 2: Run the contract and verify the negative cases fail incorrectly**

Run: `./scripts/test-infegate-chart.sh`

Expected: FAIL with `replicaCount=0 must fail schema validation` because no schema exists.

- [ ] **Step 3: Implement the values schema**

Create a draft-07 object schema with `additionalProperties: false` at the top level. Describe and type every public value. Use `minimum: 1` for replica count and service/probe numeric fields, enum `Always|IfNotPresent|Never` for pull policy, and pattern `^sha256:[a-f0-9]{64}$` for non-empty digest values. Permit the empty string with `oneOf`.

- [ ] **Step 4: Make the shared check run chart contracts**

After each chart's strict lint and kubeconform render, run `./scripts/test-${chart_name}-chart.sh` when that executable exists. Preserve the empty collection behavior.

- [ ] **Step 5: Run all local chart validation**

Run: `./scripts/test-infegate-chart.sh && ./scripts/check-charts.sh`

Expected: PASS, including strict lint, schema negative cases, and kubeconform summary with zero invalid resources.

- [ ] **Step 6: Commit**

```bash
git add charts/infegate/values.schema.json scripts/test-infegate-chart.sh scripts/check-charts.sh
git commit -m "test: enforce Infegate chart contracts"
```

---

### Task 3: CI runner fallback and disposable kind smoke proof

**Files:**
- Create: `ct.yaml`
- Create: `scripts/smoke-infegate-chart.sh`
- Modify: `.github/workflows/check.yaml`
- Modify: `.github/workflows/release.yaml`

**Interfaces:**
- Consumes: `GHCR_USERNAME`, `GHCR_TOKEN`, Docker, kind, kubectl, Helm, and the chart.
- Produces: a disposable `infegate-smoke` kind cluster and namespace proof with cleanup on every exit.

- [ ] **Step 1: Add a failing CI contract to the chart test**

Assert both workflows contain `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}`, check workflow invokes chart-testing and `scripts/smoke-infegate-chart.sh`, and release workflow remains tag-driven. Run the test and confirm it fails on the existing hosted-only runner configuration.

- [ ] **Step 2: Implement chart-testing configuration and runner fallback**

Create `ct.yaml` with `chart-dirs: [charts]`, `target-branch: main`, and strict Helm lint settings. Change both workflows to the configured fallback expression. Run chart-testing from `quay.io/helmpack/chart-testing:v3.13.0`. Install kind into `${RUNNER_TEMP}/bin` with `GOBIN="${RUNNER_TEMP}/bin" go install sigs.k8s.io/kind@v0.30.0` and append that directory to `GITHUB_PATH` before smoke.

- [ ] **Step 3: Implement the smoke script**

Create `scripts/smoke-infegate-chart.sh` with `set -eu`, unique cluster/namespace names from `GITHUB_RUN_ID` and PID, and a trap that deletes the namespace and kind cluster. Require non-empty GHCR credentials, create a `kubernetes.io/dockerconfigjson` Secret without printing the token, install the chart with `imagePullSecrets[0].name`, wait for `deployment/infegate`, port-forward Service port `80`, poll `/healthz`, and assert `/ui/` returns HTTP 200.

- [ ] **Step 4: Run static workflow checks**

Run: `actionlint .github/workflows/*.yaml && sh -n scripts/*.sh`

Expected: PASS.

- [ ] **Step 5: Run kind smoke when tooling and package permission are available**

Run: `test -n "${GHCR_USERNAME:-}" && test -n "${GHCR_TOKEN:-}" && ./scripts/smoke-infegate-chart.sh`

Expected: Deployment rollout succeeds, health and UI checks pass, and trap removes the namespace and cluster. If kind or package access is unavailable locally, leave this explicitly for PR CI rather than weakening the test.

- [ ] **Step 6: Commit**

```bash
git add ct.yaml scripts/smoke-infegate-chart.sh .github/workflows/check.yaml .github/workflows/release.yaml
git commit -m "ci: prove Infegate chart in kind"
```

---

### Task 4: Operator documentation and release readiness

**Files:**
- Create: `charts/infegate/README.md`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`

**Interfaces:**
- Consumes: chart values and the existing `infegate-v0.1.0` release contract.
- Produces: copy-paste installation, upgrade, rollback, private registry, digest pin, and ingress ownership instructions.

- [ ] **Step 1: Write documentation assertions**

Extend `scripts/test-infegate-chart.sh` to require chart README sections `Install`, `Image digest pinning`, `Ingress routing`, `Private registries and offline mirrors`, `Upgrade`, and `Rollback`.

- [ ] **Step 2: Run the contract and verify it fails**

Run: `./scripts/test-infegate-chart.sh`

Expected: FAIL because `charts/infegate/README.md` does not exist.

- [ ] **Step 3: Write operator documentation**

Document OCI install commands, the standalone Service boundary, `/ui` versus `/api` ingress routes, existing pull Secrets, repository mirror override, immutable digest values, probe behavior, security defaults, chart upgrades, and rollback to both a chart version and image digest. Update the root README to list the chart and remove the empty-collection statement.

- [ ] **Step 4: Run final verification**

Run:

```bash
./scripts/check-charts.sh
actionlint .github/workflows/*.yaml
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 5: Review the full diff and commit**

```bash
git diff --check
git status --short
git add charts/infegate/README.md README.md CONTRIBUTING.md scripts/test-infegate-chart.sh
git commit -m "docs: document Infegate chart operations"
```

---

### Task 5: Pull request delivery

**Files:**
- Modify only files required by review findings.

**Interfaces:**
- Consumes: all previous tasks and their verification evidence.
- Produces: a clean feature branch and reviewed pull request against `main`.

- [ ] **Step 1: Run fresh full verification**

Run `./scripts/check-charts.sh`, `actionlint .github/workflows/*.yaml`, and `git diff --check`. Run the kind smoke proof if its prerequisites are available.

- [ ] **Step 2: Push and open the PR**

Push `feat/infegate-chart`, open a PR against `main`, and include exact passed and unavailable checks in the body.

- [ ] **Step 3: Watch required checks**

Run `gh pr checks --watch --interval 10` and fix every failure before reporting the chart ready for merge.
