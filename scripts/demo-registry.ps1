<#
.SYNOPSIS
    Demonstrates the docker.io/quay.io registry-deny Kyverno policy (Example A).

.DESCRIPTION
    Exercises the `block-docker-quay-registries` ClusterPolicy
    (gitops/policies/kyverno/block-docker-quay-registries.yaml) by applying three
    Pods to the `governance-demo` namespace and capturing deterministic CLI text for
    each into the wiki evidence directory:

      1. docker.io/library/nginx        - expected DENIED  (disallowed registry)
      2. quay.io/prometheus/busybox     - expected DENIED  (disallowed registry)
      3. mcr.microsoft.com/.../busybox  - expected ADMITTED (allow-listed registry)

    When the policy is in Audit mode the docker.io/quay.io Pods are ADMITTED but a
    PolicyReport records the violation; when flipped to Enforce they are DENIED at
    admission. This script asserts the Enforce-mode expectations (deny/deny/admit).
    Run it after flipping the policy to Enforce for the deny capture, or pass
    -ExpectAudit to assert the Audit-mode behaviour (all three admitted) instead.

    The script makes mutating kubectl calls (namespace + Pods). It is a demo driver,
    not a read-only check. It cleans up the Pods it creates on exit.

    Requires PowerShell 7+, kubectl, and a kubeconfig pointing at a workload cluster
    that has the policy synced.

.PARAMETER CaptureDir
    Directory for the captured CLI text files. Default 'docs/captures'.

.PARAMETER Namespace
    Demo namespace. Default 'governance-demo'.

.PARAMETER ExpectAudit
    Assert Audit-mode behaviour (all three Pods admitted) instead of Enforce-mode
    (docker.io/quay.io denied, mcr admitted).

.EXAMPLE
    ./scripts/demo-registry.ps1

.EXAMPLE
    ./scripts/demo-registry.ps1 -CaptureDir docs/captures -ExpectAudit
#>
[CmdletBinding()]
param(
    [string]$CaptureDir = 'docs/captures',
    [string]$Namespace = 'governance-demo',
    [switch]$ExpectAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Accumulated case results drive the final summary and exit code.
$script:Cases = New-Object System.Collections.Generic.List[object]

# Runs kubectl with the given arguments, merging stderr into stdout, and returns the
# combined text plus the native exit code. Native non-zero exits (e.g. an admission
# denial) are returned, not thrown, so the caller can compare against expectations.
function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$StdinYaml)
    if ($PSBoundParameters.ContainsKey('StdinYaml') -and $StdinYaml) {
        $text = ($StdinYaml | & kubectl @Arguments 2>&1 | Out-String)
    }
    else {
        $text = (& kubectl @Arguments 2>&1 | Out-String)
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text.TrimEnd() }
}

# Strips noise that is unrelated to the governance control this demo exercises so the
# published wiki shows only the Kyverno admission result. Removes warnings emitted by the
# AKS Azure Policy add-on (ValidatingAdmissionPolicy / 'default-k8s-misconfiguration-policy-*'
# bindings) and Kubernetes API-deprecation warnings. Admission detection runs on the raw
# text (see Invoke-Case), so filtering here is purely cosmetic for the evidence file.
function Remove-CaptureNoise {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $kept = foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match 'Validation failed for ValidatingAdmissionPolicy') { continue }
        if ($line -match 'is deprecated; use ') { continue }
        $line
    }
    return (($kept -join [Environment]::NewLine)).Trim()
}

# Applies one Pod manifest, writes the captured CLI text to the capture dir, and
# records whether the observed admission result matched the expectation.
function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][ValidateSet('DENIED', 'ADMITTED')][string]$Expected
    )

    Write-Host ("--- Case: {0} (expected {1}) ---" -f $Name, $Expected) -ForegroundColor Cyan
    $result = Invoke-Kubectl -Arguments @('apply', '-n', $Namespace, '-f', '-') -StdinYaml $Manifest

    # An admission denial surfaces as a non-zero exit with "admission webhook" + "denied"
    # in the text; a clean apply exits zero with "created"/"configured"/"unchanged".
    $denied = ($result.ExitCode -ne 0) -and `
        ($result.Text | Select-String -Pattern 'admission webhook' -Quiet) -and `
        ($result.Text | Select-String -Pattern 'denied' -Quiet)
    $observed = if ($denied) { 'DENIED' } else { 'ADMITTED' }
    $match = ($observed -eq $Expected)

    $capturePath = Join-Path $CaptureDir ("demo-registry-{0}.txt" -f $Name)
    $cleanText = Remove-CaptureNoise -Text $result.Text
    $elided = ($result.Text | Select-String -Pattern 'Validation failed for ValidatingAdmissionPolicy' -Quiet)
    $headerLines = @(
        "# Case: $Name"
        "# Expected: $Expected"
        "# Observed: $observed"
        "# kubectl exit code: $($result.ExitCode)"
    )
    if ($elided) {
        $headerLines += '# Note: unrelated AKS Azure Policy add-on (ValidatingAdmissionPolicy) warnings elided for clarity.'
    }
    $headerLines += '# ---'
    $header = $headerLines -join [Environment]::NewLine
    ($header + [Environment]::NewLine + $cleanText) |
        Tee-Object -FilePath $capturePath | Out-Null

    $color = if ($match) { 'Green' } else { 'Red' }
    Write-Host ("    observed {0} (expected {1}) -> {2}" -f $observed, $Expected, ($match ? 'OK' : 'MISMATCH')) -ForegroundColor $color
    Write-Host ("    capture: {0}" -f $capturePath)

    $script:Cases.Add([pscustomobject]@{ Name = $Name; Expected = $Expected; Observed = $observed; Match = $match })
}

# --- Setup -----------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $CaptureDir)) {
    New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null
}

Write-Host ("Ensuring namespace '{0}' exists..." -f $Namespace) -ForegroundColor Cyan
$nsManifest = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
"@
$ns = Invoke-Kubectl -Arguments @('apply', '-f', '-') -StdinYaml $nsManifest
if ($ns.ExitCode -ne 0) {
    throw "Failed to ensure namespace '$Namespace':`n$($ns.Text)"
}

# In Audit mode the policy reports but does not block, so every Pod is admitted.
$dockerExpected = if ($ExpectAudit) { 'ADMITTED' } else { 'DENIED' }
$quayExpected = if ($ExpectAudit) { 'ADMITTED' } else { 'DENIED' }

# --- Cases -----------------------------------------------------------------------

$dockerPod = @"
apiVersion: v1
kind: Pod
metadata:
  name: demo-docker-nginx
  namespace: $Namespace
spec:
  containers:
    - name: nginx
      image: docker.io/library/nginx:1.27
"@
Invoke-Case -Name 'docker-io' -Manifest $dockerPod -Expected $dockerExpected

$quayPod = @"
apiVersion: v1
kind: Pod
metadata:
  name: demo-quay-busybox
  namespace: $Namespace
spec:
  containers:
    - name: busybox
      image: quay.io/quay/busybox:latest
      command: ['sleep', '3600']
"@
Invoke-Case -Name 'quay-io' -Manifest $quayPod -Expected $quayExpected

$mcrPod = @"
apiVersion: v1
kind: Pod
metadata:
  name: demo-mcr-busybox
  namespace: $Namespace
spec:
  containers:
    - name: busybox
      image: mcr.microsoft.com/cbl-mariner/busybox:2.0
      command: ['sleep', '3600']
"@
Invoke-Case -Name 'mcr-microsoft-com' -Manifest $mcrPod -Expected 'ADMITTED'

# --- Cleanup ---------------------------------------------------------------------

Write-Host 'Cleaning up demo Pods...' -ForegroundColor Cyan
Invoke-Kubectl -Arguments @(
    'delete', 'pod', '-n', $Namespace,
    'demo-docker-nginx', 'demo-quay-busybox', 'demo-mcr-busybox',
    '--ignore-not-found', '--wait=false'
) | Out-Null

# --- Summary + exit code ---------------------------------------------------------

Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
foreach ($c in $script:Cases) {
    $color = if ($c.Match) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: expected {2}, observed {3}" -f ($c.Match ? 'OK' : 'XX'), $c.Name, $c.Expected, $c.Observed) -ForegroundColor $color
}

$mismatches = @($script:Cases | Where-Object { -not $_.Match })
if ($mismatches.Count -gt 0) {
    Write-Host ("{0} case(s) contradicted expectations." -f $mismatches.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All registry cases matched expectations.' -ForegroundColor Green
exit 0
