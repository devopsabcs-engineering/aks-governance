# Subagent Research — Repos Analysis for Phase 1 PoC Design

Date: 2026-06-14
Status: Complete
Scope: Analyze two local git repos (aks-governance target, aks-fleet-manager reference) to inform a Phase 1 PoC design.

## Research Topics / Questions

1. aks-governance — current state, stated goals, phases, any "Phase 1" definition, directory tree, assets, existing pipelines/IaC/scripts.
2. aks-fleet-manager — reusable end-to-end pattern: pipeline structure, infra provisioning, teardown/cleanup, wiki proof/screenshot publishing, variable groups / service connections / parameters / naming conventions, with exact file references.

---

## Repository 1 — aks-governance (target)

Path: c:\src\GitHub\devopsabcs-engineering\aks-governance

### Directory tree

```
aks-governance/
├─ .copilot-tracking/
│  └─ research/
│     ├─ 2026-06-14/
│     └─ subagents/
├─ .git/
├─ assets/
│  ├─ ACME_Gouvernance_Kubernetes_Rapport_FR.docx
│  ├─ ACME_Gouvernance_Kubernetes_Synthese_Executive_FR.pptx
│  ├─ ACME_Kubernetes_Governance_Executive_Summary.pptx
│  └─ Kubernetes Cluster Management Solutions.docx
└─ README.md
```

### Current state (key finding)

- The repo is **documentation-only at present**. There is **NO** IaC (no bicep/terraform), **NO** pipelines (no `.github/workflows`, no `azure-pipelines*.yml`), and **NO** scripts. Only `README.md` plus four Office documents under `assets/`.
- `assets/` contains client-facing deliverables (ACME Inc. Kubernetes governance):
  - `ACME_Gouvernance_Kubernetes_Rapport_FR.docx` — full FR report
  - `ACME_Gouvernance_Kubernetes_Synthese_Executive_FR.pptx` — FR exec synthesis deck
  - `ACME_Kubernetes_Governance_Executive_Summary.pptx` — EN exec summary deck
  - `Kubernetes Cluster Management Solutions.docx`
  - (No image/screenshot assets — these are binary Office files only.)

### README.md summary (aks-governance/README.md)

The README is a prose executive brief titled "ACME Inc. Kubernetes governance report delivered." It is a narrative recommendation, **not** a phased implementation plan. Notable substance:

- **Strategic recommendation**: move toward a **landing-zone-aligned multi-subscription ODS** (central governance/tooling in platform subs, workload clusters in client-aligned landing-zone subscriptions). Treat the single-subscription model only as a **tactical bootstrap pattern**.
- **Two customer-proposed options** evaluated:
  - Option 1 — Single subscription: best as tactical bootstrap / temporary service-cell; reduces cross-sub network friction; concentrates quota risk and weakens isolation.
  - Option 2 — Management subscription + workload subscriptions: strategic target; aligns with Azure landing zones; needs more platform readiness (identity scoping, peering/private DNS/firewall, prerequisite ownership).
- **Governance asymmetry finding**: AKS = `managedClusters`; ARO via Arc = `connectedClusters`. AKS-targeted policy sets do NOT automatically apply to ARO; uniform policy coverage must be solved as an architecture/governance pattern.
- **Tooling split**:
  - AKS: Argo CD = GitOps reconciler for add-ons/policy/config/workloads; CAPZ/ASO = declarative AKS cluster lifecycle.
  - ARO: Argo CD for add-ons/config/workloads; managed-identity-compatible provisioning path (portal/ARM/Bicep/supported CLI) because CAPZ/ASO/Terraform ARO MI creation was blocked at the time (MI for ARO now GA).
- **Two Microsoft-aligned patterns** added beyond the customer's two: (1) Landing-zone-aligned federated ODS; (2) **Fleet-governed distributed AKS operations** (an AKS Fleet Manager overlay for multi-cluster namespace governance, quotas, RBAC, upgrades, resource placement, staged Git-based deployment + Arc-aware ARO handling).

### Phase 1 definition in aks-governance

- **There is NO explicit "Phase 1" defined anywhere in the repo.** The README contains no roadmap, no numbered phases, no milestone list. The closest signal is the recommendation that single-subscription be used as a near-term "tactical bootstrap"/"bridge" before building toward the multi-subscription target — but this is positioned as advice, not a documented phase plan.
- **Implication for the PoC**: a Phase 1 must be authored fresh. The README's "Fleet-governed distributed AKS operations" pattern is the conceptual bridge to the sibling `aks-fleet-manager` repo, which already implements a working Fleet Manager PoC — that is the most directly reusable Phase 1 candidate.

### Existing pipelines / IaC / scripts / YAML in aks-governance

- None. Confirmed by directory listing — no `infra/`, `scripts/`, `.github/`, `azure-pipelines*.yml`, `*.bicep`, or `*.tf` exist.

---

## Repository 2 — aks-fleet-manager (reference pattern to mirror)

Path: c:\src\GitHub\devopsabcs-engineering\aks-fleet-manager

This is a **complete, turnkey, end-to-end PoC** with a single-resource-group deploy/teardown lifecycle and automated wiki proof publishing. It is the reusable blueprint.

### Directory tree (key paths)

```
aks-fleet-manager/
├─ .github/
│  └─ workflows/
│     └─ fleet-poc-demo.yml          # end-to-end GH Actions pipeline
├─ infra/
│  ├─ main.bicep                     # fleet (hub/hubless) + N member AKS clusters
│  ├─ arc-members.bicep              # Arc-enabled k3s members (Standard_B2ms VMs)
│  └─ arc-members.json               # compiled ARM (from arc-members.bicep)
├─ scripts/
│  ├─ deploy.ps1                     # one-command deploy (RG + bicep + policy add-on + Fleet RBAC)
│  ├─ demo-upgrade.ps1               # Feature A: fleet update run
│  ├─ demo-policy.ps1                # Feature B: deny-privileged policy + blocked apply
│  ├─ deploy-arc-members.ps1         # Feature C: Arc VMs, onboard, join fleet, policy ext
│  ├─ demo-placement.ps1             # Feature C: ClusterResourcePlacement across members
│  ├─ verify-workloads.ps1           # Feature C: per-cluster verification + website screenshots
│  ├─ capture.ps1                    # capture CLI text + drive Playwright portal screenshots
│  ├─ publish-wiki.ps1               # generate walkthrough markdown + push to wiki
│  └─ teardown.ps1                   # delete the resource group
├─ docs/
│  ├─ capture-fleet.ts               # Playwright portal screenshot capture (TypeScript)
│  ├─ captures/                      # CLI text evidence (.txt) — committed sample artifacts
│  ├─ manifests/                     # k8s YAML: cluster-resource-placement, placement-demo, privileged-pod
│  ├─ screenshots/                   # portal/workload screenshots (.png)
│  ├─ package.json / package-lock.json / tsconfig.json / node_modules/
├─ .gitignore
└─ README.md
```

### END-TO-END FLOW (the pattern to mirror)

The whole lifecycle is driven from one `workflow_dispatch` pipeline: `.github/workflows/fleet-poc-demo.yml`. Stage-by-stage with file references:

| Pipeline job | File / lines | What it does |
| --- | --- | --- |
| `deploy` | aks-fleet-manager/.github/workflows/fleet-poc-demo.yml lines 72-105 | OIDC `azure/login@v2`, `az extension add --name fleet`, runs `scripts/deploy.ps1` with RG/location/fleet/VM/node/k8s/enableHub params |
| `feature-a-upgrade` | fleet-poc-demo.yml lines 107-138 | Runs `scripts/demo-upgrade.ps1` (coordinated multi-cluster K8s upgrade) |
| `feature-b-policy` | fleet-poc-demo.yml lines 140-163 | Installs kubectl, runs `scripts/demo-policy.ps1` (deny privileged + show block) |
| `deploy-arc-members` | fleet-poc-demo.yml lines 165-200 | `if: inputs.runArc` — runs `scripts/deploy-arc-members.ps1`, uploads `docs/captures/arc-members.txt` artifact |
| `feature-c-placement` | fleet-poc-demo.yml lines 202-239 | `if: runArc && enableHub` — runs `scripts/demo-placement.ps1`, uploads `docs/captures/placement.txt` |
| `verify-workloads` | fleet-poc-demo.yml lines 241-300 | Node 20 + Playwright Chromium, runs `scripts/verify-workloads.ps1`, uploads captures + screenshots |
| `capture` | fleet-poc-demo.yml lines ~302-330 | `if: always() && inputs.runCapture` — runs `scripts/capture.ps1`, uploads `docs/captures/` + `docs/screenshots/` |
| `publish-wiki` | fleet-poc-demo.yml lines ~332-388 | `if: always() && inputs.publishWiki && needs.capture.result=='success'` — downloads all artifacts, runs `scripts/publish-wiki.ps1 -Target github` |
| `teardown` | fleet-poc-demo.yml lines ~390-end | **Approval-gated** via `environment: fleet-poc-teardown`; `if: always() && needs.deploy.result=='success'`; runs `scripts/teardown.ps1` |

Key flow controls:
- `on: workflow_dispatch` with rich inputs (fleet-poc-demo.yml lines 10-58): `resourceGroup` (default `rg-fleet-poc`), `location` (default `eastus2`), `fleetName` (default `demo-fleet`), `nodeVmSize`, `nodeCount`, `kubernetesVersion`, and booleans `staged`, `runCapture`, `publishWiki`, `enableHub`, `runArc`.
- `concurrency: group: fleet-poc-${{ inputs.resourceGroup }}` (lines ~60-62) serializes runs against the same RG.
- `permissions: id-token: write, contents: read` (lines ~64-66) for OIDC.

### Provisioning (IaC) details

- aks-fleet-manager/infra/main.bicep:
  - `targetScope = 'resourceGroup'` (line 2).
  - Params: `fleetName` (default `demo-fleet`), `clusterNames` array (default `aks-member-01/02/03`), `kubernetesVersion`, `nodeVmSize` (default `Standard_DS2_v2`), `nodeCount` (default 1), `updateGroups` (`staging`,`production`,`production`), `enableHub` (default true), `hubDnsPrefix`, `hubVmSize` (default `Standard_D2s_v6` — note inline comment lines 39-40 about volatile allowed-VM-size policy in eastus2: `Standard_D2s_v3`/`v5` disallowed, `v6` allowed).
  - Member AKS clusters created with a Bicep loop (lines 44-78): `Microsoft.ContainerService/managedClusters@2025-02-01`, SKU `Base`/`Free`, `SystemAssigned` identity, Azure Policy add-on enabled inline (`addonProfiles.azurepolicy.enabled = true`).
  - Fleet resource (lines ~84+): `Microsoft.ContainerService/fleets@2025-03-01`, `SystemAssigned` identity; hubless = empty properties, hub = `hubProfile`. Comment notes hub is a billed single-node Standard-tier AKS cluster gated behind `enableHub` for cost.
- aks-fleet-manager/infra/arc-members.bicep + arc-members.json: cost-effective `Standard_B2ms` VMs running self-onboarding k3s + Arc (cloud-init + user-assigned MI, no SSH).

### Teardown / cost-cleanup details

- aks-fleet-manager/scripts/teardown.ps1 (whole file, ~36 lines): single command `az group delete --name $ResourceGroup --yes --no-wait`. Default `$ResourceGroup = 'rg-fleet-poc'`. Everything (fleet, members, policy, Arc VMs) lives in one RG, so one delete cleans all.
- **Cost-safety design**: the pipeline `teardown` job (fleet-poc-demo.yml) runs `if: always() && needs.deploy.result == 'success'` so it fires even when earlier jobs fail (never leaks cost), but is gated behind the `fleet-poc-teardown` GitHub Environment requiring a manual reviewer approval before deletion. This "always-run-but-approval-gated teardown" is the key reusable cost pattern.
- Single-RG "deploy and tear down with one command each" is stated explicitly in README and enforced by infra layout.

### Wiki proof / screenshot publishing details

Two-leg evidence model: deterministic CLI text + best-effort portal screenshots, interleaved into one markdown page and pushed to a wiki Git repo.

- **Capture (CLI text)**: aks-fleet-manager/scripts/capture.ps1
  - Leg 1 (always runs): tees `az fleet show`, `az fleet member list`, `az fleet updaterun list`, hub version query into `docs/captures/*.txt` (lines ~50-66+). Each command independently wrapped so one failure warns but continues.
  - Leg 2 (best-effort): Playwright portal screenshots only when `docs/storage_state.json` exists; wrapped in try/catch so missing/expired auth degrades gracefully.
- **Capture (portal screenshots)**: aks-fleet-manager/docs/capture-fleet.ts
  - Playwright Chromium, reuses persisted `storage_state.json` (created once via `npx playwright codegen https://portal.azure.com --save-storage=storage_state.json`, MFA by hand; file is git-ignored secret).
  - Deep-links to Fleet Manager blades (`overview`, `members`, `multiClusterUpdates`, `policy`) built from `AZ_SUBSCRIPTION_ID`/`AZ_RESOURCE_GROUP`/`AZ_FLEET_NAME`/`AZ_TENANT_ID` env (lines ~17-67). Waits on stable heading text, masks sensitive UI (subscription chips, directory, emails) on screenshot. Output to `docs/screenshots/*.png`, 1920x1080 viewport, deviceScaleFactor 2.
- **Markdown generation + publish**: aks-fleet-manager/scripts/publish-wiki.ps1 (~400 lines)
  - `New-DemoMarkdown` interleaves CLI text captures with screenshots by matching file base name (e.g. `01-overview.txt` pairs with `01-overview.png`). Builds intro, "What this demonstrates", a Mermaid architecture diagram, a TOC, ordered sections (with curated human descriptions per known section key), and a footer (lines ~140-280).
  - Image path prefix differs by backend: `/.attachments/` for ADO, `images/` for GitHub (line ~169).
  - Targets: `-Target ado|github`. ADO wiki URL `https://<host>/<org>/<project>/_git/<project>.wiki`; GitHub `https://github.com/<owner>/<repo>.wiki.git`. Pipeline derives GitHub wiki URL automatically from `github.repository`.
  - **Auth pattern (matches user memory azure-devops-wiki-auth.md)**: PAT-in-URL form `https://PAT@host/...` (no username, no colon). Prefers `bash` + macro substitution building the URL inside the shell with PAT passed via env (`WIKI_PAT_RUNTIME`), never argv (lines ~322-345). Falls back to direct pwsh `git clone $authUrl` when bash unavailable.
  - ADO requires PAT with **Code (Read and Write)** scope (Wiki scope alone insufficient). Branch auto-detect: ADO default `wikiMain` (fallback `wikiMaster`), GitHub default `master`; pushes `git push origin HEAD || git push origin HEAD:$Branch` (lines ~370-395).
  - ADO `.order` file maintained for TOC sequencing; GitHub has no such convention (lines ~358-368).
  - Commit identity set inline: `git config user.email pipeline@local` / `user.name pipeline`; no-ops if no staged diff.
- **Sample artifacts are committed** for reference: docs/captures/ has `06-workload-placement.txt`, `arc-members.txt`, `placement.txt`, `workload-aks-member-0{1,2,3}.txt`, `workload-arc-member-0{1,2}.txt`; docs/screenshots/ has `workload-aks-member-0{1,2,3}.png`. docs/manifests/ has `cluster-resource-placement.yaml`, `placement-demo.yaml`, `privileged-pod.yaml`.

### Variable groups / service connections / parameters / naming conventions

- **Auth model = GitHub OIDC federated** (not ADO service connections, not variable groups). Repo secrets required (README "One-time setup" + pipeline): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and optional `WIKI_PAT`. No Azure DevOps variable groups or service connections are used — this is a pure GitHub Actions repo.
- **GitHub Environment**: `fleet-poc-teardown` with Required reviewers — produces the manual approval gate for destroy.
- **Naming conventions / defaults**: RG `rg-fleet-poc`; region `eastus2`; fleet `demo-fleet`; members `aks-member-01/02/03`; Arc members `arc-member-01/02`; update groups `staging`/`production`; wiki page `Fleet-Manager-Demo`; capture dir `docs/captures`; screenshot dir `docs/screenshots`.
- **WIKI_PAT scope**: GitHub fine-grained token, resource owner `devopsabcs-engineering`, repo `aks-fleet-manager`, Contents: Read and write (covers wiki). Classic alternative: `repo` scope.

### Notable robustness patterns worth reusing

- **OIDC token refresh during long deploys**: deploy.ps1 `Connect-AzFederated` (lines ~38-62) re-mints the GitHub OIDC token and re-`az login` on each poll cycle to avoid AADSTS700024 when provisioning 3 AKS clusters exceeds the ~5-min access-token lifetime. Uses `az deployment group create --no-wait` + 90s poll loop in CI (`$useAsyncPoll` when `GITHUB_ACTIONS=true`), synchronous locally (lines ~110-150).
- **Fleet data-plane RBAC**: deploy.ps1 (lines ~155-200) grants "Azure Kubernetes Fleet Manager RBAC Cluster Admin" to the deploying identity on the fleet scope (ARM Owner/Contributor is NOT enough to call the hub k8s API for ClusterResourcePlacement). Resolves role by name (built-in GUIDs not guaranteed stable), idempotent, non-fatal.
- Scripts authored to follow user memory conventions explicitly (publish-wiki.ps1 `.NOTES` references azure-devops-wiki-auth.md + powershell-pitfalls.md: literal `&`, `Select-String` not grep, bash+macro auth).

---

## Reusable scaffolding from aks-fleet-manager for aks-governance Phase 1

Directly adaptable assets (copy + re-parameterize for a governance-flavored PoC):

1. **Pipeline skeleton** — aks-fleet-manager/.github/workflows/fleet-poc-demo.yml: the `workflow_dispatch` + OIDC + concurrency + per-feature jobs + artifact upload/download + `always()`-but-approval-gated `teardown` (via a `*-teardown` GitHub Environment) is a clean, generic deploy→demo→capture→publish→destroy harness.
2. **One-RG deploy/teardown scripts** — scripts/deploy.ps1 (with `Connect-AzFederated` OIDC refresh + role-by-name RBAC grant) and scripts/teardown.ps1 (`az group delete --no-wait`). Reusable nearly verbatim.
3. **Bicep template pattern** — infra/main.bicep loop-creating clusters with inline Azure Policy add-on + a toggle param (`enableHub`) for cost control. The governance PoC could swap the fleet for policy-assignment/custom-role/landing-zone resources but keep the loop + toggle structure.
4. **Evidence + wiki publishing chain** — scripts/capture.ps1 + docs/capture-fleet.ts + scripts/publish-wiki.ps1: the CLI-text + Playwright-screenshot + interleaved-markdown + PAT-in-URL wiki push is fully generic. Only the blade deep-links (`capture-fleet.ts` BLADES) and section descriptions (`publish-wiki.ps1 $descriptions`) need governance-specific content.
5. **Conventions to keep**: GitHub OIDC secrets (`AZURE_CLIENT_ID`/`TENANT_ID`/`SUBSCRIPTION_ID` + `WIKI_PAT`); `rg-*-poc` single-RG naming; `eastus2`; approval-gated teardown environment; pwsh 7 scripts following the literal-`&` / `Select-String` / bash+macro-wiki-auth memory rules.

---

## Clarifying questions

1. **Phase 1 target**: Should the aks-governance Phase 1 PoC mirror the Fleet Manager pattern (multi-cluster governance overlay) directly, or focus on the README's "landing-zone-aligned multi-subscription" / least-privilege custom-role + pre-provisioned-landing-zone angle? The README recommends both but they imply different infra.
2. **Pipeline platform**: aks-fleet-manager is GitHub Actions only. Does aks-governance Phase 1 need Azure DevOps pipelines (the wiki publisher already supports `-Target ado`), or stay on GitHub Actions?
3. **Subscription model for the PoC**: single-subscription bootstrap vs management+workload multi-sub? This drives whether the bicep targets one RG (current pattern) or needs subscription-scope / multiple deployments.
4. **AKS vs ARO scope**: Is Phase 1 AKS-only (where Fleet/policy patterns map cleanly) or must it also demonstrate the ARO/Arc `connectedClusters` governance path the README flags as asymmetric?

---

## Recommended next research (not yet done)

- [ ] Read the binary `assets/*.docx` / `*.pptx` (could not be parsed via text tools) to extract any concrete phased roadmap or success criteria the prose README omits — may require the docx/pdf skill or conversion.
- [ ] Read the remainder of aks-fleet-manager bicep (infra/main.bicep beyond line 90: fleet hub profile, member join `fleetMembers` resources, outputs) and infra/arc-members.bicep in full for exact resource API versions and outputs.
- [ ] Read demo-upgrade.ps1, demo-policy.ps1, deploy-arc-members.ps1, demo-placement.ps1, verify-workloads.ps1 in full to inventory every `az`/`kubectl` call (useful if the governance PoC reuses Feature B policy enforcement).
- [ ] Inspect aks-fleet-manager/.gitignore and docs/package.json to confirm the Playwright/tsx toolchain and the git-ignored secrets (`storage_state.json`).
- [ ] Check both repos' git history/branches (only `main`/default inspected) for any in-progress Phase 1 work not on the working tree.
- [ ] Confirm whether a `devopsabcs-engineering/aks-governance` GitHub wiki or ADO project wiki already exists as the publish target.
