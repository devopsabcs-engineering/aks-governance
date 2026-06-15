#requires -Version 7.0
<#
.SYNOPSIS
    Verify a wiki publish target is reachable and the PAT has the right scope
    BEFORE 'publish-wiki.ps1' attempts any clone/push.

.DESCRIPTION
    Runs a read-only diagnostic probe (no clone, no push, no mutation): an HTTP GET
    against the wiki Git repository's smart-HTTP advertisement endpoint
    '<repo>/info/refs?service=git-upload-pack' with an HTTP Basic Authorization
    header built from the PAT.

    Interpretation (per user memory azure-devops-wiki-auth.md):
      * HTTP 200 or 203 -> auth OK and the wiki target exists (203 is normal for
        Azure DevOps smart-HTTP via the gateway).
      * HTTP 401 / 403  -> the PAT is missing the required scope. Azure DevOps
        project wikis are Git repositories and require Code (Read and Write);
        the Wiki scope alone is insufficient. GitHub needs Contents (or repo).
      * HTTP 404        -> the wiki does not exist / is not provisioned. Create
        the GitHub wiki (add the first page in the UI) or enable the ADO project
        wiki, then re-run.

    The probe sends two Basic-auth variants so it works on both backends:
      1. empty username + PAT as password (':PAT')          - accepted by ADO,
      2. PAT as username + 'x-oauth-basic' as password       - GitHub fallback.

    Exit code 0 = target reachable and PAT usable; non-zero = blocked.

.PARAMETER Target
    Wiki backend: 'ado' (Azure DevOps project wiki) or 'github'.

.PARAMETER WikiRepoUrl
    HTTPS clone URL of the wiki Git repository (without embedded credentials).
    Azure DevOps: https://<host>/<org>/<project>/_git/<project>.wiki
    GitHub:       https://github.com/<owner>/<repo>.wiki.git

.PARAMETER Pat
    Personal access token. Defaults to the WIKI_PAT environment variable.

.EXAMPLE
    ./scripts/publish-wiki-preflight.ps1 -Target github `
        -WikiRepoUrl 'https://github.com/devopsabcs-engineering/aks-governance.wiki.git'

.EXAMPLE
    $env:WIKI_PAT = '<token>'
    ./scripts/publish-wiki-preflight.ps1 -Target ado `
        -WikiRepoUrl 'https://dev.azure.com/contoso/AKS%20Governance/_git/AKS%20Governance.wiki'

.NOTES
    Read-only. Follows user memory azure-devops-wiki-auth.md (info/refs probe,
    Basic ':PAT', Code R/W scope) and powershell-pitfalls.md (StrictMode,
    Select-String not grep, literal '&').
#>
[CmdletBinding()]
param(
    [ValidateSet('ado', 'github')]
    [string]$Target = 'github',

    [string]$WikiRepoUrl,

    [string]$Pat = $env:WIKI_PAT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Result {
    param([string]$Level, [string]$Message)
    switch ($Level) {
        'ok'   { Write-Host "  [OK]   $Message" }
        'warn' { Write-Warning $Message }
        default { Write-Host "  [FAIL] $Message" }
    }
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($WikiRepoUrl)) {
    Write-Result -Level 'fail' -Message 'WikiRepoUrl is required (HTTPS clone URL of the wiki Git repository).'
    exit 2
}
if ([string]::IsNullOrWhiteSpace($Pat)) {
    Write-Result -Level 'fail' -Message 'A PAT is required. Pass -Pat or set the WIKI_PAT environment variable. ADO wikis require Code (Read and Write) scope.'
    exit 2
}
if ($WikiRepoUrl -notmatch '^https://') {
    Write-Result -Level 'fail' -Message "WikiRepoUrl must be an HTTPS URL: $WikiRepoUrl"
    exit 2
}

# Build the smart-HTTP advertisement URL (read-only). URL-encode spaces.
$encodedUrl = $WikiRepoUrl -replace ' ', '%20'
$probeUrl = "$($encodedUrl.TrimEnd('/'))/info/refs?service=git-upload-pack"

# Two Basic-auth header variants (ADO accepts ':PAT'; GitHub fallback is
# 'PAT:x-oauth-basic'). Order favors the target's typical form.
$credPairs = if ($Target -eq 'github') {
    @("${Pat}:x-oauth-basic", ":${Pat}")
}
else {
    @(":${Pat}", "${Pat}:x-oauth-basic")
}

Write-Host "Preflight: probing $Target wiki target ..."
Write-Host "  URL: $probeUrl"

$okStatuses = @(200, 203)
$lastStatus = $null
$lastError = $null
$succeeded = $false

foreach ($pair in $credPairs) {
    $basic = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    try {
        $resp = Invoke-WebRequest -Uri $probeUrl -Method Get -MaximumRedirection 0 `
            -Headers @{ Authorization = "Basic $basic"; 'User-Agent' = 'aksgov-wiki-preflight' } `
            -SkipHttpErrorCheck -TimeoutSec 30
        $lastStatus = [int]$resp.StatusCode
    }
    catch {
        # -SkipHttpErrorCheck suppresses HTTP error throws; this catch handles
        # transport-level failures (DNS, TLS, connection refused).
        $lastError = $_.Exception.Message
        continue
    }

    if ($okStatuses -contains $lastStatus) {
        $succeeded = $true
        break
    }
    # 401/403 -> try the next credential variant before declaring a scope failure.
}

# ---------------------------------------------------------------------------
# Report + exit
# ---------------------------------------------------------------------------

if ($succeeded) {
    Write-Result -Level 'ok' -Message "Wiki target reachable and PAT accepted (HTTP $lastStatus)."
    exit 0
}

if ($null -ne $lastError -and $null -eq $lastStatus) {
    Write-Result -Level 'fail' -Message "Could not reach the wiki endpoint: $lastError"
    Write-Host '  Check the WikiRepoUrl host/path and network connectivity.'
    exit 1
}

switch ($lastStatus) {
    { $_ -in 401, 403 } {
        Write-Result -Level 'fail' -Message "PAT rejected (HTTP $lastStatus) - insufficient scope."
        if ($Target -eq 'ado') {
            Write-Host '  Azure DevOps project wikis are Git repos: the PAT needs Code (Read and Write). Wiki scope alone is not enough.'
        }
        else {
            Write-Host '  GitHub: the token needs Contents: Read and write (fine-grained) or the classic "repo" scope (covers the wiki).'
        }
        exit 1
    }
    404 {
        Write-Result -Level 'fail' -Message 'Wiki target not found (HTTP 404) - the wiki is not provisioned.'
        if ($Target -eq 'ado') {
            Write-Host '  Enable the Azure DevOps project wiki (Overview > Wiki > Create), then re-run.'
        }
        else {
            Write-Host '  Initialize the GitHub wiki by creating its first page in the repo UI, then re-run.'
        }
        exit 1
    }
    default {
        $shown = if ($null -ne $lastStatus) { "HTTP $lastStatus" } else { 'no HTTP response' }
        Write-Result -Level 'fail' -Message "Unexpected probe result ($shown)."
        exit 1
    }
}
