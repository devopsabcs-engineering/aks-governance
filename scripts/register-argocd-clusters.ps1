<#
.SYNOPSIS
    Registers CAPZ-provisioned workload clusters into ArgoCD as labeled cluster Secrets.

.DESCRIPTION
    Converts each workload kubeconfig produced by Phase 3
    (scripts/provision-clusters.ps1 writes <name>.kubeconfig into the kubeconfig dir) into
    an ArgoCD "cluster" Secret in the argocd namespace, carrying the labels the governance
    ApplicationSet selects on:

        argocd.argoproj.io/secret-type = cluster
        type                           = workload

    Two registration paths are supported (DR-03 — this conversion is the policy-fan-out
    linchpin and must work end-to-end):

      A. argocd CLI (preferred when present): 'argocd cluster add <context>' installs the
         argocd-manager ServiceAccount + ClusterRole on the target and stores the cluster
         Secret for you. We pass '--label type=workload' so the ApplicationSet selector
         matches. Requires an authenticated 'argocd login' session.

      B. Secret-construction fallback (no CLI required, IMPLEMENTED as the default-safe
         path): the kubeconfig is read via 'kubectl config view --raw -o json', and a
         cluster Secret is built directly with the server URL, CA data, and either a
         bearerToken or a client-cert tlsClientConfig. This is the path that works in a
         bare pipeline runner without the argocd binary.

    After registration the script FAILS FAST if fewer than two workload cluster Secrets are
    present, so policy fan-out never runs against an under-registered fleet.

    This script performs mutating kubectl/argocd calls (creating Secrets). It is idempotent:
    re-running re-applies the same Secrets.

    Requires PowerShell 7+, kubectl, and a current kube-context pointing at the MANAGEMENT
    cluster (where ArgoCD runs). The argocd CLI is optional.

.PARAMETER KubeconfigDir
    Directory containing the workload kubeconfig files (*.kubeconfig). Default 'kubeconfigs'.

.PARAMETER ArgoNamespace
    Namespace where ArgoCD (and the cluster Secrets) live. Default 'argocd'.

.EXAMPLE
    ./scripts/register-argocd-clusters.ps1

.EXAMPLE
    ./scripts/register-argocd-clusters.ps1 -KubeconfigDir kubeconfigs -ArgoNamespace argocd
#>
[CmdletBinding()]
param(
    [string]$KubeconfigDir = 'kubeconfigs',
    [string]$ArgoNamespace = 'argocd'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# DNS-1123-safe Secret/cluster name from an arbitrary kubeconfig-derived string.
function ConvertTo-DnsName {
    param([Parameter(Mandatory)][string]$Value)
    $name = $Value.ToLowerInvariant()
    $name = ($name -replace '[^a-z0-9-]', '-')
    $name = ($name -replace '-+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'workload-cluster' }
    if ($name.Length -gt 253) { $name = $name.Substring(0, 253).Trim('-') }
    return $name
}

# Runs a native command and throws (with the full command line) on a non-zero exit so a
# broken registration step never silently passes.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StdIn
    )
    if ($PSBoundParameters.ContainsKey('StdIn')) {
        $out = $StdIn | & $File @Arguments 2>&1
    }
    else {
        $out = & $File @Arguments 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$File $($Arguments -join ' ')' exited with code $LASTEXITCODE.`n$out"
    }
    return $out
}

Write-Host "==> Registering workload clusters into ArgoCD ('$ArgoNamespace' namespace)" -ForegroundColor Cyan

# --- Preconditions -----------------------------------------------------------------------
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl was not found on PATH. Install kubectl and point the current context at the management cluster."
}

$resolvedDir = Resolve-Path -Path $KubeconfigDir -ErrorAction SilentlyContinue
if (-not $resolvedDir) {
    throw "Kubeconfig directory '$KubeconfigDir' does not exist. Run Phase 3 (scripts/provision-clusters.ps1) first."
}

$kubeconfigs = @(Get-ChildItem -Path $resolvedDir -Filter '*.kubeconfig' -File -ErrorAction Stop)
if ($kubeconfigs.Count -eq 0) {
    throw "No '*.kubeconfig' files found in '$resolvedDir'. Phase 3 must produce one kubeconfig per workload cluster."
}
Write-Host "    Found $($kubeconfigs.Count) workload kubeconfig file(s)." -ForegroundColor Gray

# Is the argocd CLI available? (Path A vs Path B selection.)
$argocdAvailable = [bool](Get-Command argocd -ErrorAction SilentlyContinue)
if ($argocdAvailable) {
    Write-Host "    argocd CLI detected — preferring 'argocd cluster add' (Path A)." -ForegroundColor Gray
}
else {
    Write-Host "    argocd CLI not found — using Secret-construction fallback (Path B)." -ForegroundColor Gray
}

# --- Register each workload cluster ------------------------------------------------------
foreach ($kc in $kubeconfigs) {
    $clusterName = ConvertTo-DnsName -Value ([System.IO.Path]::GetFileNameWithoutExtension($kc.Name))
    Write-Host "==> Processing '$($kc.Name)' -> cluster '$clusterName'" -ForegroundColor Cyan

    # Read the kubeconfig as JSON via kubectl so we don't need a YAML parser module.
    $rawJson = Invoke-Native -File 'kubectl' -Arguments @('--kubeconfig', $kc.FullName, 'config', 'view', '--raw', '-o', 'json')
    $cfg = ($rawJson -join "`n") | ConvertFrom-Json

    $currentContext = $cfg.'current-context'
    if ([string]::IsNullOrWhiteSpace($currentContext)) {
        throw "Kubeconfig '$($kc.Name)' has no current-context; cannot determine which cluster/user to register."
    }

    if ($argocdAvailable) {
        # --- Path A: argocd CLI ----------------------------------------------------------
        # 'argocd cluster add' installs the argocd-manager SA/ClusterRole on the target and
        # stores the cluster Secret. --label adds the selector label used by the
        # ApplicationSet cluster generator; --name overrides the stored display name.
        Write-Host "    [Path A] argocd cluster add '$currentContext'" -ForegroundColor Gray
        Invoke-Native -File 'argocd' -Arguments @(
            'cluster', 'add', $currentContext,
            '--kubeconfig', $kc.FullName,
            '--name', $clusterName,
            '--label', 'type=workload',
            '--upsert',
            '--yes'
        ) | Out-Null
        Write-Host "    [Path A] Registered '$clusterName'." -ForegroundColor Green
        continue
    }

    # --- Path B: construct the cluster Secret directly from the kubeconfig ----------------
    $context = $cfg.contexts | Where-Object { $_.name -eq $currentContext } | Select-Object -First 1
    if (-not $context) { throw "Context '$currentContext' not found in '$($kc.Name)'." }

    $clusterEntry = $cfg.clusters | Where-Object { $_.name -eq $context.context.cluster } | Select-Object -First 1
    if (-not $clusterEntry) { throw "Cluster '$($context.context.cluster)' not found in '$($kc.Name)'." }

    $userEntry = $cfg.users | Where-Object { $_.name -eq $context.context.user } | Select-Object -First 1
    if (-not $userEntry) { throw "User '$($context.context.user)' not found in '$($kc.Name)'." }

    $server = $clusterEntry.cluster.server
    if ([string]::IsNullOrWhiteSpace($server)) { throw "No server URL for cluster in '$($kc.Name)'." }

    # tlsClientConfig: caData when present; insecure=true only if the kubeconfig itself is.
    $tls = [ordered]@{}
    $caData = $null
    if ($clusterEntry.cluster.PSObject.Properties.Name -contains 'certificate-authority-data') {
        $caData = $clusterEntry.cluster.'certificate-authority-data'
    }
    if ($caData) {
        $tls['caData'] = $caData
        $tls['insecure'] = $false
    }
    else {
        $insecure = $false
        if ($clusterEntry.cluster.PSObject.Properties.Name -contains 'insecure-skip-tls-verify') {
            $insecure = [bool]$clusterEntry.cluster.'insecure-skip-tls-verify'
        }
        $tls['insecure'] = $insecure
    }

    # Auth: prefer a bearer token; otherwise fall back to client cert/key (CAPZ aks-aso
    # admin kubeconfigs are typically client-cert based).
    $config = [ordered]@{}
    $userProps = $userEntry.user.PSObject.Properties.Name
    if ($userProps -contains 'token' -and -not [string]::IsNullOrWhiteSpace($userEntry.user.token)) {
        $config['bearerToken'] = $userEntry.user.token
    }
    elseif (($userProps -contains 'client-certificate-data') -and ($userProps -contains 'client-key-data')) {
        $tls['certData'] = $userEntry.user.'client-certificate-data'
        $tls['keyData'] = $userEntry.user.'client-key-data'
    }
    else {
        throw "Kubeconfig '$($kc.Name)' user '$($context.context.user)' has neither a bearer token nor client-certificate-data/client-key-data. Provide a token-based or cert-based kubeconfig (exec/AAD auth is out of scope for this PoC fallback)."
    }
    $config['tlsClientConfig'] = $tls
    $configJson = $config | ConvertTo-Json -Depth 6 -Compress

    # Build the cluster Secret as YAML and apply it. stringData keeps values human-readable
    # in git diffs / kubectl describe; Kubernetes base64-encodes them on write.
    $secretName = $clusterName
    $secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $secretName
  namespace: $ArgoNamespace
  labels:
    argocd.argoproj.io/secret-type: cluster
    type: workload
    environment: poc
type: Opaque
stringData:
  name: $clusterName
  server: $server
  config: |
$(($configJson -split "`n" | ForEach-Object { '    ' + $_ }) -join "`n")
"@

    Write-Host "    [Path B] Applying cluster Secret '$secretName' (server $server)" -ForegroundColor Gray
    Invoke-Native -File 'kubectl' -Arguments @('apply', '-n', $ArgoNamespace, '-f', '-') -StdIn $secretYaml | Out-Null
    Write-Host "    [Path B] Registered '$clusterName'." -ForegroundColor Green
}

# --- Fail fast: at least two workload cluster Secrets must exist --------------------------
Write-Host "==> Verifying registered workload cluster Secrets" -ForegroundColor Cyan
$listJson = Invoke-Native -File 'kubectl' -Arguments @(
    'get', 'secret', '-n', $ArgoNamespace,
    '-l', 'argocd.argoproj.io/secret-type=cluster,type=workload',
    '-o', 'json'
)
$list = ($listJson -join "`n") | ConvertFrom-Json
$registered = @($list.items)
$count = $registered.Count

foreach ($s in $registered) {
    Write-Host "    - $($s.metadata.name)" -ForegroundColor Gray
}

if ($count -lt 2) {
    throw "Expected at least 2 workload cluster Secrets labeled 'argocd.argoproj.io/secret-type=cluster,type=workload' in namespace '$ArgoNamespace', found $count. Policy fan-out cannot proceed."
}

Write-Host "==> $count workload cluster Secret(s) registered. ArgoCD policy fan-out is ready." -ForegroundColor Green
