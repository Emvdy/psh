# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportRoot,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$LockPath = (Join-Path $PSScriptRoot 'ci-dependencies.lock.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

function Invoke-PshGoal6SupplyChainStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $status = 'passed'
    $errorMessage = $null
    $output = @()
    try { $output = @(& $ScriptPath @Parameters 2>&1) }
    catch { $status = 'failed'; $errorMessage = [string]$_.Exception.Message; $output += $_ }
    Write-PshGoal6Text -Path $LogPath -Text ((@($output | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    return [pscustomobject][ordered]@{
        name = $Name
        status = $status
        log = [IO.Path]::GetFileName($LogPath)
        error = $errorMessage
    }
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$reportRootPath = [IO.Path]::GetFullPath($ReportRoot)
[void][IO.Directory]::CreateDirectory($reportRootPath)
$regeneratedRoot = Join-Path $reportRootPath 'regenerated'
[void][IO.Directory]::CreateDirectory($regeneratedRoot)
$steps = New-Object System.Collections.Generic.List[object]
$ciDependencies = @()

try {
    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath ([IO.Path]::GetFullPath($LockPath))
    $ciDependencies = @($lock.dependencies | ForEach-Object {
            [pscustomobject][ordered]@{
                id = [string]$_.id
                version = [string]$_.version
                scope = 'ci-only-not-shipped'
                packageSha256 = [string]$_.package.sha256
                license = [string]$_.license.spdxId
                licensePath = [string]$_.license.retainedPath
                licenseSha256 = [string]$_.license.sha256
                provenancePath = [string]$_.provenance.retainedPath
                provenanceSha256 = [string]$_.provenance.sha256
            }
        })
    $steps.Add([pscustomobject][ordered]@{ name = 'ci-dependency-lock-and-licenses'; status = 'passed'; log = $null; error = $null })
}
catch {
    $steps.Add([pscustomobject][ordered]@{ name = 'ci-dependency-lock-and-licenses'; status = 'failed'; log = $null; error = [string]$_.Exception.Message })
}

$generatorPath = Join-Path $repositoryRootPath 'scripts/Generate-SupplyChainArtifacts.ps1'
$interactiveCheckerPath = Join-Path $repositoryRootPath 'scripts/Test-InteractiveDependencies.ps1'
$nativeCheckerPath = Join-Path $repositoryRootPath 'scripts/Test-NativeTools.ps1'
$regeneratedNotices = Join-Path $regeneratedRoot 'THIRD_PARTY_NOTICES.md'
$regeneratedSbom = Join-Path $regeneratedRoot 'sbom.spdx.json'
$steps.Add((Invoke-PshGoal6SupplyChainStep -Name 'regenerate-release-notices-and-sbom' -ScriptPath $generatorPath -Parameters @{ RepositoryRoot = $repositoryRootPath; NoticesPath = $regeneratedNotices; SbomPath = $regeneratedSbom } -LogPath (Join-Path $reportRootPath 'supply-chain-regenerate.log')))
$steps.Add((Invoke-PshGoal6SupplyChainStep -Name 'check-release-notices-and-sbom' -ScriptPath $generatorPath -Parameters @{ RepositoryRoot = $repositoryRootPath; Check = $true } -LogPath (Join-Path $reportRootPath 'supply-chain-check.log')))
$steps.Add((Invoke-PshGoal6SupplyChainStep -Name 'check-interactive-dependencies' -ScriptPath $interactiveCheckerPath -Parameters @{ RepositoryRoot = $repositoryRootPath } -LogPath (Join-Path $reportRootPath 'interactive-dependencies.log')))
$steps.Add((Invoke-PshGoal6SupplyChainStep -Name 'check-native-tools-and-licenses' -ScriptPath $nativeCheckerPath -Parameters @{ RepositoryRoot = $repositoryRootPath; Architecture = 'all' } -LogPath (Join-Path $reportRootPath 'native-tools.log')))

$releaseArtifactError = $null
$releaseArtifactDetails = $null
try {
    $checkedNotices = Join-Path $repositoryRootPath 'THIRD_PARTY_NOTICES.md'
    $checkedSbom = Join-Path $repositoryRootPath 'sbom.spdx.json'
    foreach ($requiredPath in @($checkedNotices, $checkedSbom, $regeneratedNotices, $regeneratedSbom)) {
        Assert-PshGoal6Condition ([IO.File]::Exists($requiredPath) -and [int64](Get-Item -LiteralPath $requiredPath).Length -gt 0) "Supply-chain output is missing or empty: $requiredPath"
    }
    $checkedNoticesSha256 = Get-PshGoal6Sha256 -Path $checkedNotices
    $regeneratedNoticesSha256 = Get-PshGoal6Sha256 -Path $regeneratedNotices
    $checkedSbomSha256 = Get-PshGoal6Sha256 -Path $checkedSbom
    $regeneratedSbomSha256 = Get-PshGoal6Sha256 -Path $regeneratedSbom
    Assert-PshGoal6Condition ($checkedNoticesSha256 -ceq $regeneratedNoticesSha256) 'Regenerated THIRD_PARTY_NOTICES.md differs from the checked-in file.'
    Assert-PshGoal6Condition ($checkedSbomSha256 -ceq $regeneratedSbomSha256) 'Regenerated SPDX SBOM differs from the checked-in file.'
    $sbom = (Get-PshGoal6StrictText -Path $checkedSbom) | ConvertFrom-Json -ErrorAction Stop
    Assert-PshGoal6Condition ([string]$sbom.spdxVersion -ceq 'SPDX-2.3') 'Release SBOM is not SPDX 2.3.'
    Assert-PshGoal6Condition (@($sbom.packages).Count -eq 5) 'Release SBOM must describe PSReadLine plus four native tools.'
    $releaseArtifactDetails = [pscustomobject][ordered]@{
        noticesSha256 = $checkedNoticesSha256
        regeneratedNoticesSha256 = $regeneratedNoticesSha256
        sbomSha256 = $checkedSbomSha256
        regeneratedSbomSha256 = $regeneratedSbomSha256
        spdxVersion = [string]$sbom.spdxVersion
        packageCount = @($sbom.packages).Count
    }
}
catch { $releaseArtifactError = [string]$_.Exception.Message }
$steps.Add([pscustomobject][ordered]@{ name = 'compare-regenerated-release-artifacts'; status = if ($null -eq $releaseArtifactError) { 'passed' } else { 'failed' }; log = $null; error = $releaseArtifactError })

$failedSteps = @($steps.ToArray() | Where-Object { [string]$_.status -cne 'passed' })
$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'dependency-license-sbom'
    status = if ($failedSteps.Count -eq 0) { 'passed' } else { 'failed' }
    releaseArtifacts = $releaseArtifactDetails
    ciDependencies = $ciDependencies
    ciDependencySbomPolicy = 'CI-only tools are retained and verified separately; they are not shipped and therefore are excluded from the release SBOM.'
    steps = $steps.ToArray()
    failedStepCount = $failedSteps.Count
}
$summaryPath = Join-Path $reportRootPath 'dependency-license-sbom-summary.json'
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($failedSteps.Count -gt 0) { throw "Dependency/license/SBOM gate failed in $($failedSteps.Count) step(s). See $summaryPath" }
Write-Output ('Dependency/license/SBOM gate passed: release artifacts regenerated and checked; {0} CI-only dependencies retain verified MIT licenses.' -f $ciDependencies.Count)
