---
applyTo: '.copilot-tracking/changes/2026-06-14/phase-1-capi-aks-governance-poc-changes.md'
---
<!-- markdownlint-disable-file -->
# Implementation Plan: Phase 1 PoC — Single-Subscription AKS Governance with CAPI/CAPZ/ASO + ArgoCD + Policy

## Overview

Author a greenfield, customer-demoable Phase 1 PoC in `aks-governance` that mirrors the `aks-fleet-manager` delivery harness: a single `workflow_dispatch` pipeline provisions an ephemeral management AKS cluster running CAPI/CAPZ/ASO + ArgoCD + Kyverno, declaratively creates 2 workload AKS clusters from input YAML, proves two governance controls (deny `docker.io`/`quay.io`; enforce a minimum Kubernetes version), captures CLI + screenshot evidence to a wiki, and tears everything down behind an approval gate.

## Objectives

### User Requirements

* Create a Phase 1 PoC in `aks-governance` on a single Azure subscription able to host a couple of AKS clusters — Source: research Task Implementation Requests (Lines 8-15).
* Provision a management cluster and use CAPI/CAPZ/ASO to create 2 workload AKS clusters from input YAMLs — Source: research Task Implementation Requests (Lines 8-15).
* Install ArgoCD and bootstrap GitOps onto the clusters — Source: research Task Implementation Requests (Lines 8-15).
* Demonstrate denying container images from `docker.io` and `quay.io` — Source: research Task Implementation Requests (Lines 8-15).
* Demonstrate imposing a minimum Kubernetes version — Source: research Task Implementation Requests (Lines 8-15).
* Mirror the `aks-fleet-manager` pipeline-driven approach with cost-saving teardown — Source: research Task Implementation Requests (Lines 8-15).
* Provide proof via wiki screenshots; deliverable must be customer-demoable — Source: research Task Implementation Requests (Lines 8-15).

### Derived Objectives

* Add an Azure preflight gate (providers, AKS versions, SKUs, quotas) before provisioning — Derived from: research Implementation Risk Register + Potential Next Research (subscription quota/SKU risk).
* Register CAPZ workload clusters into ArgoCD via a kubeconfig-to-Secret step so policy fan-out has a target — Derived from: research Key Discoveries + Implementation Readiness Matrix (ArgoCD registration is the policy linchpin).
* Enforce strict teardown ordering (delete CAPI `Cluster` objects, wait for workload RGs, then delete management RG) to prevent orphaned billing — Derived from: research Success Criteria + Preferred Approach.
* Run policies Audit-first, then flip to Enforce, to produce a before/after demo narrative — Derived from: research assumptions 12 + Demo narrative.

## Context Summary

### Project Files

* aks-governance/README.md - Strategic positioning (single-subscription tactical bootstrap vs multi-subscription ODS); AKS=`managedClusters` vs ARO/Arc=`connectedClusters` asymmetry; sets Phase 1 framing.
* aks-governance/ (tree) - Documentation-only today; entire PoC (infra, scripts, pipeline, gitops, manifests) is greenfield and must be authored fresh.

### References

* .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md - Primary research: selected architecture, file tree, risk register, readiness matrix, complete manifest/policy examples.
* .copilot-tracking/research/subagents/2026-06-14/capi-capz-aso-research.md - CAPZ `aks-aso` flavor, `clusterctl init/generate`, ASO authentication, kind alternative, API version open items.
* .copilot-tracking/research/subagents/2026-06-14/argocd-policy-research.md - ArgoCD install + cluster registration, ApplicationSet cluster generator, Kyverno policy schema, min-version CR path.
* .copilot-tracking/research/subagents/2026-06-14/repos-analysis-research.md - `aks-fleet-manager` harness line references (workflow jobs, deploy/capture/publish-wiki/teardown scripts), wiki publish requirements.
* .copilot-tracking/research/subagents/2026-06-14/phase-1-capi-aks-governance-poc-rubber-duck.md - Preflight and improvement opportunities feeding the risk register.

### Sibling Repo Blueprint (read-only reference)

* aks-fleet-manager/.github/workflows/fleet-poc-demo.yml - Job topology, OIDC permissions, concurrency, approval-gated teardown pattern to mirror.
* aks-fleet-manager/infra/main.bicep - AKS Bicep loop + cost toggles + eastus2 VM-size note to adapt for the management cluster.
* aks-fleet-manager/scripts/deploy.ps1 - `Connect-AzFederated` OIDC re-mint loop for long deploys; async deployment + poll pattern.
* aks-fleet-manager/scripts/capture.ps1 + docs/capture-fleet.ts + scripts/publish-wiki.ps1 - Two-leg evidence model + wiki interleave to reuse near-verbatim.
* aks-fleet-manager/scripts/teardown.ps1 - Single-RG teardown to extend with CAPI-ordered deletion.

### Standards References

* aks-fleet-manager conventions — `rg-*-poc` naming, `eastus2`, GitHub OIDC secrets (`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID` + `WIKI_PAT`), approval-gated `*-teardown` GitHub Environment, pwsh 7 scripts.
* User memory — literal `&` (not `&amp;`) in pwsh; `Select-String` not `grep`; ADO wiki git auth via bash + `https://PAT@host` macro substitution; `WIKI_PAT` needs Code (Read & write).

## Implementation Checklist

### [ ] Implementation Phase 1: Repo Scaffolding and Azure Preflight

<!-- parallelizable: true -->

* [ ] Step 1.1: Create repo directory tree and placeholder structure
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 16-37)
* [ ] Step 1.2: Author `scripts/preflight.ps1` Azure prerequisite checks
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 38-59)

### [ ] Implementation Phase 2: Management Cluster Infra and Bootstrap

<!-- parallelizable: true -->

* [ ] Step 2.1: Author `infra/mgmt-cluster.bicep` (ephemeral AKS + UAMI + federated creds + OIDC/Workload Identity)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 62-81)
* [ ] Step 2.2: Author `scripts/deploy-mgmt.ps1` (deploy Bicep, get-credentials, `clusterctl init`, ASO creds Secret, ArgoCD + Kyverno bootstrap)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 82-103)

### [ ] Implementation Phase 3: Workload Cluster Provisioning (CAPZ aks-aso)

<!-- parallelizable: true -->

* [ ] Step 3.1: Author per-cluster `.env` inputs and checked-in `cluster-template-aks-aso.yaml`
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 106-128)
* [ ] Step 3.2: Author `scripts/provision-clusters.ps1` (loop `.env` → `clusterctl generate` → apply → wait → get kubeconfig)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 129-146)

### [ ] Implementation Phase 4: ArgoCD Registration and GitOps Fan-Out

<!-- parallelizable: true -->

* [ ] Step 4.1: Author `gitops/bootstrap/root-app.yaml` and `gitops/apps/{kyverno.yaml,governance-policies.yaml}`
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 149-167)
* [ ] Step 4.2: Author `scripts/register-argocd-clusters.ps1` (kubeconfig → ArgoCD cluster Secret labeled `type=workload`)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 168-189)

### [ ] Implementation Phase 5: Governance Policies and Demo Scripts

<!-- parallelizable: true -->

* [ ] Step 5.1: Author Kyverno policies and the under-min sample manifest
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 192-214)
* [ ] Step 5.2: Author `scripts/demo-registry.ps1` (Example A) and `scripts/demo-min-version.ps1` (Example B)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 215-233)

### [ ] Implementation Phase 6: Evidence Capture and Wiki Publishing

<!-- parallelizable: true -->

* [ ] Step 6.1: Adapt `scripts/capture.ps1` + author `docs/capture-argocd.ts` (CLI text + ArgoCD/portal screenshots)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 236-253)
* [ ] Step 6.2: Reuse `scripts/publish-wiki.ps1` from sibling and add a publish preflight
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 254-278)

### [ ] Implementation Phase 7: Cost-Safe Teardown

<!-- parallelizable: true -->

* [ ] Step 7.1: Author `scripts/teardown.ps1` with CAPI-ordered deletion
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 279-300)

### [ ] Implementation Phase 8: Pipeline Orchestration

<!-- parallelizable: false -->

* [ ] Step 8.1: Author `.github/workflows/aksgov-poc-demo.yml` wiring all jobs (deploy → bootstrap → provision → demo-A → demo-B → capture → publish-wiki → approval-gated teardown)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 303-319)
* [ ] Step 8.2: Author README/runbook for the PoC (inputs, secrets, GitHub Environment, demo narrative)
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 320-337)

### [ ] Implementation Phase 9: Validation

<!-- parallelizable: false -->

* [ ] Step 9.1: Run static validation on all authored artifacts
  * Run `az bicep build --file infra/mgmt-cluster.bicep`, `pwsh -NoProfile -Command "..."` syntax parse of every `scripts/*.ps1`, `kubectl apply --dry-run=client -f` on every YAML manifest, and `actionlint`/`yamllint` on the workflow
  * Details: .copilot-tracking/details/2026-06-14/phase-1-capi-aks-governance-poc-details.md (Lines 340-356)
* [ ] Step 9.2: Fix minor validation issues
  * Iterate on lint errors, Bicep warnings, and YAML schema issues; apply straightforward corrections directly
* [ ] Step 9.3: Report blocking issues
  * Document any failures requiring live-cluster validation or additional research (e.g., CAPZ/ASO API version drift, region-valid AKS version) and provide next steps rather than large-scale inline fixes

## Planning Log

See `.copilot-tracking/plans/logs/2026-06-14/phase-1-capi-aks-governance-poc-log.md` for discrepancy tracking, implementation paths considered, and suggested follow-on work.

## Dependencies

* GitHub Actions with OIDC federation to Azure (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` secrets) and `WIKI_PAT` with Code (Read & write).
* Azure subscription with contributor + RBAC admin rights; quota for ~3 AKS clusters in the chosen region(s).
* Tooling on the runner: Azure CLI + Bicep, `kubectl`, `clusterctl`, `helm`, PowerShell 7, Node.js + Playwright.
* CAPI/CAPZ/ASO providers (`clusterctl init --infrastructure azure`); Kyverno + ArgoCD Helm charts.
* GitHub Environment `aksgov-poc-teardown` with required reviewers; a wiki publish target (GitHub wiki or ADO project wiki).

## Success Criteria

* A single `workflow_dispatch` run completes through capture with all non-teardown jobs green, or failed demo steps still upload diagnostic artifacts — Traces to: research Success Criteria.
* Management AKS cluster has OIDC issuer + Workload Identity enabled; CAPZ and ASO controllers report Available — Traces to: research Success Criteria + Readiness Matrix.
* Exactly two CAPI `Cluster` objects reach Ready and both AKS clusters are reachable via `clusterctl get kubeconfig` — Traces to: research Success Criteria.
* ArgoCD has exactly two workload cluster Secrets labeled `type=workload`; the governance ApplicationSet creates one healthy policy Application per workload cluster — Traces to: research Success Criteria.
* In `governance-demo`, `nginx` (docker.io) and a `quay.io` image are rejected while the selected `mcr.microsoft.com` image is admitted — Traces to: research Success Criteria.
* Applying an under-minimum `AzureASOManagedControlPlane` sample is rejected at admission with the configured minimum version in the error message — Traces to: research Success Criteria.
* Capture artifacts include at least one CLI text file and one screenshot for mgmt health, ArgoCD sync, registry deny, min-version denial, and teardown verification — Traces to: research Success Criteria.
* Teardown deletes CAPI workload `Cluster` objects first, waits until workload RGs are gone, then deletes `rg-aksgov-poc-mgmt` — Traces to: research Success Criteria.
