<#
.SYNOPSIS
    Cost-safe, CAPI-ordered teardown of the AKS governance PoC.

.DESCRIPTION
    Deletes the PoC in the only order that does NOT leak billable Azure resources:

      1. kubectl delete the CAPI 'Cluster' objects for every workload cluster discovered
         under -ClustersDir. Deleting the Cluster cascades CAPI -> CAPZ -> ASO -> Azure
         resource-group deletion of each workload AKS cluster.
      2. Poll Azure until BOTH CAPZ-created workload resource groups are gone (bounded by
         -Timeout). Verification output is written to docs/captures/ for the proof wiki.
      3. ONLY after the workload RGs are confirmed deleted, delete the management RG
         (-ResourceGroup) with --no-wait.

    Destroying the management cluster first would orphan the workload AKS clusters (CAPI/CAPZ
    can no longer reconcile their deletion), and they would keep billing. This script refuses
    to delete the management RG while any workload RG still exists, unless -SkipWorkloadWait
    is supplied (dangerous escape hatch).

    This script calls live Azure and Kubernetes resources. Ensure you are logged in
    (az login) and that the current kubectl context points at the management cluster.

.PARAMETER ResourceGroup
    The management resource group to delete LAST. Default 'rg-aksgov-poc-mgmt'.

.PARAMETER ClustersDir
    Directory containing per-cluster '.env' input files (one per workload cluster). The
    cluster list is discovered from these files rather than hardcoded. Default 'clusters'.

.PARAMETER Timeout
    Maximum time to wait for the workload resource groups to disappear, expressed as a
    shorthand duration: '30m', '90s', '1h', or '1h30m'. Default '30m'.

.PARAMETER Force
    Skip the interactive confirmation prompt. Intended for unattended pipeline runs that
    are already gated by an approval environment.

.PARAMETER SkipWorkloadWait
    DANGEROUS. Skip both the workload-RG wait loop and the safety guard, deleting the
    management RG immediately after issuing the cluster deletes. This can ORPHAN the
    workload AKS clusters and leave them billing indefinitely. Use only when the workload
    clusters are already known to be gone.

.EXAMPLE
    ./scripts/teardown.ps1

.EXAMPLE
    ./scripts/teardown.ps1 -Force -Timeout 45m

.EXAMPLE
    ./scripts/teardown.ps1 -ResourceGroup rg-aksgov-poc-mgmt -ClustersDir clusters
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-aksgov-poc-mgmt',
    [string]$ClustersDir = 'clusters',
    [string]$Timeout = '30m',
    [switch]$Force,
    [switch]$SkipWorkloadWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Path resolution --------------------------------------------------------------------
# Resolve repo-relative inputs/outputs against the repo root (parent of scripts/), so the
# script works whether invoked from the repo root or from the scripts/ directory.
$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $script:RepoRoot $Path)
}

$resolvedClustersDir = Resolve-RepoPath $ClustersDir
$capturesDir = Resolve-RepoPath 'docs/captures'

# --- Capture helper ---------------------------------------------------------------------
# Mirrors the sibling repo's two-leg evidence model: deterministic CLI text under
# docs/captures/. Every verification line is echoed to the console AND appended to the
# capture file so the teardown ordering is provable in the wiki.
if (-not (Test-Path $capturesDir)) { New-Item -ItemType Directory -Path $capturesDir -Force | Out-Null }
$script:CaptureFile = Join-Path $capturesDir 'teardown.txt'
Set-Content -Path $script:CaptureFile -Value "# AKS governance PoC teardown - $(Get-Date -Format o)" -Encoding utf8

function Write-Capture {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Color = 'Gray'
    )
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $script:CaptureFile -Value $Message -Encoding utf8
}

# --- Duration parsing -------------------------------------------------------------------
# Parses shorthand like '30m', '90s', '1h', '1h30m' into a [TimeSpan].
function ConvertTo-TimeSpanFromShorthand {
    param([Parameter(Mandatory)][string]$Value)
    $matchInfo = $Value | Select-String -Pattern '^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$'
    if (-not $matchInfo -or $Value -notmatch '\d') {
        throw "Invalid -Timeout '$Value'. Use shorthand like '30m', '90s', '1h', or '1h30m'."
    }
    $groups = $matchInfo.Matches[0].Groups
    $hours = if ($groups[1].Success) { [int]$groups[1].Value } else { 0 }
    $minutes = if ($groups[2].Success) { [int]$groups[2].Value } else { 0 }
    $seconds = if ($groups[3].Success) { [int]$groups[3].Value } else { 0 }
    return [TimeSpan]::new($hours, $minutes, $seconds)
}

# --- Workload cluster discovery ---------------------------------------------------------
# Reads each clusters/*.env file and resolves: the CAPI Cluster name (CLUSTER_NAME) and the
# CAPZ-created workload resource group. The .env schema (research Lines 295-307) pins
# CLUSTER_NAME but does not pin an explicit RG variable, because the CAPZ aks-aso template
# defaults the workload resourceGroupName to the cluster name. RG resolution precedence:
#   1. AZURE_RESOURCE_GROUP / RESOURCE_GROUP / AZURE_RG in the .env (explicit override)
#   2. CLUSTER_NAME (CAPZ aks-aso default convention)
function Get-WorkloadCluster {
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path $Directory)) {
        throw "Clusters directory '$Directory' not found."
    }

    $envFiles = Get-ChildItem -Path $Directory -Filter '*.env' -File -ErrorAction SilentlyContinue |
        Sort-Object Name
    if (-not $envFiles -or $envFiles.Count -eq 0) {
        throw "No '*.env' cluster input files found under '$Directory'. Nothing to tear down."
    }

    $clusters = New-Object System.Collections.Generic.List[object]
    foreach ($file in $envFiles) {
        $pairs = @{}
        foreach ($line in (Get-Content -Path $file.FullName)) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $key = $matches[1]
                $val = $matches[2].Trim().Trim('"').Trim("'")
                $pairs[$key] = $val
            }
        }

        if (-not $pairs.ContainsKey('CLUSTER_NAME') -or [string]::IsNullOrWhiteSpace($pairs['CLUSTER_NAME'])) {
            throw "Cluster input '$($file.Name)' is missing required key CLUSTER_NAME."
        }
        $name = $pairs['CLUSTER_NAME']

        $rg = $null
        foreach ($rgKey in @('AZURE_RESOURCE_GROUP', 'RESOURCE_GROUP', 'AZURE_RG')) {
            if ($pairs.ContainsKey($rgKey) -and -not [string]::IsNullOrWhiteSpace($pairs[$rgKey])) {
                $rg = $pairs[$rgKey]
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($rg)) { $rg = $name }

        $clusters.Add([pscustomobject]@{
            Name          = $name
            ResourceGroup = $rg
            EnvFile       = $file.Name
        })
    }
    return $clusters
}

# --- Azure RG existence check -----------------------------------------------------------
function Test-RgExists {
    param([Parameter(Mandatory)][string]$Name)
    $out = az group exists --name $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Command 'az group exists --name $Name' exited with code $LASTEXITCODE."
    }
    return (($out | Select-Object -First 1) -eq 'true')
}

# ========================================================================================
# Main flow
# ========================================================================================

Write-Capture "==> Discovering workload clusters from '$resolvedClustersDir'..." 'Cyan'
$clusters = Get-WorkloadCluster -Directory $resolvedClustersDir
$clusterNames = @($clusters | Select-Object -ExpandProperty Name)
$workloadRgs = @($clusters | Select-Object -ExpandProperty ResourceGroup | Sort-Object -Unique)

foreach ($c in $clusters) {
    Write-Capture ("    cluster '{0}' (from {1}) -> workload RG '{2}'" -f $c.Name, $c.EnvFile, $c.ResourceGroup)
}
Write-Capture ("==> Management RG (deleted LAST): '{0}'" -f $ResourceGroup) 'Cyan'

# --- Confirmation gate ------------------------------------------------------------------
if (-not $Force) {
    Write-Host ''
    Write-Host 'This will DELETE the following live Azure resources:' -ForegroundColor Yellow
    Write-Host ("  - Workload clusters: {0}" -f ($clusterNames -join ', ')) -ForegroundColor Yellow
    Write-Host ("  - Workload RGs (via CAPI cascade): {0}" -f ($workloadRgs -join ', ')) -ForegroundColor Yellow
    Write-Host ("  - Management RG: {0}" -f $ResourceGroup) -ForegroundColor Yellow
    $answer = Read-Host 'Type the management RG name to confirm'
    if ($answer -ne $ResourceGroup) {
        Write-Host '==> Confirmation did not match. Aborting; nothing was deleted.' -ForegroundColor Green
        return
    }
}

# --- Step 1: cascade-delete workload clusters via CAPI ----------------------------------
Write-Capture ("==> [1/3] Deleting CAPI Cluster objects: {0}" -f ($clusterNames -join ', ')) 'Yellow'
kubectl delete cluster @clusterNames --ignore-not-found
if ($LASTEXITCODE -ne 0) {
    throw "kubectl delete cluster failed (exit $LASTEXITCODE). Workload RGs were NOT touched; management RG preserved."
}
Write-Capture '    CAPI Cluster delete issued (cascades CAPZ -> ASO -> Azure RG deletion).'

# --- Step 2: wait for workload RGs to disappear -----------------------------------------
if ($SkipWorkloadWait) {
    Write-Capture '==> [2/3] -SkipWorkloadWait set: SKIPPING workload-RG wait and safety guard.' 'Red'
    Write-Capture '    DANGER: workload clusters may still be deleting and could keep billing.' 'Red'
}
else {
    $timeoutSpan = ConvertTo-TimeSpanFromShorthand -Value $Timeout
    $deadline = (Get-Date).Add($timeoutSpan)
    Write-Capture ("==> [2/3] Waiting up to {0} for workload RGs to be deleted: {1}" -f $Timeout, ($workloadRgs -join ', ')) 'Yellow'

    $remaining = [System.Collections.Generic.List[string]]::new()
    foreach ($rg in $workloadRgs) { $remaining.Add($rg) }

    while ($remaining.Count -gt 0) {
        $stillPresent = [System.Collections.Generic.List[string]]::new()
        foreach ($rg in $remaining) {
            if (Test-RgExists -Name $rg) { $stillPresent.Add($rg) }
            else { Write-Capture ("    workload RG '{0}' is gone." -f $rg) 'Green' }
        }
        $remaining = $stillPresent
        if ($remaining.Count -eq 0) { break }

        if ((Get-Date) -gt $deadline) {
            Write-Capture ("    TIMEOUT after {0}; still present: {1}" -f $Timeout, ($remaining -join ', ')) 'Red'
            throw "Workload RGs not deleted within -Timeout ($Timeout): $($remaining -join ', '). Management RG '$ResourceGroup' preserved to avoid orphaning workload clusters."
        }
        Write-Capture ("    still present: {0}; re-checking in 30s..." -f ($remaining -join ', '))
        Start-Sleep -Seconds 30
    }
    Write-Capture '    All workload RGs confirmed deleted.' 'Green'
}

# --- Safety guard: never delete management RG while a workload RG survives ---------------
if (-not $SkipWorkloadWait) {
    $survivors = @($workloadRgs | Where-Object { Test-RgExists -Name $_ })
    if ($survivors.Count -gt 0) {
        throw "Refusing to delete management RG '$ResourceGroup': workload RGs still exist ($($survivors -join ', ')). Deleting the management cluster first would orphan them. Re-run after they are gone, or pass -SkipWorkloadWait to override (dangerous)."
    }
}

# --- Step 3: delete the management RG ----------------------------------------------------
Write-Capture ("==> [3/3] Deleting management RG '{0}' (background, --no-wait)..." -f $ResourceGroup) 'Yellow'
az group delete --name $ResourceGroup --yes --no-wait
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start deletion of management RG '$ResourceGroup' (exit $LASTEXITCODE)."
}

Write-Capture ("==> Teardown ordering complete. Verification captured to '{0}'." -f $script:CaptureFile) 'Green'
Write-Capture '    Workload RGs deleted before management RG deletion was issued.' 'Green'
