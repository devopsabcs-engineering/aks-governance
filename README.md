# aks-governance

Desjardins Kubernetes governance report delivered

Your Word report is ready: Desjardins_Kubernetes_Governance_Architecture_Report.docx

Bottom line

Strategic recommendation: move toward a landing-zone-aligned multi-subscription ODS (central governance/tooling, workload clusters in client-aligned landing zone subscriptions), while treating the single-subscription model only as a tactical bootstrap pattern if Desjardins needs a short path around current cross-subscription network/GIA friction.

That recommendation is grounded in Desjardins’ own ODS objectives: simplify AKS/ARO consumption, centralize observability/governance, support both client-oriented and mutualized service tiers, prefer AKS by default, and use ARO only for specific workload classes such as CP4D and MQ. It is also consistent with Microsoft’s landing-zone guidance, which places shared connectivity/security services in platform subscriptions and workloads in application landing zone subscriptions with centralized policy and hub-and-spoke connectivity.

Why this is the best fit

Least privilege / GIA: Desjardins explicitly asked how to deploy AKS and ARO for internal clients with the minimum rights possible, called out the problematic Microsoft.Authorization/*/Write permission family, and asked for pre-provisioned landing zones plus custom roles. A multi-subscription landing-zone model is the cleanest way to enforce those boundaries because prerequisites can be pre-created by the platform team and ODS automation can be granted only scoped rights on the target workload subscriptions.

Why the single-subscription idea exists at all: the internal notes explicitly consider a one-subscription design because one managed identity can deploy multiple clusters in the same subscription, and because a cross-subscription model would otherwise introduce Palo Alto/inter-subscription communication complexity. That makes the single-sub option attractive operationally in the very short term, especially while the governance foundation is still forming.

Why single-sub should not be the end state: the same notes also flag scale and boundary pressure—Desjardins already has notes referring to 130–140 AKS clusters and the need to size VNets for large node counts and “predict Azure limits.” On the ARO side, support notes also show that control-plane scale-up can happen automatically and scale-down must be explicitly requested, with financial/operational implications that need governance and ownership clarity. That is exactly the kind of blast-radius, quota, and accountability problem that multi-subscription boundaries are meant to contain.

Identity and conditional access realities: Desjardins’ internal notes on private AKS / Entra sign-in behavior conclude that IP allow-listing is not a reliable architectural control for AKS creation/authentication flows and that the clean supported answer is managed identity / workload identity, not brittle source-IP assumptions. That pushes the design toward pre-provisioned landing zones, managed identities, and scoped RBAC instead of broad human/operator privileges.

AKS vs ARO governance is not symmetric

One of the most important findings in your internal material is that AKS and ARO cannot be governed as if they were identical Azure resource types. An internal governance summary explicitly states that ARO surfaced through Azure Arc behaves as connectedClusters, while AKS is managedClusters, so AKS-targeted policy sets don’t automatically apply to ARO the same way. In other words, “uniform policy coverage” across AKS and ARO is not the default product behavior and must be solved as an architecture/governance pattern, not as a support fix.

That matters directly to your report’s recommendation: use AKS-native governance controls where they fit AKS best, and use Arc/Kubernetes-native controls plus GitOps where ARO requires a different enforcement path. This also lines up with the internal ARO thread where managed identity was described as non-negotiable, while the team documented gaps in ASO/Terraform support for ARO managed-identity cluster creation at the time and considered a temporary wrapper pipeline approach as Plan C. Publicly, Microsoft now documents managed identity-enabled ARO clusters as GA and also documents portal-based deployment for MI-backed ARO clusters, which materially improves the viability of a secure ARO target pattern.

What this means for the two customer-proposed options
Option 1 – Single subscription

Best use: tactical bootstrap / temporary service-cell.

It reduces cross-subscription network friction, centralizes operations quickly, and simplifies the first implementation of Argo CD + management automation because the identity and networking blast radius are all inside one subscription. But it also concentrates quota risk, weakens tenant/workload isolation, complicates cost/showback separation, and gives you fewer native boundaries for least privilege over time—especially once the estate grows beyond a few controlled service tiers.

Option 2 – Management subscription + workload subscriptions

Best use: strategic architecture, especially once the landing-zone foundation is in place.

This aligns better with Azure landing zones, gives clearer ownership and policy boundaries, supports pre-provisioned prerequisites, and matches the ODS “client-oriented” deployment model more naturally. The main downside is that it requires more platform readiness up front: identity scoping, network peering/private DNS/firewall pathing, and a clean agreement on which team owns which prerequisite under GIA/security constraints.

How the report treats CAPI/CAPZ + Argo CD

For AKS, the report uses a clear split of responsibility:

Argo CD = GitOps reconciler for platform add-ons, policy bundles, cluster configuration, and workload deployment standards.
CAPZ/ASO = declarative infrastructure engine for AKS cluster lifecycle, which is exactly how the AKS platform-engineering guidance positions GitOps + Argo CD + CAPZ + ASO together for Azure-native platform engineering on AKS.

For ARO, the report is more conservative:

Use Argo CD for add-ons, policy/config standardization, and workload delivery where appropriate.
Use a managed-identity-compatible ARO provisioning path (for example portal / ARM / Bicep / supported CLI workflows) because your own internal thread documented that ARO creation through the CAPZ/ASO/Terraform path was blocked by managed-identity support gaps at that time. Microsoft’s ARO release notes now materially improve this picture by confirming managed identity GA for ARO clusters.
Microsoft-aligned alternatives included in the report

The document includes two Microsoft-aligned patterns beyond the customer’s original two options:

Landing-zone-aligned federated ODS
 Central governance/tooling, shared connectivity/security subscriptions, and client/workload AKS/ARO clusters deployed into client-aligned application subscriptions with pre-provisioned prerequisites and scoped managed identities.

Fleet-governed distributed AKS operations
 An AKS fleet-management overlay for multi-cluster namespace governance, quotas, RBAC, upgrades, resource placement, and staged Git-based deployment—paired with Arc-aware handling for ARO where feature parity differs.

Executive one-liner

If I compress the whole report into one sentence:

Do not make the single-subscription design your destination. Use it only if you need a near-term bridge around today’s cross-subscription constraints, but build toward a landing-zone-aligned multi-subscription ODS with managed identities, scoped RBAC, GitOps standardization, and AKS/ARO-specific governance paths.

If you want, next I can turn this into a 6-slide executive deck or a 1-page decision memo in the same style.
