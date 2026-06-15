#requires -Version 7.0
<#
.SYNOPSIS
    Capture AKS governance PoC evidence artifacts (CLI text + best-effort screenshots).

.DESCRIPTION
    Two capture legs (mirrors the aks-fleet-manager evidence model):

      1. Deterministic CLI text capture (ALWAYS runs). Tees the output of
         'kubectl', 'clusterctl', and 'az' health/governance commands into
         '.txt' files under -CaptureDir. Each command is wrapped independently
         so a single failure (for example a controller not yet ready) warns but
         still lets the remaining captures and the Playwright leg proceed.
         Coverage maps to the PoC success criteria:
           * management cluster health (nodes, CAPI/CAPZ/ASO controllers),
           * workload cluster provisioning (clusterctl describe per cluster),
           * ArgoCD GitOps sync (Applications + registered workload clusters),
           * governance policy state (Kyverno ClusterPolicy + PolicyReport),
           * Azure-side AKS state (OIDC issuer + workload identity).

      2. Best-effort Playwright screenshots (only when
         'docs/storage_state.json' exists). Drives 'docs/capture-argocd.ts' to
         screenshot the ArgoCD Applications UI and (optionally) the Azure portal
         AKS blades. Wrapped in try/catch so missing or expired auth degrades
         gracefully and never fails the script.

    Capture the portal auth state once (headed, complete MFA by hand):
      npx playwright codegen https://portal.azure.com --save-storage=docs/storage_state.json

.PARAMETER ResourceGroup
    Resource group containing the management AKS cluster. Default 'rg-aksgov-poc-mgmt'.

.PARAMETER MgmtClusterName
    Management AKS cluster name (CAPI/CAPZ/ASO + ArgoCD + Kyverno host).
    Default 'aksgov-poc-mgmt'.

.PARAMETER WorkloadClusters
    CAPI workload cluster names to 'clusterctl describe'. Default 'poc-aks-1','poc-aks-2'.

.PARAMETER KubeContext
    Optional kubeconfig context that targets the management cluster. When omitted,
    the current kubeconfig context is used (the caller is expected to have run
    'az aks get-credentials' for the management cluster).

.PARAMETER CaptureDir
    Directory (relative to repo root or absolute) for CLI text captures.
    Default 'docs/captures'.

.PARAMETER ScreenshotDir
    Directory for Playwright screenshots. Default 'docs/screenshots'.

.PARAMETER SkipScreenshots
    Skip the best-effort Playwright leg entirely (CLI text capture still runs).

.EXAMPLE
    ./scripts/capture.ps1 -ResourceGroup rg-aksgov-poc-mgmt -MgmtClusterName aksgov-poc-mgmt

.EXAMPLE
    ./scripts/capture.ps1 -SkipScreenshots

.NOTES
    Follows user memory powershell-pitfalls.md: literal '&' (never '&amp;'),
    'Select-String' (never 'grep'), StrictMode, $ErrorActionPreference='Stop'.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup    = 'rg-aksgov-poc-mgmt',
    [string]$MgmtClusterName  = 'aksgov-poc-mgmt',
    [string[]]$WorkloadClusters = @('poc-aks-1', 'poc-aks-2'),
    [string]$KubeContext      = '',
    [string]$CaptureDir       = 'docs/captures',
    [string]$ScreenshotDir    = 'docs/screenshots',
    [switch]$SkipScreenshots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve paths relative to the repository root (parent of this script's folder).
$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedCaptureDir = if ([System.IO.Path]::IsPathRooted($CaptureDir)) {
    $CaptureDir
}
else {
    Join-Path $repoRoot $CaptureDir
}

New-Item -ItemType Directory -Path $resolvedCaptureDir -Force | Out-Null

# kubectl/clusterctl context selector (empty array when no explicit context).
$kubeCtx       = if ([string]::IsNullOrWhiteSpace($KubeContext)) { @() } else { @('--context', $KubeContext) }
$clusterctlCtx = if ([string]::IsNullOrWhiteSpace($KubeContext)) { @() } else { @('--kubeconfig-context', $KubeContext) }

function Invoke-Capture {
    <#
        Runs '<Exe> <Arguments>' and tees combined stdout/stderr to '<Dir>/<File>'.
        Independent failure is non-fatal: it warns and the caller continues.
    #>
    param(
        [string]$File,
        [string]$Exe,
        [string[]]$Arguments = @(),
        [string]$Dir
    )
    $target = Join-Path $Dir $File
    try {
        & $Exe @Arguments 2>&1 | Tee-Object -FilePath $target
        Write-Host "  wrote $target"
    }
    catch {
        Write-Warning "Capture for '$File' failed (non-fatal): $($_.Exception.Message)"
        "Capture failed: $($_.Exception.Message)" | Set-Content -LiteralPath $target -Encoding utf8
    }
}

# --- Leg 1: deterministic CLI text capture (always runs) ---
Write-Host "Capturing CLI evidence to $resolvedCaptureDir ..."

# Management cluster health: nodes + CAPI/CAPZ/ASO controller pods.
Invoke-Capture -Dir $resolvedCaptureDir -File '01-mgmt-nodes.txt'        -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'nodes', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '02-capi-controllers.txt'  -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'pods', '-n', 'capi-system', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '03-capz-controllers.txt'  -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'pods', '-n', 'capz-system', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '04-aso-controllers.txt'   -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'pods', '-n', 'azureserviceoperator-system', '-o', 'wide'))

# Workload cluster provisioning: CAPI Cluster objects + per-cluster description.
Invoke-Capture -Dir $resolvedCaptureDir -File '05-clusters.txt'          -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'clusters', '-A', '-o', 'wide'))
foreach ($name in $WorkloadClusters) {
    Invoke-Capture -Dir $resolvedCaptureDir -File "05-cluster-$name.txt"  -Exe 'clusterctl' -Arguments ($clusterctlCtx + @('describe', 'cluster', $name))
}

# ArgoCD GitOps sync: Applications + registered workload cluster Secrets.
Invoke-Capture -Dir $resolvedCaptureDir -File '06-argocd-applications.txt' -Exe 'kubectl'  -Arguments ($kubeCtx + @('get', 'applications', '-n', 'argocd', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '06-argocd-applicationsets.txt' -Exe 'kubectl' -Arguments ($kubeCtx + @('get', 'applicationsets', '-n', 'argocd', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '07-argocd-clusters.txt'   -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'secrets', '-n', 'argocd', '-l', 'argocd.argoproj.io/secret-type=cluster', '-o', 'wide'))

# Governance policy state: Kyverno ClusterPolicy + PolicyReport (registry deny + min-version).
Invoke-Capture -Dir $resolvedCaptureDir -File '08-kyverno-policies.txt'  -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'clusterpolicy', '-o', 'wide'))
Invoke-Capture -Dir $resolvedCaptureDir -File '09-policy-reports.txt'    -Exe 'kubectl'    -Arguments ($kubeCtx + @('get', 'policyreport', '-A'))

# Azure-side AKS state: management cluster OIDC + workload identity, and AKS inventory.
Invoke-Capture -Dir $resolvedCaptureDir -File '10-mgmt-aks.txt'          -Exe 'az'         -Arguments @('aks', 'show', '-g', $ResourceGroup, '-n', $MgmtClusterName, '--query', '{Name:name,KubernetesVersion:currentKubernetesVersion,ProvisioningState:provisioningState,PowerState:powerState.code,OidcIssuer:oidcIssuerProfile.enabled,WorkloadIdentity:securityProfile.workloadIdentity.enabled}', '-o', 'table', '--only-show-errors')
Invoke-Capture -Dir $resolvedCaptureDir -File '11-aks-inventory.txt'     -Exe 'az'         -Arguments @('aks', 'list', '--query', '[].{Name:name,ResourceGroup:resourceGroup,KubernetesVersion:currentKubernetesVersion,ProvisioningState:provisioningState,PowerState:powerState.code}', '-o', 'table', '--only-show-errors')

# --- Leg 2: best-effort Playwright screenshots (gated on auth state) ---
$docsDir       = Join-Path $repoRoot 'docs'
$storageState  = Join-Path $docsDir 'storage_state.json'
$resolvedShots = if ([System.IO.Path]::IsPathRooted($ScreenshotDir)) { $ScreenshotDir } else { Join-Path $repoRoot $ScreenshotDir }

if ($SkipScreenshots) {
    Write-Host 'SkipScreenshots set - Playwright capture skipped (CLI text capture already written).'
}
elseif (Test-Path -LiteralPath $storageState) {
    try {
        Write-Host 'storage_state.json found - attempting best-effort Playwright capture ...'
        New-Item -ItemType Directory -Path $resolvedShots -Force | Out-Null

        Push-Location $docsDir
        try {
            # capture-argocd.ts reads these. ArgoCD UI + (optional) Azure portal
            # AKS blades. Subscription/tenant fall back to the current
            # 'az account show' context when not already set.
            $env:SCREENSHOT_DIR  = $resolvedShots
            $env:AZ_RESOURCE_GROUP = $ResourceGroup
            $env:AZ_MGMT_CLUSTER = $MgmtClusterName
            if (-not $env:AZ_SUBSCRIPTION_ID) { $env:AZ_SUBSCRIPTION_ID = (az account show --query id -o tsv) }
            if (-not $env:AZ_TENANT_ID)       { $env:AZ_TENANT_ID = (az account show --query tenantId -o tsv) }

            # Resolve the ArgoCD server endpoint when not explicitly provided.
            # Prefers a LoadBalancer IP; the operator may instead 'kubectl
            # port-forward svc/argocd-server -n argocd 8080:443' and set
            # ARGOCD_URL=https://localhost:8080 before running this script.
            if (-not $env:ARGOCD_URL) {
                $lbIp = & kubectl @($kubeCtx + @('get', 'svc', 'argocd-server', '-n', 'argocd', '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}')) 2>$null
                if (-not [string]::IsNullOrWhiteSpace($lbIp)) {
                    $env:ARGOCD_URL = "https://$($lbIp.Trim())"
                    Write-Host "  using ArgoCD endpoint $($env:ARGOCD_URL)"
                }
            }

            # Defined in docs/package.json: "capture": "tsx capture-argocd.ts".
            # Falls back to a direct tsx invocation when the npm script is absent.
            $npmCapture = $false
            $pkgJson = Join-Path $docsDir 'package.json'
            if (Test-Path -LiteralPath $pkgJson) {
                if (Select-String -LiteralPath $pkgJson -Pattern '"capture"' -Quiet) { $npmCapture = $true }
            }
            if ($npmCapture) {
                npm run capture
            }
            else {
                npx --yes tsx capture-argocd.ts
            }
            Write-Host "  screenshots written to $resolvedShots"
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Warning "Playwright capture skipped/failed (non-fatal): $($_.Exception.Message)"
        Write-Warning 'Re-capture auth: npx playwright codegen https://portal.azure.com --save-storage=docs/storage_state.json'
    }
}
else {
    Write-Host 'docs/storage_state.json not found - skipping Playwright capture (CLI text capture already written).'
    Write-Host 'To enable screenshots: npx playwright codegen https://portal.azure.com --save-storage=docs/storage_state.json'
}

Write-Host 'Capture complete.'
