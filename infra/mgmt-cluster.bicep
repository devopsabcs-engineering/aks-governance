// mgmt-cluster.bicep — Ephemeral management AKS cluster for the AKS Governance PoC.
//
// Provisions ONE small management AKS cluster that hosts CAPI/CAPZ/ASO + ArgoCD + Kyverno,
// plus a User-Assigned Managed Identity (UAMI) that CAPZ/ASO use to create the workload
// clusters in Azure via Workload Identity (no client secrets).
//
// Adapted from aks-fleet-manager/infra/main.bicep. Decision record DD-01: an ephemeral AKS
// management cluster is chosen over kind because AKS provides a native OIDC issuer, which makes
// Workload Identity for CAPZ/ASO trivial (kind needs brittle JWKS-in-storage + SA keypair work).
//
// POST-CREATE STEPS performed by scripts/deploy-mgmt.ps1 (NOT by this template):
//   * The AKS OIDC issuer URL is only known AFTER the cluster is created. This template exposes it
//     as the `oidcIssuerUrl` output; the deploy script creates the federated identity credential on
//     the UAMI keyed to that issuer for the ASO controller service account
//     (subject system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default).
//   * This template is RG-scoped, so it grants the UAMI Contributor at the RESOURCE GROUP scope
//     only. CAPZ/ASO create the workload clusters in their own (new) resource groups, so the deploy
//     script ALSO creates a SUBSCRIPTION-scope Contributor assignment for the UAMI principal.
//   * Creating role assignments requires the deploying identity to hold either Owner or
//     "Role Based Access Control Administrator" on the target scope; otherwise the role-assignment
//     resources below (and the subscription-scope assignment in the deploy script) will fail.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Name of the ephemeral management AKS cluster.')
param mgmtClusterName string = 'aksgov-poc-mgmt'

@description('DNS prefix for the management AKS cluster (1-54 chars).')
param dnsPrefix string = 'aksgovpocmgmt'

@description('Kubernetes version for the management cluster. Empty = take the AKS default for the region.')
param kubernetesVersion string = ''

@description('VM size for the single system node pool. Standard_D2s_v6 is currently the allowed small SKU in eastus2 for this subscription.')
param nodeVmSize string = 'Standard_D2s_v6'

@description('Node count for the system node pool.')
@minValue(1)
param nodeCount int = 2

@description('Name of the User-Assigned Managed Identity that CAPZ/ASO use (Workload Identity).')
param uamiName string = 'id-aksgov-poc-capz'

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity for CAPZ/ASO (Workload Identity)
// ---------------------------------------------------------------------------

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// ---------------------------------------------------------------------------
// Management AKS cluster
// ---------------------------------------------------------------------------
// oidcIssuerProfile + securityProfile.workloadIdentity enable the OIDC issuer and the Workload
// Identity webhook so CAPZ/ASO service accounts can federate to the UAMI with no secrets.
resource mgmtCluster 'Microsoft.ContainerService/managedClusters@2025-02-01' = {
  name: mgmtClusterName
  location: location
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osDiskType: 'Managed'
        type: 'VirtualMachineScaleSets'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// UAMI role assignments are created by scripts/deploy-mgmt.ps1 (az CLI), NOT here.
// ---------------------------------------------------------------------------
// The deploy script grants the UAMI subscription-scope Contributor (which already
// covers this resource group) AFTER the identity exists. Creating a role assignment
// inside this same deployment races the UAMI's Entra propagation and intermittently
// fails with a misleading 'RoleDefinitionDoesNotExist'. The az CLI path tolerates the
// propagation delay, so all UAMI role assignments live in the deploy script.
// Built-in role definition GUIDs (for reference):
//   Contributor                              = b24988ac-6180-42a0-bf88-d4f8a4e6f8a0
//   Role Based Access Control Administrator  = f58310d9-a9f6-439a-9e8d-f62e7b41a168

// ---------------------------------------------------------------------------
// Outputs (consumed by scripts/deploy-mgmt.ps1)
// ---------------------------------------------------------------------------

@description('Name of the management AKS cluster.')
output mgmtClusterName string = mgmtCluster.name

@description('AKS OIDC issuer URL. The deploy script uses this as the issuer for the ASO federated credential.')
output oidcIssuerUrl string = mgmtCluster.properties.oidcIssuerProfile.issuerURL

@description('Client ID of the CAPZ/ASO UAMI (set as AZURE_CLIENT_ID for Workload Identity auth).')
output uamiClientId string = uami.properties.clientId

@description('Principal (object) ID of the CAPZ/ASO UAMI (used for the subscription-scope role assignment).')
output uamiPrincipalId string = uami.properties.principalId

@description('Full resource ID of the CAPZ/ASO UAMI.')
output uamiResourceId string = uami.id
