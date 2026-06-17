---
title: Phase 1 CAPI AKS Governance PoC Research Critique
description: Rubber-duck review of the Phase 1 CAPI AKS governance PoC research document
author: GitHub Copilot
ms.date: 2026-06-14
ms.topic: research
---

## Research Topics

* Inspect `.copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md` as an implementation-ready Phase 1 PoC artifact.
* Verify claims against the local workspace where possible, especially `README.md` and `assets/`.
* Identify gaps, contradictions, missing evidence, weak alternatives analysis, unclear success criteria, and implementation risks.
* Recommend exact sections or text to add or revise.

## Workspace Evidence

* `README.md` supports the strategic context: single subscription is only a tactical bootstrap, multi-subscription ODS is the recommended end state, AKS and ARO governance are asymmetric, and AKS uses Argo CD plus CAPZ/ASO for GitOps and declarative lifecycle.
* `assets/` contains four binary Office deliverables and no directly readable implementation assets: `ACME_Gouvernance_Kubernetes_Rapport_FR.docx`, `ACME_Gouvernance_Kubernetes_Synthese_Executive_FR.pptx`, `ACME_Kubernetes_Governance_Executive_Summary.pptx`, and `Kubernetes Cluster Management Solutions.docx`.
* The target repo is otherwise greenfield for implementation: no `.github/workflows`, `infra`, `scripts`, `gitops`, Bicep, Terraform, or Kubernetes manifests were present in the initial workspace listing and supporting repo-analysis note.
* The research document relies on sibling `aks-fleet-manager` patterns. That sibling evidence is captured in `repos-analysis-research.md`, not in the target workspace itself.

## Document Status

Status: Strong draft, not yet implementation-ready.

The document is directionally coherent and has enough architecture detail to start a plan, but it still mixes validated facts, design decisions, assumptions, and untested implementation details. The highest-risk gaps are date-sensitive CAPZ/ASO schema pins, unproven workload cluster registration into Argo CD, unclear management-cluster decision rationale compared with the CAPI subagent recommendation, and success criteria that are observable but not fully measurable.

## Strongest Sections

* The scope and assumptions section is clear about Phase 1 boundaries and deliberately limits ARO, multi-subscription, HA Argo CD, private clusters, and custom networking.
* The sibling Fleet Manager harness mapping is useful and concrete: workflow dispatch, OIDC, concurrency, artifact handling, capture, wiki publishing, and approval-gated teardown.
* The policy-engine comparison is strong: Kyverno is justified by readability, image parsing, GitOps fit, semver support, and demo immediacy.
* The teardown warning is crucial and should remain prominent: deleting the management cluster before deleting CAPI Cluster objects can orphan AKS resources and keep billing alive.
* The proposed file tree is a practical bridge from research to implementation.

## Improvement Opportunities

1. Reconcile the management-cluster recommendation conflict. The CAPI subagent recommended kind for a teardownable pipeline, while the main document selects ephemeral AKS. Both are defensible, but the main document should explicitly acknowledge the conflict and define why customer-demoability and Workload Identity simplicity outweigh extra cost and bootstrap time.
2. Separate verified workspace facts from design assumptions. The README does not define Phase 1, two workload clusters, Kyverno, wiki proof, or GitHub Actions. These are derived implementation decisions. Label them as decisions, not repo facts.
3. Add an implementation readiness matrix with owners, validation command, expected output, and evidence artifact for every major step. Current success criteria are useful but not enough for a developer to know exactly what to build and prove.
4. Replace date-sensitive hard pins with validation steps. CAPZ ASO API versions, ASO service account subjects, Kyverno policy schema, and AKS Kubernetes versions must be checked at pipeline runtime or before implementation.
5. Expand the Argo CD cluster-registration design. The current text names kubeconfig-to-Secret automation but does not define the concrete service account, token handling, RBAC, Secret schema, failure handling, or rotation strategy.
6. Tighten the governance examples around namespaces and add-on safety. Blocking docker.io and quay.io can break common add-ons. The document needs explicit test namespaces, exclusions if any, allowed registries, and demo image choices that will not rely on denied registries.
7. Define minimum Kubernetes version behavior more precisely. The document should specify whether the demo rejects a new invalid cluster, rejects an update to an existing CR, or audits existing CRs. It should also include the exact CR kind and field after CRD validation.
8. Add Azure prerequisite and quota checks. Three AKS clusters in one subscription can fail because of regional quotas, provider registration, VM SKU availability, public IP quotas, or identity/RBAC gaps.
9. Clarify wiki target readiness. The research says wiki publishing is required, but the target repo wiki existence and token permissions are not confirmed.
10. Parse the binary assets before finalizing customer framing. The README is a summary, and the assets may contain phased roadmap details or customer success language that should shape the PoC.

## Exact Text To Add Or Revise

### Add After Scope And Success Criteria

```markdown
### Evidence Classification

* Verified in `aks-governance`: the repo is documentation-only today; `README.md` positions single subscription as a tactical bootstrap and multi-subscription ODS as the strategic destination; AKS governance is distinct from ARO/Arc governance; Argo CD plus CAPZ/ASO is the AKS lifecycle and GitOps pattern.
* Verified in sibling `aks-fleet-manager`: the deploy, demo, capture, publish-wiki, and approval-gated teardown harness exists and is reusable as a delivery pattern.
* Phase 1 design decisions introduced by this research: GitHub Actions for `aks-governance`, two workload AKS clusters, Kyverno as primary admission policy engine, management AKS rather than kind, Argo CD ApplicationSet fan-out, and wiki proof as the customer-demo deliverable.
* Not yet verified: CAPZ bundled ASO version, exact `aks-aso` template API versions, ASO/CAPZ service account names for Workload Identity, current AKS supported versions in target regions, GitHub wiki availability, and binary asset roadmap alignment.
```

### Add To The Preferred Approach Section

```markdown
#### Management cluster decision record

The CAPI quick-start path favors kind because it is fully ephemeral and low cost. This PoC selects an ephemeral AKS management cluster instead for three reasons: AKS provides a native OIDC issuer for Workload Identity, Argo CD can be captured through a stable live endpoint during the customer demo, and the approach better matches the README's Azure-native ODS direction. The tradeoff is higher runtime cost and longer bootstrap time per pipeline run. The pipeline must therefore include quota checks, explicit teardown ordering, and a manual approval gate before resource deletion.

Option B remains kind. Use it only if cost is prioritized over live Argo CD screenshots and Workload Identity simplicity, and document the added JWKS/OIDC bootstrap work.
```

### Add A New Implementation Readiness Matrix

```markdown
### Implementation Readiness Matrix

| Capability | Build artifact | Validation command | Expected evidence |
| --- | --- | --- | --- |
| Management AKS | `infra/mgmt-cluster.bicep`, `scripts/deploy-mgmt.ps1` | `az aks show -g rg-aksgov-poc-mgmt -n <mgmtName>` | AKS exists, OIDC issuer enabled, workload identity enabled |
| CAPI/CAPZ/ASO controllers | `scripts/deploy-mgmt.ps1` | `kubectl get deployments -n capz-system` and `kubectl get crd azureasomanagedcontrolplanes.infrastructure.cluster.x-k8s.io` | Controllers available and CRDs served |
| Workload clusters | `clusters/*.env`, `scripts/provision-clusters.ps1` | `kubectl get clusters -A` and `clusterctl describe cluster <name>` | Both clusters Ready, kubeconfig secrets present |
| Argo CD registration | `scripts/register-argocd-clusters.ps1` or Kubernetes Job | `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster,type=workload` | Two workload cluster Secrets with reachable API servers |
| Policy fan-out | `gitops/apps/governance-policies.yaml` | `argocd app list` and `kubectl --context <workload> get clusterpolicy` | Policy Application per workload cluster is Synced and Healthy |
| Registry deny | `gitops/policies/kyverno/block-docker-quay-registries.yaml` | `kubectl run denied-nginx --image=nginx -n governance-demo` | Admission denial mentions docker.io or blocked registry |
| Minimum version | `gitops/policies/kyverno/enforce-min-k8s-version.yaml` | `kubectl apply -f samples/under-min-version.yaml` | Admission denial mentions minimum Kubernetes version |
| Teardown | `scripts/teardown.ps1` | `kubectl delete cluster <name>` then `az group show -n <workloadRg>` | Workload RGs deleted before management RG deletion |
```

### Revise Success Criteria

Replace broad criteria with measurable acceptance tests:

```markdown
* A single `workflow_dispatch` run completes through capture with all non-teardown jobs green, or failed demo steps still upload diagnostic artifacts.
* The management AKS cluster has OIDC issuer and Workload Identity enabled, and CAPZ plus ASO controllers report Available.
* Exactly two CAPI `Cluster` objects reach Ready, and both generated AKS clusters are accessible with `clusterctl get kubeconfig`.
* Argo CD has exactly two workload cluster Secrets labeled `type=workload`, and the governance ApplicationSet creates one healthy policy Application per workload cluster.
* In namespace `governance-demo`, `kubectl run denied-nginx --image=nginx` and a `quay.io` test image are rejected, while the selected `mcr.microsoft.com` test image is admitted.
* Applying an under-minimum `AzureASOManagedControlPlane` sample to the management cluster is rejected at admission with the configured minimum version in the error message.
* Capture artifacts include at least one CLI text file and one screenshot for management cluster health, Argo CD sync state, registry-deny evidence, min-version denial, and teardown verification.
* Teardown first deletes CAPI workload `Cluster` objects, waits until workload resource groups are gone, and only then deletes `rg-aksgov-poc-mgmt`.
```

### Add A Risk Register

```markdown
### Implementation Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| CAPZ/ASO API versions drift | Generated manifests fail to apply | Fetch or validate `cluster-template-aks-aso.yaml` during implementation and pin known-good versions in the repo |
| AKS version unavailable in region | Workload cluster creation fails | Run `az aks get-versions -l <region>` before provisioning and select a supported patch version |
| Argo CD cluster registration incomplete | Policies never reach workload clusters | Implement and test kubeconfig-to-Argo-Secret conversion before policy work; fail fast if two cluster Secrets are not present |
| Deny policy blocks system add-ons | Cluster add-ons or demo apps fail | Limit tests to `governance-demo`, include known allowed registries, and document namespace exclusions deliberately |
| Management cluster destroyed first | Workload AKS clusters orphan and continue billing | Teardown script must delete CAPI Cluster objects, wait for workload RG deletion, then delete management RG |
| Wiki target or PAT missing | Demo proof is not published | Add preflight check for GitHub wiki/ADO wiki target and token scope before the publish job |
| Subscription quota/SKU limits | Pipeline fails after long provisioning | Add preflight checks for VM SKU, regional core quota, public IP quota, and provider registration |
```

## Recommended Next Research

* Parse the four Office files in `assets/` to extract any Phase 1 roadmap, customer wording, or success metrics hidden outside `README.md`.
* Validate current CAPZ `aks-aso` template content and bundled ASO version for the implementation date.
* Run a small spike for Argo CD cluster registration from a CAPZ-generated kubeconfig Secret to a labeled Argo CD cluster Secret.
* Confirm target subscription quotas, supported AKS versions, resource provider registration, and VM SKU availability for `eastus2` and the second region.
* Confirm the `devopsabcs-engineering/aks-governance` wiki target and PAT scope before making wiki publishing a hard success criterion.
* Validate Kyverno chart version and policy schema, especially `validationFailureAction` versus rule-level `failureAction` syntax.

## Clarifying Questions

* Should customer-demoability and stable Argo CD screenshots remain more important than minimizing management cluster cost?
* Is GitHub wiki definitely the proof target, or should the implementation keep ADO wiki as the primary customer-facing publishing path?
* Should Phase 1 intentionally avoid ARO entirely, or include a short non-goal note explaining how ARO/Arc governance will be handled in Phase 2?
