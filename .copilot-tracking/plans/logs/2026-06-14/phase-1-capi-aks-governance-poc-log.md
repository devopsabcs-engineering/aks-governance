<!-- markdownlint-disable-file -->
# Planning Log: Phase 1 PoC — Single-Subscription AKS Governance with CAPI/CAPZ/ASO + ArgoCD + Policy

## Discrepancy Log

Gaps and differences identified between research findings and the implementation plan.

### Unaddressed Research Items

* DR-01: Confirm the exact ASO `containerservice.azure.com/v1apiYYYYMMDD` date and bundled ASO version for the current CAPZ release.
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 75-77) + subagent capi-capz-aso-research.md section 8.
  * Reason: API versions are date-sensitive and the flavor template evolves; deferred to build-time fetch in Phase 3 Step 3.1 rather than pinned now.
  * Impact: medium
* DR-02: Pin a region-valid AKS `KUBERNETES_VERSION` via `az aks get-versions` for the chosen region(s).
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 87-89).
  * Reason: Handled at runtime by the Phase 1 preflight script; a concrete value cannot be committed statically without drift risk.
  * Impact: medium
* DR-03: Decide/test the CAPI→ArgoCD cluster-Secret automation end-to-end.
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 81-83).
  * Reason: Planned in Phase 4 Step 4.2 (kubeconfig→Secret script) but full end-to-end behavior is only verifiable against live clusters.
  * Impact: high
* DR-04: Confirm the precise `spec.version` JSON path on `AzureASOManagedControlPlane` for the deployed API version.
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 84-86).
  * Reason: The min-version Kyverno policy keys on this path; verified at build time in Phase 5 Step 5.1.
  * Impact: medium
* DR-05: Verify Kyverno chart version and whether `validationFailureAction` is replaced by per-rule `validate.failureAction` (Kyverno 1.12+).
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 78-80) + subagent argocd-policy-research.md.
  * Reason: Schema must match the installed chart; addressed in Phase 5 Step 5.1 at build time.
  * Impact: medium
* DR-06: Confirm a wiki publish target exists for `devopsabcs-engineering/aks-governance` (GitHub wiki enabled, or ADO project wiki).
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 93-95).
  * Reason: Addressed by the Phase 6 Step 6.2 publish preflight, but the actual target/PAT must be provisioned by the operator.
  * Impact: low
* DR-07: Parse the binary `assets/*.docx`/`*.pptx` for any concrete phased roadmap the README omits.
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 90-92).
  * Reason: Out of implementation scope; Phase 1 framing already established. Tracked as follow-on (WI-03).
  * Impact: low
* DR-08: Add Azure preflight checks (provider registration, regional VM SKU availability, AKS supported versions, public IP + core quota) before provisioning.
  * Source: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 96-98) + subagent phase-1-capi-aks-governance-poc-rubber-duck.md improvement opportunities.
  * Reason: Addressed by the Phase 1 Step 1.2 preflight script, but live provider/SKU/quota state can only be confirmed at runtime against the target subscription; details Step 1.2 previously mis-referenced this item as "DR-07".
  * Impact: medium

### Plan Deviations from Research

* DD-01: Management cluster uses ephemeral AKS rather than the upstream-default kind.
  * Research recommends: CAPI quick-start defaults to kind for zero standing cost.
  * Plan implements: Bicep-provisioned ephemeral AKS management cluster (Phase 2).
  * Rationale: Native OIDC issuer for Workload Identity, stable live ArgoCD endpoint for demo screenshots, mirrors sibling Bicep pattern, aligns with README ODS direction. See IP-01.
* DD-02: Authentication uses Workload Identity (federated UAMI) as primary, SP+secret as documented fallback.
  * Research recommends: both are valid; Workload Identity preferred.
  * Plan implements: federated UAMI primary in Phase 2 Step 2.2, SP fallback documented.
  * Rationale: Avoids long-lived secrets; OIDC issuer on management AKS makes it low-friction.
* DD-03: CAPZ/ASO API versions are fetched/validated at build time rather than committed as fixed values.
  * Research recommends: re-fetch `cluster-template-aks-aso.yaml` at build time (DR-01).
  * Plan implements: Phase 3 Step 3.1 renders from a checked-in template but validates API versions during implementation.
  * Rationale: Date-sensitive API versions drift; build-time validation prevents stale manifests.
* DD-04: Kyverno policy schema (`validationFailureAction` vs per-rule `validate.failureAction`) is verified against the installed chart before finalizing policies.
  * Research recommends: confirm chart schema (DR-05).
  * Plan implements: Phase 5 Step 5.1 validates schema at build time.
  * Rationale: Kyverno 1.12+ changed the failure-action location; policies must match the deployed chart.

## Implementation Paths Considered

### Selected: Ephemeral AKS management cluster + CAPZ aks-aso + ArgoCD + Kyverno, single subscription

* Approach: Per-run Bicep-provisioned management AKS hosting CAPI/CAPZ/ASO + ArgoCD + Kyverno; 2 workload AKS clusters via CAPZ aks-aso flavor; policy fan-out via ArgoCD ApplicationSet; approval-gated teardown.
* Rationale: Native OIDC/Workload Identity, live demoable ArgoCD, mirrors the sibling harness the user asked to follow, closest to the README's Azure-native ODS direction.
* Evidence: .copilot-tracking/research/2026-06-14/phase-1-capi-aks-governance-poc-research.md (Lines 319-336).

### IP-01: kind management cluster on the runner

* Approach: Fully ephemeral kind cluster on the GitHub runner hosting CAPI/CAPZ/ASO + ArgoCD.
* Trade-offs: Zero standing Azure cost and upstream-default; but Workload Identity on kind is brittle (SA signing keypair + JWKS in Azure storage), ArgoCD only lives for the job (no stable demo screenshots), and teardown ordering is more fragile (kind destruction can orphan workload AKS).
* Rejection rationale: Live customer demo + Workload Identity simplicity outweigh the cost savings; retained as a documented Option B / potential pipeline toggle.

### IP-02: Classic (non-ASO) CAPZ AzureManagedControlPlane

* Approach: Use the GA non-ASO CAPZ managed-cluster flavor instead of the aks-aso flavor.
* Trade-offs: Slightly simpler and GA, but exposes only a CAPZ-curated subset of AKS fields and is the older path.
* Rejection rationale: aks-aso is the current recommended direction and gives full AKS field access; min-version policy works on either CR kind.

### IP-03: Gatekeeper (OPA) or Azure Policy add-on as the registry policy engine

* Approach: Use Gatekeeper `k8sallowedrepos` or the Azure Policy add-on for the registry control.
* Trade-offs: Gatekeeper is battle-tested but Rego is unfamiliar and prefix matching does not auto-resolve implicit docker.io/library defaults; Azure Policy has ~15-min sync, is control-plane scoped, and double-webhooks with Kyverno.
* Rejection rationale: Kyverno's parsed `images.*.registry` resolves the implicit docker.io default natively and toggles Audit⇄Enforce instantly for the demo; both alternatives documented for the customer. Azure Policy approved-version allow-list is retained as the Azure-native min-version complement.

### IP-04: Azure DevOps pipelines instead of GitHub Actions

* Approach: Run the harness in ADO; `publish-wiki.ps1` already supports `-Target ado`.
* Trade-offs: ADO wiki auth is documented in user memory, but the sibling is GitHub-only.
* Rejection rationale: GitHub Actions is the lowest-friction mirror of the sibling; ADO remains a drop-in alternative if the customer requires it.

## Suggested Follow-On Work

Items identified during planning that fall outside current scope.

* WI-01: ARO / Arc `connectedClusters` governance asymmetry demo (Phase 2+). — README flags AKS vs ARO/Arc policy asymmetry. (medium)
  * Source: research Scope (out) + README.
  * Dependency: Phase 1 PoC complete.
* WI-02: Multi-subscription landing-zone-aligned ODS (README strategic target). — Production direction beyond single-subscription bootstrap. (high)
  * Source: research Scope (out).
  * Dependency: Phase 1 PoC complete; landing-zone design.
* WI-03: Parse `assets/*.docx`/`*.pptx` for a concrete phased roadmap to confirm Phase 1 framing aligns with client deliverables (needs docx/pptx skill). (low)
  * Source: DR-07.
  * Dependency: none.
* WI-04: Production HA ArgoCD, private clusters, custom VNet/CNI hardening. (medium)
  * Source: research Scope (out).
  * Dependency: Phase 1 PoC complete.
* WI-05: Add kind management-cluster mode as a pipeline input toggle (cost-optimized variant from IP-01). (low)
  * Source: IP-01.
  * Dependency: Phase 1 PoC complete.

## User Decisions

Decisions recorded from Implementation Decision prompts.

* ID-00: Live-test subscription — selected `ME-MngEnvMCAP675646-emknafo-1` (`64c3d212-40ed-4c6d-a825-6adfbdf25dad`), tenant `aa93b9d9-037d-4f08-a26d-783cff0e2369`.
  * Rationale: current `az login` context; user confirmed billable provisioning of ~3 AKS clusters.
* ID-01: Execution path — run end-to-end **locally first** against the current `az login`, then wire GitHub Actions OIDC.
  * Rationale: fastest iteration; avoids org-admin dependency for the first green run.
* ID-02: Identity + cost authorization — user authorized creating app registrations + role assignments and running teardown at the end.
