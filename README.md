# AKS Governance — ACME Inc. Kubernetes Governance Architecture

> **Strategic governance reference and runnable Proof of Concept** for deploying and governing
> Azure Kubernetes Service (AKS) — and, where required, Azure Red Hat OpenShift (ARO) — for
> internal clients with least-privilege, landing-zone-aligned, GitOps-driven operations.

🌐 **Language:** **English** · [Français](README.fr.md)

📄 **Companion report:** `ACME_Kubernetes_Governance_Architecture_Report.docx`

---

## Table of contents

- [Terminology](#terminology)
- [Bottom line](#bottom-line)
- [Why a multi-subscription model is the best fit](#why-a-multi-subscription-model-is-the-best-fit)
- [AKS vs ARO governance is not symmetric](#aks-vs-aro-governance-is-not-symmetric)
- [The two customer-proposed options](#the-two-customer-proposed-options)
- [Comparison synthesis](#comparison-synthesis)
- [Microsoft-aligned alternatives](#microsoft-aligned-alternatives)
- [How the design treats CAPI/CAPZ + Argo CD](#how-the-design-treats-capicapz--argo-cd)
- [Executive one-liner](#executive-one-liner)
- [Proof of Concept](#proof-of-concept)
- [References](#references)

---

## Terminology

> [!NOTE]
> **ODS** — *Offre de Service* (Service Offering): the central ACME Inc. platform/self-service
> capability that provisions and governs Kubernetes (AKS, and ARO where required) on behalf of
> internal clients. Throughout this document, "ODS" refers to that central platform team and its
> deployment automation — e.g., the entity granted scoped rights to deploy into workload
> subscriptions and the owner of centralized observability and governance.
>
> **Federated ODS** — the recommended target shape of that service offering: the same central
> governance/tooling/observability hosted in platform subscriptions, with workload clusters
> **federated** into per-client [landing-zone subscriptions][caf-lz]. This contrasts with the
> concentrated **single-subscription bootstrap**, where everything lives in one subscription.
>
> Other acronyms used below: **AKS** (Azure Kubernetes Service), **ARO** (Azure Red Hat OpenShift),
> **CAPI/CAPZ** (Cluster API / Cluster API Provider Azure), **ASO** (Azure Service Operator),
> **GIA** (ACME Inc. identity & access management / *Gestion des identités et des accès*).

---

## Bottom line

> [!IMPORTANT]
> **Strategic recommendation:** move toward a **landing-zone-aligned multi-subscription ODS**
> (central governance/tooling, with workload clusters in client-aligned
> [landing-zone subscriptions][caf-lz]), and treat the **single-subscription model only as a
> tactical bootstrap** pattern if ACME Inc. needs a short path around current cross-subscription
> network / GIA friction.

That recommendation is grounded in ACME Inc.'s own ODS objectives: simplify AKS/ARO consumption,
centralize observability/governance, support both client-oriented and mutualized service tiers,
prefer AKS by default, and use ARO only for specific workload classes such as CP4D and MQ. It is
also consistent with Microsoft's [landing-zone guidance][caf-lz], which places shared
connectivity/security services in **platform subscriptions** and workloads in **application
landing-zone subscriptions** with centralized policy and [hub-and-spoke connectivity][hub-spoke].

---

## Why a multi-subscription model is the best fit

### Least privilege / GIA

ACME Inc. explicitly asked how to deploy AKS and ARO for internal clients with the **minimum
rights possible**, called out the problematic `Microsoft.Authorization/*/Write` permission family,
and asked for pre-provisioned landing zones plus [custom roles][custom-roles]. A multi-subscription
landing-zone model is the cleanest way to enforce those boundaries because prerequisites can be
pre-created by the platform team and ODS automation can be granted **only scoped rights** on the
target workload subscriptions, in line with [Azure RBAC least-privilege best practices][rbac-bp].

### Why the single-subscription idea exists at all

The internal notes explicitly consider a one-subscription design because **one managed identity can
deploy multiple clusters in the same subscription**, and because a cross-subscription model would
otherwise introduce Palo Alto / inter-subscription communication complexity. That makes the
single-sub option attractive operationally in the very short term, especially while the governance
foundation is still forming.

### Why single-sub should not be the end state

The same notes flag **scale and boundary pressure** — ACME Inc. already references **130–140 AKS
clusters** and the need to size VNets for large node counts and "predict Azure limits." Those limits
are real and bounded: a single subscription is capped (for example, [**5,000 AKS clusters per
subscription** and **5,000 nodes per cluster**][aks-quotas]), and [subscription-wide service
limits][sub-limits] apply to networking, compute, and identity objects alike. At that scale, VNet
IP planning ([Azure CNI addressing][aks-cni]) and [large-cluster best practices][aks-large] become
first-class concerns. On the ARO side, control-plane scale-up can happen automatically while
scale-down must be explicitly requested, with financial/operational implications that need
governance and ownership clarity. This is exactly the blast-radius, quota, and accountability
problem that **multi-subscription boundaries are meant to contain**.

### Identity and Conditional Access realities

ACME Inc.'s internal notes on private AKS / Entra sign-in behavior conclude that **IP allow-listing
is not a reliable architectural control** for AKS creation/authentication flows, and that the clean
supported answer is [managed identity][aks-mi] / [workload identity][aks-wi] — not brittle
source-IP assumptions ([Conditional Access network conditions][ca-network],
[private AKS clusters][aks-private]). That pushes the design toward pre-provisioned landing zones,
managed identities, and [scoped RBAC][rbac-bp] instead of broad human/operator privileges.

---

## AKS vs ARO governance is not symmetric

> [!NOTE]
> One of the most important findings in the internal material is that **AKS and ARO cannot be
> governed as if they were identical Azure resource types.**

An internal governance summary states that ARO surfaced through [Azure Arc][arc-k8s] behaves as
`connectedClusters`, while AKS is `managedClusters`, so AKS-targeted policy sets don't automatically
apply to ARO the same way. In other words, **"uniform policy coverage" across AKS and ARO is not the
default product behavior** and must be solved as an architecture/governance pattern, not a support
fix.

That matters directly to the recommendation:

- Use **AKS-native governance** controls ([Azure Policy for Kubernetes][policy-k8s], plus
  [Kyverno][kyverno]) where they fit AKS best.
- Use **Arc / Kubernetes-native controls plus GitOps** where ARO requires a different enforcement
  path.

This also lines up with the internal ARO thread where managed identity was described as
non-negotiable, while the team documented gaps in ASO/Terraform support for ARO managed-identity
cluster creation at the time and considered a temporary wrapper pipeline as "Plan C." Publicly,
Microsoft now documents [managed-identity ARO clusters][aro-mi] as **GA**, including portal-based
deployment, which materially improves the viability of a secure ARO target pattern
([create an ARO cluster][aro-create], [ARO overview][aro-intro]).

---

## The two customer-proposed options

### Option 1 — Single subscription

> **Best use:** tactical bootstrap / temporary service-cell.

It reduces cross-subscription network friction, centralizes operations quickly, and simplifies the
first implementation of Argo CD + management automation because the identity and networking blast
radius are all inside one subscription. But it also **concentrates quota risk** ([subscription
limits][sub-limits], [AKS limits][aks-quotas]), weakens tenant/workload isolation, complicates
cost/showback separation, and gives you fewer native boundaries for least privilege over time —
especially once the estate grows beyond a few controlled service tiers.

### Option 2 — Management subscription + workload subscriptions

> **Best use:** strategic architecture, especially once the landing-zone foundation is in place.

This aligns better with [Azure landing zones][caf-lz], gives clearer ownership and policy
boundaries, supports pre-provisioned prerequisites, and matches the ODS "client-oriented"
deployment model more naturally. The main downside is that it requires **more platform readiness up
front**: identity scoping, network peering / private DNS / firewall pathing, and a clean agreement
on which team owns which prerequisite under GIA/security constraints.

---

## Comparison synthesis

| Criterion | Single subscription | Multi-subscription | Advantage | Executive reading |
| --- | --- | --- | --- | --- |
| **Least privilege** | Low to medium | High | 🟢 Multi-sub | Rights can be scoped per client or per workload. |
| **Network / Palo Alto** | Simple | More complex | 🔵 Single-sub | Cross-subscription requires more network coordination. |
| **Scalability** | Limited | Strong | 🟢 Multi-sub | Better management of quotas, costs, and boundaries. |
| **Governance** | Centralized but concentrated | Centralized with better boundaries | 🟢 Multi-sub | Better balance between central control and isolation. |
| **Time-to-value** | Fast | Medium | 🔵 Single-sub | Good transition model, weaker end state. |

> [!TIP]
> **Reading:** the **multi-subscription** option clearly wins on **security, governance, and
> durability**; the **single-subscription** option wins mainly on **start-up simplicity**.

---

## Microsoft-aligned alternatives

Beyond the customer's original two options, the report includes two Microsoft-aligned patterns:

1. **Landing-zone-aligned federated ODS** — central governance/tooling, shared
   connectivity/security subscriptions, and client/workload AKS/ARO clusters deployed into
   client-aligned application subscriptions with pre-provisioned prerequisites and
   [scoped managed identities][aks-mi]. See [Azure landing zone design principles][caf-design] and
   the [AKS baseline architecture][aks-baseline].
2. **Fleet-governed distributed AKS operations** — an [AKS Fleet Manager][fleet] overlay for
   multi-cluster namespace governance, quotas, RBAC, upgrades, resource placement, and staged
   Git-based deployment — paired with [Arc][arc-k8s]-aware handling for ARO where feature parity
   differs.

---

## How the design treats CAPI/CAPZ + Argo CD

For **AKS**, the design uses a clear split of responsibility:

- **Argo CD** = GitOps reconciler for platform add-ons, policy bundles, cluster configuration, and
  workload deployment standards ([Argo CD docs][argocd]).
- **CAPZ / ASO** = declarative infrastructure engine for AKS cluster lifecycle — exactly how the
  [AKS platform-engineering guidance][aks-pe] positions GitOps + Argo CD +
  [Cluster API Provider Azure (CAPZ)][capz] + [Azure Service Operator (ASO)][aso] together for
  Azure-native platform engineering on AKS.

For **ARO**, the design is more conservative:

- Use **Argo CD** for add-ons, policy/config standardization, and workload delivery where
  appropriate.
- Use a **managed-identity-compatible ARO provisioning path** (portal / ARM / Bicep / supported CLI)
  because the internal thread documented that ARO creation through the CAPZ/ASO/Terraform path was
  blocked by managed-identity support gaps at that time. Microsoft's docs now confirm
  [managed identity GA for ARO][aro-mi].

> [!NOTE]
> This repository's PoC also demonstrates how to keep Argo CD **Synced** against Kyverno's
> self-managed fields (CRD `spec.conversion`, ClusterPolicy admission defaults) via
> [`ignoreDifferences`][argocd-diff] — a practical detail when running GitOps governance at scale.

---

## Executive one-liner

> [!IMPORTANT]
> **Do not make the single-subscription design your destination.** Use it only if you need a
> near-term bridge around today's cross-subscription constraints, but build toward a
> **landing-zone-aligned multi-subscription ODS** with managed identities, scoped RBAC, GitOps
> standardization, and AKS/ARO-specific governance paths.

---

## Proof of Concept

A runnable **CAPI/CAPZ + Kyverno + Argo CD** governance PoC backs this report.

- 📓 **Operations runbook:** **[docs/runbook.md](docs/runbook.md)** — required GitHub secrets, the
  OIDC app registration, the `aksgov-poc-teardown` approval environment, the local-first script run
  order, and the customer-demo walkthrough.
- ⚙️ **Pipeline:** [`.github/workflows/aksgov-poc-demo.yml`](.github/workflows/aksgov-poc-demo.yml).

What it provisions and demonstrates:

| Stage | What happens |
| --- | --- |
| Management cluster | A CAPI/CAPZ/ASO management AKS cluster + Argo CD + Kyverno (Bicep + `clusterctl init`). |
| Workload clusters | Two workload AKS clusters provisioned declaratively via CAPZ/ASO. |
| GitOps fan-out | Argo CD `ApplicationSet`s install Kyverno and fan governance `ClusterPolicy` objects to every workload cluster. |
| Governance demo | A two-phase **Audit → Enforce** registry policy captures a real Kyverno `PolicyReport`, then blocks violating Pods; a minimum-Kubernetes-version policy is also demonstrated. |
| Evidence + wiki | CLI evidence is captured and published to the repository wiki. |
| Teardown | All Azure resources are removed behind a manual approval gate. |

---

## References

> [!TIP]
> Quotas and limits are the load-bearing constraint behind the single-vs-multi-subscription
> decision — start with the first three links below.

### Quotas & limits

- **Azure subscription & service limits** — [`azure-subscription-service-limits`][sub-limits]
- **AKS limits, SKUs & region availability** (5,000 clusters/subscription, 5,000 nodes/cluster, …) —
  [`aks/quotas-skus-regions`][aks-quotas]
- **View and request quota increases** — [`quotas/view-quotas`][quotas-view]
- **AKS best practices for large clusters** — [`aks/best-practices-performance-scale-large`][aks-large]
- **Azure CNI IP address planning** — [`aks/concepts-network-cni-overview`][aks-cni] ·
  [`aks/configure-azure-cni`][aks-cni-cfg]

### Landing zones, network & architecture

- **Azure landing zones (Cloud Adoption Framework)** — [`ready/landing-zone`][caf-lz]
- **Landing zone design principles** — [`ready/landing-zone/design-principles`][caf-design]
- **Hub-and-spoke network topology** — [`networking/architecture/hub-spoke`][hub-spoke]
- **AKS baseline reference architecture** — [`reference-architectures/containers/aks/baseline-aks`][aks-baseline]
- **Azure Well-Architected: AKS service guide** — [`well-architected/service-guides/azure-kubernetes-service`][aks-waf]

### Identity, RBAC & least privilege

- **AKS managed identity** — [`aks/use-managed-identity`][aks-mi]
- **AKS workload identity** — [`aks/workload-identity-overview`][aks-wi]
- **AKS access & identity concepts** — [`aks/concepts-identity`][aks-id]
- **Azure custom roles** (`Microsoft.Authorization/*`) — [`role-based-access-control/custom-roles`][custom-roles]
- **Azure RBAC best practices (least privilege)** — [`role-based-access-control/best-practices`][rbac-bp]
- **Conditional Access network conditions** — [`conditional-access/concept-assignment-network`][ca-network]
- **Private AKS clusters** — [`aks/private-clusters`][aks-private]

### Policy & governance enforcement

- **Azure Policy for Kubernetes** — [`governance/policy/concepts/policy-for-kubernetes`][policy-k8s]
- **Kyverno documentation** — [kyverno.io/docs][kyverno]

### Azure Red Hat OpenShift (ARO)

- **ARO overview** — [`openshift/intro-openshift`][aro-intro]
- **Create an ARO cluster** — [`openshift/howto-create-openshift-cluster`][aro-create]
- **Understand managed identities in ARO (GA)** — [`openshift/howto-understand-managed-identities`][aro-mi]

### Arc & multi-cluster fleet

- **Azure Arc-enabled Kubernetes** (`connectedClusters` vs `managedClusters`) — [`azure-arc/kubernetes/overview`][arc-k8s]
- **Azure Kubernetes Fleet Manager** — [`kubernetes-fleet/overview`][fleet]

### Platform engineering, GitOps & Cluster API

- **AKS platform engineering sample (GitOps + Argo CD + CAPZ + ASO)** — [Microsoft Learn sample][aks-pe] ·
  [`Azure-Samples/aks-platform-engineering`][aks-pe-gh]
- **Cluster API Provider Azure (CAPZ)** — [capz.sigs.k8s.io][capz]
- **Azure Service Operator (ASO)** — [azure.github.io/azure-service-operator][aso]
- **Argo CD** — [argo-cd.readthedocs.io][argocd] · [Diffing & `ignoreDifferences`][argocd-diff]
- **GitOps (Flux) on Azure Arc / AKS** — [`azure-arc/kubernetes/tutorial-use-gitops-flux2`][flux]

---

<!-- Reference links -->
[caf-lz]: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/
[caf-design]: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-principles
[hub-spoke]: https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke
[aks-baseline]: https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks/baseline-aks
[aks-waf]: https://learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-kubernetes-service
[sub-limits]: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits
[aks-quotas]: https://learn.microsoft.com/en-us/azure/aks/quotas-skus-regions
[quotas-view]: https://learn.microsoft.com/en-us/azure/quotas/view-quotas
[aks-large]: https://learn.microsoft.com/en-us/azure/aks/best-practices-performance-scale-large
[aks-cni]: https://learn.microsoft.com/en-us/azure/aks/concepts-network-cni-overview
[aks-cni-cfg]: https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni
[aks-mi]: https://learn.microsoft.com/en-us/azure/aks/use-managed-identity
[aks-wi]: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
[aks-id]: https://learn.microsoft.com/en-us/azure/aks/concepts-identity
[custom-roles]: https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles
[rbac-bp]: https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices
[ca-network]: https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-assignment-network
[aks-private]: https://learn.microsoft.com/en-us/azure/aks/private-clusters
[policy-k8s]: https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes
[kyverno]: https://kyverno.io/docs/
[aro-intro]: https://learn.microsoft.com/en-us/azure/openshift/intro-openshift
[aro-create]: https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster
[aro-mi]: https://learn.microsoft.com/en-us/azure/openshift/howto-understand-managed-identities
[arc-k8s]: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview
[fleet]: https://learn.microsoft.com/en-us/azure/kubernetes-fleet/overview
[aks-pe]: https://learn.microsoft.com/en-us/samples/azure-samples/aks-platform-engineering/aks-platform-engineering/
[aks-pe-gh]: https://github.com/Azure-Samples/aks-platform-engineering
[capz]: https://capz.sigs.k8s.io/
[aso]: https://azure.github.io/azure-service-operator/
[argocd]: https://argo-cd.readthedocs.io/en/stable/
[argocd-diff]: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
[flux]: https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/tutorial-use-gitops-flux2
