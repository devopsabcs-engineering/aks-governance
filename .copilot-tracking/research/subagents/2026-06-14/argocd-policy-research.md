# Research: ArgoCD + Policy Governance for AKS PoC

Status: Complete
Date: 2026-06-14
Author: Researcher Subagent

## Research Topics / Questions

1. ArgoCD install for PoC (Helm vs manifests vs Operator); app-of-apps bootstrap from git.
2. ArgoCD multi-cluster registration to CAPI/CAPZ-provisioned workload clusters; ApplicationSet cluster generators.
3. Policy engine choice (Gatekeeper/OPA vs Kyverno vs Azure Policy) — recommend ONE primary for a customer demo.
4. Example A — Deny images from docker.io and quay.io (Kyverno + Gatekeeper).
5. Example B — Impose minimum Kubernetes version (cluster-level via CAPZ/ASO + Azure Policy; CR-validation via Kyverno on mgmt cluster).
6. GitOps wiring — deliver policies via ArgoCD Application; demo a violation for screenshots.

---

## 1. ArgoCD — Install + Bootstrap

### 1.1 Install options compared

| Method | When to use | PoC verdict |
| --- | --- | --- |
| **Install manifests** (`kubectl apply -f .../manifests/install.yaml`) | Fastest, single command, pinned by branch/tag | Good for a throwaway demo |
| **Helm chart** (`argo/argo-cd`) | Declarative, GitOps-managed, parameterized values, easy HA/ingress toggles, self-manageable | **RECOMMENDED for the PoC** — lives in git, reproducible, fits the "everything is a manifest" story |
| **ArgoCD Operator** (argoproj-labs / community-operators) | Multi-instance lifecycle management, OpenShift GitOps | Overkill for a 2-control demo; adds an extra moving part |

**Recommendation:** Install Argo CD via the **Helm chart**, delivered itself by a thin bootstrap (Terraform `helm_release`, `helm install`, or a Flux/kubectl one-liner during cluster provisioning). This keeps the install declarative and lets Argo CD later "manage itself."

Reference install (pinned, server-side apply is required because the ApplicationSet CRD exceeds the client-side 262 KB annotation limit):

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.0/manifests/install.yaml
```

Helm equivalent (PoC values):

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set configs.params."server\.insecure"=true   # demo only; front with ingress/TLS for real
```

Initial admin password: `argocd admin initial-password -n argocd` (delete `argocd-initial-admin-secret` after first login). Access for the demo via `kubectl port-forward svc/argocd-server -n argocd 8080:443` or `--set server.service.type=LoadBalancer`.

Source: [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/).

### 1.2 App-of-apps bootstrap pattern

A single **root/parent Application** points at a git folder that contains only child `Application` manifests. Syncing the root recursively creates/syncs all children — this is how you bootstrap an entire cluster's config from git in one click.

Root Application (the only thing you apply manually / via bootstrap):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete children
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/aks-governance.git
    targetRevision: HEAD
    path: gitops/apps           # folder full of child Application manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

A child Application, e.g. the policy engine install:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://kyverno.github.io/kyverno/   # helm repo
    chart: kyverno
    targetRevision: 3.2.6
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true, ServerSideApply=true ]
```

Notes:
- App-of-apps is admin-only — only admins should have push access to the parent's repo/path (the `project` field grants privilege).
- Use **sync waves** (`argocd.argoproj.io/sync-wave` annotation) so the policy engine (CRDs + controller) installs in an earlier wave than the policies that depend on its CRDs. Example: Kyverno install = wave `0`, ClusterPolicies = wave `1`.

Source: [Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/), [Declarative Setup → App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/).

---

## 2. ArgoCD — Multi-cluster registration + ApplicationSet

### 2.1 Topology for this PoC

A **management cluster** runs Argo CD (and, with CAPI/CAPZ, the cluster lifecycle controllers). Argo CD registers each **CAPI-provisioned workload cluster** as a target and deploys policy + workload config to them.

### 2.2 Registering a workload cluster

Two ways:

**A. CLI (imperative, quickest for a demo):**
```bash
kubectl config get-contexts -o name
argocd cluster add <workload-context>   # installs argocd-manager SA + ClusterRole on the target, stores a cluster Secret
```

**B. Declarative cluster Secret (GitOps-friendly).** Argo CD stores every managed cluster as a `Secret` labeled `argocd.argoproj.io/secret-type: cluster` in the `argocd` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: workload-cluster-1
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    # custom labels used by ApplicationSet cluster generator + selectors:
    environment: poc
    type: workload
type: Opaque
stringData:
  name: workload-cluster-1
  server: https://<workload-apiserver>:443
  config: |
    {
      "bearerToken": "<sa-token>",
      "tlsClientConfig": { "insecure": false, "caData": "<base64 CA>" }
    }
```

**CAPI/CAPZ tie-in:** CAPI writes a `<clustername>-kubeconfig` Secret into the management cluster for each workload cluster. A small job/script (or a tool like the `argocd-cluster-register` pattern / Sveltos / the cluster-api Argo addon) converts that kubeconfig into an Argo CD cluster Secret with the labels above. Bearer-token + caData is the field set Argo CD needs.

**AKS-specific auth (if registering AKS via AAD)**: Argo CD supports `execProviderConfig` calling `argocd-k8s-auth azure` (wraps `kubelogin`), with `AAD_LOGIN_METHOD` of `workloadidentity` / `spn` / `msi` etc. Relevant if workload clusters are AAD-enabled AKS rather than CAPZ self-managed. Source: [Declarative Setup → Clusters → AKS](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters).

### 2.3 ApplicationSet with the cluster generator (recommended for "deploy to every workload cluster")

The **cluster generator** reads the cluster Secrets and produces one Application per matching cluster automatically — ideal for fanning policies out to all workload clusters:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: governance-policies
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters:
        selector:
          matchLabels:
            type: workload          # only workload clusters, excludes mgmt/in-cluster
  template:
    metadata:
      name: 'policies-{{.name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<org>/aks-governance.git
        targetRevision: HEAD
        path: gitops/policies/kyverno   # folder of ClusterPolicy YAML
      destination:
        server: '{{.server}}'
        namespace: kyverno
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ CreateNamespace=true ]
```

Useful extras:
- A label selector that matches on any cluster-secret label automatically **excludes the local/in-cluster** target (it has no Secret), so policies only land on remote workload clusters.
- `argocd.argoproj.io/auto-label-cluster-info: "true"` on a cluster Secret makes Argo CD auto-label it with `argocd.argoproj.io/kubernetes-version`, which the generator can select on — a lightweight way to target clusters by K8s version.
- A **matrix generator** (git directories × clusters) lets you deploy per-cluster app sets from a git layout.

Source: [ApplicationSet Cluster Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/).

---

## 3. Policy Engine Choice — Recommendation

### 3.1 Comparison for a customer demo

| Criterion | **Kyverno** | Gatekeeper (OPA) | Azure Policy for AKS |
| --- | --- | --- | --- |
| Policy language | Native Kubernetes YAML (also CEL) | Rego (separate DSL) | Built-ins + Gatekeeper under the hood (constraint templates) |
| Readability for customers | **High** — looks like K8s manifests | Medium — Rego is unfamiliar | High for built-ins, low for custom |
| Image-registry handling | **Auto-parses `image.registry`, resolves implicit `docker.io` + `library/`** | Prefix string match only (manual `/` handling) | Built-in "allowed images" (regex) |
| Install via GitOps | **Helm chart, single Application** | Helm chart | Add-on enabled on the AKS resource (ARM/Bicep), not pure in-cluster GitOps |
| Demo blast radius | In-cluster, instant Enforce/Audit toggle | In-cluster | Control-plane scoped; ~15-min sync; effects Audit/Deny |
| Min-K8s-version on a CR | **Yes — matches any CRD, semver operators** | Yes (Rego) | Cluster-level via `kubernetesVersion` field |
| Best at | Validate + **mutate + generate**, image verification | Large-scale constraint libraries | Azure-native governance/compliance reporting |

### 3.2 Recommendation: **Kyverno** as the primary engine for the demo

Rationale:
1. **Readability** — policies are plain Kubernetes YAML; a customer can read a `ClusterPolicy` and understand it without learning Rego. Great for a live demo / screenshots.
2. **Implicit-registry correctness out of the box** — Kyverno parses each image reference and exposes `image.registry`, normalizing bare `nginx` → `docker.io` and `library/nginx`. This is exactly the docker.io pitfall the customer cares about, handled natively rather than with manual prefix gymnastics.
3. **GitOps-native install** — one Helm-based Argo CD Application installs the controller + CRDs; ClusterPolicies are just more YAML in a git folder synced by Argo CD.
4. **One engine covers both examples** — registry deny (Pod admission) and minimum-K8s-version (validation of a CAPI control-plane CR on the management cluster) are both expressible in Kyverno.
5. **Instant demo toggle** — `validationFailureAction: Audit` ⇄ `Enforce` flips between "report" and "block" for a clean before/after screenshot.

**Keep Azure Policy in the story as the Azure-native, control-plane layer** (compliance dashboard + provisioning-time AKS version control), and **show Gatekeeper as the alternative admission engine**. Note: Azure Policy for AKS itself is implemented on Gatekeeper v3 under the hood — useful framing for the customer.

> Pitfall — don't run Kyverno **and** the Azure Policy add-on enforcing overlapping Pod rules on the same cluster; you get double admission webhooks and confusing double-denials. For the demo, use Kyverno in-cluster for Pod-level controls and Azure Policy for cluster-level/compliance.

---

## 4. Example A — Deny images from docker.io and quay.io

### 4.0 Registry-matching pitfalls (read first)

- **Implicit default registry**: `nginx` ≡ `docker.io/library/nginx:latest`. A naive prefix check on the literal string `"nginx"` will NOT see `docker.io`. You must resolve the implicit registry.
- **`library/` prefix**: official Docker images get `library/` injected (`docker.io/library/nginx`). Match on the registry host, not the path.
- **docker.io aliases**: `index.docker.io` and `registry-1.docker.io` are the same registry. Kyverno normalizes them to `docker.io`; Gatekeeper string matching does not — list all three if you string-match.
- **Digests vs tags**: `nginx@sha256:...` and `nginx:1.27` both still carry registry `docker.io` — matching on registry covers both.
- **Allow-list the registries the customer needs**: `mcr.microsoft.com` (AKS system images, .NET, etc.), the customer's **ACR** (`<name>.azurecr.io`), and frequently `registry.k8s.io` (upstream K8s images) and `ghcr.io`. Blocking docker.io/quay.io can break cert-manager, ingress-nginx, prometheus, etc., which commonly pull from quay.io/registry.k8s.io — call this out so the customer scopes the allow-list deliberately.

### 4.1 Kyverno — RECOMMENDED (deny docker.io + quay.io, handles implicit default)

This uses Kyverno's parsed `images` variable, whose `.registry` field already resolves the implicit `docker.io` and strips `library/`. `Enforce` blocks at admission.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-docker-quay-registries
  annotations:
    policies.kyverno.io/title: Block docker.io and quay.io
    policies.kyverno.io/category: Supply Chain
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce      # flip to Audit for "report-only" demo
  background: true
  rules:
    - name: block-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          Images from docker.io and quay.io are not allowed.
          Use mcr.microsoft.com or your ACR (<name>.azurecr.io).
        deny:
          conditions:
            any:
              # 'images' is Kyverno's parsed view; .registry resolves bare 'nginx' -> docker.io
              - key: "{{ images.containers.*.registry || `[]` }}"
                operator: AnyIn
                value: ["docker.io", "quay.io"]
              - key: "{{ images.initContainers.*.registry || `[]` }}"
                operator: AnyIn
                value: ["docker.io", "quay.io"]
              - key: "{{ images.ephemeralContainers.*.registry || `[]` }}"
                operator: AnyIn
                value: ["docker.io", "quay.io"]
```

Why this is correct: Kyverno's image parser normalizes `index.docker.io` / `registry-1.docker.io` → `docker.io` and injects `library/`, so a bare `nginx`, `docker.io/library/nginx:1.27`, and `nginx@sha256:...` all expose `registry == "docker.io"` and are denied. `quay.io/...` exposes `registry == "quay.io"`.

#### 4.1b Kyverno allow-list variant (pattern style — the official "Restrict Image Registries" shape)

The canonical Kyverno sample is an **allow-list** (only listed registries pass), which inherently denies docker.io/quay.io. Note the implicit-default caveat below.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-registries
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Only mcr.microsoft.com and the corporate ACR are allowed."
        pattern:
          spec:
            =(ephemeralContainers):
              - image: "mcr.microsoft.com/* | *.azurecr.io/*"
            =(initContainers):
              - image: "mcr.microsoft.com/* | *.azurecr.io/*"
            containers:
              - image: "mcr.microsoft.com/* | *.azurecr.io/*"
```

> Caveat for the pattern/allow-list style: it matches the **literal image string**, so a bare `nginx` (no registry prefix) fails the pattern and is blocked — which is the desired outcome (it's really docker.io) but the deny message reads as "doesn't match allowed registries" rather than "docker.io blocked." The `deny.conditions` form in 4.1 gives the clearer, registry-aware message. Source: [Kyverno Restrict Image Registries](https://kyverno.io/policies/best-practices/restrict-image-registries/restrict-image-registries/).

### 4.2 Gatekeeper (OPA) — equivalent

**Recommended Gatekeeper approach = allow-list** using the library `k8sallowedrepos` ConstraintTemplate (prefix match). Allowing only `mcr.microsoft.com/` + ACR implicitly denies docker.io and quay.io, and because a bare `nginx` has no allowed prefix it is also blocked (handles the implicit default by exclusion).

ConstraintTemplate (verbatim from the gatekeeper-library, `k8sallowedrepos`, v1.0.2):

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
  annotations:
    metadata.gatekeeper.sh/title: "Allowed Repositories"
    metadata.gatekeeper.sh/version: 1.0.2
    description: >-
      Requires container images to begin with a string from the specified list.
      To prevent bypasses, ensure a '/' is added when specifying DockerHub
      repositories or custom registries.
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              description: The list of prefixes a container image is allowed to have.
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not strings.any_prefix_match(container.image, input.parameters.repos)
          msg := sprintf("container <%v> has an invalid image repo <%v>, allowed repos are %v", [container.name, container.image, input.parameters.repos])
        }
        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          not strings.any_prefix_match(container.image, input.parameters.repos)
          msg := sprintf("initContainer <%v> has an invalid image repo <%v>, allowed repos are %v", [container.name, container.image, input.parameters.repos])
        }
        violation[{"msg": msg}] {
          container := input.review.object.spec.ephemeralContainers[_]
          not strings.any_prefix_match(container.image, input.parameters.repos)
          msg := sprintf("ephemeralContainer <%v> has an invalid image repo <%v>, allowed repos are %v", [container.name, container.image, input.parameters.repos])
        }
```

Constraint (allow only MCR + ACR ⇒ denies docker.io/quay.io and bare images):

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: allowed-registries
spec:
  enforcementAction: deny       # 'dryrun' for report-only demo
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system", "azure-arc"]
  parameters:
    repos:
      - "mcr.microsoft.com/"
      - "<name>.azurecr.io/"
      - "registry.k8s.io/"      # include if cluster add-ons need it
```

Source: [Gatekeeper Library — Allowed Repositories](https://open-policy-agent.github.io/gatekeeper-library/website/validation/allowedrepos/).

**Gatekeeper explicit deny-list variant (custom ConstraintTemplate).** If the customer insists on an explicit "block these two registries" (not an allow-list), a custom template with the implicit-default handled in Rego:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdeniedregistries
spec:
  crd:
    spec:
      names:
        kind: K8sDeniedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items: { type: string }
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdeniedregistries

        # registry host of an image; bare images (no host) default to docker.io
        reg(image) = out {
          parts := split(image, "/")
          count(parts) > 1
          contains_host(parts[0])
          out := parts[0]
        }
        reg(image) = "docker.io" {
          parts := split(image, "/")
          not host_in_first_segment(parts)
        }
        contains_host(seg) { contains(seg, ".") }
        contains_host(seg) { contains(seg, ":") }
        host_in_first_segment(parts) {
          count(parts) > 1
          contains_host(parts[0])
        }

        violation[{"msg": msg}] {
          c := input.review.object.spec.containers[_]
          denied := input.parameters.registries[_]
          reg(c.image) == denied
          msg := sprintf("container <%v> uses denied registry <%v> (image <%v>)", [c.name, denied, c.image])
        }
        violation[{"msg": msg}] {
          c := input.review.object.spec.initContainers[_]
          denied := input.parameters.registries[_]
          reg(c.image) == denied
          msg := sprintf("initContainer <%v> uses denied registry <%v> (image <%v>)", [c.name, denied, c.image])
        }
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDeniedRegistries
metadata:
  name: block-docker-quay
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    registries: ["docker.io", "quay.io"]
```

> The library `k8sallowedrepos` is the battle-tested choice; the custom deny-list is shown for completeness but the allow-list is recommended because it's safer (default-deny) and is the documented pattern.

---

## 5. Example B — Impose a minimum Kubernetes version

### 5.1 The two interpretations

**(i) Cluster provisioning-time version (the realistic control).** A Pod manifest carries no Kubernetes version, so "minimum K8s version" is fundamentally a **cluster-level** control. Enforce it where the cluster is *defined*:
- On the **management cluster CRs** that declare workload clusters (CAPI `Cluster` / CAPZ `AzureManagedControlPlane` / ASO `AzureASOManagedControlPlane` / `KubeadmControlPlane`), each of which has a `spec.version` (or `version`) field.
- On the **Azure AKS resource** (`Microsoft.ContainerService/managedClusters`) via its `kubernetesVersion` property using Azure Policy.

**(ii) Admission-style guardrail concept.** There is no per-Pod K8s version to validate. The admission-style equivalent is to put a **validating admission policy on the management cluster** that inspects the workload-cluster-defining CR and rejects creation/update if `spec.version` is below the minimum. This is the realistic "guardrail" — admission control applied to the *infrastructure CRs*, not to Pods.

### 5.2 Kyverno on the MANAGEMENT cluster — validate a CR's version field (semver)

Kyverno can `match` any CRD kind. Kyverno's comparison operators (`GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals`) support **semver** values (the leading `v` is handled), so you can compare CAPI version strings like `v1.28.3` directly.

Example — block CAPZ managed control planes below v1.28.0:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-min-k8s-version
  annotations:
    policies.kyverno.io/title: Minimum Kubernetes version for workload clusters
    policies.kyverno.io/category: Governance
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce      # Audit for report-only
  background: false                      # CR validation is admission-time
  rules:
    - name: capz-control-plane-min-version
      match:
        any:
          - resources:
              kinds:
                - AzureManagedControlPlane          # CAPZ (infrastructure.cluster.x-k8s.io)
                - AzureASOManagedControlPlane        # ASO-backed CAPZ
                - KubeadmControlPlane                # generic CAPI control plane
      validate:
        message: "Workload clusters must run Kubernetes v1.28.0 or newer."
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.version }}"
                operator: LessThan
                value: "v1.28.0"
```

Notes:
- `spec.version` is the field on CAPI/CAPZ control-plane CRs (e.g. `v1.29.2`). For the AKS-flavored `AzureManagedControlPlane`, the field is `spec.version`. Confirm the exact path for the CRD version you deploy and adjust (some ASO CRDs expose it under `spec.version` too).
- Kyverno semver comparison: `LessThan` with `"v1.28.0"` returns true for `v1.27.x` and below → denied. Use `GreaterThanOrEquals` inverted if you prefer an allow condition.
- This is the **admission guardrail (ii)** applied to the infrastructure CRs on the management cluster — the practical realization of "minimum K8s version."

### 5.3 Azure Policy — AKS cluster version (Azure-native control plane)

**Built-in (Audit only):** *"Kubernetes Services should be upgraded to a non-vulnerable Kubernetes version"* (effect `Audit`, v1.0.2) — flags clusters on known-vulnerable versions but does **not** enforce a numeric minimum and cannot Deny. Good for the compliance-dashboard part of the story. Also relevant: *"Azure Kubernetes Service Clusters should enable cluster auto-upgrade"* (Audit) to keep versions current. Source: [Azure Policy built-ins for AKS](https://learn.microsoft.com/en-us/azure/aks/policy-reference).

**There is no built-in `Deny` policy for a numeric minimum AKS version.** For provisioning-time enforcement use a **custom Azure Policy** on the `kubernetesVersion` field. Caveat: Azure Policy has **no native semver comparator** — string `less`/`greater` break across digit-count boundaries (e.g. `"1.9"` > `"1.10"` lexically). Two workable patterns:

Pattern A — allow-list of approved versions (most reliable, deny everything else):

```json
{
  "properties": {
    "displayName": "AKS clusters must use an approved Kubernetes version",
    "mode": "Indexed",
    "policyRule": {
      "if": {
        "allOf": [
          { "field": "type", "equals": "Microsoft.ContainerService/managedClusters" },
          {
            "not": {
              "field": "Microsoft.ContainerService/managedClusters/kubernetesVersion",
              "in": "[parameters('allowedVersions')]"
            }
          }
        ]
      },
      "then": { "effect": "[parameters('effect')]" }
    },
    "parameters": {
      "allowedVersions": {
        "type": "Array",
        "defaultValue": ["1.28.9", "1.29.7", "1.30.3"]
      },
      "effect": {
        "type": "String",
        "allowedValues": ["Audit", "Deny", "Disabled"],
        "defaultValue": "Deny"
      }
    }
  }
}
```

Pattern B — block specific disallowed minor versions with `like` (coarser):

```json
{
  "field": "Microsoft.ContainerService/managedClusters/kubernetesVersion",
  "anyOf": [
    { "field": "Microsoft.ContainerService/managedClusters/kubernetesVersion", "like": "1.2[0-7].*" },
    { "field": "Microsoft.ContainerService/managedClusters/kubernetesVersion", "like": "1.1*" }
  ]
}
```

> Recommendation: use **Pattern A (approved-version allow-list)** for Azure-native enforcement — it sidesteps the semver-comparison limitation and is easy to keep current. Pair it with the built-in Audit policy for the dashboard. For the in-cluster/CAPI demo, use the **Kyverno CR policy (5.2)** which *does* understand semver.

### 5.4 CAPZ/ASO manifest field (where the version is set)

For reference, the version the policies validate is set in the cluster-defining manifest, e.g. CAPZ AKS control plane:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureManagedControlPlane
metadata:
  name: workload-cluster-1
spec:
  location: eastus2
  resourceGroupName: rg-poc
  version: v1.30.3            # <-- enforced >= minimum by Kyverno policy in 5.2
  # ...
```

(ASO-backed `AzureASOManagedControlPlane` similarly carries the version in its spec; confirm the exact field for the API version in use.)

---

## 6. GitOps Wiring + Demoing a Violation

### 6.1 Suggested git layout

```
gitops/
├── apps/
│   ├── kyverno.yaml                 # Application: install Kyverno (Helm)
│   ├── kyverno-policies.yaml        # Application: sync gitops/policies/kyverno
│   └── min-version-policy.yaml      # Application: sync the mgmt-cluster CR policy
├── policies/
│   └── kyverno/
│       ├── block-docker-quay-registries.yaml
│       └── enforce-min-k8s-version.yaml
└── bootstrap/
    └── root-app.yaml                # app-of-apps root
```

### 6.2 Application that delivers the policies

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno-policies
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"     # after the Kyverno install (wave 0)
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/aks-governance.git
    targetRevision: HEAD
    path: gitops/policies/kyverno
  destination:
    server: https://kubernetes.default.svc   # or '{{.server}}' via ApplicationSet for workload clusters
    namespace: kyverno
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ ServerSideApply=true ]
```

- For **per-workload-cluster** delivery, deliver this via the **ApplicationSet cluster generator** in §2.3 (one Application per workload cluster, `destination.server: '{{.server}}'`).
- Use **sync waves** so CRDs/controller (wave 0) precede policies (wave 1); otherwise the first sync fails on missing CRDs.

### 6.3 Demoing the violation (for screenshots)

1. Sync the policy Application in Argo CD → show it `Synced/Healthy` and the `ClusterPolicy` resource green in the tree.
2. Apply a deliberately bad Pod:
   ```bash
   kubectl run bad-nginx --image=nginx          # implicit docker.io -> blocked
   kubectl run bad-quay --image=quay.io/prometheus/busybox  # quay.io -> blocked
   ```
   Expected (Kyverno Enforce):
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/default/bad-nginx was blocked due to the following policies:
     block-docker-quay-registries:
       block-registries: 'Images from docker.io and quay.io are not allowed. Use
       mcr.microsoft.com or your ACR (<name>.azurecr.io).'
   ```
3. Apply a good Pod to show it passes:
   ```bash
   kubectl run good --image=mcr.microsoft.com/cbl-mariner/busybox:2.0   # allowed
   ```
4. For the **report-only → enforce** narrative, first deploy with `validationFailureAction: Audit`, show a `PolicyReport` (`kubectl get policyreport -A`) flagging the violation without blocking, then flip to `Enforce` via a git commit → Argo CD self-heals → re-apply the bad Pod → now blocked. Clean before/after screenshots.
5. Min-version demo (management cluster): `kubectl apply` an `AzureManagedControlPlane` with `version: v1.26.0` → Kyverno denies with "must run Kubernetes v1.28.0 or newer."

---

## Key Discoveries (summary of evidence)

- Argo CD official guidance: **ApplicationSet + cluster generator is the recommended bootstrap**; app-of-apps is the documented alternative. Both verified from the Cluster Bootstrapping doc.
- Argo CD stores clusters as labeled Secrets (`argocd.argoproj.io/secret-type: cluster`); the cluster generator and label selectors target workload clusters and naturally exclude the local cluster. AKS auth via `argocd-k8s-auth azure` (kubelogin) is documented.
- Kyverno's official **Restrict Image Registries** sample is an allow-list (`eu.foo.io/* | bar.io/*` pattern). For an explicit docker.io/quay.io **deny** with correct implicit-default handling, the `deny.conditions` + parsed `images.*.registry` form is the precise tool (registry normalization handles `index.docker.io`/`registry-1.docker.io`/`library/`).
- Gatekeeper library `k8sallowedrepos` (v1.0.2) is a **prefix allow-list**; deny docker.io/quay.io by allowing only MCR+ACR. A custom `K8sDeniedRegistries` template can express explicit deny-list with implicit-default Rego.
- **No Azure Policy built-in enforces a numeric minimum AKS version** (only an Audit "non-vulnerable version" built-in). Custom Azure Policy on `kubernetesVersion` works but lacks semver comparison → use an approved-version allow-list. Kyverno on the management cluster *does* support semver comparison on CAPI/CAPZ CR `spec.version`.

## References

- [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [Argo CD Cluster Bootstrapping (ApplicationSet + App-of-Apps)](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Argo CD Declarative Setup — Applications, Projects, Clusters (incl. AKS auth)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [Argo CD ApplicationSet — Cluster Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/)
- [Kyverno — Restrict Image Registries policy](https://kyverno.io/policies/best-practices/restrict-image-registries/restrict-image-registries/)
- [Kyverno policies repo — restrict-image-registries.yaml](https://github.com/kyverno/policies/blob/main/best-practices/restrict-image-registries/restrict-image-registries.yaml)
- [Gatekeeper Library — Allowed Repositories (k8sallowedrepos)](https://open-policy-agent.github.io/gatekeeper-library/website/validation/allowedrepos/)
- [Azure Policy built-in definitions for AKS](https://learn.microsoft.com/en-us/azure/aks/policy-reference)
- [Cluster API Provider Azure (CAPZ) docs](https://capz.sigs.k8s.io/)

## Clarifying Questions

1. **Topology**: Is Argo CD running on a dedicated **management cluster** (alongside CAPI/CAPZ), or one Argo CD per workload cluster? This changes whether multi-cluster registration (§2) is needed.
2. **CAPI flavor**: CAPZ self-managed (`AzureManagedControlPlane`) vs ASO (`AzureASOManagedControlPlane`) vs `KubeadmControlPlane`? Determines the exact `spec.version` path for the min-version policy (§5.2).
3. **Enforcement layer for min-version**: Do you want it enforced **in-cluster on the CAPI CRs** (Kyverno, §5.2), **Azure-native at the AKS resource** (Azure Policy, §5.3), or both?
4. **Allow-list scope**: Besides `mcr.microsoft.com` and ACR, should `registry.k8s.io`, `ghcr.io`, or specific quay.io repos be allowed (cert-manager, ingress-nginx, prometheus commonly need them)?
5. **Enforce vs Audit at demo time**: Start in `Audit` (PolicyReport) and flip to `Enforce` for the screenshot narrative, or go straight to `Enforce`?
6. **Single vs dual engine**: Demo Kyverno only, or also stand up Gatekeeper / the Azure Policy add-on to contrast? (Avoid overlapping Pod-level enforcement on the same cluster.)

## Recommended Next Research (not completed)

- [ ] Confirm exact `spec.version` JSON path for the specific CAPZ/ASO CRD API version the PoC will deploy (e.g. `AzureASOManagedControlPlane` field name/casing).
- [ ] Verify current Kyverno chart version and that `validationFailureAction` (deprecated in newer Kyverno in favor of `failureAction` under `validate`) matches the chart you install — newer Kyverno (1.12+) moved to per-rule `validate.failureAction`.
- [ ] Decide and test the CAPI→Argo CD cluster-Secret automation (Sveltos, the cluster-api-addon-provider, or a small kubeconfig→Secret job) end-to-end.
- [ ] Validate Azure Policy custom definition assignment scope (management group vs subscription vs RG) and the ~Audit/Deny sync timing for the demo.
- [ ] Build the actual git repo folder structure and dry-run `argocd app sync` to confirm sync-wave ordering (CRDs before policies).
