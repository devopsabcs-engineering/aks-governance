# Gouvernance AKS — Architecture de gouvernance Kubernetes ACME Inc.

> **Référence de gouvernance stratégique et preuve de concept exécutable** pour déployer et gouverner
> Azure Kubernetes Service (AKS) — et, lorsque requis, Azure Red Hat OpenShift (ARO) — pour des
> clients internes, avec une approche de moindre privilège, alignée sur les zones d'atterrissage
> (« landing zones ») et pilotée par GitOps.

🌐 **Langue :** [English](README.md) · **Français**

📄 **Rapport associé :** `ACME_Kubernetes_Governance_Architecture_Report.docx`

---

## Table des matières

- [Terminologie](#terminologie)
- [En résumé](#en-résumé)
- [Pourquoi un modèle multi-abonnements est le meilleur choix](#pourquoi-un-modèle-multi-abonnements-est-le-meilleur-choix)
- [La gouvernance AKS et ARO n'est pas symétrique](#la-gouvernance-aks-et-aro-nest-pas-symétrique)
- [Les deux options proposées par le client](#les-deux-options-proposées-par-le-client)
- [Comparatif synthèse](#comparatif-synthèse)
- [Alternatives alignées sur Microsoft](#alternatives-alignées-sur-microsoft)
- [Traitement de CAPI/CAPZ + Argo CD](#traitement-de-capicapz--argo-cd)
- [Phrase exécutive](#phrase-exécutive)
- [Preuve de concept](#preuve-de-concept)
- [Références](#références)

---

## Terminologie

> [!NOTE]
> **ODS** — *Offre de Service* : la capacité centrale de plateforme / libre-service de ACME Inc.
> qui provisionne et gouverne Kubernetes (AKS, et ARO lorsque requis) pour le compte des clients
> internes. Dans ce document, « ODS » désigne cette équipe plateforme centrale et son automatisation
> de déploiement — par exemple, l'entité à qui sont accordés des droits restreints pour déployer
> dans les abonnements de charge de travail, et le propriétaire de l'observabilité et de la
> gouvernance centralisées.
>
> **ODS fédéré** — la forme cible recommandée de cette offre de service : la même
> gouvernance/outillage/observabilité centralisés hébergés dans des abonnements de plateforme, avec
> les clusters de charge de travail **fédérés** dans des [abonnements de zone d'atterrissage][caf-lz]
> par client. Cela contraste avec l'**amorçage à abonnement unique** concentré, où tout réside dans
> un seul abonnement.
>
> Autres acronymes utilisés ci-dessous : **AKS** (Azure Kubernetes Service), **ARO** (Azure Red Hat
> OpenShift), **CAPI/CAPZ** (Cluster API / Cluster API Provider Azure), **ASO** (Azure Service
> Operator), **GIA** (Gestion des identités et des accès).

---

## En résumé

> [!IMPORTANT]
> **Recommandation stratégique :** évoluer vers un **ODS multi-abonnements aligné sur les zones
> d'atterrissage** (gouvernance/outillage centralisés, avec les clusters de charge de travail dans
> des [abonnements de zone d'atterrissage alignés sur le client][caf-lz]), et ne traiter le **modèle
> à abonnement unique que comme un patron tactique d'amorçage** si ACME Inc. a besoin d'un chemin
> court pour contourner les frictions actuelles de réseau inter-abonnements / GIA.

Cette recommandation s'appuie sur les objectifs ODS de ACME Inc. : simplifier la consommation
d'AKS/ARO, centraliser l'observabilité/la gouvernance, prendre en charge les paliers de service
orientés client et mutualisés, privilégier AKS par défaut, et n'utiliser ARO que pour des classes de
charges spécifiques telles que CP4D et MQ. Elle est aussi cohérente avec les [recommandations
Microsoft sur les zones d'atterrissage][caf-lz], qui placent les services partagés de
connectivité/sécurité dans des **abonnements de plateforme** et les charges de travail dans des
**abonnements de zone d'atterrissage applicative**, avec une politique centralisée et une
[connectivité en étoile (hub-and-spoke)][hub-spoke].

---

## Pourquoi un modèle multi-abonnements est le meilleur choix

### Moindre privilège / GIA

ACME Inc. a explicitement demandé comment déployer AKS et ARO pour des clients internes avec le
**minimum de droits possible**, a signalé la famille de permissions problématique
`Microsoft.Authorization/*/Write`, et a demandé des zones d'atterrissage pré-provisionnées ainsi que
des [rôles personnalisés][custom-roles]. Un modèle multi-abonnements aligné sur les zones
d'atterrissage est la façon la plus propre d'imposer ces frontières, car les prérequis peuvent être
pré-créés par l'équipe plateforme et l'automatisation ODS ne reçoit que des **droits restreints** sur
les abonnements de charge de travail cibles, conformément aux [bonnes pratiques de moindre privilège
Azure RBAC][rbac-bp].

### Pourquoi l'idée de l'abonnement unique existe

Les notes internes envisagent un modèle à un seul abonnement parce qu'**une seule identité managée
peut déployer plusieurs clusters dans le même abonnement**, et parce qu'un modèle inter-abonnements
introduirait par ailleurs une complexité de communication Palo Alto / inter-abonnements. Cela rend
l'option à abonnement unique attrayante sur le plan opérationnel à très court terme, surtout pendant
que la fondation de gouvernance se met en place.

### Pourquoi l'abonnement unique ne devrait pas être l'état final

Ces mêmes notes signalent une **pression d'échelle et de frontières** — ACME Inc. évoque déjà
**130 à 140 clusters AKS** et le besoin de dimensionner les VNets pour de grands nombres de nœuds et
de « prédire les limites Azure ». Ces limites sont réelles et bornées : un abonnement unique est
plafonné (par exemple, [**5 000 clusters AKS par abonnement** et **5 000 nœuds par cluster**][aks-quotas]),
et des [limites de service à l'échelle de l'abonnement][sub-limits] s'appliquent au réseau, au calcul
et aux objets d'identité. À cette échelle, la planification d'adressage IP des VNets
([adressage Azure CNI][aks-cni]) et les [bonnes pratiques pour grands clusters][aks-large] deviennent
des préoccupations de premier ordre. Côté ARO, la montée en charge du plan de contrôle peut se faire
automatiquement, tandis que la réduction doit être explicitement demandée, avec des implications
financières/opérationnelles qui exigent une gouvernance et une clarté de responsabilité. C'est
exactement le problème de rayon d'impact, de quota et d'imputabilité que les **frontières
multi-abonnements sont censées contenir**.

### Réalités d'identité et d'accès conditionnel

Les notes internes sur l'AKS privé / le comportement de connexion Entra concluent que le **filtrage
par liste d'autorisation d'IP n'est pas un contrôle d'architecture fiable** pour les flux de
création/authentification AKS, et que la réponse propre et prise en charge est l'[identité
managée][aks-mi] / l'[identité de charge de travail][aks-wi] — et non des hypothèses fragiles basées
sur l'IP source ([conditions réseau d'accès conditionnel][ca-network], [clusters AKS
privés][aks-private]). Cela oriente la conception vers des zones d'atterrissage pré-provisionnées,
des identités managées et un [RBAC restreint][rbac-bp] plutôt que de larges privilèges
humains/opérateurs.

---

## La gouvernance AKS et ARO n'est pas symétrique

> [!NOTE]
> L'une des conclusions les plus importantes du matériel interne est qu'**AKS et ARO ne peuvent pas
> être gouvernés comme s'ils étaient des types de ressources Azure identiques.**

Un résumé de gouvernance interne indique qu'ARO exposé via [Azure Arc][arc-k8s] se comporte comme des
`connectedClusters`, tandis qu'AKS correspond à des `managedClusters` ; ainsi, les ensembles de
politiques ciblant AKS ne s'appliquent pas automatiquement à ARO de la même façon. Autrement dit, une
**« couverture de politique uniforme » sur AKS et ARO n'est pas le comportement produit par
défaut** ; cela doit être résolu comme un patron d'architecture/gouvernance, et non comme un correctif
de support.

Cela impacte directement la recommandation :

- Utiliser des contrôles de **gouvernance natifs AKS** ([Azure Policy pour Kubernetes][policy-k8s],
  ainsi que [Kyverno][kyverno]) là où ils conviennent le mieux à AKS.
- Utiliser des **contrôles Arc / natifs Kubernetes plus GitOps** là où ARO exige un chemin
  d'application différent.

Cela rejoint aussi le fil interne sur ARO où l'identité managée était décrite comme non négociable,
tandis que l'équipe documentait des lacunes de prise en charge ASO/Terraform pour la création de
clusters ARO avec identité managée à l'époque, et envisageait un pipeline « wrapper » temporaire en
« Plan C ». Publiquement, Microsoft documente désormais les [clusters ARO avec identité
managée][aro-mi] comme **GA (disponibilité générale)**, y compris le déploiement via le portail, ce
qui améliore matériellement la viabilité d'un patron cible ARO sécurisé ([créer un cluster
ARO][aro-create], [aperçu d'ARO][aro-intro]).

---

## Les deux options proposées par le client

### Option 1 — Abonnement unique

> **Meilleur usage :** amorçage tactique / cellule de service temporaire.

Elle réduit les frictions réseau inter-abonnements, centralise rapidement les opérations et simplifie
la première mise en œuvre d'Argo CD + automatisation de gestion, car le rayon d'impact d'identité et
de réseau est entièrement dans un seul abonnement. Mais elle **concentre aussi le risque de quota**
([limites d'abonnement][sub-limits], [limites AKS][aks-quotas]), affaiblit l'isolation
tenant/charge de travail, complique la séparation des coûts/refacturation et offre, au fil du temps,
moins de frontières natives pour le moindre privilège — surtout une fois que le parc dépasse quelques
paliers de service contrôlés.

### Option 2 — Abonnement de gestion + abonnements de charge de travail

> **Meilleur usage :** architecture stratégique, surtout une fois la fondation de zone
> d'atterrissage en place.

Cela s'aligne mieux sur les [zones d'atterrissage Azure][caf-lz], offre des frontières de propriété
et de politique plus claires, prend en charge les prérequis pré-provisionnés et correspond plus
naturellement au modèle de déploiement ODS « orienté client ». Le principal inconvénient est qu'elle
exige **plus de préparation de plateforme en amont** : cadrage d'identité, appairage réseau / DNS
privé / cheminement pare-feu, et un accord clair sur l'équipe propriétaire de chaque prérequis sous
contraintes GIA/sécurité.

---

## Comparatif synthèse

| Critère | Abonnement unique | Multi-abonnements | Avantage | Lecture exécutive |
| --- | --- | --- | --- | --- |
| **Least privilege** | Faible à moyen | Élevé | 🟢 Multi-sub | Les droits peuvent être limités par client ou par workload. |
| **Réseau / Palo Alto** | Simple | Plus complexe | 🔵 Single-sub | Le cross-sub demande plus de coordination réseau. |
| **Scalabilité** | Limitée | Forte | 🟢 Multi-sub | Meilleure gestion des quotas, coûts et frontières. |
| **Gouvernance** | Centralisée mais concentrée | Centralisée avec meilleures frontières | 🟢 Multi-sub | Meilleur équilibre entre contrôle central et isolation. |
| **Time-to-value** | Rapide | Moyen | 🔵 Single-sub | Bon modèle de transition, moins bon état final. |

> [!TIP]
> **Lecture :** l'option **multi-subscription** gagne clairement sur la **sécurité, la gouvernance et
> la pérennité** ; l'option **single subscription** gagne surtout sur la **simplicité de démarrage**.

---

## Alternatives alignées sur Microsoft

Au-delà des deux options initiales du client, le rapport inclut deux patrons alignés sur Microsoft :

1. **ODS fédéré aligné sur les zones d'atterrissage** — gouvernance/outillage centralisés,
   abonnements partagés de connectivité/sécurité, et clusters AKS/ARO client/charge de travail
   déployés dans des abonnements applicatifs alignés sur le client, avec prérequis pré-provisionnés et
   [identités managées restreintes][aks-mi]. Voir les [principes de conception des zones
   d'atterrissage Azure][caf-design] et l'[architecture de référence AKS de base][aks-baseline].
2. **Opérations AKS distribuées gouvernées par flotte** — une surcouche [AKS Fleet Manager][fleet]
   pour la gouvernance multi-cluster des espaces de noms, des quotas, du RBAC, des mises à niveau, du
   placement des ressources et du déploiement Git par étapes — couplée à une prise en charge
   compatible [Arc][arc-k8s] pour ARO là où la parité des fonctionnalités diffère.

---

## Traitement de CAPI/CAPZ + Argo CD

Pour **AKS**, la conception utilise une répartition claire des responsabilités :

- **Argo CD** = réconciliateur GitOps pour les modules complémentaires de plateforme, les ensembles
  de politiques, la configuration des clusters et les standards de déploiement de charges de travail
  ([documentation Argo CD][argocd]).
- **CAPZ / ASO** = moteur d'infrastructure déclaratif pour le cycle de vie des clusters AKS —
  exactement la façon dont les [recommandations d'ingénierie de plateforme AKS][aks-pe] positionnent
  GitOps + Argo CD + [Cluster API Provider Azure (CAPZ)][capz] + [Azure Service Operator (ASO)][aso]
  ensemble pour l'ingénierie de plateforme native Azure sur AKS.

Pour **ARO**, la conception est plus prudente :

- Utiliser **Argo CD** pour les modules complémentaires, la standardisation politique/configuration et
  la livraison des charges de travail le cas échéant.
- Utiliser un **chemin de provisionnement ARO compatible identité managée** (portail / ARM / Bicep /
  CLI prise en charge), car le fil interne documentait que la création d'ARO via le chemin
  CAPZ/ASO/Terraform était bloquée par des lacunes de prise en charge de l'identité managée à
  l'époque. La documentation Microsoft confirme maintenant la [disponibilité générale (GA) de
  l'identité managée pour ARO][aro-mi].

> [!NOTE]
> La preuve de concept de ce dépôt montre aussi comment maintenir Argo CD **Synced** face aux champs
> auto-gérés par Kyverno (CRD `spec.conversion`, valeurs par défaut d'admission de ClusterPolicy) au
> moyen de [`ignoreDifferences`][argocd-diff] — un détail pratique pour exécuter la gouvernance GitOps
> à grande échelle.

---

## Phrase exécutive

> [!IMPORTANT]
> **Ne faites pas du modèle à abonnement unique votre destination.** Utilisez-le uniquement si vous
> avez besoin d'un pont à court terme pour contourner les contraintes inter-abonnements actuelles,
> mais construisez vers un **ODS multi-abonnements aligné sur les zones d'atterrissage**, avec
> identités managées, RBAC restreint, standardisation GitOps et chemins de gouvernance spécifiques à
> AKS/ARO.

---

## Preuve de concept

Une preuve de concept de gouvernance **CAPI/CAPZ + Kyverno + Argo CD** exécutable accompagne ce
rapport.

- 📓 **Runbook d'exploitation :** **[docs/runbook.md](docs/runbook.md)** — secrets GitHub requis,
  enregistrement d'application OIDC, environnement d'approbation `aksgov-poc-teardown`, ordre
  d'exécution des scripts en local-first, et procédure de démonstration client.
- ⚙️ **Pipeline :** [`.github/workflows/aksgov-poc-demo.yml`](.github/workflows/aksgov-poc-demo.yml).

Ce que la PoC provisionne et démontre :

| Étape | Ce qui se passe |
| --- | --- |
| Cluster de gestion | Un cluster AKS de gestion CAPI/CAPZ/ASO + Argo CD + Kyverno (Bicep + `clusterctl init`). |
| Clusters de charge de travail | Deux clusters AKS de charge de travail provisionnés de façon déclarative via CAPZ/ASO. |
| Diffusion GitOps | Des `ApplicationSet` Argo CD installent Kyverno et diffusent les objets `ClusterPolicy` de gouvernance vers chaque cluster de charge de travail. |
| Démonstration de gouvernance | Une politique de registre en deux phases **Audit → Enforce** capture un véritable `PolicyReport` Kyverno, puis bloque les Pods en violation ; une politique de version minimale de Kubernetes est aussi démontrée. |
| Preuves + wiki | Les preuves CLI sont capturées et publiées dans le wiki du dépôt. |
| Démantèlement | Toutes les ressources Azure sont supprimées derrière une porte d'approbation manuelle. |

---

## Références

> [!TIP]
> Les quotas et limites sont la contrainte porteuse derrière la décision abonnement unique vs
> multi-abonnements — commencez par les trois premiers liens ci-dessous.

### Quotas & limites

- **Limites d'abonnement et de service Azure** — [`azure-subscription-service-limits`][sub-limits]
- **Limites, SKU et disponibilité régionale AKS** (5 000 clusters/abonnement, 5 000 nœuds/cluster, …)
  — [`aks/quotas-skus-regions`][aks-quotas]
- **Consulter et demander des augmentations de quota** — [`quotas/view-quotas`][quotas-view]
- **Bonnes pratiques AKS pour grands clusters** — [`aks/best-practices-performance-scale-large`][aks-large]
- **Planification d'adressage IP Azure CNI** — [`aks/concepts-network-cni-overview`][aks-cni] ·
  [`aks/configure-azure-cni`][aks-cni-cfg]

### Zones d'atterrissage, réseau & architecture

- **Zones d'atterrissage Azure (Cloud Adoption Framework)** — [`ready/landing-zone`][caf-lz]
- **Principes de conception des zones d'atterrissage** — [`ready/landing-zone/design-principles`][caf-design]
- **Topologie réseau en étoile (hub-and-spoke)** — [`networking/architecture/hub-spoke`][hub-spoke]
- **Architecture de référence AKS de base** — [`reference-architectures/containers/aks/baseline-aks`][aks-baseline]
- **Azure Well-Architected : guide de service AKS** — [`well-architected/service-guides/azure-kubernetes-service`][aks-waf]

### Identité, RBAC & moindre privilège

- **Identité managée AKS** — [`aks/use-managed-identity`][aks-mi]
- **Identité de charge de travail AKS** — [`aks/workload-identity-overview`][aks-wi]
- **Concepts d'accès et d'identité AKS** — [`aks/concepts-identity`][aks-id]
- **Rôles personnalisés Azure** (`Microsoft.Authorization/*`) — [`role-based-access-control/custom-roles`][custom-roles]
- **Bonnes pratiques Azure RBAC (moindre privilège)** — [`role-based-access-control/best-practices`][rbac-bp]
- **Conditions réseau d'accès conditionnel** — [`conditional-access/concept-assignment-network`][ca-network]
- **Clusters AKS privés** — [`aks/private-clusters`][aks-private]

### Politique & application de la gouvernance

- **Azure Policy pour Kubernetes** — [`governance/policy/concepts/policy-for-kubernetes`][policy-k8s]
- **Documentation Kyverno** — [kyverno.io/docs][kyverno]

### Azure Red Hat OpenShift (ARO)

- **Aperçu d'ARO** — [`openshift/intro-openshift`][aro-intro]
- **Créer un cluster ARO** — [`openshift/howto-create-openshift-cluster`][aro-create]
- **Comprendre les identités managées dans ARO (GA)** — [`openshift/howto-understand-managed-identities`][aro-mi]

### Arc & flotte multi-cluster

- **Kubernetes avec Azure Arc** (`connectedClusters` vs `managedClusters`) — [`azure-arc/kubernetes/overview`][arc-k8s]
- **Azure Kubernetes Fleet Manager** — [`kubernetes-fleet/overview`][fleet]

### Ingénierie de plateforme, GitOps & Cluster API

- **Exemple d'ingénierie de plateforme AKS (GitOps + Argo CD + CAPZ + ASO)** — [exemple Microsoft Learn][aks-pe] ·
  [`Azure-Samples/aks-platform-engineering`][aks-pe-gh]
- **Cluster API Provider Azure (CAPZ)** — [capz.sigs.k8s.io][capz]
- **Azure Service Operator (ASO)** — [azure.github.io/azure-service-operator][aso]
- **Argo CD** — [argo-cd.readthedocs.io][argocd] · [Diffing & `ignoreDifferences`][argocd-diff]
- **GitOps (Flux) sur Azure Arc / AKS** — [`azure-arc/kubernetes/tutorial-use-gitops-flux2`][flux]

---

<!-- Liens de référence -->
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
