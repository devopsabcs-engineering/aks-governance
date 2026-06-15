#Requires -Version 7.0
<#
.SYNOPSIS
    Generates the AKS governance PoC demo walkthrough markdown and publishes it to an
    Azure DevOps project wiki or a GitHub wiki Git repository.

.DESCRIPTION
    Interleaves captured CLI text blocks (from -CaptureDir) with screenshots
    (from -ImageDir) into a single 'AKS-Governance-Demo.md' page, clones the target
    wiki Git repository, copies the referenced images into the wiki's attachment
    folder ('.attachments/' for Azure DevOps, 'images/' for GitHub), writes the
    markdown, then commits and pushes the change.

    Authentication uses the PAT-in-URL form with no username and no colon
    (https://PAT@host/...), which is accepted by both Azure DevOps and GitHub on
    every OS. Azure DevOps project wikis are Git repositories and therefore require
    a PAT with the Code (Read and Write) scope; the Wiki scope alone is insufficient.

    This script performs a live 'git push'. It is intended to be run by an operator
    or pipeline that already holds a valid PAT. Pass -Preflight to verify the wiki
    target is reachable and the PAT has Code (Read and Write) scope BEFORE publishing.

.PARAMETER Target
    Wiki backend to publish to: 'ado' (Azure DevOps project wiki) or 'github'.

.PARAMETER WikiRepoUrl
    HTTPS clone URL of the wiki Git repository (without embedded credentials).
    Azure DevOps: https://<host>/<org>/<project>/_git/<project>.wiki
    GitHub:       https://github.com/<owner>/<repo>.wiki.git

.PARAMETER Pat
    Personal access token. Defaults to the WIKI_PAT environment variable.

.PARAMETER CaptureDir
    Directory containing captured CLI text blocks (.txt/.md/.log).

.PARAMETER ImageDir
    Directory containing screenshots (.png/.jpg/.jpeg).

.PARAMETER Branch
    Wiki branch to push to. See the branch note below.

.PARAMETER PageName
    Wiki page file name (without extension).

.PARAMETER CommitMessage
    Commit message for the published change.

.PARAMETER Preflight
    Run 'publish-wiki-preflight.ps1' first to verify the wiki target + PAT scope,
    and abort before any clone/push when the preflight fails.

.EXAMPLE
    ./scripts/publish-wiki.ps1 -Target github -Preflight `
        -WikiRepoUrl 'https://github.com/devopsabcs-engineering/aks-governance.wiki.git'

.EXAMPLE
    $env:WIKI_PAT = '<token>'
    ./scripts/publish-wiki.ps1 -Target ado `
        -WikiRepoUrl 'https://dev.azure.com/contoso/AKS%20Governance/_git/AKS%20Governance.wiki'

.NOTES
    Follows user memory azure-devops-wiki-auth.md (PAT-in-URL, Code R/W scope,
    bash+macro auth) and powershell-pitfalls.md (literal '&', Select-String).
#>
[CmdletBinding()]
param(
    [ValidateSet('ado', 'github')]
    [string]$Target = 'github',

    [string]$WikiRepoUrl,

    [string]$Pat = $env:WIKI_PAT,

    [string]$CaptureDir = 'docs/captures',

    [string]$ImageDir = 'docs/screenshots',

    # Newer Azure DevOps project wikis default to 'wikiMain'; older/provisioned
    # wikis historically used 'wikiMaster'. GitHub wikis default to 'master'.
    # When the default branch differs, override it with -Branch. The script also
    # detects the cloned default branch and pushes HEAD, so this value is a fallback.
    [string]$Branch = 'wikiMain',

    [string]$PageName = 'AKS-Governance-Demo',

    [string]$CommitMessage = 'docs(wiki): publish AKS governance PoC demo walkthrough',

    [switch]$Preflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Assert-LastExit {
    param([string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "Git operation failed ($Operation), exit code $LASTEXITCODE."
    }
}

function ConvertTo-Heading {
    param([string]$Key)
    # Turn '01-argocd-applications' into 'Argocd Applications' (drop a leading
    # numeric ordering prefix).
    $text = $Key -replace '^[0-9]+[-_]?', ''
    $text = $text -replace '[-_]+', ' '
    $text = $text.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { $text = $Key }
    return ((Get-Culture).TextInfo.ToTitleCase($text.ToLower()))
}

function New-DemoMarkdown {
    <#
        Interleaves CLI text captures with screenshots into a single markdown page.
        Returns a hashtable: @{ Markdown = <string>; Images = <FileInfo[]> }.
        Pairing is by file base name (e.g. '01-argocd-applications.txt' pairs with
        '01-argocd-applications.png').
    #>
    param(
        [string]$CapturePath,
        [string]$ImagePath,
        [ValidateSet('ado', 'github')]
        [string]$WikiTarget
    )

    $captureFiles = @()
    if (Test-Path -LiteralPath $CapturePath) {
        $captureFiles = Get-ChildItem -LiteralPath $CapturePath -File |
            Where-Object { $_.Extension -in '.txt', '.md', '.log' }
    }

    $imageFiles = @()
    if (Test-Path -LiteralPath $ImagePath) {
        $imageFiles = Get-ChildItem -LiteralPath $ImagePath -File |
            Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg' }
    }

    $capturesByKey = @{}
    foreach ($c in $captureFiles) { $capturesByKey[$c.BaseName] = $c }
    $imagesByKey = @{}
    foreach ($i in $imageFiles) { $imagesByKey[$i.BaseName] = $i }

    # Image path prefix differs by wiki backend.
    $imagePrefix = if ($WikiTarget -eq 'ado') { '/.attachments/' } else { 'images/' }

    # Human-readable narrative for known section keys. Sections not listed here still
    # render with an auto-generated heading; this just adds context where we have it.
    $descriptions = @{
        '01-mgmt-nodes'           = 'Management AKS cluster nodes (`kubectl get nodes -o wide`). This ephemeral cluster hosts CAPI core, CAPZ, ASO, ArgoCD, and Kyverno; it is provisioned per run via Bicep and torn down afterwards.'
        '02-capi-controllers'     = '`kubectl get pods -n capi-system` - the Cluster API core controllers that reconcile the declarative `Cluster` objects.'
        '03-capz-controllers'     = '`kubectl get pods -n capz-system` - the Cluster API Provider for Azure (CAPZ) controllers that drive AKS provisioning via the `aks-aso` flavor.'
        '04-aso-controllers'      = '`kubectl get deployment azureserviceoperator-controller-manager -n capz-system` - the Azure Service Operator (ASO) controller CAPZ uses to create the underlying Azure resources. CAPZ bundles ASO into the `capz-system` namespace (there is no separate `azureserviceoperator-system` namespace).'
        '05-clusters'             = '`kubectl get clusters -A` - the CAPI `Cluster` objects for both workload clusters and their phase/ready state.'
        '06-argocd-applications'  = 'The ArgoCD **Applications** view (`kubectl get applications -n argocd`). The governance `ApplicationSet` creates one policy Application per registered workload cluster; healthy + Synced status proves the GitOps fan-out reached every cluster.'
        '06-argocd-applicationsets' = '`kubectl get applicationsets -n argocd` - the cluster-generator `ApplicationSet` that templates a policy Application for each workload cluster labeled `type=workload`.'
        '07-argocd-clusters'      = '`kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster` - the two registered workload cluster Secrets. Each CAPI `<cluster>-kubeconfig` Secret is converted into an ArgoCD cluster Secret so policies can be synced to it.'
        '08-kyverno-policies'     = '`kubectl get clusterpolicy` on the management cluster - the `enforce-min-k8s-version` policy (B) that rejects an under-minimum CAPZ control-plane CR at admission. The registry-deny policy (A) runs on the workload clusters (admission happens where the workload lands); its enforcement is shown in the Example A captures below.'
        '09-policy-reports'       = '`kubectl get policyreport -A` - the Audit-phase violation report. The demo deploys policies as `Audit` first (violations visible but not blocked), captures this report, then a git commit flips them to `Enforce`.'
        '10-mgmt-aks'             = '`az aks show` - the management AKS cluster with its OIDC issuer and workload-identity flags, confirming the identity wiring CAPZ/ASO depend on.'
        '11-aks-inventory'        = '`az aks list` - the live AKS inventory across the subscription (management + both CAPZ-provisioned workload clusters) with their Kubernetes versions.'
        'registry-deny'          = '**Example A - registry governance.** Applying a Pod that pulls from `docker.io` / `quay.io` is rejected at admission by Kyverno with the disallowed-registry message; an allow-listed `mcr.microsoft.com` image is admitted.'
        'min-version-denial'     = '**Example B - minimum Kubernetes version.** Applying an under-minimum `AzureASOManagedControlPlane` is rejected at admission, with the configured minimum version echoed in the error message.'
        'teardown'               = '`scripts/teardown.ps1` - CAPI-ordered teardown: delete the `Cluster` objects, wait for the workload resource groups to drain, then delete the management resource group so no Azure cost is left behind.'
    }

    # Preferred section order. Anything not listed falls to the end, alphabetically.
    $orderHint = @(
        '01-mgmt-nodes', '02-capi-controllers', '03-capz-controllers', '04-aso-controllers',
        '05-clusters',
        '06-argocd-applications', '06-argocd-applicationsets', '07-argocd-clusters',
        '08-kyverno-policies', '09-policy-reports',
        '10-mgmt-aks', '11-aks-inventory',
        'registry-deny', 'min-version-denial', 'teardown'
    )
    # Per-workload-cluster describe sections (05-cluster-<name>.txt).
    $allClusterKeys = @($capturesByKey.Keys + $imagesByKey.Keys) | Where-Object { $_ -match '^05-cluster-' } | Sort-Object -Unique
    $insertAt = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $orderHint) {
        $insertAt.Add($k) | Out-Null
        if ($k -eq '05-clusters') { foreach ($ck in $allClusterKeys) { $insertAt.Add($ck) | Out-Null } }
    }
    $orderHint = $insertAt.ToArray()
    # ArgoCD app-detail screenshots (02-argocd-app-<name>.png).
    foreach ($k in @($imagesByKey.Keys)) { if ($k -match '^02-argocd-app-' -and $orderHint -notcontains $k) { $orderHint += $k } }

    $allKeys = @($capturesByKey.Keys + $imagesByKey.Keys) | Sort-Object -Unique
    $keys = @()
    foreach ($k in $orderHint) { if ($allKeys -contains $k -and $keys -notcontains $k) { $keys += $k } }
    foreach ($k in $allKeys) { if ($keys -notcontains $k) { $keys += $k } }

    $usedImages = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $sb = [System.Text.StringBuilder]::new()

    # --- Intro / context ---
    $null = $sb.AppendLine('# AKS Governance PoC - Demo Walkthrough')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("_Last published: $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC (generated by ``scripts/publish-wiki.ps1``)._")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('This walkthrough is produced automatically by the end-to-end pipeline. It pairs')
    $null = $sb.AppendLine('live CLI output (`kubectl` / `clusterctl` / `az`) with ArgoCD and Azure portal')
    $null = $sb.AppendLine('screenshots, proving that two governance controls are enforced across AKS')
    $null = $sb.AppendLine('clusters that were provisioned declaratively with Cluster API.')
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## What this demonstrates')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('- **Declarative AKS lifecycle** - an ephemeral management AKS cluster runs CAPI core + CAPZ + ASO and provisions two workload AKS clusters from checked-in YAML (the `aks-aso` flavor).')
    $null = $sb.AppendLine('- **GitOps fan-out** - ArgoCD registers each workload cluster and an `ApplicationSet` syncs the governance policy bundle to every cluster.')
    $null = $sb.AppendLine('- **Example A - registry governance** - a Kyverno policy denies container images from `docker.io` / `quay.io` (allow-list: `mcr.microsoft.com`, the customer ACR, `registry.k8s.io`).')
    $null = $sb.AppendLine('- **Example B - minimum Kubernetes version** - a Kyverno policy rejects an under-minimum CAPZ control-plane at admission, with the minimum version in the error.')
    $null = $sb.AppendLine('- **Audit then Enforce** - policies deploy as `Audit` first (`PolicyReport` shows violations without blocking), then a git commit flips them to `Enforce` for the before/after narrative.')
    $null = $sb.AppendLine('- **Evidence capture** - CLI output and screenshots are published here for review; teardown then deletes everything to keep costs near-zero between demos.')
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Architecture')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('```mermaid')
    $null = $sb.AppendLine('flowchart TD')
    $null = $sb.AppendLine('  subgraph MGMT["Management RG: rg-aksgov-poc-mgmt"]')
    $null = $sb.AppendLine('    M["Management AKS<br/>CAPI + CAPZ + ASO<br/>ArgoCD + Kyverno"]')
    $null = $sb.AppendLine('  end')
    $null = $sb.AppendLine('  subgraph WL["CAPZ-created workload RGs"]')
    $null = $sb.AppendLine('    W1["poc-aks-1<br/>(workload AKS)"]')
    $null = $sb.AppendLine('    W2["poc-aks-2<br/>(workload AKS)"]')
    $null = $sb.AppendLine('  end')
    $null = $sb.AppendLine('  M -- "CAPI Cluster CRs" --> W1')
    $null = $sb.AppendLine('  M -- "CAPI Cluster CRs" --> W2')
    $null = $sb.AppendLine('  M -- "ArgoCD ApplicationSet" --> W1')
    $null = $sb.AppendLine('  M -- "ArgoCD ApplicationSet" --> W2')
    $null = $sb.AppendLine('  POL["Kyverno policies<br/>(deny docker.io/quay.io;<br/>min K8s version)"] -. enforces .-> W1 & W2')
    $null = $sb.AppendLine('```')
    $null = $sb.AppendLine()

    if ($keys.Count -eq 0) {
        $null = $sb.AppendLine('> No captures or screenshots were found. Run `scripts/capture.ps1` first.')
        $null = $sb.AppendLine()
    }
    else {
        # --- Table of contents ---
        $null = $sb.AppendLine('## Contents')
        $null = $sb.AppendLine()
        foreach ($key in $keys) {
            $heading = ConvertTo-Heading -Key $key
            $anchor = ($heading.ToLower() -replace '[^a-z0-9 ]', '' -replace ' ', '-')
            $null = $sb.AppendLine("- [$heading](#$anchor)")
        }
        $null = $sb.AppendLine()
    }

    foreach ($key in $keys) {
        $heading = ConvertTo-Heading -Key $key
        $null = $sb.AppendLine("## $heading")
        $null = $sb.AppendLine()

        if ($descriptions.ContainsKey($key)) {
            $null = $sb.AppendLine($descriptions[$key])
            $null = $sb.AppendLine()
        }

        if ($imagesByKey.ContainsKey($key)) {
            $img = $imagesByKey[$key]
            $usedImages.Add($img)
            $null = $sb.AppendLine("![$heading]($imagePrefix$($img.Name))")
            $null = $sb.AppendLine()
        }

        if ($capturesByKey.ContainsKey($key)) {
            $body = Get-Content -LiteralPath $capturesByKey[$key].FullName -Raw
            $null = $sb.AppendLine('```text')
            $null = $sb.AppendLine($body.TrimEnd())
            $null = $sb.AppendLine('```')
            $null = $sb.AppendLine()
        }
    }

    # --- Footer ---
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('Reproduce this end-to-end via the AKS Governance PoC GitHub Actions workflow')
    $null = $sb.AppendLine('under `.github/workflows/`, or run the scripts under `scripts/` manually.')
    $null = $sb.AppendLine('See the repository `README.md` for setup and teardown.')
    $null = $sb.AppendLine()

    return @{
        Markdown = $sb.ToString()
        Images   = $usedImages.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($WikiRepoUrl)) {
    throw 'WikiRepoUrl is required (HTTPS clone URL of the wiki Git repository).'
}
if ([string]::IsNullOrWhiteSpace($Pat)) {
    throw 'A PAT is required. Pass -Pat or set the WIKI_PAT environment variable. ADO wikis require Code (Read and Write) scope.'
}
if ($WikiRepoUrl -notmatch '^https://') {
    throw "WikiRepoUrl must be an HTTPS URL: $WikiRepoUrl"
}

# GitHub wikis default to 'master'; only override the ADO default when the caller
# did not pass -Branch explicitly.
if ($Target -eq 'github' -and -not $PSBoundParameters.ContainsKey('Branch')) {
    $Branch = 'master'
}

# ---------------------------------------------------------------------------
# Optional preflight (verify wiki target + PAT scope before any push)
# ---------------------------------------------------------------------------

if ($Preflight) {
    $preflightScript = Join-Path $PSScriptRoot 'publish-wiki-preflight.ps1'
    if (-not (Test-Path -LiteralPath $preflightScript)) {
        throw "Preflight requested but '$preflightScript' was not found."
    }
    Write-Host 'Running publish preflight...'
    & $preflightScript -Target $Target -WikiRepoUrl $WikiRepoUrl -Pat $Pat
    if ($LASTEXITCODE -ne 0) {
        throw "Publish preflight failed (exit code $LASTEXITCODE). Aborting before any git push."
    }
    Write-Host 'Preflight passed.'
}

# URL-encode spaces (Azure DevOps project names frequently contain them).
$encodedUrl = $WikiRepoUrl -replace ' ', '%20'
$noScheme = $encodedUrl -replace '^https://', ''
$authUrl = "https://$Pat@$noScheme"

# ---------------------------------------------------------------------------
# Generate markdown + resolve referenced images
# ---------------------------------------------------------------------------

Write-Host "Generating '$PageName.md' from captures='$CaptureDir' and images='$ImageDir'..."
$doc = New-DemoMarkdown -CapturePath $CaptureDir -ImagePath $ImageDir -WikiTarget $Target
Write-Host "Resolved $($doc.Images.Count) screenshot(s) to publish."

# ---------------------------------------------------------------------------
# Clone the wiki repo into a temp work dir
# ---------------------------------------------------------------------------

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wiki-publish-" + [System.Guid]::NewGuid().ToString('N'))
$useBash = [bool](Get-Command bash -ErrorAction SilentlyContinue)

try {
    Write-Host "Cloning wiki repository into '$workDir'..."
    if ($useBash) {
        # Preferred: bash + macro substitution so the PAT is built inside the shell
        # (user memory azure-devops-wiki-auth.md). The PAT is passed via env, never argv.
        $env:WIKI_PAT_RUNTIME = $Pat
        $env:WIKI_NOSCHEME = $noScheme
        $env:WIKI_WORKDIR = $workDir
        $cloneScript = @'
set -euo pipefail
WIKI_REPO="https://${WIKI_PAT_RUNTIME}@${WIKI_NOSCHEME}"
git clone --depth 1 "$WIKI_REPO" "$WIKI_WORKDIR"
'@
        $cloneScript | bash
        Assert-LastExit -Operation 'clone (bash)'
    }
    else {
        # Fallback: build the PAT-in-URL string directly in PowerShell.
        git clone --depth 1 $authUrl $workDir
        Assert-LastExit -Operation 'clone (pwsh)'
    }

    # -----------------------------------------------------------------------
    # Copy images + write markdown into the clone
    # -----------------------------------------------------------------------

    $attachDirName = if ($Target -eq 'ado') { '.attachments' } else { 'images' }
    $attachDir = Join-Path $workDir $attachDirName
    if ($doc.Images.Count -gt 0) {
        New-Item -ItemType Directory -Path $attachDir -Force | Out-Null
        foreach ($img in $doc.Images) {
            Copy-Item -LiteralPath $img.FullName -Destination (Join-Path $attachDir $img.Name) -Force
        }
        Write-Host "Copied $($doc.Images.Count) image(s) into '$attachDirName/'."
    }

    $pageFile = Join-Path $workDir "$PageName.md"
    Set-Content -LiteralPath $pageFile -Value $doc.Markdown -Encoding utf8
    Write-Host "Wrote '$PageName.md'."

    # Azure DevOps wikis use a root '.order' file to control the table-of-contents
    # sequence; ensure the new page is listed (GitHub wikis have no such convention).
    if ($Target -eq 'ado') {
        $orderFile = Join-Path $workDir '.order'
        $orderEntries = @()
        if (Test-Path -LiteralPath $orderFile) {
            $orderEntries = Get-Content -LiteralPath $orderFile
        }
        if (-not ($orderEntries | Select-String -SimpleMatch -Pattern $PageName -Quiet)) {
            Add-Content -LiteralPath $orderFile -Value $PageName
            Write-Host "Added '$PageName' to .order."
        }
    }

    # -----------------------------------------------------------------------
    # Commit + push
    # -----------------------------------------------------------------------

    Write-Host 'Committing and pushing...'
    if ($useBash) {
        $env:WIKI_WORKDIR = $workDir
        $env:WIKI_COMMIT_MSG = $CommitMessage
        $env:WIKI_BRANCH = $Branch
        $pushScript = @'
set -euo pipefail
cd "$WIKI_WORKDIR"
git config user.email pipeline@local
git config user.name  pipeline
git add -A
if git diff --cached --quiet; then
  echo "No changes to publish."
  exit 0
fi
git commit -m "$WIKI_COMMIT_MSG"
# Push the cloned default branch (wikiMain/wikiMaster/master); fall back to the
# configured branch name when HEAD is detached.
git push origin HEAD || git push origin "HEAD:$WIKI_BRANCH"
'@
        $pushScript | bash
        Assert-LastExit -Operation 'commit/push (bash)'
    }
    else {
        Push-Location $workDir
        try {
            git config user.email pipeline@local
            Assert-LastExit -Operation 'config email'
            git config user.name pipeline
            Assert-LastExit -Operation 'config name'
            git add -A
            Assert-LastExit -Operation 'add'

            git diff --cached --quiet
            if ($LASTEXITCODE -eq 0) {
                Write-Host 'No changes to publish.'
            }
            else {
                git commit -m $CommitMessage
                Assert-LastExit -Operation 'commit'
                git push origin HEAD
                if ($LASTEXITCODE -ne 0) {
                    git push origin "HEAD:$Branch"
                    Assert-LastExit -Operation 'push (branch fallback)'
                }
            }
        }
        finally {
            Pop-Location
        }
    }

    Write-Host "Published '$PageName.md' to the $Target wiki."
}
finally {
    if ($useBash) {
        Remove-Item Env:\WIKI_PAT_RUNTIME -ErrorAction SilentlyContinue
        Remove-Item Env:\WIKI_NOSCHEME -ErrorAction SilentlyContinue
        Remove-Item Env:\WIKI_WORKDIR -ErrorAction SilentlyContinue
        Remove-Item Env:\WIKI_COMMIT_MSG -ErrorAction SilentlyContinue
        Remove-Item Env:\WIKI_BRANCH -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
