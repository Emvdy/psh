# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [AllowNull()][string] $ReportRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$candidateScript = Join-Path $RepositoryRoot 'scripts/goal6/New-Goal6Candidate.ps1'
$buildScript = Join-Path $RepositoryRoot 'scripts/Build-PshPackages.ps1'
$indexScript = Join-Path $RepositoryRoot 'scripts/Generate-PshReleaseIndex.ps1'
$artifactScript = Join-Path $RepositoryRoot 'scripts/Test-PshReleaseArtifacts.ps1'
foreach ($path in @($lifecyclePath, $candidateScript, $buildScript, $indexScript, $artifactScript)) {
    if (-not [IO.File]::Exists($path)) { throw "Goal 6 candidate test input is missing: $path" }
}
. $lifecyclePath

$script:Goal6CandidateAssertions = 0

function Assert-PshGoal6CandidateTest {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)

    $script:Goal6CandidateAssertions++
    if (-not $Condition) { throw "Goal 6 candidate artifacts failed: $Message" }
}

function Get-PshGoal6CandidateFailureData {
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshExitCode')) {
            return [pscustomobject][ordered]@{
                ExitCode = [int]$exception.Data['PshExitCode']
                ErrorId = [string]$exception.Data['PshErrorId']
            }
        }
        $exception = $exception.InnerException
    }
    return [pscustomobject][ordered]@{ ExitCode = 1; ErrorId = '' }
}

function Assert-PshGoal6CandidateFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Label,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId
    )

    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        $metadata = Get-PshGoal6CandidateFailureData -ErrorRecord $_
        Assert-PshGoal6CandidateTest ([int]$metadata.ExitCode -eq $ExitCode) "$Label used exit code $($metadata.ExitCode), expected $ExitCode."
        Assert-PshGoal6CandidateTest ([string]$metadata.ErrorId -ceq $ErrorId) "$Label used error id '$($metadata.ErrorId)', expected '$ErrorId'."
    }
    Assert-PshGoal6CandidateTest $failed "$Label unexpectedly succeeded."
}

function Get-PshGoal6CandidateFunctionDefinition {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) {
        throw "Unable to parse production helper source '$Path': $([string]::Join('; ', @($parseErrors | ForEach-Object { [string]$_.Message })))"
    }
    $functionMatches = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and [string]$node.Name -ceq $Name
            }, $true))
    if ($functionMatches.Count -ne 1) { throw "Production helper '$Name' was found $($functionMatches.Count) times in: $Path" }
    return [scriptblock]::Create([string]$functionMatches[0].Extent.Text)
}

function Initialize-PshGoal6CandidateTestDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description 'Goal 6 candidate test directory'
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { throw "Goal 6 candidate fixture already exists: $full" }
    [void][IO.Directory]::CreateDirectory($full)
    return $full
}

function Write-PshGoal6CandidateTestText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Initialize-PshGoal6CandidatePeFixture {
    param([Parameter(Mandatory = $true)][string] $Path)

    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    [BitConverter]::GetBytes([uint16]0x014C).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Copy-PshGoal6CandidateTestRoot {
    param([Parameter(Mandatory = $true)][string] $Source, [Parameter(Mandatory = $true)][string] $Destination)

    [void](Initialize-PshGoal6CandidateTestDirectory -Path $Destination)
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Force -File)) {
        [IO.File]::Copy($file.FullName, (Join-Path $Destination $file.Name), $false)
    }
}

function Invoke-PshGoal6CandidateTestCatalogCreation {
    param(
        [Parameter(Mandatory = $true)][object] $CatalogCommand,
        [Parameter(Mandatory = $true)][object[]] $Members,
        [Parameter(Mandatory = $true)][string] $ContentRoot,
        [Parameter(Mandatory = $true)][string] $CatalogPath
    )

    [void](Initialize-PshGoal6CandidateTestDirectory -Path $ContentRoot)
    foreach ($member in $Members) {
        $name = [string]$member.Name
        $source = [IO.Path]::GetFullPath([string]$member.SourcePath)
        Assert-PshGoal6CandidateTest ([IO.Path]::GetFileName($name) -ceq $name -and [IO.File]::Exists($source)) "Catalog test member is unsafe or missing: $name"
        [IO.File]::Copy($source, (Join-Path $ContentRoot $name), $false)
    }
    [void](& $CatalogCommand -Path $ContentRoot -CatalogFilePath $CatalogPath -CatalogVersion 2.0 -ErrorAction Stop)
    Assert-PshGoal6CandidateTest ([IO.File]::Exists($CatalogPath) -and ([IO.FileInfo]$CatalogPath).Length -gt 0) "Catalog test output is missing or empty: $CatalogPath"
    return $CatalogPath
}

function Get-PshGoal6CandidateZipEntryContent {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $EntryName)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entryMatches = @($archive.Entries | Where-Object { [string]$_.FullName -ceq $EntryName })
        if ($entryMatches.Count -ne 1) { throw "ZIP entry was not found exactly once: $EntryName" }
        $entryStream = $entryMatches[0].Open()
        $memory = New-Object IO.MemoryStream
        try { $entryStream.CopyTo($memory); return (, $memory.ToArray()) }
        finally { $memory.Dispose(); $entryStream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Invoke-PshGoal6CandidateZipEntryRewrite {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $EntryName,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporary = $Path + '.rewrite-' + [Guid]::NewGuid().ToString('N')
    $inputStream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    $outputStream = New-Object IO.FileStream($temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None))
    $replaced = 0
    try {
        $sourceArchive = New-Object IO.Compression.ZipArchive($inputStream, [IO.Compression.ZipArchiveMode]::Read, $true, (New-Object Text.UTF8Encoding($false, $true)))
        $targetArchive = New-Object IO.Compression.ZipArchive($outputStream, [IO.Compression.ZipArchiveMode]::Create, $true, (New-Object Text.UTF8Encoding($false)))
        try {
            foreach ($sourceEntry in @($sourceArchive.Entries)) {
                $entryBytes = if ([string]$sourceEntry.FullName -ceq $EntryName) {
                    $replaced++
                    $Bytes
                }
                else {
                    $source = $sourceEntry.Open()
                    $memory = New-Object IO.MemoryStream
                    try { $source.CopyTo($memory); $memory.ToArray() }
                    finally { $memory.Dispose(); $source.Dispose() }
                }
                $targetEntry = $targetArchive.CreateEntry([string]$sourceEntry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                $targetEntry.LastWriteTime = $sourceEntry.LastWriteTime
                $targetEntry.ExternalAttributes = $sourceEntry.ExternalAttributes
                $target = $targetEntry.Open()
                try { $target.Write($entryBytes, 0, $entryBytes.Length) }
                finally { $target.Dispose() }
            }
        }
        finally { $targetArchive.Dispose(); $sourceArchive.Dispose() }
    }
    finally { $outputStream.Dispose(); $inputStream.Dispose() }
    if ($replaced -ne 1) {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        throw "ZIP entry replacement count was $replaced, expected 1: $EntryName"
    }
    [IO.File]::Delete($Path)
    [IO.File]::Move($temporary, $Path)
}

function Write-PshGoal6CandidateMutationState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $AssetName
    )

    $indexPath = Join-Path $Root "psh-release-$Version.json"
    $snapshot = Read-PshStrictJsonSnapshot -Path $indexPath -Description 'candidate mutation release index'
    $index = $snapshot.Document
    $assetMatches = @($index.assets | Where-Object { [string]$_.name -ceq $AssetName })
    if ($assetMatches.Count -ne 1) { throw "Candidate mutation asset is missing from release index: $AssetName" }
    $state = Get-PshLifecycleFileSha256 -Path (Join-Path $Root $AssetName)
    $assetMatches[0].length = [int64]$state.Length
    $assetMatches[0].sha256 = [string]$state.Sha256
    Write-PshGoal6CandidateTestText -Path $indexPath -Text ((ConvertTo-PshCanonicalJson -InputObject $index) + "`n")
    $checksumLines = @($index.assets | ForEach-Object { '{0}  {1}' -f [string]$_.sha256, [string]$_.name })
    Write-PshGoal6CandidateTestText -Path (Join-Path $Root 'SHA256SUMS') -Text (([string]::Join("`n", $checksumLines)) + "`n")
}

function Invoke-PshGoal6CandidateTestTreeCleanup {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to remove reparse fixture: $($entry.FullName)" }
    }
    [IO.Directory]::Delete($Path, $true)
}

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-candidate-test-' + [Guid]::NewGuid().ToString('N'))
}
$ReportRoot = [IO.Path]::GetFullPath($ReportRoot)
if (-not [IO.Directory]::Exists($ReportRoot)) { [void](Initialize-PshGoal6CandidateTestDirectory -Path $ReportRoot) }

foreach ($functionName in @(
        'Invoke-PshGoal6CandidateFailure',
        'Initialize-PshGoal6CandidateNativeMethod',
        'Initialize-PshGoal6CandidateOwnedDirectory',
        'Test-PshGoal6CandidateContainedPath',
        'Test-PshGoal6CandidateSamePath',
        'Assert-PshGoal6CandidateOutputIsolation',
        'Move-PshGoal6CandidateDirectoryAtomically',
        'Move-PshGoal6CandidateFileAtomically',
        'Invoke-PshGoal6CandidateTreeCleanup',
        'Invoke-PshGoal6CandidateCleanupAction',
        'Write-PshGoal6CandidateReportTemp'
    )) {
    . (Get-PshGoal6CandidateFunctionDefinition -Path $candidateScript -Name $functionName)
}
foreach ($functionName in @('Throw-PshReleaseIndexBuildError', 'Invoke-PshReleaseIndexCleanupActions', 'Resolve-PshReleaseIndexFile', 'Copy-PshReleaseIndexFile')) {
    . (Get-PshGoal6CandidateFunctionDefinition -Path $indexScript -Name $functionName)
}

$atomicContractRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $ReportRoot 'atomic-contracts')

$candidateReportHelperText = [string](Get-PshGoal6CandidateFunctionDefinition -Path $candidateScript -Name 'Write-PshGoal6CandidateReportTemp')
$candidateReportDisposeLines = @($candidateReportHelperText -split "`r?`n" | Where-Object { [string]$_ -match '\.Dispose\(\)' })
Assert-PshGoal6CandidateTest ($candidateReportDisposeLines.Count -eq 1 -and @($candidateReportDisposeLines | Where-Object { [string]$_ -notmatch 'Action\s*=' }).Count -eq 0) 'Candidate report helper has a Dispose call outside independent cleanup actions.'
Assert-PshGoal6CandidateTest ($candidateReportHelperText.Contains('Invoke-PshGoal6CandidateCleanupAction') -and $candidateReportHelperText.Contains('PshDisposeDiagnostics')) 'Candidate report helper does not aggregate Dispose failures with diagnostics.'

$releaseCopyHelperText = [string](Get-PshGoal6CandidateFunctionDefinition -Path $indexScript -Name 'Copy-PshReleaseIndexFile')
$releaseCopyDisposeLines = @($releaseCopyHelperText -split "`r?`n" | Where-Object { [string]$_ -match '\.Dispose\(\)' })
Assert-PshGoal6CandidateTest ($releaseCopyDisposeLines.Count -eq 4 -and @($releaseCopyDisposeLines | Where-Object { [string]$_ -notmatch 'Action\s*=' }).Count -eq 0) 'Release catalog copy helper has a Dispose call outside independent cleanup actions.'
Assert-PshGoal6CandidateTest ($releaseCopyHelperText.Contains('Invoke-PshReleaseIndexCleanupActions') -and $releaseCopyHelperText.Contains('PshDisposeDiagnostics')) 'Release catalog copy helper does not aggregate Dispose failures with diagnostics.'

$candidateDiagnosticError = $null
try {
    Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidatePrimary' -Message 'candidate primary failure' -Diagnostics @{ PshDisposeDiagnostics = 'candidate dispose failure' }
}
catch { $candidateDiagnosticError = $_ }
$candidateDiagnosticMetadata = Get-PshGoal6CandidateFailureData -ErrorRecord $candidateDiagnosticError
Assert-PshGoal6CandidateTest ([int]$candidateDiagnosticMetadata.ExitCode -eq 5 -and [string]$candidateDiagnosticMetadata.ErrorId -ceq 'PshGoal6CandidatePrimary') 'Candidate diagnostics replaced primary Psh error metadata.'
Assert-PshGoal6CandidateTest ([string]$candidateDiagnosticError.Exception.Data['PshDisposeDiagnostics'] -ceq 'candidate dispose failure') 'Candidate failure did not retain Dispose diagnostics.'

$indexDiagnosticError = $null
try {
    Throw-PshReleaseIndexBuildError -ExitCode 3 -ErrorId 'PshReleaseIndexPrimary' -Message 'release index primary failure' -Diagnostics @{ PshDisposeDiagnostics = 'index dispose failure' }
}
catch { $indexDiagnosticError = $_ }
$indexDiagnosticMetadata = Get-PshGoal6CandidateFailureData -ErrorRecord $indexDiagnosticError
Assert-PshGoal6CandidateTest ([int]$indexDiagnosticMetadata.ExitCode -eq 3 -and [string]$indexDiagnosticMetadata.ErrorId -ceq 'PshReleaseIndexPrimary') 'Release index diagnostics replaced primary Psh error metadata.'
Assert-PshGoal6CandidateTest ([string]$indexDiagnosticError.Exception.Data['PshDisposeDiagnostics'] -ceq 'index dispose failure') 'Release index failure did not retain Dispose diagnostics.'

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $atomicOwnedRoot = Join-Path $atomicContractRoot 'atomic-owned-root'
    Initialize-PshGoal6CandidateOwnedDirectory -Path $atomicOwnedRoot -Description 'atomic owned root fixture'
    $atomicOwnedEntries = @(Get-ChildItem -LiteralPath $atomicOwnedRoot -Force)
    Assert-PshGoal6CandidateTest ([IO.Directory]::Exists($atomicOwnedRoot) -and $atomicOwnedEntries.Count -eq 0) 'Atomic owned directory creation did not create one empty directory.'

    $preoccupiedOwnedRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $atomicContractRoot 'atomic-owned-root-sentinel')
    $ownedRootSentinelPath = Join-Path $preoccupiedOwnedRoot 'sentinel.bin'
    [IO.File]::WriteAllBytes($ownedRootSentinelPath, [byte[]](21, 22, 23, 24))
    $ownedRootSentinelBefore = Get-PshLifecycleFileSha256 -Path $ownedRootSentinelPath
    Assert-PshGoal6CandidateFailure -Label 'preoccupied atomic owned directory claim' -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Action {
        Initialize-PshGoal6CandidateOwnedDirectory -Path $preoccupiedOwnedRoot -Description 'preoccupied atomic owned root fixture'
    }
    $ownedRootSentinelAfter = Get-PshLifecycleFileSha256 -Path $ownedRootSentinelPath
    Assert-PshGoal6CandidateTest ([int64]$ownedRootSentinelAfter.Length -eq [int64]$ownedRootSentinelBefore.Length -and [string]$ownedRootSentinelAfter.Sha256 -ceq [string]$ownedRootSentinelBefore.Sha256) 'Atomic owned directory claim changed the preoccupied sentinel.'
}

$candidateMoveSource = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $atomicContractRoot 'candidate-staging')
Write-PshGoal6CandidateTestText -Path (Join-Path $candidateMoveSource 'owned.txt') -Text "owned candidate bytes`n"
$preoccupiedCandidateRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $atomicContractRoot 'candidate-root-sentinel')
$candidateSentinelPath = Join-Path $preoccupiedCandidateRoot 'sentinel.bin'
[IO.File]::WriteAllBytes($candidateSentinelPath, [byte[]](0, 1, 2, 3, 254, 255))
$candidateSentinelBefore = Get-PshLifecycleFileSha256 -Path $candidateSentinelPath
Assert-PshGoal6CandidateFailure -Label 'preoccupied candidate root atomic move' -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Action {
    Move-PshGoal6CandidateDirectoryAtomically -Source $candidateMoveSource -Destination $preoccupiedCandidateRoot -Description 'candidate root'
}
$candidateSentinelAfter = Get-PshLifecycleFileSha256 -Path $candidateSentinelPath
$candidateSentinelEntries = @(Get-ChildItem -LiteralPath $preoccupiedCandidateRoot -Force)
Assert-PshGoal6CandidateTest ([IO.Directory]::Exists($candidateMoveSource)) 'Preoccupied CandidateRoot consumed the owned staging directory.'
Assert-PshGoal6CandidateTest ($candidateSentinelEntries.Count -eq 1 -and [string]$candidateSentinelEntries[0].Name -ceq 'sentinel.bin') 'Preoccupied CandidateRoot contents changed.'
Assert-PshGoal6CandidateTest ([int64]$candidateSentinelAfter.Length -eq [int64]$candidateSentinelBefore.Length -and [string]$candidateSentinelAfter.Sha256 -ceq [string]$candidateSentinelBefore.Sha256) 'Preoccupied CandidateRoot sentinel bytes changed.'

$reportMoveSource = Join-Path $atomicContractRoot 'candidate-report.tmp'
$preoccupiedReportPath = Join-Path $atomicContractRoot 'candidate-report.json'
Write-PshGoal6CandidateTestText -Path $reportMoveSource -Text "owned report bytes`n"
[IO.File]::WriteAllBytes($preoccupiedReportPath, [byte[]](9, 8, 7, 6, 5, 4))
$reportSentinelBefore = Get-PshLifecycleFileSha256 -Path $preoccupiedReportPath
Assert-PshGoal6CandidateFailure -Label 'preoccupied report atomic move' -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Action {
    Move-PshGoal6CandidateFileAtomically -Source $reportMoveSource -Destination $preoccupiedReportPath -Description 'candidate report'
}
$reportSentinelAfter = Get-PshLifecycleFileSha256 -Path $preoccupiedReportPath
Assert-PshGoal6CandidateTest ([IO.File]::Exists($reportMoveSource)) 'Preoccupied ReportPath consumed the owned report temp file.'
Assert-PshGoal6CandidateTest ([int64]$reportSentinelAfter.Length -eq [int64]$reportSentinelBefore.Length -and [string]$reportSentinelAfter.Sha256 -ceq [string]$reportSentinelBefore.Sha256) 'Preoccupied ReportPath sentinel bytes changed.'

$reportCreateNewCollisionPath = Join-Path $atomicContractRoot '.candidate-report.json.tmp-collision'
[IO.File]::WriteAllBytes($reportCreateNewCollisionPath, [byte[]](31, 32, 33, 34))
$reportCreateNewSentinelBefore = Get-PshLifecycleFileSha256 -Path $reportCreateNewCollisionPath
Assert-PshGoal6CandidateFailure -Label 'candidate report CreateNew collision' -ExitCode 3 -ErrorId 'PshGoal6CandidateReportWrite' -Action {
    Write-PshGoal6CandidateReportTemp -Path $reportCreateNewCollisionPath -Value ([pscustomobject][ordered]@{ status = 'must-not-overwrite' })
}
$reportCreateNewSentinelAfter = Get-PshLifecycleFileSha256 -Path $reportCreateNewCollisionPath
Assert-PshGoal6CandidateTest ([int64]$reportCreateNewSentinelAfter.Length -eq [int64]$reportCreateNewSentinelBefore.Length -and [string]$reportCreateNewSentinelAfter.Sha256 -ceq [string]$reportCreateNewSentinelBefore.Sha256) 'Candidate report CreateNew collision changed or removed the sentinel.'

foreach ($overlapCase in @(
        [pscustomobject]@{
            Label = 'ReportPath ancestor of CandidateRoot'
            Report = (Join-Path $atomicContractRoot 'candidate-report-ancestor')
            Candidate = (Join-Path (Join-Path $atomicContractRoot 'candidate-report-ancestor') 'candidate')
            Working = (Join-Path $atomicContractRoot 'candidate-report-other-working')
        },
        [pscustomobject]@{
            Label = 'ReportPath ancestor of WorkingRoot'
            Report = (Join-Path $atomicContractRoot 'working-report-ancestor')
            Candidate = (Join-Path $atomicContractRoot 'working-report-other-candidate')
            Working = (Join-Path (Join-Path $atomicContractRoot 'working-report-ancestor') 'working')
        }
    )) {
    Assert-PshGoal6CandidateFailure -Label ([string]$overlapCase.Label) -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputOverlap' -Action {
        Assert-PshGoal6CandidateOutputIsolation -CandidateRoot ([string]$overlapCase.Candidate) -ReportPath ([string]$overlapCase.Report) -WorkingRoot ([string]$overlapCase.Working) -RepositoryRoot $RepositoryRoot
    }
    foreach ($path in @([string]$overlapCase.Report, [string]$overlapCase.Candidate, [string]$overlapCase.Working)) {
        Assert-PshGoal6CandidateTest (-not [IO.File]::Exists($path) -and -not [IO.Directory]::Exists($path)) "$($overlapCase.Label) left output residue: $path"
    }
}

$cleanupRefusalRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $atomicContractRoot 'cleanup-refusal')
[void](Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $cleanupRefusalRoot 'allowed'))
$cleanupSentinelPath = Join-Path $cleanupRefusalRoot 'unexpected-sentinel.bin'
[IO.File]::WriteAllBytes($cleanupSentinelPath, [byte[]](10, 20, 30, 40))
$cleanupSentinelBefore = Get-PshLifecycleFileSha256 -Path $cleanupSentinelPath
Assert-PshGoal6CandidateFailure -Label 'cleanup unexpected ordinary top-level sentinel' -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Action {
    Invoke-PshGoal6CandidateTreeCleanup -Path $cleanupRefusalRoot -Description 'cleanup refusal fixture' -AllowedDirectories @('allowed')
}
$cleanupSentinelAfter = Get-PshLifecycleFileSha256 -Path $cleanupSentinelPath
Assert-PshGoal6CandidateTest ([IO.Directory]::Exists($cleanupRefusalRoot) -and [IO.Directory]::Exists((Join-Path $cleanupRefusalRoot 'allowed'))) 'Cleanup refusal removed an owned tree containing an unexpected entry.'
Assert-PshGoal6CandidateTest ([int64]$cleanupSentinelAfter.Length -eq [int64]$cleanupSentinelBefore.Length -and [string]$cleanupSentinelAfter.Sha256 -ceq [string]$cleanupSentinelBefore.Sha256) 'Cleanup refusal changed the unexpected sentinel bytes.'

$cleanupOrder = New-Object System.Collections.Generic.List[string]
$cleanupActionFailures = @(Invoke-PshGoal6CandidateCleanupAction -Actions @(
        [pscustomobject]@{ Label = 'first'; Action = { $cleanupOrder.Add('first'); throw 'first cleanup failed' } },
        [pscustomobject]@{ Label = 'second'; Action = { $cleanupOrder.Add('second') } },
        [pscustomobject]@{ Label = 'third'; Action = { $cleanupOrder.Add('third') } }
    ))
Assert-PshGoal6CandidateTest ($cleanupActionFailures.Count -eq 1 -and [string]$cleanupActionFailures[0].Label -ceq 'first') 'Cleanup aggregation did not retain exactly the first action failure.'
Assert-PshGoal6CandidateTest ([string]::Join(',', $cleanupOrder.ToArray()) -ceq 'first,second,third') 'Cleanup aggregation stopped before executing later actions.'

$indexDisposeOrder = New-Object System.Collections.Generic.List[string]
$indexDisposeFailures = @(Invoke-PshReleaseIndexCleanupActions -Actions @(
        [pscustomobject]@{ Label = 'temporary stream'; Action = { $indexDisposeOrder.Add('temporary'); throw 'temporary stream dispose failed' } },
        [pscustomobject]@{ Label = 'source stream'; Action = { $indexDisposeOrder.Add('source') } },
        [pscustomobject]@{ Label = 'hash'; Action = { $indexDisposeOrder.Add('hash') } }
    ))
Assert-PshGoal6CandidateTest ($indexDisposeFailures.Count -eq 1 -and [string]$indexDisposeFailures[0].Label -ceq 'temporary stream') 'Release index Dispose aggregation did not retain exactly the first failure.'
Assert-PshGoal6CandidateTest ([string]::Join(',', $indexDisposeOrder.ToArray()) -ceq 'temporary,source,hash') 'Release index Dispose aggregation stopped before closing later resources.'

$catalogSourcePath = Join-Path $atomicContractRoot 'verified-release.cat'
$catalogDestinationPath = Join-Path $atomicContractRoot 'psh-release-1.2.3.cat'
[IO.File]::WriteAllBytes($catalogSourcePath, [byte[]](1, 3, 3, 7, 9, 11))
[IO.File]::WriteAllBytes($catalogDestinationPath, [byte[]](42, 42, 42, 42))
$catalogSentinelBefore = Get-PshLifecycleFileSha256 -Path $catalogDestinationPath
Assert-PshGoal6CandidateFailure -Label 'atomic release catalog destination sentinel' -ExitCode 5 -ErrorId 'PshReleaseIndexOutputExists' -Action {
    Copy-PshReleaseIndexFile -Source $catalogSourcePath -Destination $catalogDestinationPath -Description 'membership-verified release catalog'
}
$catalogSentinelAfter = Get-PshLifecycleFileSha256 -Path $catalogDestinationPath
$catalogTemporaryEntries = @(Get-ChildItem -LiteralPath $atomicContractRoot -Force | Where-Object { [string]$_.Name -like '.psh-release-1.2.3.cat.tmp-*' })
Assert-PshGoal6CandidateTest ([int64]$catalogSentinelAfter.Length -eq [int64]$catalogSentinelBefore.Length -and [string]$catalogSentinelAfter.Sha256 -ceq [string]$catalogSentinelBefore.Sha256) 'Atomic release catalog publication overwrote the destination sentinel.'
Assert-PshGoal6CandidateTest ($catalogTemporaryEntries.Count -eq 0) 'Atomic release catalog publication retained a temp or partial file.'

Invoke-PshGoal6CandidateTestTreeCleanup -Path $atomicContractRoot

$fixtureRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $ReportRoot 'fixtures')
$bootstrapperPath = Join-Path $fixtureRoot 'psh-installer.exe'
$releaseNotesPath = Join-Path $fixtureRoot 'RELEASE_NOTES.md'
$releaseNotesZhCnPath = Join-Path $fixtureRoot 'RELEASE_NOTES.zh-CN.md'
Initialize-PshGoal6CandidatePeFixture -Path $bootstrapperPath
Write-PshGoal6CandidateTestText -Path $releaseNotesPath -Text "# Goal 6 candidate 1.2.3`n"
Write-PshGoal6CandidateTestText -Path $releaseNotesZhCnPath -Text "# Goal 6 candidate zh-CN 1.2.3`n"
$version = '1.2.3'
$commit = '1234567890abcdef1234567890abcdef12345678'
$candidateRoot = Join-Path $ReportRoot 'candidate'
$candidateReportPath = Join-Path $ReportRoot 'candidate-report.json'
$workingRoot = Join-Path $ReportRoot 'candidate-working'
$driverParameters = @{
    CandidateRoot = $candidateRoot
    ReportPath = $candidateReportPath
    Version = $version
    SourceCommit = $commit
    BootstrapperPath = $bootstrapperPath
    ReleaseNotesPath = $releaseNotesPath
    ReleaseNotesZhCnPath = $releaseNotesZhCnPath
    RepositoryRoot = $RepositoryRoot
    WorkingRoot = $workingRoot
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Assert-PshGoal6CandidateFailure -Label 'non-Windows candidate creation' -ExitCode 4 -ErrorId 'PshGoal6CandidateCatalogUnavailable' -Action {
        & $candidateScript @driverParameters
    }
    Assert-PshGoal6CandidateTest (-not [IO.File]::Exists($candidateRoot) -and -not [IO.Directory]::Exists($candidateRoot)) 'Non-Windows candidate boundary created a candidate root.'
    Assert-PshGoal6CandidateTest (-not [IO.File]::Exists($candidateReportPath) -and -not [IO.Directory]::Exists($candidateReportPath)) 'Non-Windows candidate boundary created a report.'
    $summary = [pscustomobject][ordered]@{
        schemaVersion = 1
        gate = 'goal6-candidate-artifacts'
        platform = 'non-windows'
        status = 'passed'
        assertions = $script:Goal6CandidateAssertions
        windowsCatalogCasesExecuted = $false
        atomicPublicationCasesExecuted = $true
        windowsAtomicDirectoryCasesExecuted = $false
        platformBoundaryCode = 4
        platformBoundaryErrorId = 'PshGoal6CandidateCatalogUnavailable'
    }
    $summaryPath = Join-Path $ReportRoot 'Goal6.CandidateArtifacts.summary.json'
    Write-PshGoal6CandidateTestText -Path $summaryPath -Text ((ConvertTo-PshCanonicalJson -InputObject $summary) + "`n")
    Write-Output ("Goal 6 candidate artifacts non-Windows boundary passed ({0} assertions); report: {1}" -f $script:Goal6CandidateAssertions, $summaryPath)
    return
}

$catalogCommand = Get-Command -Name New-FileCatalog -CommandType Cmdlet -ErrorAction Stop
$catalogTestCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction Stop
Assert-PshGoal6CandidateTest ($null -ne $catalogCommand -and $null -ne $catalogTestCommand) 'Windows catalog commands are unavailable.'
$driverResult = @(& $candidateScript @driverParameters)[-1]
Assert-PshGoal6CandidateTest ([int]$driverResult.code -eq 0 -and [string]$driverResult.phase -ceq 'candidate-verified') 'Candidate driver returned an unexpected phase or code.'
Assert-PshGoal6CandidateTest ([bool]$driverResult.catalogMembershipVerified -and [int]$driverResult.assetCount -eq 13 -and [int]$driverResult.packageCount -eq 3) 'Candidate driver did not enforce the exact catalog/asset/package contract.'
Assert-PshGoal6CandidateTest (-not [IO.Directory]::Exists($workingRoot) -and -not [IO.File]::Exists($workingRoot)) 'Candidate driver retained its controlled working root.'

$expectedNames = @(
    'install.ps1', 'install.sh', 'psh-installer.exe',
    "psh-$version-core.zip", "psh-$version-full-win-x64.zip", "psh-$version-full-win-arm64.zip",
    'sbom.spdx.json', 'THIRD_PARTY_NOTICES.md', 'RELEASE_NOTES.md', 'RELEASE_NOTES.zh-CN.md',
    "psh-release-$version.json", 'SHA256SUMS', "psh-release-$version.cat"
)
$actualEntries = @(Get-ChildItem -LiteralPath $candidateRoot -Force)
Assert-PshGoal6CandidateTest ($actualEntries.Count -eq 13 -and @($actualEntries | Where-Object { $_.PSIsContainer -or (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) }).Count -eq 0) 'Candidate root does not contain exactly 13 regular files.'
foreach ($expectedName in $expectedNames) {
    Assert-PshGoal6CandidateTest (@($actualEntries | Where-Object { [string]$_.Name -ceq $expectedName }).Count -eq 1) "Candidate root is missing exact asset '$expectedName'."
}
Assert-PshGoal6CandidateTest (@($actualEntries | Where-Object { [string]$_.Extension -ieq '.zip' }).Count -eq 3) 'Candidate root does not contain exactly three ZIP packages.'
$candidateReport = Read-PshStrictJsonSnapshot -Path $candidateReportPath -Description 'Goal 6 candidate report'
Assert-PshGoal6CandidateTest ([string]$candidateReport.Document.phase -ceq 'candidate-verified' -and [int]$candidateReport.Document.code -eq 0) 'Candidate JSON report has an unexpected phase or code.'
Assert-PshGoal6CandidateTest ([string]$candidateReport.Document.assetContract -ceq 'exact-13-public-assets-before-provenance-attestation') 'Candidate JSON report lost the exact asset contract.'
Assert-PshGoal6CandidateTest ([string]$candidateReport.Document.provenanceAttestation -ceq 'external-workflow-gate') 'Candidate JSON report fabricated or absorbed provenance attestation.'
Assert-PshGoal6CandidateTest ([bool]$candidateReport.Document.authenticodeStatus.informationalOnly) 'Candidate report did not mark Authenticode status as informational only.'
$releaseAuthenticodeStatus = [string]$candidateReport.Document.authenticodeStatus.releaseCatalog
Assert-PshGoal6CandidateTest (-not [string]::IsNullOrWhiteSpace($releaseAuthenticodeStatus) -and $releaseAuthenticodeStatus -cne 'Valid') 'Unsigned release catalog Authenticode status is missing or was incorrectly reported as Valid.'
$packageAuthenticodeStatuses = @($candidateReport.Document.authenticodeStatus.packageCatalogs)
Assert-PshGoal6CandidateTest ($packageAuthenticodeStatuses.Count -eq 3 -and @($packageAuthenticodeStatuses | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.status) -or [string]$_.status -ceq 'Valid' }).Count -eq 0) 'The three unsigned package catalog Authenticode statuses are missing or were incorrectly reported as Valid.'

$wrongReleaseRoot = Join-Path $ReportRoot 'negative-release-catalog'
Copy-PshGoal6CandidateTestRoot -Source $candidateRoot -Destination $wrongReleaseRoot
[IO.File]::Delete((Join-Path $wrongReleaseRoot "psh-release-$version.cat"))
$wrongReleaseCatalog = Join-Path $ReportRoot 'wrong-release.cat'
[void](Invoke-PshGoal6CandidateTestCatalogCreation -CatalogCommand $catalogCommand -Members @(
        [pscustomobject]@{ Name = "psh-release-$version.json"; SourcePath = (Join-Path $wrongReleaseRoot "psh-release-$version.json") }
    ) -ContentRoot (Join-Path $ReportRoot 'wrong-release-input') -CatalogPath $wrongReleaseCatalog)
Assert-PshGoal6CandidateFailure -Label 'release index finalize catalog membership mismatch' -ExitCode 5 -ErrorId 'PshReleaseCatalogMembership' -Action {
    & $indexScript -ReleaseAssetsRoot $wrongReleaseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Finalize -ReleaseCatalogPath $wrongReleaseCatalog
}
Assert-PshGoal6CandidateTest (-not [IO.File]::Exists((Join-Path $wrongReleaseRoot "psh-release-$version.cat"))) 'Failed release catalog finalization published a catalog.'
Invoke-PshGoal6CandidateTestTreeCleanup -Path $wrongReleaseRoot

$wrongArtifactReleaseRoot = Join-Path $ReportRoot 'negative-artifact-release-catalog'
Copy-PshGoal6CandidateTestRoot -Source $candidateRoot -Destination $wrongArtifactReleaseRoot
[IO.File]::Delete((Join-Path $wrongArtifactReleaseRoot "psh-release-$version.cat"))
[IO.File]::Copy($wrongReleaseCatalog, (Join-Path $wrongArtifactReleaseRoot "psh-release-$version.cat"), $false)
Assert-PshGoal6CandidateFailure -Label 'release artifact catalog membership mismatch' -ExitCode 5 -ErrorId 'PshReleaseCatalogMembership' -Action {
    & $artifactScript -ReleaseAssetsRoot $wrongArtifactReleaseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode Release
}
Invoke-PshGoal6CandidateTestTreeCleanup -Path $wrongArtifactReleaseRoot

$wrongPackageRoot = Join-Path $ReportRoot 'negative-package-catalog'
Copy-PshGoal6CandidateTestRoot -Source $candidateRoot -Destination $wrongPackageRoot
$coreZipName = "psh-$version-core.zip"
$x64ZipName = "psh-$version-full-win-x64.zip"
$x64CatalogBytes = Get-PshGoal6CandidateZipEntryContent -Path (Join-Path $wrongPackageRoot $x64ZipName) -EntryName 'package.manifest.cat'
Invoke-PshGoal6CandidateZipEntryRewrite -Path (Join-Path $wrongPackageRoot $coreZipName) -EntryName 'package.manifest.cat' -Bytes $x64CatalogBytes
Write-PshGoal6CandidateMutationState -Root $wrongPackageRoot -Version $version -AssetName $coreZipName
$replacementReleaseCatalog = Join-Path $ReportRoot 'replacement-release.cat'
[void](Invoke-PshGoal6CandidateTestCatalogCreation -CatalogCommand $catalogCommand -Members @(
        [pscustomobject]@{ Name = "psh-release-$version.json"; SourcePath = (Join-Path $wrongPackageRoot "psh-release-$version.json") },
        [pscustomobject]@{ Name = 'SHA256SUMS'; SourcePath = (Join-Path $wrongPackageRoot 'SHA256SUMS') }
    ) -ContentRoot (Join-Path $ReportRoot 'replacement-release-input') -CatalogPath $replacementReleaseCatalog)
[IO.File]::Delete((Join-Path $wrongPackageRoot "psh-release-$version.cat"))
[IO.File]::Copy($replacementReleaseCatalog, (Join-Path $wrongPackageRoot "psh-release-$version.cat"), $false)
Assert-PshGoal6CandidateFailure -Label 'package manifest catalog membership mismatch' -ExitCode 5 -ErrorId 'PshReleasePackageCatalogMembership' -Action {
    & $artifactScript -ReleaseAssetsRoot $wrongPackageRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode Release
}
Invoke-PshGoal6CandidateTestTreeCleanup -Path $wrongPackageRoot

$buildCatalogRoot = Initialize-PshGoal6CandidateTestDirectory -Path (Join-Path $ReportRoot 'negative-build-catalogs')
foreach ($slot in @('core', 'full-win-x64', 'full-win-arm64')) {
    $packageName = "psh-$version-$slot"
    $catalogBytes = Get-PshGoal6CandidateZipEntryContent -Path (Join-Path $candidateRoot ($packageName + '.zip')) -EntryName 'package.manifest.cat'
    [IO.File]::WriteAllBytes((Join-Path $buildCatalogRoot ($packageName + '.manifest.cat')), $catalogBytes)
}
$coreCatalogPath = Join-Path $buildCatalogRoot "psh-$version-core.manifest.cat"
$x64CatalogPath = Join-Path $buildCatalogRoot "psh-$version-full-win-x64.manifest.cat"
[IO.File]::WriteAllBytes($x64CatalogPath, [IO.File]::ReadAllBytes($coreCatalogPath))
$negativeBuildRoot = Join-Path $ReportRoot 'negative-build-output'
$negativeBuildParameters = @{
    OutputRoot = $negativeBuildRoot
    Version = $version
    SourceCommit = $commit
    OnlineInstallerPath = (Join-Path $RepositoryRoot 'src/install/install.ps1')
    OfflineInstallerPath = (Join-Path $RepositoryRoot 'src/install/install-offline.ps1')
    ShellInstallerPath = (Join-Path $RepositoryRoot 'src/install/install.sh')
    UninstallerPath = (Join-Path $RepositoryRoot 'src/install/Uninstall-Psh.ps1')
    BootstrapperPath = $bootstrapperPath
    ReleaseNotesPath = $releaseNotesPath
    ReleaseNotesZhCnPath = $releaseNotesZhCnPath
    RepositoryRoot = $RepositoryRoot
    Finalize = $true
    PackageCatalogRoot = $buildCatalogRoot
}
Assert-PshGoal6CandidateFailure -Label 'package build catalog membership mismatch' -ExitCode 5 -ErrorId 'PshPackageBuildCatalogMembership' -Action {
    & $buildScript @negativeBuildParameters
}
Invoke-PshGoal6CandidateTestTreeCleanup -Path $negativeBuildRoot
Invoke-PshGoal6CandidateTestTreeCleanup -Path $buildCatalogRoot
Invoke-PshGoal6CandidateTestTreeCleanup -Path (Join-Path $ReportRoot 'wrong-release-input')
Invoke-PshGoal6CandidateTestTreeCleanup -Path (Join-Path $ReportRoot 'replacement-release-input')
foreach ($temporaryCatalog in @($wrongReleaseCatalog, $replacementReleaseCatalog)) {
    if ([IO.File]::Exists($temporaryCatalog)) { [IO.File]::Delete($temporaryCatalog) }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'goal6-candidate-artifacts'
    platform = 'windows'
    status = 'passed'
    assertions = $script:Goal6CandidateAssertions
    candidateRoot = $candidateRoot
    candidateReport = $candidateReportPath
    assetCount = 13
    packageCount = 3
    catalogMembershipVerified = $true
    authenticodeIsInformational = $true
    negativeCases = @(
        'preoccupied-candidate-root',
        'preoccupied-report-path',
        'report-createnew-collision',
        'report-path-ancestor-overlap',
        'cleanup-unexpected-top-level-entry',
        'cleanup-action-aggregation',
        'atomic-release-catalog-destination',
        'release-index-catalog-membership',
        'release-artifact-catalog-membership',
        'package-artifact-catalog-membership',
        'package-build-catalog-membership'
    )
    windowsAtomicDirectoryCasesExecuted = $true
    provenanceAttestation = 'not-created-by-this-gate'
}
$summaryPath = Join-Path $ReportRoot 'Goal6.CandidateArtifacts.summary.json'
Write-PshGoal6CandidateTestText -Path $summaryPath -Text ((ConvertTo-PshCanonicalJson -InputObject $summary) + "`n")
Write-Output ("Goal 6 candidate artifacts passed ({0} assertions); candidate: {1}; report: {2}" -f $script:Goal6CandidateAssertions, $candidateRoot, $summaryPath)
