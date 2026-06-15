<!-- markdownlint-disable-file -->
# Release Changes: Phase 1 PoC — Single-Subscription AKS Governance with CAPI/CAPZ/ASO + ArgoCD + Policy

**Related Plan**: phase-1-capi-aks-governance-poc-plan.instructions.md
**Implementation Date**: 2026-06-14

## Summary

Greenfield Phase 1 PoC in `aks-governance`: pipeline-driven provisioning of an ephemeral management AKS cluster (CAPI/CAPZ/ASO + ArgoCD + Kyverno), declarative creation of 2 workload AKS clusters, two governance demos (deny docker.io/quay.io; enforce minimum Kubernetes version), wiki evidence capture, and cost-safe ordered teardown. Live-tested against subscription `ME-MngEnvMCAP675646-emknafo-1` (local-first execution, then GitHub Actions wiring).

## Changes

### Added

* scripts/preflight.ps1 - Azure readiness gate (provider registration + auto-register, AKS version availability per region, VM SKU restriction check, vCPU + public-IP quota warnings, PASS/FAIL summary).
* .github/workflows/.gitkeep, infra/.gitkeep, clusters/.gitkeep, gitops/bootstrap/.gitkeep, gitops/apps/.gitkeep, gitops/policies/kyverno/.gitkeep, docs/captures/.gitkeep, docs/screenshots/.gitkeep, samples/.gitkeep - greenfield directory scaffolding.
* infra/mgmt-cluster.bicep - ephemeral management AKS (OIDC issuer + Workload Identity), CAPZ/ASO UAMI, RG-scope Contributor; outputs cluster name/OIDC issuer/UAMI ids.
* scripts/deploy-mgmt.ps1 - mgmt bootstrap (local + CI OIDC): Bicep deploy, federated cred + sub-scope Contributor, get-credentials, clusterctl init, ASO Workload Identity wiring (aso-credentials Secret), ArgoCD install, root-app apply, readiness checks.
* clusters/poc-aks-1.env, clusters/poc-aks-2.env - per-cluster inputs (eastus2 / westus3).
* clusters/cluster-template-aks-aso.yaml - parametrized CAPZ aks-aso template (Cluster + control-plane + infra + system MachinePool).
* scripts/provision-clusters.ps1 - generate -> apply -> wait Ready -> get kubeconfig loop.
* .gitignore - ignore generated/, kubeconfigs/, *.kubeconfig, storage_state.json, node_modules/, *.pem.
* gitops/bootstrap/root-app.yaml - app-of-apps root Application.
* gitops/apps/kyverno.yaml - Kyverno install Application (sync-wave 0).
* gitops/apps/governance-policies.yaml - ApplicationSet cluster generator (type=workload, sync-wave 1).
* scripts/register-argocd-clusters.ps1 - kubeconfig -> ArgoCD cluster Secret (labels type=workload), fail-fast if < 2.
* gitops/policies/kyverno/block-docker-quay-registries.yaml - Example A registry deny (Audit-first).
* gitops/policies/kyverno/enforce-min-k8s-version.yaml - Example B min-version on AzureASOManagedControlPlane.
* samples/under-min-version.yaml - under-minimum control-plane CR for the demo rejection.
* scripts/demo-registry.ps1, scripts/demo-min-version.ps1 - governance demo drivers with CLI capture.
* scripts/capture.ps1 - two-leg evidence (CLI .txt + Playwright .png) adapted from sibling.
* docs/capture-argocd.ts - Playwright ArgoCD UI + portal screenshots.
* scripts/publish-wiki.ps1, scripts/publish-wiki-preflight.ps1 - wiki publisher + read-only PAT/target probe.
* scripts/teardown.ps1 - CAPI-ordered cost-safe teardown (workload clusters -> wait RGs gone -> mgmt RG).
* .github/workflows/aksgov-poc-demo.yml - 9-job pipeline (preflight -> deploy-mgmt -> provision -> register-argocd -> demo-registry -> demo-min-version -> capture -> publish-wiki -> approval-gated teardown).
* docs/runbook.md - PoC operations runbook (secrets, OIDC app reg, teardown environment, wiki setup, local-first run order, Audit->Enforce demo narrative).

### Modified

* README.md - appended a delimited PoC pointer section linking to docs/runbook.md.
* gitops/policies/kyverno/enforce-min-k8s-version.yaml - strip the `v` prefix from `spec.version` before the Kyverno `LessThan` minimum-version comparison (live fix).
* scripts/provision-clusters.ps1 - pipe the CAPZ template via stdin (`--from -`) to avoid clusterctl v1.13+ misreading Windows absolute paths as URLs, AND wait on the CAPI v1beta2 `Available` condition (with `Ready` fallback) instead of the removed `Ready` condition (live fixes).
* clusters/cluster-template-aks-aso.yaml - removed a literal `${VAR}` token from the header comment that aborted `clusterctl generate` (live fix).

### Removed

* (pending)

## Additional or Deviating Changes

* Phase 1 Step 1.2: preflight.ps1 implements "fail fast" as collect-all-checks-then-exit-nonzero (full PASS/WARN/FAIL summary in one pass) rather than short-circuit on first failure.
  * Reason: gives the operator the complete readiness picture in a single run while still gating provisioning with a non-zero exit; aligns with sibling style.
* Cross-phase reconciliation: standardized ASO credential Secret name to `aso-credentials` (plural) across clusters/*.env and samples/under-min-version.yaml to match deploy-mgmt.ps1 and research; aligned capture.ps1 default `-MgmtClusterName` to the Bicep value `aksgov-poc-mgmt`.
  * Reason: the `credential-from` annotation must resolve to the Secret deploy-mgmt creates; capture must target the actual cluster name.
* Live fix (preflight.ps1): wrapped the `Test-HasProperty $minor 'patchVersions'` call in parentheses inside `Get-AksVersionInfo` so the following `-and` is not parsed as a parameter to the function.
  * Reason: bare-call form `if (Test-HasProperty $minor 'patchVersions' -and $null -ne ...)` made PowerShell bind `-and` as a named parameter, raising "A parameter cannot be found that matches parameter name 'and'" and failing both AKS-version checks. Caught during the first live preflight run; both regions now PASS (eastus2/westus3 offer up to 1.36.0, AKS default 1.34.8).
* Live run — preflight PASSED 14/0/0: providers registered, eastus2+westus3 offer AKS up to 1.36.0 (default 1.34.8), Standard_D2s_v6 unrestricted in both regions, 100 vCPUs + 1000 public IPs free per region. Management cluster deploys with the AKS default version (Bicep `kubernetesVersion` left empty -> null).
* Live run — signed-in user holds subscription-scope **Owner**, so app-registration creation and the UAMI subscription-scope Contributor assignment are authorized. Local-first run uses UAMI + Workload Identity (no app registration required until GitHub Actions OIDC wiring).
* Live fix (infra/mgmt-cluster.bicep + scripts/deploy-mgmt.ps1): removed the RG-scope UAMI `Contributor` role assignment from the Bicep template; the deploy script now owns ALL UAMI role assignments via `az role assignment create` with a 6×10s propagation retry.
  * Reason: the first live mgmt deploy failed with `RoleDefinitionDoesNotExist` (Contributor) — the in-template role assignment raced the freshly-created UAMI's Entra propagation. The AKS cluster + UAMI themselves deployed Succeeded; only the role assignment failed. The RG-scope grant was also redundant because the script grants subscription-scope Contributor (which already covers the mgmt RG). Moving it to the az CLI path (which tolerates propagation) makes both local and CI deploys robust and removes the redundancy. The script's sub-scope grant was upgraded from non-fatal warning to fail-hard-with-retry since it is now the sole UAMI permission.
* Live fix (tooling): upgraded `clusterctl` v1.8.5 -> v1.13.2 in `C:\Users\emknafo\aksgov-tools` (old binary kept as `clusterctl-old.exe`).
  * Reason: clusterctl v1.8.5 installed CAPI core v1.10.10 which only serves `cluster.x-k8s.io/v1beta1`, but CAPZ v1.24.1 requires CAPI v1beta2 (core v1.11+). The `capz-controller-manager` crash-looped with `no matches for kind "Cluster" in version "cluster.x-k8s.io/v1beta2"` and `failed to wait for azurecluster caches to sync`, which also left `capz-webhook-service` with no endpoints. Tore down the broken v1beta1 stack (clusterctl delete via the old binary + manual `kubectl delete crd/ns` cleanup of 46 CAPI/CAPZ/ASO CRDs and provider namespaces), then re-ran `clusterctl init --infrastructure azure` with v1.13.2 → CAPI core v1.13.2 (v1beta2 storage) + CAPZ v1.24.1 + cert-manager v1.20.2; `capz-controller-manager` 1/1 Running and webhook endpoint live. **Follow-on: pin clusterctl >= v1.13.2 in scripts/install-tools.ps1.**
* Live fix (scripts/provision-clusters.ps1): pipe the CAPZ template to `clusterctl generate cluster --from -` via stdin instead of passing the absolute file path.
  * Reason: clusterctl v1.13+ parses the `--from` argument as a URL first; a Windows absolute path (`C:\repo\...`) is misread as a URL scheme, erroring `invalid GetFromURL operation ... Only reading from GitHub and local file system is supported`. Reading the template into stdin sidesteps cross-platform path/URL parsing.
* Live fix (scripts/provision-clusters.ps1): `Wait-ClusterReady` now polls the CAPI `Available` condition (with `Ready` as a fallback) instead of only `Ready`.
  * Reason: CAPI v1.11+ (v1beta2, installed by clusterctl v1.13.2) renamed the top-level Cluster health condition from `Ready` to `Available`. `poc-aks-1` reached `phase=Provisioned` with `Available=True`/`RemoteConnectionProbe=True`/`ControlPlaneAvailable=True` and the machine pool `Running`, but the old jsonpath for a `Ready` condition returned empty forever and the wait timed out after 40m even though the cluster was fully healthy. The cluster was already usable; only the readiness probe was wrong.
* Live fix (clusters/cluster-template-aks-aso.yaml): removed a literal `${VAR}` example token from the header comment.
  * Reason: `clusterctl generate cluster` scans the entire file (including comments) for `${...}` placeholders; the documentation token `${VAR}` had no default and aborted rendering with `value for variables [VAR] is not set`.
* Live fix (gitops/policies/kyverno/enforce-min-k8s-version.yaml): strip the `v` prefix from the control-plane version before the `LessThan` comparison via `regex_replace_all('^v', '{{ request.object.spec.version }}', '')`.
  * Reason: Kyverno's `LessThan` operator cannot parse `v`-prefixed semver — the admission webhook logged `Invalid character(s) found in major number "v1"` and silently evaluated the deny condition to false, so under-minimum control planes were ADMITTED instead of denied. Each failed test also created a real provisioning Cluster + AzureASOManagedControlPlane that had to be deleted immediately for cost safety. After stripping the prefix, the `samples/under-min-version.yaml` (v1.27.0) CR is correctly DENIED with a message naming the v1.28.0 minimum.
* Live run — ASO Workload Identity re-wired on the fresh CAPZ v1.24.1 install: patched the global `aso-controller-settings` Secret (AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID + USE_WORKLOAD_IDENTITY_AUTH=true), annotated+labeled the `azureserviceoperator-default` SA in `capz-system`, set the ASO deployment pod-template label `azure.workload.identity/use=true`, and restarted. Verified the ASO pod has `AZURE_FEDERATED_TOKEN_FILE` env + `azure-identity-token` volume injected (DR-01/DD-03 resolved: CAPZ bundles ASO in `capz-system`, SA `azureserviceoperator-default`, global credential `aso-controller-settings`; the WI webhook objectSelector matches POD labels, not SA labels).
* Live run — Kyverno v1.18.1 + both ClusterPolicies applied Ready=True; **registry-deny demo PASSING** (Audit: all admitted; Enforce: docker.io denied, quay.io denied, mcr.microsoft.com admitted) and **min-version demo PASSING** (v1.27.0 control plane denied naming the v1.28.0 minimum). Captures written to docs/captures/.

## Release Summary

(pending final phase)
