<#
.SYNOPSIS
    Provisions the PoC workload AKS clusters from per-cluster .env inputs using
    CAPI/CAPZ (aks-aso) on an already-bootstrapped management cluster.

.DESCRIPTION
    For every clusters/*.env file this script:

      1. Loads the KEY=VALUE inputs as process environment variables.
      2. Renders the checked-in CAPZ template with
         `clusterctl generate cluster <name> --from clusters/cluster-template-aks-aso.yaml`
         into a gitignored generated/<name>.yaml working file.
      3. Applies the rendered manifest to the management cluster (kubectl apply).
      4. Waits for the CAPI Cluster object to reach Ready, polling control-plane
         and machine-pool status for progress visibility.
      5. Retrieves the workload kubeconfig with `clusterctl get kubeconfig` into a
         gitignored kubeconfigs/<name>.kubeconfig file.

    It finishes by printing the kubeconfig paths so Phase 4 (ArgoCD registration)
    can consume them.

    PREREQUISITES (runtime, Phase 2): a management cluster with CAPI + CAPZ + ASO
    installed (`clusterctl init --infrastructure azure`), the ASO credential Secret
    applied, and the current kubectl context pointed at that management cluster.
    Requires PowerShell 7+, clusterctl, and kubectl on PATH.

    This script issues mutating cluster/Azure operations (kubectl apply, cluster
    creation). It is intended to be run only against the PoC management cluster.

.PARAMETER ClustersDir
    Directory containing the per-cluster *.env input files. Default 'clusters'.

.PARAMETER Timeout
    Maximum time to wait for each CAPI Cluster to reach Ready. Accepts a Go-style
    duration suffix (e.g. '30m', '45s', '1h'). Default '30m'.

.EXAMPLE
    ./scripts/provision-clusters.ps1

.EXAMPLE
    ./scripts/provision-clusters.ps1 -ClustersDir clusters -Timeout 45m
#>
[CmdletBinding()]
param(
    [string]$ClustersDir = 'clusters',
    [string]$Timeout = '30m'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo-root anchored paths so the script works regardless of the caller's CWD.
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:TemplatePath = Join-Path $script:RepoRoot 'clusters/cluster-template-aks-aso.yaml'
$script:GeneratedDir = Join-Path $script:RepoRoot 'generated'
$script:KubeconfigDir = Join-Path $script:RepoRoot 'kubeconfigs'

# Parses a Go-style duration ('30m', '45s', '1h', or a bare integer = seconds)
# into a [timespan]. Used for the readiness polling deadline.
function ConvertTo-TimeSpanDuration {
    param([Parameter(Mandatory)][string]$Duration)
    $match = [regex]::Match($Duration.Trim(), '^(?<value>\d+)(?<unit>[smh]?)$')
    if (-not $match.Success) {
        throw "Invalid -Timeout '$Duration'. Use a value like '30m', '45s', or '1h'."
    }
    $value = [int]$match.Groups['value'].Value
    switch ($match.Groups['unit'].Value) {
        's' { return [timespan]::FromSeconds($value) }
        'm' { return [timespan]::FromMinutes($value) }
        'h' { return [timespan]::FromHours($value) }
        default { return [timespan]::FromSeconds($value) }
    }
}

# Reads a KEY=VALUE .env file and returns an ordered hashtable. Blank lines and
# '#' comments are skipped; only the first '=' is treated as the separator.
function Import-EnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $vars = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        $sep = $trimmed.IndexOf('=')
        if ($sep -lt 1) { continue }
        $key = $trimmed.Substring(0, $sep).Trim()
        $val = $trimmed.Substring($sep + 1).Trim()
        $vars[$key] = $val
    }
    return $vars
}

# Polls the CAPI Cluster Ready condition, printing control-plane and machine-pool
# progress each interval. Returns when Ready=True; throws on timeout. This is the
# progress-aware equivalent of:
#   kubectl wait --for=condition=Ready cluster/<name> --timeout=<Timeout>
function Wait-ClusterReady {
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][timespan]$WaitTimeout
    )
    $deadline = (Get-Date).Add($WaitTimeout)
    $intervalSeconds = 30
    Write-Host ("    Waiting for cluster/{0} to become Available (timeout {1})..." -f $ClusterName, $Timeout) -ForegroundColor Cyan

    while ((Get-Date) -lt $deadline) {
        # Readiness condition status of the CAPI Cluster. CAPI v1.11+ (v1beta2)
        # renamed the top-level health condition from 'Ready' to 'Available'; older
        # CAPI (v1beta1) used 'Ready'. Query both and accept whichever reports True
        # so the wait works across management-cluster CAPI versions.
        $available = & kubectl get cluster $ClusterName `
            -o "jsonpath={.status.conditions[?(@.type=='Available')].status}" 2>$null
        $available_exit = $LASTEXITCODE
        $ready = & kubectl get cluster $ClusterName `
            -o "jsonpath={.status.conditions[?(@.type=='Ready')].status}" 2>$null
        if ($available_exit -ne 0) {
            Write-Host "    Cluster object not yet visible; retrying..." -ForegroundColor DarkYellow
        }
        else {
            $phase = & kubectl get cluster $ClusterName -o 'jsonpath={.status.phase}' 2>$null
            $mpReady = & kubectl get machinepool -l "cluster.x-k8s.io/cluster-name=$ClusterName" `
                -o "jsonpath={range .items[*]}{.metadata.name}={.status.phase} {end}" 2>$null
            $health = if ($available) { $available } else { $ready }
            Write-Host ("    [{0}] phase={1} available={2} machinepools=[{3}]" -f `
                (Get-Date -Format 'HH:mm:ss'), $phase, $health, ($mpReady ?? '')) -ForegroundColor Gray

            if ($available -eq 'True' -or $ready -eq 'True') {
                Write-Host ("    cluster/{0} is Available." -f $ClusterName) -ForegroundColor Green
                return
            }
        }
        Start-Sleep -Seconds $intervalSeconds
    }

    throw "Timed out after $Timeout waiting for cluster/$ClusterName to reach Available."
}

# Provisions a single workload cluster from one .env file. Returns the path of the
# written kubeconfig for the Phase 4 summary.
function Invoke-ClusterProvision {
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][timespan]$WaitTimeout
    )

    Write-Host ("==> Processing {0}" -f (Split-Path -Leaf $EnvFile)) -ForegroundColor White
    $vars = Import-EnvFile -Path $EnvFile

    if (-not $vars.Contains('CLUSTER_NAME') -or [string]::IsNullOrWhiteSpace($vars['CLUSTER_NAME'])) {
        throw "Input '$EnvFile' is missing required CLUSTER_NAME."
    }
    $clusterName = $vars['CLUSTER_NAME']

    # Export every input as a process env var so clusterctl substitutes ${VAR}.
    foreach ($key in $vars.Keys) {
        Set-Item -Path ("Env:{0}" -f $key) -Value $vars[$key]
    }

    $generatedFile = Join-Path $script:GeneratedDir ("{0}.yaml" -f $clusterName)
    $kubeconfigFile = Join-Path $script:KubeconfigDir ("{0}.kubeconfig" -f $clusterName)

    # 1. Render the template for this cluster's variables.
    # NOTE: clusterctl v1.13+ parses the --from argument as a URL first and a
    # Windows absolute path (e.g. C:\repo\...) is misread as a URL scheme
    # ("invalid GetFromURL operation ... Only reading from GitHub and local file
    # system is supported"). Pipe the template via stdin (--from -) to sidestep
    # cross-platform path/URL parsing entirely.
    Write-Host ("    Generating manifest -> {0}" -f $generatedFile) -ForegroundColor Cyan
    Get-Content -LiteralPath $script:TemplatePath -Raw | & clusterctl generate cluster $clusterName --from - > $generatedFile
    if ($LASTEXITCODE -ne 0) {
        throw "clusterctl generate cluster '$clusterName' failed with exit code $LASTEXITCODE."
    }

    # 2. Apply to the management cluster.
    Write-Host "    Applying manifest to management cluster..." -ForegroundColor Cyan
    & kubectl apply -f $generatedFile
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl apply for '$clusterName' failed with exit code $LASTEXITCODE."
    }

    # 3. Wait for Ready with progress polling.
    Wait-ClusterReady -ClusterName $clusterName -WaitTimeout $WaitTimeout

    # 4. Retrieve the workload kubeconfig.
    Write-Host ("    Retrieving kubeconfig -> {0}" -f $kubeconfigFile) -ForegroundColor Cyan
    & clusterctl get kubeconfig $clusterName > $kubeconfigFile
    if ($LASTEXITCODE -ne 0) {
        throw "clusterctl get kubeconfig '$clusterName' failed with exit code $LASTEXITCODE."
    }

    return $kubeconfigFile
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
$waitTimeout = ConvertTo-TimeSpanDuration -Duration $Timeout

$resolvedClustersDir = if ([System.IO.Path]::IsPathRooted($ClustersDir)) {
    $ClustersDir
}
else {
    Join-Path $script:RepoRoot $ClustersDir
}
if (-not (Test-Path -LiteralPath $resolvedClustersDir)) {
    throw "Clusters directory not found: $resolvedClustersDir"
}

$envFiles = Get-ChildItem -LiteralPath $resolvedClustersDir -Filter '*.env' -File | Sort-Object Name
if ($envFiles.Count -eq 0) {
    throw "No *.env input files found in $resolvedClustersDir."
}

# Working directories (gitignored). Created up front so a partial run still leaves
# the dirs in place for inspection.
New-Item -ItemType Directory -Force -Path $script:GeneratedDir | Out-Null
New-Item -ItemType Directory -Force -Path $script:KubeconfigDir | Out-Null

Write-Host ("Provisioning {0} workload cluster(s) from {1}" -f $envFiles.Count, $resolvedClustersDir) -ForegroundColor White

$kubeconfigPaths = New-Object System.Collections.Generic.List[string]
foreach ($envFile in $envFiles) {
    $path = Invoke-ClusterProvision -EnvFile $envFile.FullName -WaitTimeout $waitTimeout
    $kubeconfigPaths.Add($path)
}

# Summary for Phase 4 (ArgoCD cluster registration).
Write-Host ''
Write-Host '================ Provisioning Summary ================' -ForegroundColor White
Write-Host ("Workload clusters provisioned: {0}" -f $kubeconfigPaths.Count) -ForegroundColor Green
foreach ($path in $kubeconfigPaths) {
    Write-Host ("  kubeconfig: {0}" -f $path) -ForegroundColor Green
}
Write-Host 'Register these kubeconfigs as ArgoCD cluster Secrets in Phase 4.' -ForegroundColor White
