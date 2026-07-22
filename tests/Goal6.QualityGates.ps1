# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-quality-gates-' + [Guid]::NewGuid().ToString('N'))
$assertionCount = 0
. (Join-Path $repositoryRootPath 'scripts/goal6/Goal6.Common.ps1')
. (Join-Path $repositoryRootPath 'scripts/goal6/Goal6.Zip.ps1')

function Assert-PshGoal6Quality {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "Goal 6 quality-gate regression failed: $Message" }
    $script:assertionCount++
}

function Assert-PshGoal6QualityThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failure = $null
    try { & $Action }
    catch { $failure = [string]$_.Exception.Message }
    Assert-PshGoal6Quality (-not [string]::IsNullOrWhiteSpace($failure)) "$Description did not fail."
    Assert-PshGoal6Quality ($failure -match $MessagePattern) "$Description failed with an unexpected message: $failure"
}

function New-PshGoal6QualityLockCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Mutation
    )

    $sourcePath = Join-Path $repositoryRootPath 'scripts/goal6/ci-dependencies.lock.json'
    $lock = (Get-PshGoal6StrictText -Path $sourcePath) | ConvertFrom-Json -ErrorAction Stop
    & $Mutation $lock
    $path = Join-Path $testRoot ($Name + '.json')
    Write-PshGoal6Json -Path $path -InputObject $lock
    return $path
}

function New-PshGoal6QualityZip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$EntryNames,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Timestamp,
        [int]$ExternalAttributes = 0
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($entryName in $EntryNames) {
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $Timestamp
                $entry.ExternalAttributes = $ExternalAttributes
                $entryStream = $entry.Open()
                try {
                    $content = [Text.Encoding]::UTF8.GetBytes("content:$entryName`n")
                    $entryStream.Write($content, 0, $content.Length)
                }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $lockPath = Join-Path $repositoryRootPath 'scripts/goal6/ci-dependencies.lock.json'
    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $lockPath
    Assert-PshGoal6Quality (@($lock.dependencies).Count -eq 3) 'The CI dependency lock does not contain exactly three dependencies.'
    Assert-PshGoal6Quality ((@($lock.dependencies | ForEach-Object { [string]$_.id }) -join '|') -ceq 'gitleaks|pester|psscriptanalyzer') 'The CI dependency order is not gitleaks, pester, psscriptanalyzer.'
    $pester = Get-PshGoal6Dependency -Lock $lock -Id pester
    Assert-PshGoal6Quality ([string]$pester.version -ceq '5.9.0' -and [string]$pester.license.spdxId -ceq 'Apache-2.0' -and -not [bool]$pester.license.packageContainsLicense) 'The pinned Pester package/license contract changed.'
    Assert-PshGoal6Quality ($null -eq $pester.license.archivePath -and [string]$pester.package.galleryHashAlgorithm -ceq 'SHA512') 'The Pester source-license or Gallery-hash policy changed.'

    $analyzerGateText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6PSScriptAnalyzer.ps1')
    Assert-PshGoal6Quality ($analyzerGateText -match '\bIncludeSuppressed\b' -and $analyzerGateText -match '\bIsSuppressed\b' -and $analyzerGateText -match '\bSuppressMessage(Attribute)?\b') 'The analyzer gate no longer includes and audits suppressed diagnostics and attributes.'
    $secretGateText = Get-PshGoal6StrictText -Path (Join-Path $repositoryRootPath 'scripts/goal6/Invoke-Goal6SecretScan.ps1')
    Assert-PshGoal6Quality ($secretGateText -match [regex]::Escape('--log-opts=--all') -and $secretGateText -match '\bAssert-PshGoal6RemoteRefCoverage\b') 'The secret gate no longer explicitly scans all refs after remote parity validation.'

    $leafTraversalLock = New-PshGoal6QualityLockCopy -Name 'package-file-name-traversal' -Mutation {
        param($value)
        $value.dependencies[0].package.fileName = '../escape.zip'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $leafTraversalLock } -MessagePattern 'single file leaf name' -Description 'Package fileName traversal'

    $licenseTraversalLock = New-PshGoal6QualityLockCopy -Name 'license-archive-path-traversal' -Mutation {
        param($value)
        $value.dependencies[0].license.archivePath = '../LICENSE'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $licenseTraversalLock } -MessagePattern 'traversal segment' -Description 'License archivePath traversal'

    $repositoryLock = New-PshGoal6QualityLockCopy -Name 'untrusted-repository' -Mutation {
        param($value)
        $value.dependencies[0].source.repository = 'https://example.invalid/gitleaks'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $repositoryLock } -MessagePattern 'repository is not trusted' -Description 'Untrusted dependency repository'

    $tagLock = New-PshGoal6QualityLockCopy -Name 'untrusted-tag' -Mutation {
        param($value)
        $value.dependencies[1].source.tag = '5.9.1'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $tagLock } -MessagePattern 'source tag changed' -Description 'Untrusted dependency tag'

    $urlLock = New-PshGoal6QualityLockCopy -Name 'untrusted-package-url' -Mutation {
        param($value)
        $value.dependencies[2].package.url = 'https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.25.0?alternate=1'
    }
    Assert-PshGoal6QualityThrows -Action { Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath $urlLock } -MessagePattern 'package URL changed' -Description 'Untrusted dependency package URL'

    $remoteRefs = @(
        '1111111111111111111111111111111111111111 refs/heads/main',
        '2222222222222222222222222222222222222222 refs/heads/release',
        '3333333333333333333333333333333333333333 refs/tags/v0.1.0'
    )
    $localBranches = @(
        '1111111111111111111111111111111111111111 refs/remotes/origin/main',
        '2222222222222222222222222222222222222222 refs/remotes/origin/release'
    )
    $localTags = @('3333333333333333333333333333333333333333 refs/tags/v0.1.0')
    $coverage = Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines $localBranches -LocalTagLines $localTags
    Assert-PshGoal6Quality ([int]$coverage.branchCount -eq 2 -and [int]$coverage.tagCount -eq 1 -and [string]$coverage.parity -ceq 'exact') 'Exact remote-ref coverage did not pass.'
    Assert-PshGoal6QualityThrows -Action { Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines @($localBranches[0]) -LocalTagLines $localTags } -MessagePattern 'missing-local:refs/heads/release' -Description 'Missing remote branch coverage'
    Assert-PshGoal6QualityThrows -Action { Assert-PshGoal6RemoteRefCoverage -RemoteLines $remoteRefs -LocalBranchLines $localBranches -LocalTagLines @() } -MessagePattern 'missing-local:refs/tags/v0.1.0' -Description 'Missing remote tag coverage'

    $stagingRoot = Join-Path $testRoot 'dependency.staging'
    $destinationRoot = Join-Path $testRoot 'dependency.committed'
    $invalidSummaryPath = Join-Path $testRoot 'summary-as-directory'
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    [void][IO.File]::WriteAllText((Join-Path $stagingRoot 'marker.txt'), 'committed bytes')
    [void][IO.Directory]::CreateDirectory($invalidSummaryPath)
    Assert-PshGoal6QualityThrows -Action { Complete-PshGoal6DependencyInstall -StagingRoot $stagingRoot -DestinationRoot $destinationRoot -SummaryPath $invalidSummaryPath -Summary ([pscustomobject]@{ status = 'passed' }) } -MessagePattern 'committed dependency directory was rolled back' -Description 'Dependency summary transaction'
    Assert-PshGoal6Quality (-not [IO.Directory]::Exists($stagingRoot) -and -not [IO.Directory]::Exists($destinationRoot)) 'Dependency summary failure left staging or committed dependency bytes behind.'

    $firstZip = Join-Path $testRoot 'first.zip'
    $timestampZip = Join-Path $testRoot 'timestamp-only.zip'
    $reorderedZip = Join-Path $testRoot 'reordered.zip'
    New-PshGoal6QualityZip -Path $firstZip -EntryNames @('alpha.txt', 'nested/beta.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero))
    New-PshGoal6QualityZip -Path $timestampZip -EntryNames @('alpha.txt', 'nested/beta.txt') -Timestamp (New-Object DateTimeOffset(2026, 2, 3, 4, 5, 8, [TimeSpan]::Zero))
    New-PshGoal6QualityZip -Path $reorderedZip -EntryNames @('nested/beta.txt', 'alpha.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero))
    $firstManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $firstZip -DisplayPath 'fixture.zip'
    $timestampManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $timestampZip -DisplayPath 'fixture.zip'
    $reorderedManifest = Get-PshGoal6ZipArchiveManifest -ArchivePath $reorderedZip -DisplayPath 'fixture.zip'
    Assert-PshGoal6Quality ([string]$firstManifest.containerSha256Informational -cne [string]$timestampManifest.containerSha256Informational) 'Timestamp fixture did not change raw ZIP bytes.'
    Assert-PshGoal6Quality ([string]$firstManifest.timestampNormalizedContainerSha256 -ceq [string]$timestampManifest.timestampNormalizedContainerSha256) 'Timestamp-only ZIP differences were not normalized.'
    Assert-PshGoal6Quality (@(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $timestampManifest).Count -eq 0) 'Timestamp-only ZIP differences reached the reproducibility diff.'
    $orderDifferences = @(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $reorderedManifest)
    Assert-PshGoal6Quality (@($orderDifferences | Where-Object { [string]$_.kind -ceq 'archive-entry-order' }).Count -gt 0) 'ZIP entry order was not hard-compared.'

    $metadataMutation = (($firstManifest | ConvertTo-Json -Depth 20) | ConvertFrom-Json -ErrorAction Stop)
    $metadataMutation.archiveCommentBase64 = 'Y29tbWVudA=='
    $metadataMutation.entries[0].flags = '0x0808'
    $metadataMutation.entries[0].compressionMethod = 0
    $metadataMutation.entries[0].centralExtraBase64 = 'AQID'
    $metadataMutation.entries[0].entryCommentBase64 = 'BAUG'
    $metadataMutation.entries[0].localExtraBase64 = 'BwgJ'
    $metadataMutation.entries[0].externalAttributes = '0x00000020'
    $metadataDifferences = @(Compare-PshGoal6ZipArchiveManifest -First $firstManifest -Second $metadataMutation)
    $metadataKinds = @($metadataDifferences | ForEach-Object { [string]$_.kind })
    foreach ($requiredKind in @('archive-comment', 'archive-entry-flags', 'archive-entry-compressionMethod', 'archive-entry-centralExtraBase64', 'archive-entry-entryCommentBase64', 'archive-entry-localExtraBase64', 'archive-entry-externalAttributes')) {
        Assert-PshGoal6Quality ($metadataKinds -ccontains $requiredKind) "ZIP metadata comparison omitted $requiredKind."
    }

    $reparseZip = Join-Path $testRoot 'reparse.zip'
    New-PshGoal6QualityZip -Path $reparseZip -EntryNames @('reparse.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero)) -ExternalAttributes 0x400
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $reparseZip -DisplayPath 'reparse.zip' } -MessagePattern 'reparse-point entry' -Description 'ZIP reparse-point semantics'

    $symlinkZip = Join-Path $testRoot 'symlink.zip'
    $symlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([Convert]::ToUInt32('A1FF0000', 16)), 0)
    New-PshGoal6QualityZip -Path $symlinkZip -EntryNames @('link.txt') -Timestamp (New-Object DateTimeOffset(2025, 1, 2, 3, 4, 6, [TimeSpan]::Zero)) -ExternalAttributes $symlinkAttributes
    Assert-PshGoal6QualityThrows -Action { Get-PshGoal6ZipArchiveManifest -ArchivePath $symlinkZip -DisplayPath 'symlink.zip' } -MessagePattern 'symbolic-link entry' -Description 'ZIP symbolic-link semantics'

    Write-Output "Goal 6 quality-gate regression passed: $assertionCount assertions."
    $global:LASTEXITCODE = 0
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

$global:LASTEXITCODE = 0
