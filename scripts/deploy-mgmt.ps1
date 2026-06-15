<#
.SYNOPSIS
    Bootstraps the ephemeral AKS Governance PoC management cluster: deploys the management AKS
    cluster + UAMI (Bicep), wires Workload Identity for ASO, runs clusterctl init, installs ArgoCD,
    and applies the GitOps app-of-apps root.

.DESCRIPTION
    Supports BOTH local execution (current 'az login' context) and CI execution with GitHub Actions
    OIDC. For long-running provisioning under OIDC the GitHub client assertion expires (~5 min) so
    -UseFederatedLogin re-mints a fresh federated token periodically (Connect-AzFederated), mirroring
    the aks-fleet-manager harness.

    Sequence:
      1. (CI) federated az login; (local) reuse current az login.
      2. az group create + az deployment group create (infra/mgmt-cluster.bicep); capture outputs.
      3. Create the UAMI federated identity credential for the ASO controller SA + a subscription-scope
         Contributor role assignment for the UAMI principal.
      4. az aks get-credentials --overwrite-existing.
      5. clusterctl init --infrastructure azure (Workload Identity env; SP+secret fallback documented).
      6. Wire ASO Workload Identity: annotate/label the ASO controller SA, create the aso-credentials
         Secret with USE_WORKLOAD_IDENTITY_AUTH=true.
      7. helm upgrade --install argocd (idempotent).
      8. kubectl apply gitops/bootstrap/root-app.yaml (guarded: tolerated missing until Phase 4).
      9. Readiness checks for capi/capz/aso controllers + the AzureASOManagedControlPlane CRD.

    This script calls LIVE Azure / Kubernetes resources. Author-time validation only parses it.

.EXAMPLE
    ./scripts/deploy-mgmt.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    # CI (GitHub Actions OIDC):
    ./scripts/deploy-mgmt.ps1 -SubscriptionId $env:AZURE_SUBSCRIPTION_ID -UseFederatedLogin
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-aksgov-poc-mgmt',
    [string]$Location = 'eastus2',
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$KubernetesVersion = '',
    [switch]$UseFederatedLogin,
    # How often (seconds) to re-mint the federated OIDC token during long polls. CI only.
    [int]$ReauthIntervalSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ASO controller identifiers. CAPZ (verified live against v1.24.1) bundles ASO INTO the
# capz-system namespace — there is NO separate azureserviceoperator-system namespace, and the
# global credential is the 'aso-controller-settings' secret (not a per-resource secret).
$AsoNamespace = 'capz-system'
$AsoServiceAccount = 'azureserviceoperator-default'
$AsoDeployment = 'azureserviceoperator-controller-manager'
$AsoSettingsSecret = 'aso-controller-settings'

# ---------------------------------------------------------------------------
# Connect-AzFederated — re-mint a short-lived GitHub Actions OIDC token and az login with it.
# Federated-credential access tokens cannot be silently refreshed for long-running operations
# (the GitHub client assertion is only valid ~5 minutes), so a multi-step deployment that runs
# past the access-token lifetime fails with AADSTS700024. Calling this on each poll iteration
# keeps auth fresh. Reused near-verbatim from aks-fleet-manager/scripts/deploy.ps1.
# ---------------------------------------------------------------------------
function Connect-AzFederated {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    try {
        $uri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange"
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" } -ErrorAction Stop
        az login --service-principal --username $ClientId --tenant $TenantId --federated-token $resp.value --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { Write-Warning "Federated re-login returned exit $LASTEXITCODE; continuing with existing token."; return $false }
        az account set --subscription $SubscriptionId --only-show-errors
        return $true
    }
    catch {
        Write-Warning "Federated re-login failed: $($_.Exception.Message); continuing with existing token."
        return $false
    }
}

# Resolve infra/mgmt-cluster.bicep relative to this script so the deploy works from any directory.
$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'infra/mgmt-cluster.bicep'
$rootAppPath = Join-Path $repoRoot 'gitops/bootstrap/root-app.yaml'

Write-Host '==> AKS Governance PoC — management cluster bootstrap' -ForegroundColor Cyan
Write-Host "    ResourceGroup     : $ResourceGroup"
Write-Host "    Location          : $Location"
Write-Host "    SubscriptionId    : $SubscriptionId"
Write-Host "    KubernetesVersion : $(if ($KubernetesVersion) { $KubernetesVersion } else { '<AKS default>' })"
Write-Host "    UseFederatedLogin : $UseFederatedLogin"
Write-Host "    Bicep template    : $bicepPath"

if (-not (Test-Path -Path $bicepPath)) {
    throw "Bicep template not found at '$bicepPath'. Run Phase 2 Step 2.1 (infra/mgmt-cluster.bicep) first."
}

# ---------------------------------------------------------------------------
# 1. Authenticate. CI: federated login + select subscription. Local: reuse current az login.
# ---------------------------------------------------------------------------
$clientId = $env:AZURE_CLIENT_ID
$tenantId = $env:AZURE_TENANT_ID
$ciFederated = $UseFederatedLogin.IsPresent `
    -and -not [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) `
    -and -not [string]::IsNullOrWhiteSpace($clientId) `
    -and -not [string]::IsNullOrWhiteSpace($tenantId)

if ($ciFederated) {
    Write-Host '==> Authenticating with GitHub Actions OIDC (federated)...' -ForegroundColor Cyan
    [void](Connect-AzFederated -ClientId $clientId -TenantId $tenantId -SubscriptionId $SubscriptionId)
}
else {
    Write-Host '==> Using existing az login context...' -ForegroundColor Cyan
    az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to select subscription '$SubscriptionId'. Run 'az login' first." }
}

# ---------------------------------------------------------------------------
# 2. Resource group + Bicep deployment. Async + periodic re-auth under CI OIDC for the long AKS
#    create; simple synchronous create locally.
# ---------------------------------------------------------------------------
Write-Host "==> Creating resource group '$ResourceGroup' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group '$ResourceGroup'." }

$deployParams = @("location=$Location")
if ($KubernetesVersion) { $deployParams += "kubernetesVersion=$KubernetesVersion" }

$deploymentName = "mgmt-cluster-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "==> Deploying '$deploymentName' (infra/mgmt-cluster.bicep)..." -ForegroundColor Cyan

if ($ciFederated) {
    az deployment group create `
        --name $deploymentName `
        --resource-group $ResourceGroup `
        --template-file $bicepPath `
        --parameters $deployParams `
        --no-wait `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to submit Bicep deployment '$deploymentName'." }

    $state = 'Running'
    while ($state -notin @('Succeeded', 'Failed', 'Canceled')) {
        Start-Sleep -Seconds $ReauthIntervalSeconds
        [void](Connect-AzFederated -ClientId $clientId -TenantId $tenantId -SubscriptionId $SubscriptionId)
        $state = az deployment group show --name $deploymentName --resource-group $ResourceGroup --query 'properties.provisioningState' -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($state)) { $state = 'Unknown' }
        Write-Host "    deployment '$deploymentName' state: $state"
    }
    if ($state -ne 'Succeeded') { throw "Bicep deployment '$deploymentName' ended in state '$state'." }
}
else {
    az deployment group create `
        --name $deploymentName `
        --resource-group $ResourceGroup `
        --template-file $bicepPath `
        --parameters $deployParams `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Bicep deployment '$deploymentName' to '$ResourceGroup' failed." }
}

Write-Host '==> Capturing deployment outputs...' -ForegroundColor Cyan
$outputsJson = az deployment group show --name $deploymentName --resource-group $ResourceGroup --query 'properties.outputs' -o json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($outputsJson)) { throw "Could not read outputs for deployment '$deploymentName'." }
$outputs = $outputsJson | ConvertFrom-Json

$mgmtClusterName = $outputs.mgmtClusterName.value
$oidcIssuerUrl = $outputs.oidcIssuerUrl.value
$uamiClientId = $outputs.uamiClientId.value
$uamiPrincipalId = $outputs.uamiPrincipalId.value
$uamiResourceId = $outputs.uamiResourceId.value

if ([string]::IsNullOrWhiteSpace($oidcIssuerUrl)) { throw 'OIDC issuer URL output was empty; cannot create the ASO federated credential.' }
Write-Host "    mgmtClusterName : $mgmtClusterName"
Write-Host "    oidcIssuerUrl   : $oidcIssuerUrl"
Write-Host "    uamiClientId    : $uamiClientId"

# ---------------------------------------------------------------------------
# 3. Federated identity credential on the UAMI for the ASO controller SA + subscription-scope
#    Contributor for the UAMI principal (the RG-scope assignment is created by the Bicep template).
#    NOTE: creating the subscription-scope assignment requires the caller to hold Owner or
#    "Role Based Access Control Administrator" at the subscription scope.
# ---------------------------------------------------------------------------
$ficName = 'aso-federated-credential'
$ficSubject = "system:serviceaccount:${AsoNamespace}:${AsoServiceAccount}"
Write-Host "==> Ensuring UAMI federated credential '$ficName' (subject $ficSubject)..." -ForegroundColor Cyan
$ficExists = az identity federated-credential show --name $ficName --identity-name (Split-Path $uamiResourceId -Leaf) --resource-group $ResourceGroup --query name -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($ficExists)) {
    az identity federated-credential create `
        --name $ficName `
        --identity-name (Split-Path $uamiResourceId -Leaf) `
        --resource-group $ResourceGroup `
        --issuer $oidcIssuerUrl `
        --subject $ficSubject `
        --audiences 'api://AzureADTokenExchange' `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create federated credential '$ficName' on the UAMI." }
}
else {
    Write-Host "    federated credential '$ficName' already exists."
}

Write-Host '==> Ensuring subscription-scope Contributor for the UAMI principal...' -ForegroundColor Cyan
$subScope = "/subscriptions/$SubscriptionId"
$existingSub = az role assignment list --assignee $uamiPrincipalId --scope $subScope --query "[?roleDefinitionName=='Contributor'] | length(@)" -o tsv 2>$null
if ($existingSub -eq '0' -or [string]::IsNullOrWhiteSpace($existingSub)) {
    # The UAMI was just created; its Entra service principal can take a few seconds to
    # propagate, so retry the assignment (this is the sole grant the UAMI gets — fatal on failure).
    $assigned = $false
    for ($attempt = 1; $attempt -le 6 -and -not $assigned; $attempt++) {
        az role assignment create `
            --assignee-object-id $uamiPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role Contributor `
            --scope $subScope `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -eq 0) { $assigned = $true; break }
        Write-Host "    attempt ${attempt}: assignment not yet accepted (UAMI propagation); retrying in 10s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 10
    }
    if (-not $assigned) { throw "Failed to assign subscription-scope Contributor to the UAMI principal after retries. The UAMI cannot manage workload-cluster resource groups without it." }
}
else {
    Write-Host '    subscription-scope Contributor already assigned to the UAMI.'
}

# ---------------------------------------------------------------------------
# 4. Get kubeconfig for the management cluster.
# ---------------------------------------------------------------------------
Write-Host "==> Fetching kubeconfig for '$mgmtClusterName'..." -ForegroundColor Cyan
az aks get-credentials --resource-group $ResourceGroup --name $mgmtClusterName --overwrite-existing --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Failed to get credentials for '$mgmtClusterName'." }

# ---------------------------------------------------------------------------
# 5. clusterctl init --infrastructure azure. Installs CAPI core + kubeadm + CAPZ (bundles ASO).
#    Workload Identity auth: AZURE_CLIENT_ID = UAMI client ID, USE_WORKLOAD_IDENTITY_AUTH=true,
#    no client secret. SP+SECRET FALLBACK (uncomment if Workload Identity is unavailable):
#        $env:AZURE_CLIENT_SECRET = '<sp-secret>'   # and set AZURE_CLIENT_ID to the SP appId
#        # omit USE_WORKLOAD_IDENTITY_AUTH; clusterctl uses the SP+secret directly.
# ---------------------------------------------------------------------------
Write-Host '==> Running clusterctl init --infrastructure azure...' -ForegroundColor Cyan
$env:EXP_MACHINE_POOL = 'true'          # MachinePool API required by the CAPZ aks-aso flavor
$env:EXP_ASO_API = 'true'               # ASO-backed managed-cluster API (default-on; explicit)
$env:EXP_AKS_RESOURCE_HEALTH = 'true'   # AKS resource-health experimental feature
$env:AZURE_SUBSCRIPTION_ID = $SubscriptionId
$env:AZURE_TENANT_ID = $tenantId
$env:AZURE_CLIENT_ID = $uamiClientId
$env:USE_WORKLOAD_IDENTITY_AUTH = 'true'

clusterctl init --infrastructure azure
if ($LASTEXITCODE -ne 0) { throw 'clusterctl init --infrastructure azure failed.' }

# ---------------------------------------------------------------------------
# 6. Wire ASO Workload Identity (global credential model). The Azure Workload Identity webhook
#    only mutates PODS carrying the label azure.workload.identity/use=true (objectSelector), so the
#    label MUST be on the ASO deployment's pod template — not just the service account. The ASO
#    controller reads its global credential from the 'aso-controller-settings' secret, which CAPZ
#    ships EMPTY; populate it with the UAMI client/tenant/subscription + USE_WORKLOAD_IDENTITY_AUTH.
#    SP+SECRET FALLBACK: add AZURE_CLIENT_SECRET to the patch below and drop USE_WORKLOAD_IDENTITY_AUTH.
# ---------------------------------------------------------------------------
Write-Host '==> Configuring ASO Workload Identity (service account + pod label + settings)...' -ForegroundColor Cyan
kubectl annotate serviceaccount $AsoServiceAccount -n $AsoNamespace "azure.workload.identity/client-id=$uamiClientId" --overwrite
if ($LASTEXITCODE -ne 0) { throw 'Failed to annotate the ASO controller service account.' }
kubectl label serviceaccount $AsoServiceAccount -n $AsoNamespace 'azure.workload.identity/use=true' --overwrite
if ($LASTEXITCODE -ne 0) { throw 'Failed to label the ASO controller service account.' }

# Populate the global ASO credential secret (UAMI Workload Identity).
$asoSettingsPatch = @{ stringData = @{
        AZURE_CLIENT_ID            = $uamiClientId
        AZURE_TENANT_ID            = $tenantId
        AZURE_SUBSCRIPTION_ID      = $SubscriptionId
        USE_WORKLOAD_IDENTITY_AUTH = 'true'
    } } | ConvertTo-Json -Compress
$asoSettingsFile = Join-Path ([System.IO.Path]::GetTempPath()) 'aso-settings-patch.json'
$asoSettingsPatch | Set-Content -NoNewline -Path $asoSettingsFile
kubectl patch secret $AsoSettingsSecret -n $AsoNamespace --type merge --patch-file $asoSettingsFile
if ($LASTEXITCODE -ne 0) { throw "Failed to patch the ASO settings secret '$AsoSettingsSecret'." }
Remove-Item -Path $asoSettingsFile -ErrorAction SilentlyContinue

# Add the Workload Identity pod label to the ASO deployment template (webhook objectSelector match),
# then restart so the webhook injects the federated token volume/env on the new pods.
kubectl patch deployment $AsoDeployment -n $AsoNamespace --type merge -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}'
if ($LASTEXITCODE -ne 0) { throw "Failed to add the Workload Identity pod label to deployment '$AsoDeployment'." }
kubectl rollout restart deployment $AsoDeployment -n $AsoNamespace
[void]$LASTEXITCODE
kubectl rollout status deployment $AsoDeployment -n $AsoNamespace --timeout=180s
if ($LASTEXITCODE -ne 0) { Write-Warning "ASO controller '$AsoDeployment' did not report ready within the timeout." }

# ---------------------------------------------------------------------------
# 7. Install ArgoCD via Helm (idempotent upgrade --install).
# ---------------------------------------------------------------------------
Write-Host '==> Installing ArgoCD (helm upgrade --install)...' -ForegroundColor Cyan
helm repo add argo https://argoproj.github.io/argo-helm 2>$null
[void]$LASTEXITCODE
helm repo update argo 2>$null
[void]$LASTEXITCODE
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
if ($LASTEXITCODE -ne 0) { throw 'Failed to install ArgoCD via Helm.' }

# ---------------------------------------------------------------------------
# 8. Apply the GitOps app-of-apps root. Authored in Phase 4 (Step 4.1); tolerate absence here.
# ---------------------------------------------------------------------------
if (Test-Path -Path $rootAppPath) {
    Write-Host "==> Applying GitOps root app ($rootAppPath)..." -ForegroundColor Cyan
    kubectl apply -f $rootAppPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply root app '$rootAppPath'." }
}
else {
    Write-Warning "Root app '$rootAppPath' not found (authored in Phase 4). Skipping GitOps bootstrap apply."
}

# ---------------------------------------------------------------------------
# 9. Readiness checks: CAPI/CAPZ/ASO controllers Available + the ASO managed control-plane CRD.
# ---------------------------------------------------------------------------
Write-Host '==> Waiting for controllers to become Available...' -ForegroundColor Cyan
$deployments = @(
    @{ ns = 'capi-system'; name = 'capi-controller-manager' },
    @{ ns = 'capz-system'; name = 'capz-controller-manager' },
    @{ ns = $AsoNamespace; name = 'azureserviceoperator-controller-manager' }
)
foreach ($d in $deployments) {
    Write-Host "    waiting: $($d.ns)/$($d.name)"
    kubectl wait --for=condition=Available --timeout=300s deployment/$($d.name) -n $($d.ns)
    if ($LASTEXITCODE -ne 0) { Write-Warning "Deployment $($d.ns)/$($d.name) did not report Available within the timeout." }
}

Write-Host '==> Verifying the AzureASOManagedControlPlane CRD is served...' -ForegroundColor Cyan
kubectl get crd azureasomanagedcontrolplanes.infrastructure.cluster.x-k8s.io
if ($LASTEXITCODE -ne 0) { throw 'AzureASOManagedControlPlane CRD not found; clusterctl init may not have completed.' }

Write-Host '==> Management cluster bootstrap complete.' -ForegroundColor Green
Write-Host "    Next: ./scripts/provision-clusters.ps1 to create the workload clusters."
