<#
.SYNOPSIS
    Validates Azure readiness before provisioning the AKS governance PoC.

.DESCRIPTION
    Performs read-only preflight checks so a provisioning run does not fail halfway through:

      1. Resource provider registration for AKS, Managed Identity, Authorization, and the
         Azure Service Operator (ASO) prerequisites (Network, Compute, OperationalInsights).
         Providers found in 'NotRegistered' state are auto-registered, then re-checked.
      2. Region-valid AKS Kubernetes versions for both the management and second workload
         region. When -KubernetesVersion is supplied it is asserted to be an available patch;
         otherwise the latest supported and AKS-default versions are reported.
      3. VM SKU availability for the node pool size in each region (fails when the SKU carries
         a subscription/region restriction).
      4. Quota headroom: regional vCPU usage and public IP usage (emits warnings when low).

    Aside from auto-registering missing resource providers (the documented remediation), this
    script makes no mutating Azure calls. It is safe to run repeatedly.

    Requires PowerShell 7+, the Azure CLI, and an authenticated session (az login).

.PARAMETER Location
    Primary / management region. Default 'eastus2'.

.PARAMETER WorkloadLocation2
    Second workload-cluster region. Default 'westus3'.

.PARAMETER KubernetesVersion
    Optional. When supplied, asserts this exact patch version is offered by AKS in both
    regions. When omitted, the script reports the latest supported and default versions.

.PARAMETER MinNodeSku
    VM size used for cluster node pools. Default 'Standard_D2s_v6'.

.PARAMETER SubscriptionId
    Optional. Sets the active subscription before running checks. When omitted, the current
    az CLI subscription context is used.

.EXAMPLE
    ./scripts/preflight.ps1

.EXAMPLE
    ./scripts/preflight.ps1 -Location eastus2 -WorkloadLocation2 westus3 -KubernetesVersion 1.30.4

.EXAMPLE
    ./scripts/preflight.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -MinNodeSku Standard_D4s_v6
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [string]$WorkloadLocation2 = 'westus3',
    [string]$KubernetesVersion = '',
    [string]$MinNodeSku = 'Standard_D2s_v6',
    [string]$SubscriptionId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Warning thresholds (free units below which a non-fatal warning is emitted).
$script:CoreWarnThreshold = 16
$script:PublicIpWarnThreshold = 4

# Resource providers required by AKS + Azure Service Operator (ASO) managed clusters.
$script:RequiredProviders = @(
    'Microsoft.ContainerService',
    'Microsoft.ManagedIdentity',
    'Microsoft.Authorization',
    'Microsoft.Network',
    'Microsoft.Compute',
    'Microsoft.OperationalInsights'
)

# Accumulated check results; each entry drives the final summary and exit code.
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ("    [{0}] {1} - {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

# Runs an az command and returns its stdout parsed from JSON. Throws (with the full command
# line) on a non-zero exit so a broken prerequisite check never silently passes.
function Get-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command 'az $($Arguments -join ' ')' exited with code $LASTEXITCODE."
    }
    $joined = ($out -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }
    return ($joined | ConvertFrom-Json)
}

# Returns $true when the named property exists on a parsed-JSON object (StrictMode-safe).
function Test-HasProperty {
    param([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $false }
    return [bool]($InputObject.PSObject.Properties.Name -contains $Name)
}

# Collapses AKS get-versions output (current 'values' schema or legacy 'orchestrators'
# schema) into a flat patch list plus the AKS-default version.
function Get-AksVersionInfo {
    param([Parameter(Mandatory)][string]$Region)
    $data = Get-AzJson @('aks', 'get-versions', '-l', $Region, '-o', 'json')
    $patches = New-Object System.Collections.Generic.List[string]
    $default = $null

    if (Test-HasProperty $data 'values') {
        foreach ($minor in $data.values) {
            $isDefaultMinor = $false
            if ((Test-HasProperty $minor 'isDefault') -and $minor.isDefault) { $isDefaultMinor = $true }
            if ((Test-HasProperty $minor 'patchVersions') -and ($null -ne $minor.patchVersions)) {
                $minorPatches = @($minor.patchVersions.PSObject.Properties.Name)
                foreach ($p in $minorPatches) { $patches.Add($p) }
                if ($isDefaultMinor -and $minorPatches.Count -gt 0) {
                    $default = ($minorPatches | Sort-Object { [version]$_ } | Select-Object -Last 1)
                }
            }
        }
    }
    elseif (Test-HasProperty $data 'orchestrators') {
        foreach ($o in $data.orchestrators) {
            if (Test-HasProperty $o 'orchestratorVersion') { $patches.Add($o.orchestratorVersion) }
            if ((Test-HasProperty $o 'default') -and $o.default) { $default = $o.orchestratorVersion }
        }
    }

    $latest = $null
    if ($patches.Count -gt 0) {
        $latest = ($patches | Sort-Object { [version]$_ } | Select-Object -Last 1)
    }
    if (-not $default) { $default = $latest }

    return [pscustomobject]@{
        Patches = ($patches | Sort-Object { [version]$_ } -Unique)
        Latest  = $latest
        Default = $default
    }
}

Write-Host '==> AKS governance PoC - Azure preflight' -ForegroundColor Cyan
Write-Host "    Location           : $Location"
Write-Host "    WorkloadLocation2  : $WorkloadLocation2"
Write-Host "    KubernetesVersion  : $(if ($KubernetesVersion) { $KubernetesVersion } else { '<discover latest/default>' })"
Write-Host "    MinNodeSku         : $MinNodeSku"
Write-Host "    SubscriptionId     : $(if ($SubscriptionId) { $SubscriptionId } else { '<current az context>' })"
Write-Host ''

# --- Preconditions: az present + authenticated --------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') was not found on PATH. Install it from https://aka.ms/azure-cli then re-run."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to set active subscription to '$SubscriptionId'. Confirm the id and your access." }
}

$account = $null
try { $account = Get-AzJson @('account', 'show', '-o', 'json') } catch { $account = $null }
if ($null -eq $account) {
    throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') then re-run preflight."
}
$accountName = if (Test-HasProperty $account 'name') { $account.name } else { '<unknown>' }
$accountId = if (Test-HasProperty $account 'id') { $account.id } else { '<unknown>' }
Write-Host "==> Subscription context: $accountName ($accountId)" -ForegroundColor Cyan
Write-Host ''

# --- Check 1: resource provider registration ----------------------------------------------
Write-Host '==> [1/4] Resource provider registration' -ForegroundColor Cyan
foreach ($ns in $script:RequiredProviders) {
    $state = Get-AzJson @('provider', 'show', '--namespace', $ns, '--query', 'registrationState', '-o', 'json')

    if ($state -ne 'Registered') {
        Write-Host "    '$ns' is '$state'; registering..." -ForegroundColor Yellow
        az provider register --namespace $ns --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Add-Result -Name "Provider:$ns" -Status 'FAIL' -Detail "Registration command failed (exit $LASTEXITCODE). Run 'az provider register --namespace $ns' manually."
            continue
        }

        # Poll for completion (registration is asynchronous; usually fast for these RPs).
        $maxWaitSeconds = 90
        $intervalSeconds = 10
        $elapsed = 0
        while ($state -ne 'Registered' -and $elapsed -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $intervalSeconds
            $elapsed += $intervalSeconds
            $state = Get-AzJson @('provider', 'show', '--namespace', $ns, '--query', 'registrationState', '-o', 'json')
        }
    }

    if ($state -eq 'Registered') {
        Add-Result -Name "Provider:$ns" -Status 'PASS' -Detail 'Registered.'
    }
    else {
        Add-Result -Name "Provider:$ns" -Status 'FAIL' -Detail "State '$state' after registration attempt. Wait for registration to complete, then re-run preflight."
    }
}
Write-Host ''

# --- Check 2: region-valid AKS Kubernetes versions ----------------------------------------
Write-Host '==> [2/4] AKS Kubernetes versions' -ForegroundColor Cyan
$normalizedRequested = $KubernetesVersion.TrimStart('v', 'V')
foreach ($region in @($Location, $WorkloadLocation2)) {
    try {
        $info = Get-AksVersionInfo -Region $region
    }
    catch {
        Add-Result -Name "AksVersions:$region" -Status 'FAIL' -Detail "Could not read AKS versions: $($_.Exception.Message)"
        continue
    }

    if ($info.Patches.Count -eq 0) {
        Add-Result -Name "AksVersions:$region" -Status 'FAIL' -Detail "AKS reported no available versions for region '$region'."
        continue
    }

    if ($normalizedRequested) {
        if ($info.Patches -contains $normalizedRequested) {
            Add-Result -Name "AksVersions:$region" -Status 'PASS' -Detail "Requested version $normalizedRequested is available (latest offered: $($info.Latest))."
        }
        else {
            $sample = (($info.Patches | Sort-Object { [version]$_ } | Select-Object -Last 5) -join ', ')
            Add-Result -Name "AksVersions:$region" -Status 'FAIL' -Detail "Requested version $normalizedRequested is NOT offered in '$region'. Recent available: $sample."
        }
    }
    else {
        Add-Result -Name "AksVersions:$region" -Status 'PASS' -Detail "Latest supported: $($info.Latest); AKS default: $($info.Default)."
    }
}
Write-Host ''

# --- Check 3: VM SKU availability ----------------------------------------------------------
Write-Host '==> [3/4] VM SKU availability' -ForegroundColor Cyan
foreach ($region in @($Location, $WorkloadLocation2)) {
    try {
        $skus = @(Get-AzJson @('vm', 'list-skus', '-l', $region, '--size', $MinNodeSku, '--query', "[?name=='$MinNodeSku']", '-o', 'json'))
    }
    catch {
        Add-Result -Name "VmSku:$region" -Status 'FAIL' -Detail "Could not query VM SKUs: $($_.Exception.Message)"
        continue
    }

    if ($skus.Count -eq 0) {
        Add-Result -Name "VmSku:$region" -Status 'FAIL' -Detail "SKU '$MinNodeSku' is not offered in region '$region'. Choose a different size or region."
        continue
    }

    $sku0 = $skus[0]
    $restrictions = @()
    if ((Test-HasProperty $sku0 'restrictions') -and $null -ne $sku0.restrictions) { $restrictions = @($sku0.restrictions) }

    if ($restrictions.Count -gt 0) {
        $reasons = @()
        foreach ($r in $restrictions) {
            $reason = if (Test-HasProperty $r 'reasonCode') { $r.reasonCode } else { 'Restricted' }
            $reasons += $reason
        }
        Add-Result -Name "VmSku:$region" -Status 'FAIL' -Detail "SKU '$MinNodeSku' is restricted in '$region' ($([string]::Join('; ', $reasons))). Request a quota increase or pick another size/region."
    }
    else {
        Add-Result -Name "VmSku:$region" -Status 'PASS' -Detail "SKU '$MinNodeSku' is available with no restrictions in '$region'."
    }
}
Write-Host ''

# --- Check 4: quota headroom (warnings only) ----------------------------------------------
Write-Host '==> [4/4] Quota headroom' -ForegroundColor Cyan
foreach ($region in @($Location, $WorkloadLocation2)) {

    # Regional vCPU (core) usage.
    try {
        $usage = @(Get-AzJson @('vm', 'list-usage', '-l', $region, '-o', 'json'))
        $cores = $usage | Where-Object { (Test-HasProperty $_ 'name') -and (Test-HasProperty $_.name 'value') -and $_.name.value -eq 'cores' } | Select-Object -First 1
        if ($null -ne $cores) {
            $current = [int]$cores.currentValue
            $limit = [int]$cores.limit
            $free = $limit - $current
            if ($free -lt $script:CoreWarnThreshold) {
                Add-Result -Name "Quota:vCPU:$region" -Status 'WARN' -Detail "Only $free of $limit regional vCPUs free (used $current). Below the $($script:CoreWarnThreshold)-core guideline; consider a quota increase."
            }
            else {
                Add-Result -Name "Quota:vCPU:$region" -Status 'PASS' -Detail "$free of $limit regional vCPUs free (used $current)."
            }
        }
        else {
            Add-Result -Name "Quota:vCPU:$region" -Status 'WARN' -Detail "Could not locate the regional 'cores' usage entry for '$region'."
        }
    }
    catch {
        Add-Result -Name "Quota:vCPU:$region" -Status 'WARN' -Detail "Could not read vCPU usage: $($_.Exception.Message)"
    }

    # Public IP usage.
    try {
        $netUsage = @(Get-AzJson @('network', 'list-usages', '-l', $region, '-o', 'json'))
        $pip = $netUsage | Where-Object { (Test-HasProperty $_ 'name') -and (Test-HasProperty $_.name 'value') -and $_.name.value -eq 'PublicIPAddresses' } | Select-Object -First 1
        if ($null -ne $pip) {
            $current = [int]$pip.currentValue
            $limit = [int]$pip.limit
            $free = $limit - $current
            if ($free -lt $script:PublicIpWarnThreshold) {
                Add-Result -Name "Quota:PublicIP:$region" -Status 'WARN' -Detail "Only $free of $limit public IPs free (used $current). Below the $($script:PublicIpWarnThreshold)-IP guideline; consider a quota increase."
            }
            else {
                Add-Result -Name "Quota:PublicIP:$region" -Status 'PASS' -Detail "$free of $limit public IPs free (used $current)."
            }
        }
        else {
            Add-Result -Name "Quota:PublicIP:$region" -Status 'WARN' -Detail "Could not locate the 'PublicIPAddresses' usage entry for '$region'."
        }
    }
    catch {
        Add-Result -Name "Quota:PublicIP:$region" -Status 'WARN' -Detail "Could not read public IP usage: $($_.Exception.Message)"
    }
}
Write-Host ''

# --- Summary + exit code ------------------------------------------------------------------
$passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count

Write-Host '================ PREFLIGHT SUMMARY ================' -ForegroundColor Cyan
foreach ($r in $script:Results) {
    $color = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ("  {0,-4} {1,-26} {2}" -f $r.Status, $r.Name, $r.Detail) -ForegroundColor $color
}
Write-Host '---------------------------------------------------'
Write-Host ("  Totals: {0} PASS / {1} WARN / {2} FAIL" -f $passCount, $warnCount, $failCount)
Write-Host '==================================================='

if ($failCount -gt 0) {
    Write-Host ''
    Write-Host "PREFLIGHT FAILED: resolve the $failCount FAIL item(s) above before provisioning." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'PREFLIGHT PASSED: regions, versions, SKUs, and providers are usable.' -ForegroundColor Green
if ($warnCount -gt 0) {
    Write-Host "Note: $warnCount warning(s) above are non-blocking but worth reviewing." -ForegroundColor Yellow
}
exit 0
