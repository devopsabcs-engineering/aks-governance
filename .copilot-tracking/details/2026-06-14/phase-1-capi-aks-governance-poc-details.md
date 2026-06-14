<!-- markdownlint-disable-file -->
# Implementation Details: Phase 1 PoC — Single-Subscription AKS Governance with CAPI/CAPZ/ASO + ArgoCD + Policy

## Context Reference

Sources:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md — primary research (architecture, file tree, risk register, readiness matrix, manifest/policy examples).
* .copilot-tracking/research/subagents/2026-06-14/capi-capz-aso-research.md — CAPZ aks-aso flavor, clusterctl, ASO auth, API version open items.
* .copilot-tracking/research/subagents/2026-06-14/argocd-policy-research.md — ArgoCD install/registration, ApplicationSet, Kyverno schema, min-version CR path.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md — sibling harness line references and wiki requirements.

## Implementation Phase 1: Repo Scaffolding and Azure Preflight

<!-- parallelizable: true -->

### Step 1.1: Create repo directory tree and placeholder structure

Create the greenfield directory layout matching the proposed tree so subsequent phases author into stable paths.

Files:
* .github/workflows/ - workflow directory (file authored in Phase 8)
* infra/ - Bicep directory
* clusters/ - per-cluster `.env` + CAPZ template directory
* gitops/bootstrap/, gitops/apps/, gitops/policies/kyverno/ - GitOps directories
* scripts/ - PowerShell automation directory
* docs/captures/, docs/screenshots/ - committed sample evidence directories
* samples/ - under-min CAPZ CR sample directory

Success criteria:
* Directory tree exists and matches the research file tree.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 337-368) - proposed repo file tree.

Dependencies:
* None.

### Step 1.2: Author scripts/preflight.ps1 Azure prerequisite checks

PowerShell 7 script that validates Azure readiness before any long-running provisioning: registered providers (`Microsoft.ContainerService`, `Microsoft.ManagedIdentity`, ASO-required RPs), region-valid AKS versions via `az aks get-versions -l <region>`, VM SKU availability via `az vm list-skus`, and core/public-IP quota. Fail fast with actionable messages. Use literal `&` (never `&amp;`) and `Select-String` (never `grep`).

Files:
* scripts/preflight.ps1 - provider, version, SKU, and quota checks.

Discrepancy references:
* Addresses DR-08 (Azure preflight gap from rubber-duck research).

Success criteria:
* Script exits non-zero with a clear message when any prerequisite is missing; exits zero when the chosen region/version/SKU/quota are usable.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 399-403) - preflight readiness-matrix row.
* .copilot-tracking/research/subagents/2026-06-14/phase-1-capi-aks-governance-poc-rubber-duck.md - improvement opportunities (preflight checks).

Dependencies:
* Step 1.1 completion.

## Implementation Phase 2: Management Cluster Infra and Bootstrap

<!-- parallelizable: true -->

### Step 2.1: Author infra/mgmt-cluster.bicep

Adapt `aks-fleet-manager/infra/main.bicep` to provision one small ephemeral management AKS cluster (single system pool, `Standard_D2s_v6` in eastus2) with OIDC issuer and Workload Identity enabled, plus a User-Assigned Managed Identity and federated credentials for CAPZ/ASO. Grant the UAMI the Azure roles ASO/CAPZ need (Contributor on the subscription or target scope). `targetScope = 'resourceGroup'`.

Files:
* infra/mgmt-cluster.bicep - management AKS + UAMI + federated creds + role assignments.

Discrepancy references:
* Addresses DD-01 (management AKS chosen over kind).

Success criteria:
* `az bicep build` succeeds; template outputs cluster name, OIDC issuer URL, and UAMI client ID.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 331-336) - Management Cluster Decision Record.
* .copilot-tracking/research/subagents/2026-06-14/capi-capz-aso-research.md - ASO authentication (workload identity) section.

Dependencies:
* Step 1.1 completion.

### Step 2.2: Author scripts/deploy-mgmt.ps1

PowerShell 7 orchestration of management-cluster bootstrap, reusing the sibling's `Connect-AzFederated` OIDC re-mint loop for the long deploy. Sequence: `az deployment group create` (Bicep) → `az aks get-credentials` → `clusterctl init --infrastructure azure` → apply the ASO credential Secret (Workload Identity federated UAMI) → `helm install argocd` → `kubectl apply -f gitops/bootstrap/root-app.yaml`. Document SP+secret as the quick fallback.

Files:
* scripts/deploy-mgmt.ps1 - deploy + clusterctl init + ASO creds + ArgoCD/Kyverno bootstrap.

Discrepancy references:
* Addresses DD-02 (Workload Identity primary; SP fallback documented).

Success criteria:
* CAPZ + ASO controllers report Available; `kubectl get crd azureasomanagedcontrolplanes.infrastructure.cluster.x-k8s.io` succeeds; ArgoCD root app is created.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 388-395) - deploy-mgmt implementation details.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md - deploy.ps1 OIDC re-mint pattern.

Dependencies:
* Step 2.1 completion; Phase 4 Step 4.1 (root-app.yaml) for the bootstrap apply target.

## Implementation Phase 3: Workload Cluster Provisioning (CAPZ aks-aso)

<!-- parallelizable: true -->

### Step 3.1: Author per-cluster .env inputs and cluster-template-aks-aso.yaml

Two `.env` files differing only by name/region, plus a checked-in CAPZ `aks-aso` template parametrized via envsubst/`clusterctl generate`. Pin a region-valid `KUBERNETES_VERSION` (confirmed in preflight). Include the `Cluster`, `AzureASOManagedControlPlane`, `AzureASOManagedCluster`, and MachinePool resources with `serviceoperator.azure.com/credential-from` annotations.

Files:
* clusters/poc-aks-1.env - `CLUSTER_NAME=poc-aks-1`, `AZURE_LOCATION=eastus2`, etc.
* clusters/poc-aks-2.env - `CLUSTER_NAME=poc-aks-2`, `AZURE_LOCATION=westus3`, else identical.
* clusters/cluster-template-aks-aso.yaml - parametrized CAPZ aks-aso template.

Discrepancy references:
* Deviates per DD-03 (pin API versions at build time rather than assume).

Success criteria:
* `clusterctl generate cluster --from clusters/cluster-template-aks-aso.yaml` renders valid YAML for both `.env` files.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 174-230) - CAPZ aks-aso manifest example.
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 295-307) - per-cluster `.env` example.
* .copilot-tracking/research/subagents/2026-06-14/capi-capz-aso-research.md - section 1.2 MachinePool details + section 8 API versions.

Dependencies:
* Step 1.1 completion.

### Step 3.2: Author scripts/provision-clusters.ps1

Loop the `.env` files: `clusterctl generate cluster --flavor aks-aso` → `kubectl apply` → wait for `Cluster` Ready → `clusterctl get kubeconfig`. Emit each workload kubeconfig for ArgoCD registration in Phase 4.

Files:
* scripts/provision-clusters.ps1 - generate + apply + wait + get kubeconfig loop.

Success criteria:
* Both CAPI `Cluster` objects reach Ready; two workload kubeconfigs are written.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 388-395) - provision-clusters implementation details.

Dependencies:
* Step 3.1 completion; Phase 2 (management cluster + CAPZ/ASO) at runtime.

## Implementation Phase 4: ArgoCD Registration and GitOps Fan-Out

<!-- parallelizable: true -->

### Step 4.1: Author gitops bootstrap and app manifests

App-of-apps root plus the Kyverno install Application (sync-wave 0) and the governance ApplicationSet (cluster generator, `matchLabels: {type: workload}`, sync-wave 1). The ApplicationSet naturally excludes the in-cluster management target.

Files:
* gitops/bootstrap/root-app.yaml - app-of-apps root.
* gitops/apps/kyverno.yaml - Application installing Kyverno via Helm.
* gitops/apps/governance-policies.yaml - ApplicationSet fanning policies to workload clusters.

Success criteria:
* `kubectl apply --dry-run=client -f` succeeds on all three manifests; ApplicationSet selector targets `type=workload`.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 412-433) - ApplicationSet manifest.
* .copilot-tracking/research/subagents/2026-06-14/argocd-policy-research.md - sections 2.2-2.3 (cluster registration + fan-out).

Dependencies:
* Step 1.1 completion.

### Step 4.2: Author scripts/register-argocd-clusters.ps1

Convert each workload kubeconfig into an ArgoCD cluster Secret labeled `argocd.argoproj.io/secret-type=cluster` and `type=workload`. Fail fast if fewer than two workload cluster Secrets are present before policy fan-out.

Files:
* scripts/register-argocd-clusters.ps1 - kubeconfig → ArgoCD cluster Secret conversion.

Discrepancy references:
* Addresses DR-03 (CAPI→ArgoCD cluster-Secret automation must be tested end-to-end).

Success criteria:
* `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster,type=workload` returns exactly two Secrets.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 405) - ArgoCD registration readiness-matrix row.
* .copilot-tracking/research/subagents/2026-06-14/argocd-policy-research.md - section 2.2 kubeconfig-to-Secret options.

Dependencies:
* Step 4.1 completion; Phase 3 (workload kubeconfigs) at runtime.

## Implementation Phase 5: Governance Policies and Demo Scripts

<!-- parallelizable: true -->

### Step 5.1: Author Kyverno policies and the under-min sample manifest

Registry-deny ClusterPolicy (Example A) over parsed `images.*.registry` for docker.io/quay.io with an MCR + ACR + `registry.k8s.io` allow-list, and the min-version ClusterPolicy (Example B) on CAPZ control-plane CRs keyed on `spec.version`. Validate the chart's `validationFailureAction` vs per-rule `validate.failureAction` (Kyverno 1.12+) at build time. Add an under-min `AzureASOManagedControlPlane` sample.

Files:
* gitops/policies/kyverno/block-docker-quay-registries.yaml - Example A.
* gitops/policies/kyverno/enforce-min-k8s-version.yaml - Example B (applied to mgmt CRs).
* samples/under-min-version.yaml - under-minimum CAPZ control-plane CR for the demo.

Discrepancy references:
* Deviates per DD-04 (verify Kyverno chart schema rather than assume `validationFailureAction`).

Success criteria:
* `kubectl apply --dry-run=client -f` succeeds on both policies; the sample sets a `spec.version` below the configured minimum.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 232-261) - Kyverno Example A.
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 263-286) - Kyverno Example B.
* .copilot-tracking/research/subagents/2026-06-14/argocd-policy-research.md - sections 5.2-5.4 (min-version CR path).

Dependencies:
* Step 1.1 completion.

### Step 5.2: Author demo-registry.ps1 (Example A) and demo-min-version.ps1 (Example B)

Demo A: in `governance-demo`, apply a docker.io `nginx` Pod and a `quay.io` test Pod (both blocked), then an `mcr.microsoft.com` Pod (admitted); capture each result. Demo B: apply `samples/under-min-version.yaml` to the management cluster and capture the admission rejection mentioning the minimum version. Both scripts capture deterministic CLI text for the wiki.

Files:
* scripts/demo-registry.ps1 - Example A apply + capture.
* scripts/demo-min-version.ps1 - Example B apply + capture.

Success criteria:
* docker.io/quay.io Pods are denied, mcr Pod is admitted; under-min CR is rejected with the minimum version in the message.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 388-395) - demo narrative (Audit→Enforce).

Dependencies:
* Step 5.1 completion; Phases 2-4 at runtime.

## Implementation Phase 6: Evidence Capture and Wiki Publishing

<!-- parallelizable: true -->

### Step 6.1: Adapt capture.ps1 and author capture-argocd.ts

Reuse the sibling's two-leg evidence model: deterministic CLI `.txt` (`tee` of `kubectl`/`clusterctl`/`az` output) + best-effort Playwright `.png`. Replace Fleet deep-links with ArgoCD UI + AKS/portal deep-links. Reuse the git-ignored `storage_state.json` pattern.

Files:
* scripts/capture.ps1 - CLI text + Playwright orchestration (adapted from sibling).
* docs/capture-argocd.ts - Playwright ArgoCD UI + portal screenshots.

Success criteria:
* Capture produces at least one `.txt` and one `.png` per success criterion (mgmt health, ArgoCD sync, registry deny, min-version denial, teardown).

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 409) - evidence capture readiness-matrix row.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md - capture.ps1 + capture-fleet.ts two-leg model.

Dependencies:
* Step 1.1 completion.

### Step 6.2: Reuse publish-wiki.ps1 and add a publish preflight

Reuse the sibling's `publish-wiki.ps1` near-verbatim (interleave text+png by base name, Mermaid + TOC, `https://PAT@host` bash macro auth). Add a preflight that verifies the GitHub wiki (or ADO project wiki) target exists and `WIKI_PAT` has Code (Read & write) scope before publishing.

Files:
* scripts/publish-wiki.ps1 - reused wiki publisher.
* scripts/publish-wiki-preflight.ps1 (or inline preflight) - verify wiki target + PAT scope.

Discrepancy references:
* Addresses DR-06 (confirm wiki publish target + PAT).

Success criteria:
* Preflight reports an enabled wiki target and a usable PAT; publish step generates interleaved markdown.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 108-109) - wiki publish risk + mitigation.
* User memory — ADO wiki git auth via bash + `https://PAT@host`; `WIKI_PAT` needs Code (Read & write).

Dependencies:
* Step 6.1 completion.

## Implementation Phase 7: Cost-Safe Teardown

<!-- parallelizable: true -->

### Step 7.1: Author scripts/teardown.ps1 with CAPI-ordered deletion

Extend the sibling's single-RG teardown with mandatory ordering: `kubectl delete cluster poc-aks-1 poc-aks-2` (cascades CAPI→CAPZ→ASO→Azure RG deletion), poll until both workload RGs are gone, then `az group delete --name rg-aksgov-poc-mgmt --yes --no-wait`. Capture verification output.

Files:
* scripts/teardown.ps1 - ordered workload-then-management deletion.

Discrepancy references:
* Addresses the orphaned-billing risk (management cluster must not be destroyed first).

Success criteria:
* Workload RGs are confirmed deleted before the management RG deletion is issued.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 325-330) - teardown ordering rationale.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md - teardown.ps1 single-RG baseline.

Dependencies:
* Step 1.1 completion.

## Implementation Phase 8: Pipeline Orchestration

<!-- parallelizable: false -->

### Step 8.1: Author .github/workflows/aksgov-poc-demo.yml

Mirror `fleet-poc-demo.yml`: `permissions: id-token: write`; `concurrency: aksgov-poc-<rg>`; `workflow_dispatch` inputs (`resourceGroup` default `rg-aksgov-poc-mgmt`, `location` default `eastus2`, `minK8sVersion` default `v1.28.0`, `kubernetesVersion`, booleans `runCapture`/`publishWiki`/`auditFirst`). Jobs in order: `preflight` → `deploy-mgmt` → `provision` → `register-argocd` → `demo-registry` → `demo-min-version` → `capture` → `publish-wiki` → `teardown`. Teardown job `if: always() && needs.deploy-mgmt.result=='success'` behind `environment: aksgov-poc-teardown`. Failed demo jobs still upload diagnostic artifacts.

Files:
* .github/workflows/aksgov-poc-demo.yml - full pipeline wiring all scripts.

Success criteria:
* `actionlint` passes; job graph matches the research flowchart; teardown is approval-gated and always-run-on-deploy-success.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 370-395) - flowchart + pipeline implementation details.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md - fleet-poc-demo.yml job line references.

Dependencies:
* Phases 1-7 completion (all referenced scripts/manifests exist).

### Step 8.2: Author README/runbook for the PoC

Document required secrets, the `aksgov-poc-teardown` GitHub Environment, wiki target setup, the Audit→Enforce demo narrative, and the customer-demo walkthrough. Keep it customer-demoable.

Files:
* README updates or docs/runbook.md - PoC operation + demo guide.

Success criteria:
* A reader can configure secrets/environment and run the pipeline end-to-end from the runbook.

Context references:
* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 308) - GitHub OIDC + secrets/Environment.

Dependencies:
* Step 8.1 completion.

## Implementation Phase 9: Validation

<!-- parallelizable: false -->

### Step 9.1: Run static validation on all authored artifacts

Execute static checks that do not require a live cluster:
* `az bicep build --file infra/mgmt-cluster.bicep`
* `pwsh -NoProfile -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/<each>.ps1', [ref]$null, [ref]$null)"` for every script
* `kubectl apply --dry-run=client -f <file>` for every YAML manifest
* `actionlint` (or `yamllint`) on `.github/workflows/aksgov-poc-demo.yml`

### Step 9.2: Fix minor validation issues

Iterate on Bicep warnings, PowerShell parse errors, YAML schema issues, and workflow lint findings. Apply straightforward, isolated corrections directly.

### Step 9.3: Report blocking issues

When validation surfaces issues requiring live-cluster execution or external confirmation (CAPZ/ASO API version drift, region-valid AKS version, Kyverno chart schema, wiki target), document them and provide next steps. Avoid large-scale refactoring inline.

## Dependencies

* Azure CLI + Bicep, `kubectl`, `clusterctl`, `helm`, PowerShell 7, Node.js + Playwright, `actionlint`.
* GitHub OIDC federation + `WIKI_PAT`; `aksgov-poc-teardown` GitHub Environment.

## Success Criteria

* All authored artifacts pass static validation (Bicep build, PowerShell parse, YAML dry-run, workflow lint).
* The pipeline job graph and teardown ordering match the research-defined architecture and success criteria.
