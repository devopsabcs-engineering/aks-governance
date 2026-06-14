# Research: CAPI + CAPZ + ASO for declarative AKS provisioning (Phase 1 PoC)

Date: 2026-06-14
Status: Complete (with date-sensitivity flags noted in Open Items)

Goal: Inform a Phase 1 PoC in a single Azure subscription where one management
cluster creates 2 workload AKS clusters from input YAMLs, parametrized,
pipeline-driven and teardownable.

---

## Research Topics / Questions

1. CAPI + CAPZ for AKS managed clusters via ASO-backed resources (AzureASOManagedCluster / AzureASOManagedControlPlane / AzureASOManagedMachinePool). Latest GA/stable API versions + example manifests.
2. clusterctl init for Azure: prerequisites, identity/auth (workload identity vs service principal), required env vars.
3. Management cluster options for PoC: kind (local) vs small AKS management cluster. Tradeoffs for pipeline-driven teardownable PoC.
4. ASO role and version compatibility with CAPZ for managed AKS. Auth options (workload identity federation).
5. Bootstrapping minimal reproducible setup: install CAPI+CAPZ, define 2 workload clusters, apply, retrieve kubeconfig.
6. Parametrizing input YAML (clusterctl generate cluster / envsubst / Helm / Kustomize).
7. Teardown: clean deletion (kubectl delete cluster), Azure resource removal, finalizer pitfalls.

---

## Executive Summary

- The current recommended path for declarative AKS via CAPZ is the
  ASO-backed managed cluster API: `AzureASOManagedCluster`,
  `AzureASOManagedControlPlane`, `AzureASOManagedMachinePool`. These are at
  API version `infrastructure.cluster.x-k8s.io/v1beta1` (graduated from
  `v1alpha1`; the two are equivalent and migration is low risk). The feature
  is described by CAPZ docs as "alpha, not experimental, fully supported" and
  is enabled by default (feature gate `ASOAPI` / env `EXP_ASO_API`). Requires
  the CAPI `MachinePool=true` feature gate (default on).
- ASO (Azure Service Operator v2) is installed automatically by CAPZ during
  `clusterctl init --infrastructure azure`. The ASO-backed CAPZ resources
  embed literal ASO resource specs inline under `spec.resources` (e.g. an ASO
  `ManagedCluster` at `containerservice.azure.com/v1api20240901`, a
  `ResourceGroup` at `resources.azure.com/v1api20200601`,
  `ManagedClustersAgentPool` for node pools).
- Recommended auth: Azure Workload Identity (OIDC federation) for both CAPZ
  and ASO. Service Principal with client secret is the simplest for a
  short-lived single-sub PoC.
- Management cluster for a teardownable pipeline PoC: a local `kind` cluster
  is the lightest, fully ephemeral option and is what CAPZ/CAPI quick-starts
  use. A small AKS management cluster is better if the management cluster must
  persist between pipeline runs or use Azure-native identity (IMDS/UAMI).
- Teardown is `kubectl delete cluster <name>` (NOT `kubectl delete -f`), which
  cascades through CAPI -> CAPZ -> ASO -> Azure resource group deletion.

---

## 1. CAPI + CAPZ for AKS managed clusters (ASO-backed path)

### 1.1 The three ASO-backed resources

CAPZ implements the ASO-backed managed cluster path with:

- `AzureASOManagedControlPlane` — embeds an ASO `ManagedCluster` (the AKS
  cluster control plane).
- `AzureASOManagedCluster` — embeds an ASO `ResourceGroup` (the
  infrastructure object referenced by the CAPI `Cluster`).
- `AzureASOManagedMachinePool` — embeds an ASO `ManagedClustersAgentPool`
  (one per AKS node pool). At least one pool with `mode: System` is required.

These replace the older `AzureManagedControlPlane` / `AzureManagedCluster` /
`AzureManagedMachinePool` (non-ASO) resources, which still exist and are GA but
expose only a CAPZ-curated subset of AKS fields. The ASO-backed API lets you
set, in full, any ASO-supported version/field of the underlying Azure
resource via the inline `spec.resources` literal.

API version (current): `infrastructure.cluster.x-k8s.io/v1beta1`.

Notes:
- Introduced in CAPZ v1.15.0 as `v1alpha1`; `v1beta1` is now the storage
  version. `v1alpha1` and `v1beta1` are equivalent.
- The ASO API resources embedded inline carry their own ASO apiVersions:
  - `resources.azure.com/v1api20200601` (ResourceGroup)
  - `containerservice.azure.com/v1api20240901` (ManagedCluster,
    ManagedClustersAgentPool)
- Preview AKS fields: set `spec.enablePreviewFeatures: true` on the
  control plane and patch via `asoManagedClusterPatches` /
  `asoManagedClustersAgentPoolPatches`.

### 1.2 Full working example (the upstream `aks-aso` flavor)

Source: templates/cluster-template-aks-aso.yaml in
kubernetes-sigs/cluster-api-provider-azure (main). Reconstructed runnable
manifest with the `${VAR}` placeholders the flavor expects:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  controlPlaneRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: AzureASOManagedControlPlane
    name: ${CLUSTER_NAME}
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: AzureASOManagedCluster
    name: ${CLUSTER_NAME}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureASOManagedControlPlane
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20240901
    kind: ManagedCluster
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}
    spec:
      dnsPrefix: ${CLUSTER_NAME}
      identity:
        type: SystemAssigned
      location: ${AZURE_LOCATION}
      networkProfile:
        networkPlugin: azure
      owner:
        name: ${CLUSTER_NAME}
      servicePrincipalProfile:
        clientId: msi
  version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureASOManagedCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  resources:
  - apiVersion: resources.azure.com/v1api20200601
    kind: ResourceGroup
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}
    spec:
      location: ${AZURE_LOCATION}
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: ${CLUSTER_NAME}-pool0
  namespace: default
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: ${WORKER_MACHINE_COUNT:=2}
  template:
    metadata: {}
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: ${CLUSTER_NAME}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: AzureASOManagedMachinePool
        name: ${CLUSTER_NAME}-pool0
      version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureASOManagedMachinePool
metadata:
  name: ${CLUSTER_NAME}-pool0
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20240901
    kind: ManagedClustersAgentPool
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}-pool0
    spec:
      azureName: pool0
      mode: System
      owner:
        name: ${CLUSTER_NAME}
      type: VirtualMachineScaleSets
      vmSize: ${AZURE_NODE_MACHINE_TYPE}
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: ${CLUSTER_NAME}-pool1
  namespace: default
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: ${WORKER_MACHINE_COUNT:=2}
  template:
    metadata: {}
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: ${CLUSTER_NAME}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: AzureASOManagedMachinePool
        name: ${CLUSTER_NAME}-pool1
      version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureASOManagedMachinePool
metadata:
  name: ${CLUSTER_NAME}-pool1
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20240901
    kind: ManagedClustersAgentPool
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}-pool1
    spec:
      azureName: pool1
      mode: User
      owner:
        name: ${CLUSTER_NAME}
      type: VirtualMachineScaleSets
      vmSize: ${AZURE_NODE_MACHINE_TYPE}
```

Key behaviors:
- `servicePrincipalProfile.clientId: msi` + `identity.type: SystemAssigned`
  makes AKS use a system-assigned managed identity for the cluster.
- The `serviceoperator.azure.com/credential-from` annotation on each ASO
  resource points to the ASO credential secret to use
  (`${ASO_CREDENTIAL_SECRET_NAME}`), enabling per-cluster/per-namespace
  credentials.
- The CAPI `Cluster` apiserver endpoint is auto-populated from the AKS API;
  do not set it.
- `${WORKER_MACHINE_COUNT:=2}` and similar `:=` syntax are envsubst-style
  defaults baked into the flavor template.

### 1.3 Env vars consumed by the `aks-aso` flavor

```bash
export CLUSTER_NAME="poc-aks-1"          # RFC1123: lowercase alnum, '-' or '.'
export AZURE_LOCATION="eastus"
export KUBERNETES_VERSION="v1.35.4"       # example; pick a currently-supported AKS version
export WORKER_MACHINE_COUNT=2
export AZURE_NODE_MACHINE_TYPE="Standard_D2s_v3"
export ASO_CREDENTIAL_SECRET_NAME="aso-credentials"  # name of the ASO cred secret
```

---

## 2. clusterctl init for Azure

### 2.1 Prerequisites
- kubectl, kind (min v0.32.0) + Docker (or any existing k8s >= v1.20), Helm.
- clusterctl binary (observed current release line v1.13.x; example commands
  used v1.13.2). Install via curl/brew/choco per CAPI quick-start.
- Azure CLI (`az`), logged in to the target subscription.
- An Azure identity (workload identity UAMI/SP or SP+secret) with at least
  `Contributor` on the subscription (or scoped RG). For ASO managed AKS with
  local accounts disabled, the identity also needs
  `Azure Kubernetes Service RBAC Cluster Admin`.

### 2.2 Initialize the management cluster

```bash
# Local management cluster
kind create cluster

# (MachinePool is on by default; explicit for clarity)
export EXP_MACHINE_POOL=true
# ASO-backed API is on by default; explicit for clarity
export EXP_ASO_API=true

# Install CAPI core + kubeadm providers + CAPZ (this also installs ASO)
clusterctl init --infrastructure azure
```

`clusterctl init --infrastructure azure` fetches and installs: cert-manager,
cluster-api core, kubeadm bootstrap + control-plane providers, the CAPZ
infrastructure provider, and Azure Service Operator (CAPZ bundles ASO).

### 2.3 Identity / auth — two options

Option A — Service Principal + client secret (simplest for short PoC):
```bash
az ad sp create-for-rbac --role Contributor \
  --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}" --sdk-auth > sp.json
export AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId sp.json)"
export AZURE_CLIENT_ID="$(jq -r .clientId sp.json)"
export AZURE_CLIENT_SECRET="$(jq -r .clientSecret sp.json)"
export AZURE_TENANT_ID="$(jq -r .tenantId sp.json)"
```
For the classic (non-ASO) flavor, CAPZ also wants an AzureClusterIdentity +
a k8s secret holding the client secret:
```bash
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"
export CLUSTER_IDENTITY_NAME="cluster-identity"
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" \
  --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"
```
For the ASO-backed `aks-aso` flavor, ASO reads credentials from the secret
named by `serviceoperator.azure.com/credential-from`
(`${ASO_CREDENTIAL_SECRET_NAME}`). Create it as an ASO credential secret (see
section 4.2).

Option B — Workload Identity (recommended): set up OIDC issuer + federated
identity credentials for both the CAPZ service account
(`capz-manager` in `capz-system`) and the ASO service account
(`azureserviceoperator-default` in `azureserviceoperator-system`). With kind
this requires generating a SA signing keypair, publishing a JWKS discovery doc
to an Azure storage container, and creating the kind cluster with
`service-account-issuer`/`service-account-signing-key-file` configured. Then
the AzureClusterIdentity uses `type: WorkloadIdentity` (no `clientSecret`).
This is heavier to bootstrap on kind; on an AKS management cluster it is much
simpler because AKS provides the OIDC issuer natively.

---

## 3. Management cluster options for the PoC

| Option | Pros | Cons |
| --- | --- | --- |
| kind (local/CI runner) | Fully ephemeral, zero Azure cost, trivial create/delete (`kind create/delete cluster`), what upstream quick-starts use, ideal for "create then teardown" pipelines | Not for production; workload-identity setup on kind is involved (needs SA keypair + JWKS storage); management cluster state is lost on teardown unless `clusterctl move` is used; the runner must have Docker |
| Small AKS management cluster | Native OIDC issuer makes workload identity easy; can use IMDS/UAMI auth (no secrets); persists across pipeline runs; closer to production | Costs money continuously; must itself be provisioned/torn down; chicken-and-egg if you also tear down management infra |

Recommendation for a teardownable, pipeline-driven Phase 1 PoC: use kind on
the pipeline agent. Each pipeline run creates a fresh kind management cluster,
`clusterctl init`s it, applies the 2 workload cluster YAMLs, retrieves
kubeconfigs, and at teardown deletes the workload Clusters first (so Azure
resources are removed) and then `kind delete cluster`.

Important pivot caveat: if you `kind delete cluster` WITHOUT first deleting the
workload `Cluster` objects, the management cluster (and its finalizers/state)
is gone but the Azure AKS clusters remain — orphaned and costing money. Always
delete workload Clusters before destroying the management cluster, OR use
`clusterctl move` to pivot management state to a persistent cluster.

---

## 4. ASO (Azure Service Operator v2)

### 4.1 Role with CAPZ
- ASO is the thin Azure-resource reconciler that CAPZ delegates to in the
  ASO-backed API. CAPZ becomes "the thinnest possible translation layer
  between ASO and Cluster API." The inline `spec.resources` are literal ASO
  CRs that ASO creates/updates/deletes in Azure.
- ASO is installed automatically by `clusterctl init --infrastructure azure`
  (CAPZ bundles a specific ASO version). Do not separately Helm-install ASO
  into a CAPZ management cluster unless you know you need to.
- Version compatibility: use the ASO version that CAPZ ships for your CAPZ
  release; the embedded ASO apiVersions in the flavor
  (`v1api20240901`, `v1api20200601`) must be CRD versions that the bundled ASO
  serves. CRD availability is controlled by ASO's `crdPattern`
  (CAPZ configures this to include `containerservice.azure.com/*`,
  `resources.azure.com/*`, etc.).

### 4.2 ASO authentication options (recommended: workload identity)
ASO supports (in order of recommendation):
1. Workload Identity (OIDC + UAMI or SP) — recommended for production.
2. Service Principal + client secret.
3. Service Principal + client certificate.
4. Managed Identity via IMDS (only when ASO runs on Azure infra, e.g. an AKS
   management cluster with a UAMI assigned).
5. (Deprecated) aad-pod-identity.

Credential scope: Global, Namespace, or Resource (most specific wins). The
CAPZ flavor uses the Resource/Namespace scope via the
`serviceoperator.azure.com/credential-from: <secret-name>` annotation.

ASO credential secret (Service Principal + secret) for the PoC:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aso-credentials        # == ${ASO_CREDENTIAL_SECRET_NAME}
  namespace: default           # same namespace as the AzureASOManaged* resources
stringData:
  AZURE_SUBSCRIPTION_ID: "<sub-id>"
  AZURE_TENANT_ID: "<tenant-id>"
  AZURE_CLIENT_ID: "<sp-app-id>"
  AZURE_CLIENT_SECRET: "<sp-secret>"
```

ASO credential secret (Workload Identity) — omit the client secret, add the
workload-identity flag:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aso-credentials
  namespace: default
stringData:
  AZURE_SUBSCRIPTION_ID: "<sub-id>"
  AZURE_TENANT_ID: "<tenant-id>"
  AZURE_CLIENT_ID: "<uami-or-app-client-id>"
  USE_WORKLOAD_IDENTITY_AUTH: "true"
```
Federated credential subject for ASO's controller SA:
`system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default`
audience `api://AzureADTokenExchange`.

Disabled local accounts caveat (e.g. AKS Automatic / AAD-only): ASO cannot
fetch `adminCredentials`; specify `userCredentials` with a DIFFERENT secret
name than `${CLUSTER_NAME}-kubeconfig` so CAPZ and ASO don't overwrite each
other:
```yaml
spec:
  operatorSpec:
    secrets:
      userCredentials:
        name: ${CLUSTER_NAME}-user-kubeconfig   # NOT ${CLUSTER_NAME}-kubeconfig
        key: value
```
The ASO identity must then hold `Azure Kubernetes Service RBAC Cluster Admin`.

---

## 5. Bootstrapping minimal reproducible setup (2 workload clusters)

End-to-end with envsubst templating (recommended for a pipeline because it
is provider-agnostic and explicit). Either generate from the flavor with
`clusterctl generate cluster --flavor aks-aso`, or keep a checked-in template
and `envsubst` it.

### 5.1 One-time management cluster bring-up
```bash
kind create cluster
export EXP_MACHINE_POOL=true
export EXP_ASO_API=true
clusterctl init --infrastructure azure
# wait for providers
kubectl wait --for=condition=Available --timeout=300s \
  -n capz-system deployment/capz-controller-manager
```

### 5.2 ASO credentials (SP path)
```bash
kubectl apply -f aso-credentials.secret.yaml   # the Secret from 4.2 in 'default'
```

### 5.3 Generate + apply 2 workload clusters
```bash
# Cluster 1
export CLUSTER_NAME="poc-aks-1" AZURE_LOCATION="eastus" \
       KUBERNETES_VERSION="v1.35.4" WORKER_MACHINE_COUNT=2 \
       AZURE_NODE_MACHINE_TYPE="Standard_D2s_v3" \
       ASO_CREDENTIAL_SECRET_NAME="aso-credentials"
clusterctl generate cluster "${CLUSTER_NAME}" --flavor aks-aso \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --worker-machine-count "${WORKER_MACHINE_COUNT}" > poc-aks-1.yaml
kubectl apply -f poc-aks-1.yaml

# Cluster 2 (different name/region/size as desired)
export CLUSTER_NAME="poc-aks-2" AZURE_LOCATION="westus3"
clusterctl generate cluster "${CLUSTER_NAME}" --flavor aks-aso \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --worker-machine-count "${WORKER_MACHINE_COUNT}" > poc-aks-2.yaml
kubectl apply -f poc-aks-2.yaml
```

### 5.4 Watch + retrieve kubeconfig per workload cluster
```bash
kubectl get clusters -A
clusterctl describe cluster poc-aks-1
clusterctl describe cluster poc-aks-2

# AKS-managed clusters publish ${CLUSTER_NAME}-kubeconfig secret; clusterctl reads it:
clusterctl get kubeconfig poc-aks-1 > poc-aks-1.kubeconfig
clusterctl get kubeconfig poc-aks-2 > poc-aks-2.kubeconfig
kubectl --kubeconfig=./poc-aks-1.kubeconfig get nodes
kubectl --kubeconfig=./poc-aks-2.kubeconfig get nodes
```
Note: AKS provides its own CNI/cloud-provider; you do NOT install Calico/
cloud-provider-azure for managed AKS (that step in the CAPI quick-start is
only for self-managed kubeadm clusters).

---

## 6. Parametrizing the input YAML

Three viable approaches; pick one for the pipeline:

1. clusterctl generate cluster --flavor aks-aso (built-in): variables come
   from env vars or `$XDG_CONFIG_HOME/cluster-api/clusterctl.yaml`. Variables
   exposed by the aks-aso flavor: `CLUSTER_NAME`, `AZURE_LOCATION`,
   `KUBERNETES_VERSION` (also `--kubernetes-version`), `WORKER_MACHINE_COUNT`
   (also `--worker-machine-count`), `AZURE_NODE_MACHINE_TYPE`,
   `ASO_CREDENTIAL_SECRET_NAME`. Cleanest because the template is maintained
   upstream.
2. envsubst over a checked-in copy of the template: full control, no clusterctl
   template fetch at apply time. Use `${VAR}` and `${VAR:=default}`.
   `envsubst < template.yaml | kubectl apply -f -`.
3. Kustomize or Helm: wrap the template; good if you also overlay extra ASO
   resources (VNet, NSG) or per-cluster patches. For the ASO-backed API,
   per-cluster differences can also be expressed via `asoManagedClusterPatches`.

For 2 clusters that differ only by name/region/size/version, approach 1 in a
loop (or approach 2 with a per-cluster `.env`) is the simplest and most
reproducible for CI.

Example parametrization matrix (one .env per cluster):
```
# poc-aks-1.env
CLUSTER_NAME=poc-aks-1
AZURE_LOCATION=eastus
KUBERNETES_VERSION=v1.35.4
WORKER_MACHINE_COUNT=2
AZURE_NODE_MACHINE_TYPE=Standard_D2s_v3
ASO_CREDENTIAL_SECRET_NAME=aso-credentials
```

---

## 7. Teardown

### 7.1 Clean per-cluster deletion (the supported path)
```bash
kubectl delete cluster poc-aks-1
kubectl delete cluster poc-aks-2
```
Deleting the CAPI `Cluster` object cascades: CAPI -> CAPZ AzureASOManaged*
-> ASO ManagedCluster/ResourceGroup -> Azure deletes the AKS cluster and its
resource group. Because the ASO `ResourceGroup` is the owner, its deletion
removes the contained AKS resources.

IMPORTANT (from CAPI docs): always delete the `Cluster` object. Do NOT use
`kubectl delete -f cluster.yaml`; deleting the whole template can leave
pending Azure resources requiring manual cleanup.

Verify Azure cleanup:
```bash
az group show -n poc-aks-1 -o table     # should be NotFound when done
az aks list -o table
```

### 7.2 Management cluster teardown (kind)
```bash
# ONLY after workload clusters are confirmed deleted in Azure:
kind delete cluster
```

### 7.3 Finalizer pitfalls
- Finalizers on `Cluster`, `AzureASOManaged*`, `MachinePool`, and the ASO CRs
  block deletion until Azure resources are gone. If a delete hangs, inspect
  with `clusterctl describe cluster <name>` and check ASO resource conditions.
- Do NOT blindly strip finalizers on a live cluster — that orphans Azure
  resources (they keep billing). Force-removing finalizers
  (`kubectl patch ... -p '{"metadata":{"finalizers":null}}'`) is only the
  documented escape hatch for the migration/adoption flow where you have
  paused reconciliation and intend the Azure resources to survive.
- If you destroy the management cluster before deleting workload Clusters, the
  finalizer-driven cleanup never runs and AKS clusters are orphaned. Recovery:
  delete the leftover resource groups manually with `az group delete -n <rg>`,
  or re-create a management cluster and `clusterctl move`/adopt before deleting.
- Order matters in pipelines: delete workload Clusters, wait for Azure RGs to
  disappear, THEN delete the kind management cluster.

---

## 8. Version numbers observed (date-sensitive — today 2026-06-14)

- CAPZ ASO-backed API: `infrastructure.cluster.x-k8s.io/v1beta1` (was
  `v1alpha1`, introduced CAPZ v1.15.0). Feature: "alpha, not experimental,
  fully supported"; default-on; gate `ASOAPI` / `EXP_ASO_API`.
- Embedded ASO apiVersions in flavor: `containerservice.azure.com/v1api20240901`
  (ManagedCluster, ManagedClustersAgentPool), `resources.azure.com/v1api20200601`
  (ResourceGroup). Newer ASO `containerservice` API dates likely exist now;
  confirm against the ASO reference and the CAPZ-bundled ASO version before
  pinning.
- clusterctl: example commands referenced v1.13.2; CAPI core providers install
  at whatever the current clusterctl resolves.
- kind: minimum v0.32.0.
- KUBERNETES_VERSION example `v1.35.4` (must be a currently AKS-supported
  version at apply time — verify with `az aks get-versions -l <region>`).
- Docs caching/date risk: the CAPZ book and ASO docs evolve; the exact
  embedded ASO API date and the `v1beta1` vs `v2`-candidate status may have
  advanced. Re-fetch the live `templates/cluster-template-aks-aso.yaml` and
  the CAPZ "ASO Managed Clusters" page at implementation time to confirm the
  current apiVersions and flavor variable names.

---

## References

- CAPZ — ASO Managed Clusters (AKS): https://capz.sigs.k8s.io/managed/asomanagedcluster
- CAPZ — Managed Clusters (AKS) overview / clusterctl flavor: https://capz.sigs.k8s.io/managed/managedcluster
- CAPZ — aks-aso flavor template (raw): https://github.com/kubernetes-sigs/cluster-api-provider-azure/blob/main/templates/cluster-template-aks-aso.yaml
- CAPZ — Workload Identity: https://capz.sigs.k8s.io/topics/workload-identity
- CAPZ — CAPI v1beta1 API reference: https://capz.sigs.k8s.io/reference/v1beta1-api
- CAPI — Quick Start (clusterctl init, generate, teardown): https://cluster-api.sigs.k8s.io/user/quick-start
- ASO v2 — Authentication overview: https://azure.github.io/azure-service-operator/guide/authentication/
- ASO v2 — Credential format (workload identity / SP / cert / IMDS): https://azure.github.io/azure-service-operator/guide/authentication/credential-format/
- ASO v2 — Credential scope: https://azure.github.io/azure-service-operator/guide/authentication/credential-scope/
- ASO v2 — CRD management (crdPattern): https://azure.github.io/azure-service-operator/guide/crd-management/
- ASO v2 — ContainerService reference: https://azure.github.io/azure-service-operator/reference/containerservice/

---

## Open Items / Next Research (not completed this session)

- [ ] Confirm the exact ASO version CAPZ bundles for the latest CAPZ release
      and whether a newer `containerservice.azure.com/v1apiYYYYMMDD` is the
      current default in `cluster-template-aks-aso.yaml` (re-fetch at build).
- [ ] Validate the precise federated identity subjects/namespaces for CAPZ
      (`capz-manager` / `capz-system`) and ASO
      (`azureserviceoperator-default` / `azureserviceoperator-system`) against
      the installed manifests, since SA names/namespaces can drift by version.
- [ ] Determine whether the PoC pipeline should use `clusterctl move` to a
      persistent AKS management cluster (to survive runner teardown) vs.
      fully ephemeral kind each run.
- [ ] Pin a known-good AKS `KUBERNETES_VERSION` per target region via
      `az aks get-versions` at pipeline time.
- [ ] Decide CNI/network plugin and whether to extend the ASO inline
      `ManagedCluster` spec (e.g. `azure` vs `cilium`/overlay, network policy)
      and confirm field availability in the chosen ASO API version.
- [ ] Confirm whether SystemAssigned identity (`servicePrincipalProfile.clientId: msi`)
      is acceptable, or whether a UserAssigned identity per workload cluster is
      required for downstream RBAC.

## Clarifying Questions

1. Auth model for the PoC: is Service Principal + client secret acceptable for
   speed, or must the PoC use Workload Identity federation from the start?
2. Management cluster lifecycle: should it be fully ephemeral kind per pipeline
   run, or a persistent (AKS) management cluster that workload clusters are
   moved/adopted into?
3. Are the 2 workload clusters meant to differ (region, version, node SKU,
   node count) or be identical except for name? This drives the parametrization
   approach (loop vs per-cluster .env vs Kustomize overlays).
4. Any networking constraints (existing VNet/subnet, CNI choice, private
   cluster) that must be expressed in the ASO `ManagedCluster` spec?
5. Single subscription confirmed — is there a target resource-group naming
   convention, or is one RG per workload cluster (as the flavor defaults) fine?
