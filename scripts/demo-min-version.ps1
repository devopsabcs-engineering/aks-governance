<#
.SYNOPSIS
    Demonstrates the minimum-Kubernetes-version Kyverno policy (Example B).

.DESCRIPTION
    Applies an ASO-backed CAPZ workload-cluster control-plane CR whose spec.version
    (v1.27.0) is below the configured minimum (v1.28.0) to the MANAGEMENT cluster,
    and asserts the apply is REJECTED by the Kyverno ClusterPolicy
    `enforce-min-k8s-version` (gitops/policies/kyverno/enforce-min-k8s-version.yaml)
    with a denial message that names the minimum version.

    The deterministic CLI text is captured into the wiki evidence directory.

    The script issues a single mutating `kubectl apply` (expected to be denied, so no
    object is actually created). Run it against the management-cluster kubeconfig.

    Requires PowerShell 7+, kubectl, and a kubeconfig pointing at the management
    cluster that has the policy applied.

.PARAMETER CaptureDir
    Directory for the captured CLI text file. Default 'docs/captures'.

.PARAMETER SamplePath
    Path to the under-minimum sample manifest. Default 'samples/under-min-version.yaml'.

.PARAMETER MinVersion
    Minimum version string expected to appear in the denial message. Default 'v1.28.0'.
    Keep in sync with the policy's deny condition and message.

.EXAMPLE
    ./scripts/demo-min-version.ps1

.EXAMPLE
    ./scripts/demo-min-version.ps1 -CaptureDir docs/captures -MinVersion v1.28.0
#>
[CmdletBinding()]
param(
    [string]$CaptureDir = 'docs/captures',
    [string]$SamplePath = 'samples/under-min-version.yaml',
    [string]$MinVersion = 'v1.28.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runs kubectl with the given arguments, merging stderr into stdout, and returns the
# combined text plus the native exit code. A non-zero exit from an admission denial is
# returned (not thrown) so it can be asserted against the expected rejection.
function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $text = (& kubectl @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.TrimEnd() }
}

if (-not (Test-Path -LiteralPath $SamplePath)) {
    throw "Sample manifest not found: $SamplePath"
}
if (-not (Test-Path -LiteralPath $CaptureDir)) {
    New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null
}

Write-Host ("Applying under-minimum control-plane CR from '{0}' (expected REJECTED)..." -f $SamplePath) -ForegroundColor Cyan
$result = Invoke-Kubectl -Arguments @('apply', '-f', $SamplePath)

# A successful guardrail produces a non-zero exit, an "admission webhook ... denied"
# message, AND the configured minimum version in that message.
$denied = ($result.ExitCode -ne 0) -and `
    ($result.Text | Select-String -Pattern 'admission webhook' -Quiet) -and `
    ($result.Text | Select-String -Pattern 'denied' -Quiet)
$mentionsMin = [bool]($result.Text | Select-String -Pattern ([regex]::Escape($MinVersion)) -Quiet)
$pass = $denied -and $mentionsMin

$capturePath = Join-Path $CaptureDir 'demo-min-version.txt'
$header = @(
    "# Demo: minimum Kubernetes version guardrail"
    "# Sample: $SamplePath"
    "# Expected: REJECTED, message mentions $MinVersion"
    "# Observed denied: $denied"
    "# Observed mentions-min-version: $mentionsMin"
    "# kubectl exit code: $($result.ExitCode)"
    "# ---"
) -join [Environment]::NewLine
($header + [Environment]::NewLine + $result.Text) |
    Tee-Object -FilePath $capturePath | Out-Null

Write-Host ("Capture written: {0}" -f $capturePath)
Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
$denyColor = if ($denied) { 'Green' } else { 'Red' }
$minColor = if ($mentionsMin) { 'Green' } else { 'Red' }
Write-Host ("  admission denied: {0}" -f $denied) -ForegroundColor $denyColor
Write-Host ("  message mentions {0}: {1}" -f $MinVersion, $mentionsMin) -ForegroundColor $minColor

if (-not $pass) {
    Write-Host 'Result contradicted expectations (expected a denial naming the minimum version).' -ForegroundColor Red
    exit 1
}
Write-Host ("Under-minimum CR was correctly rejected with the minimum version ({0})." -f $MinVersion) -ForegroundColor Green
exit 0
