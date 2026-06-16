<#
.SYNOPSIS
    Demonstrates the docker.io/quay.io registry Kyverno policy (Example A) as a real
    two-phase Audit -> Enforce flow.

.DESCRIPTION
    Exercises the `block-docker-quay-registries` ClusterPolicy
    (gitops/policies/kyverno/block-docker-quay-registries.yaml) against a workload
    cluster and captures deterministic CLI text into the wiki evidence directory.

    The policy ships from git in `Enforce` mode (the final, desired governance state).
    This driver demonstrates BOTH phases of a typical rollout in a single run:

      Phase 1 - Audit (report, not block):
        * Patches the live ClusterPolicy to `validationFailureAction: Audit`.
          (The governance-policies ApplicationSet runs with selfHeal=false, so ArgoCD
          does not revert this live edit; git still defines Enforce as the end state.)
        * Applies the docker.io/quay.io Pods - under Audit they are ADMITTED.
        * Waits for Kyverno's reports controller to emit a PolicyReport recording the
          violations, then captures it (`demo-registry-audit-*.txt`). This is the
          report a team would review before enforcing.

      Phase 2 - Enforce (block):
        * Patches the live ClusterPolicy back to `validationFailureAction: Enforce`
          (matching git), deletes the Audit-phase Pods, and re-applies them.
        * docker.io/quay.io are now DENIED at admission; an allow-listed
          mcr.microsoft.com image is ADMITTED. Captures each result
          (`demo-registry-docker-io.txt`, `-quay-io.txt`, `-mcr-microsoft-com.txt`).

    The script makes mutating kubectl calls (namespace, Pods, and a policy patch). It
    is a demo driver, not a read-only check. It cleans up the Pods it creates and
    leaves the policy in Enforce mode (its git/desired state) on exit.

    Requires PowerShell 7+, kubectl, and a kubeconfig pointing at a workload cluster
    that has the policy synced.

.PARAMETER CaptureDir
    Directory for the captured CLI text files. Default 'docs/captures'.

.PARAMETER Namespace
    Demo namespace. Default 'governance-demo'.

.PARAMETER PolicyName
    The ClusterPolicy to toggle Audit/Enforce. Default 'block-docker-quay-registries'.

.PARAMETER ReportTimeoutSec
    Seconds to wait for the Audit-phase PolicyReport to record both violations.
    Default 180.

.EXAMPLE
    ./scripts/demo-registry.ps1

.EXAMPLE
    ./scripts/demo-registry.ps1 -CaptureDir docs/captures
#>
[CmdletBinding()]
param(
    [string]$CaptureDir = 'docs/captures',
    [string]$Namespace = 'governance-demo',
    [string]$PolicyName = 'block-docker-quay-registries',
    [int]$ReportTimeoutSec = 180
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
# text (see Test-Denied), so filtering here is purely cosmetic for the evidence file.
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

# True when the kubectl apply output is a Kyverno admission denial.
function Test-Denied {
    param([Parameter(Mandatory)][object]$Result)
    return ($Result.ExitCode -ne 0) -and `
        ($Result.Text | Select-String -Pattern 'admission webhook' -Quiet) -and `
        ($Result.Text | Select-String -Pattern 'denied' -Quiet)
}

# Writes a capture file with the standard demo header and de-noised body.
function Write-Capture {
    param(
        [Parameter(Mandatory)][string]$FileBaseName,
        [Parameter(Mandatory)][string[]]$HeaderLines,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    $capturePath = Join-Path $CaptureDir ("{0}.txt" -f $FileBaseName)
    $header = ($HeaderLines + '# ---') -join [Environment]::NewLine
    ($header + [Environment]::NewLine + $Body) | Tee-Object -FilePath $capturePath | Out-Null
    Write-Host ("    capture: {0}" -f $capturePath)
    return $capturePath
}

# Applies one Pod manifest, records whether the observed admission result matched the
# expectation, writes the capture, and tracks the case for the final exit code.
function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][ValidateSet('DENIED', 'ADMITTED')][string]$Expected,
        [Parameter(Mandatory)][ValidateSet('Audit', 'Enforce')][string]$Phase
    )

    Write-Host ("--- Case: {0} | phase {1} (expected {2}) ---" -f $Name, $Phase, $Expected) -ForegroundColor Cyan
    $result = Invoke-Kubectl -Arguments @('apply', '-n', $Namespace, '-f', '-') -StdinYaml $Manifest

    $observed = if (Test-Denied -Result $result) { 'DENIED' } else { 'ADMITTED' }
    $match = ($observed -eq $Expected)

    $cleanText = Remove-CaptureNoise -Text $result.Text
    $elided = ($result.Text | Select-String -Pattern 'Validation failed for ValidatingAdmissionPolicy' -Quiet)
    $header = @(
        "# Case: $Name"
        "# Phase: $Phase ($(if ($Phase -eq 'Audit') { 'report, not block' } else { 'block at admission' }))"
        "# Expected: $Expected"
        "# Observed: $observed"
        "# kubectl exit code: $($result.ExitCode)"
    )
    if ($elided) {
        $header += '# Note: unrelated AKS Azure Policy add-on (ValidatingAdmissionPolicy) warnings elided for clarity.'
    }
    Write-Capture -FileBaseName ("demo-registry-{0}" -f $Name) -HeaderLines $header -Body $cleanText | Out-Null

    $color = if ($match) { 'Green' } else { 'Red' }
    Write-Host ("    observed {0} (expected {1}) -> {2}" -f $observed, $Expected, ($match ? 'OK' : 'MISMATCH')) -ForegroundColor $color

    $script:Cases.Add([pscustomobject]@{ Name = $Name; Phase = $Phase; Expected = $Expected; Observed = $observed; Match = $match })
    return $result
}

# Reads the live policy-level validationFailureAction.
function Get-LivePolicyMode {
    $r = Invoke-Kubectl -Arguments @('get', 'clusterpolicy', $PolicyName, '-o', 'jsonpath={.spec.validationFailureAction}')
    return $r.Text.Trim()
}

# Patches the live ClusterPolicy to the requested mode and confirms the API reflects it.
# selfHeal is disabled on the governance-policies ApplicationSet, so ArgoCD will not
# revert this live edit; git remains the source of truth for the end-state (Enforce).
function Set-PolicyMode {
    param([Parameter(Mandatory)][ValidateSet('Audit', 'Enforce')][string]$Mode)
    Write-Host ("Setting ClusterPolicy '{0}' -> validationFailureAction: {1}" -f $PolicyName, $Mode) -ForegroundColor Cyan
    $patch = '{"spec":{"validationFailureAction":"' + $Mode + '"}}'
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Invoke-Kubectl -Arguments @('patch', 'clusterpolicy', $PolicyName, '--type', 'merge', '-p', $patch) | Out-Null
        Start-Sleep -Seconds 2
        $live = Get-LivePolicyMode
        if ($live -eq $Mode) {
            Write-Host ("    live validationFailureAction is now '{0}'" -f $live) -ForegroundColor Green
            return
        }
        Write-Host ("    attempt {0}: live is '{1}', retrying..." -f $attempt, $live) -ForegroundColor Yellow
    }
    throw "Failed to set ClusterPolicy '$PolicyName' to '$Mode' (live still '$(Get-LivePolicyMode)')."
}

# Polls the workload-cluster PolicyReports until the named policy records a `fail`
# result for each expected Pod (or the timeout elapses). Returns the parsed fail
# results so the caller can render a deterministic capture.
function Wait-ForPolicyReportFail {
    param(
        [Parameter(Mandatory)][string[]]$ExpectedResourceNames,
        [int]$TimeoutSec = 180
    )
    Write-Host ("Waiting up to {0}s for Audit-phase PolicyReport fails on: {1}" -f $TimeoutSec, ($ExpectedResourceNames -join ', ')) -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $json = Invoke-Kubectl -Arguments @('get', 'policyreport', '-n', $Namespace, '-o', 'json')
        $fails = @()
        if ($json.ExitCode -eq 0 -and $json.Text) {
            try { $parsed = $json.Text | ConvertFrom-Json } catch { $parsed = $null }
            if ($parsed -and $parsed.PSObject.Properties.Name -contains 'items') {
                foreach ($report in $parsed.items) {
                    if (-not ($report.PSObject.Properties.Name -contains 'results')) { continue }
                    foreach ($res in $report.results) {
                        if ($res.result -ne 'fail') { continue }
                        if ($res.policy -ne $PolicyName) { continue }
                        $rule = if ($res.PSObject.Properties.Name -contains 'rule') { $res.rule } else { '' }
                        foreach ($r in @($res.resources)) {
                            $fails += [pscustomobject]@{
                                Policy = $res.policy
                                Rule   = $rule
                                Kind   = $r.kind
                                Name   = $r.name
                            }
                        }
                    }
                }
            }
        }
        $found = @($fails | Select-Object -ExpandProperty Name -Unique)
        $missing = @($ExpectedResourceNames | Where-Object { $found -notcontains $_ })
        if ($missing.Count -eq 0 -and $fails.Count -gt 0) {
            Write-Host ("    PolicyReport recorded {0} fail result(s) for the violating Pods." -f $fails.Count) -ForegroundColor Green
            return $fails
        }
        if ((Get-Date) -ge $deadline) {
            Write-Host ("    timed out; missing fail results for: {0}" -f ($missing -join ', ')) -ForegroundColor Yellow
            return $fails
        }
        Start-Sleep -Seconds 10
    }
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

# Pod manifests (defined once; reused across both phases).
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

$allPods = @('demo-docker-nginx', 'demo-quay-busybox', 'demo-mcr-busybox')

function Remove-DemoPods {
    Invoke-Kubectl -Arguments (@('delete', 'pod', '-n', $Namespace) + $allPods + @('--ignore-not-found', '--wait=false')) | Out-Null
}

try {
    # ============================================================================
    # Phase 1 - Audit: report violations without blocking, then capture the report.
    # ============================================================================
    Write-Host ''
    Write-Host '=== Phase 1: Audit (report, not block) ===' -ForegroundColor Magenta
    Set-PolicyMode -Mode 'Audit'

    # Start from a clean slate so the report reflects freshly-admitted Pods.
    Remove-DemoPods

    Invoke-Case -Name 'audit-docker-io' -Manifest $dockerPod -Expected 'ADMITTED' -Phase 'Audit' | Out-Null
    Invoke-Case -Name 'audit-quay-io'   -Manifest $quayPod   -Expected 'ADMITTED' -Phase 'Audit' | Out-Null

    $fails = Wait-ForPolicyReportFail -ExpectedResourceNames @('demo-docker-nginx', 'demo-quay-busybox') -TimeoutSec $ReportTimeoutSec

    $reportText = (Invoke-Kubectl -Arguments @('get', 'policyreport', '-n', $Namespace, '-o', 'wide')).Text
    $failLines = foreach ($f in ($fails | Sort-Object Name -Unique)) {
        ("# FAIL  {0}/{1}  ->  {2}/{3}" -f $f.Policy, $f.Rule, $f.Kind, $f.Name)
    }
    $reportBody = (@(
            $reportText
            '#'
            '# --- Violations reported (result=fail) ---'
        ) + @($failLines)) -join [Environment]::NewLine
    $reportHeader = @(
        '# Example A - Audit-phase PolicyReport (report, not block)'
        "# Namespace: $Namespace"
        "# Policy: $PolicyName (validationFailureAction: Audit)"
        "# Source: kubectl get policyreport -n $Namespace -o wide"
    )
    Write-Capture -FileBaseName 'demo-registry-audit-policyreport' -HeaderLines $reportHeader -Body $reportBody | Out-Null

    # The report must actually contain the two violations for the phase to be meaningful.
    $reportedNames = @($fails | Select-Object -ExpandProperty Name -Unique)
    $reportOk = ($reportedNames -contains 'demo-docker-nginx') -and ($reportedNames -contains 'demo-quay-busybox')
    $script:Cases.Add([pscustomobject]@{
            Name     = 'audit-policyreport'; Phase = 'Audit'
            Expected = 'docker+quay fail reported'
            Observed = if ($reportOk) { 'both reported' } else { "only: $($reportedNames -join ',')" }
            Match    = $reportOk
        })

    # ============================================================================
    # Phase 2 - Enforce: block violations at admission (the git/desired end state).
    # ============================================================================
    Write-Host ''
    Write-Host '=== Phase 2: Enforce (block at admission) ===' -ForegroundColor Magenta
    Set-PolicyMode -Mode 'Enforce'

    # Remove the Audit-phase Pods so the re-apply is evaluated fresh under Enforce.
    Remove-DemoPods
    Start-Sleep -Seconds 3

    Invoke-Case -Name 'docker-io'         -Manifest $dockerPod -Expected 'DENIED'   -Phase 'Enforce' | Out-Null
    Invoke-Case -Name 'quay-io'           -Manifest $quayPod   -Expected 'DENIED'   -Phase 'Enforce' | Out-Null
    Invoke-Case -Name 'mcr-microsoft-com' -Manifest $mcrPod    -Expected 'ADMITTED' -Phase 'Enforce' | Out-Null
}
finally {
    # --- Cleanup -----------------------------------------------------------------
    Write-Host ''
    Write-Host 'Cleaning up demo Pods and restoring Enforce mode...' -ForegroundColor Cyan
    Remove-DemoPods
    # Leave the policy in its git/desired state regardless of where a failure occurred.
    try { Set-PolicyMode -Mode 'Enforce' } catch { Write-Host "    (could not restore Enforce: $_)" -ForegroundColor Yellow }
}

# --- Summary + exit code ---------------------------------------------------------

Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
foreach ($c in $script:Cases) {
    $color = if ($c.Match) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1} ({2}): expected {3}, observed {4}" -f ($c.Match ? 'OK' : 'XX'), $c.Name, $c.Phase, $c.Expected, $c.Observed) -ForegroundColor $color
}

$mismatches = @($script:Cases | Where-Object { -not $_.Match })
if ($mismatches.Count -gt 0) {
    Write-Host ("{0} case(s) contradicted expectations." -f $mismatches.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'All registry cases matched expectations (Audit reported, Enforce blocked).' -ForegroundColor Green
exit 0
