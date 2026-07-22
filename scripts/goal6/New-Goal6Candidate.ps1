# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateRoot,
    [Parameter(Mandatory = $true)][string] $ReportPath,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $BootstrapperPath,
    [Parameter(Mandatory = $true)][string] $ReleaseNotesPath,
    [Parameter(Mandatory = $true)][string] $ReleaseNotesZhCnPath,
    [string] $RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [AllowNull()][string] $WorkingRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
if (-not [IO.File]::Exists($lifecyclePath)) { throw "Package lifecycle helpers were not found: $lifecyclePath" }
. $lifecyclePath

function Invoke-PshGoal6CandidateFailure {
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][Exception] $InnerException,
        [AllowNull()][hashtable] $Diagnostics
    )

    $exception = if ($null -eq $InnerException) { New-Object Exception($Message) } else { New-Object Exception($Message, $InnerException) }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorId'] = $ErrorId
    if ($null -ne $Diagnostics) {
        foreach ($key in @($Diagnostics.Keys)) { $exception.Data[[string]$key] = $Diagnostics[$key] }
    }
    throw $exception
}

function Resolve-PshGoal6CandidateFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 4 -ErrorId 'PshGoal6CandidateInputMissing' -Message "$Description must be an existing regular non-reparse file: $full"
    }
    return $full
}

function Resolve-PshGoal6CandidateDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 4 -ErrorId 'PshGoal6CandidateInputMissing' -Message "$Description must be an existing non-reparse directory: $full"
    }
    return $full
}

function Assert-PshGoal6CandidateOutputPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Message "$Description already exists and will not be overwritten: $full"
    }
    return $full
}

function Initialize-PshGoal6CandidateNativeMethods {
    if ($null -ne ('PshGoal6CandidateNativeMethods' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PshGoal6CandidateNativeMethods
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectory(string path, IntPtr securityAttributes);
}
'@
}

function New-PshGoal6CandidateOwnedDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    $parent = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "$Description must have a parent directory: $Path"
    }
    try {
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [void](Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description)
        Initialize-PshGoal6CandidateNativeMethods
    }
    catch {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "Unable to prepare ${Description}: $Path" -InnerException $_.Exception
    }

    if (-not [PshGoal6CandidateNativeMethods]::CreateDirectory($Path, [IntPtr]::Zero)) {
        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $inner = New-Object System.ComponentModel.Win32Exception($nativeError)
        if ($nativeError -eq 80 -or $nativeError -eq 183) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Message "$Description appeared concurrently and will not be adopted: $Path" -InnerException $inner
        }
        Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateOutputCreate' -Message "Unable to create ${Description}: $Path" -InnerException $inner
    }
}

function New-PshGoal6CandidateUniqueSiblingPath {
    param(
        [Parameter(Mandatory = $true)][string] $DestinationPath,
        [Parameter(Mandatory = $true)][string] $Purpose
    )

    $parent = [IO.Path]::GetDirectoryName($DestinationPath)
    $name = [IO.Path]::GetFileName($DestinationPath)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($name)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "Unable to derive a sibling $Purpose path from: $DestinationPath"
    }
    return Join-Path $parent ('.' + $name + '.' + $Purpose + '-' + [Guid]::NewGuid().ToString('N'))
}

function Move-PshGoal6CandidateDirectoryAtomically {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Description
    )

    try { [IO.Directory]::Move($Source, $Destination) }
    catch {
        if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Message "$Description appeared concurrently and will not be overwritten: $Destination" -InnerException $_.Exception
        }
        Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidatePublish' -Message "Unable to publish ${Description}: $Destination" -InnerException $_.Exception
    }
}

function Move-PshGoal6CandidateFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Description
    )

    try { [IO.File]::Move($Source, $Destination) }
    catch {
        if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputExists' -Message "$Description appeared concurrently and will not be overwritten: $Destination" -InnerException $_.Exception
        }
        Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidatePublish' -Message "Unable to publish ${Description}: $Destination" -InnerException $_.Exception
    }
}

function Test-PshGoal6CandidateContainedPath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    return $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, (Get-PshLifecyclePathComparison))
}

function Test-PshGoal6CandidateSamePath {
    param([Parameter(Mandatory = $true)][string] $First, [Parameter(Mandatory = $true)][string] $Second)

    $firstFull = [IO.Path]::GetFullPath($First).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $secondFull = [IO.Path]::GetFullPath($Second).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [string]::Equals($firstFull, $secondFull, (Get-PshLifecyclePathComparison))
}

function Assert-PshGoal6CandidateOutputIsolation {
    param(
        [Parameter(Mandatory = $true)][string] $CandidateRoot,
        [Parameter(Mandatory = $true)][string] $ReportPath,
        [Parameter(Mandatory = $true)][string] $WorkingRoot,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot
    )

    if ((Test-PshGoal6CandidateSamePath -First $CandidateRoot -Second $WorkingRoot) -or
        (Test-PshGoal6CandidateSamePath -First $CandidateRoot -Second $ReportPath) -or
        (Test-PshGoal6CandidateSamePath -First $WorkingRoot -Second $ReportPath)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputOverlap' -Message 'CandidateRoot, WorkingRoot, and ReportPath must be distinct.'
    }
    foreach ($pair in @(
            [pscustomobject]@{ Root = $CandidateRoot; Path = $WorkingRoot },
            [pscustomobject]@{ Root = $WorkingRoot; Path = $CandidateRoot },
            [pscustomobject]@{ Root = $CandidateRoot; Path = $ReportPath },
            [pscustomobject]@{ Root = $ReportPath; Path = $CandidateRoot },
            [pscustomobject]@{ Root = $WorkingRoot; Path = $ReportPath },
            [pscustomobject]@{ Root = $ReportPath; Path = $WorkingRoot },
            [pscustomobject]@{ Root = $RepositoryRoot; Path = $CandidateRoot },
            [pscustomobject]@{ Root = $RepositoryRoot; Path = $WorkingRoot },
            [pscustomobject]@{ Root = $RepositoryRoot; Path = $ReportPath }
        )) {
        if (Test-PshGoal6CandidateContainedPath -Root ([string]$pair.Root) -Path ([string]$pair.Path)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputOverlap' -Message 'Candidate, report, working, and repository paths must not overlap.'
        }
    }
}

function Invoke-PshGoal6CandidateTreeCleanup {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [AllowEmptyCollection()][string[]] $AllowedFiles = @(),
        [AllowEmptyCollection()][string[]] $AllowedDirectories = @(),
        [switch] $RequireAll
    )

    $entry = Get-PshLifecyclePathEntry -Path $Path -Description $Description
    if (-not [bool]$entry.Exists) { return }
    if (-not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description changed to an unsafe entry: $Path"
    }
    $fileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $directoryNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($AllowedFiles)) {
        if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -cne $name -or
            -not $fileNames.Add($name) -or $directoryNames.Contains($name)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description has an invalid cleanup file allowlist entry: $name"
        }
    }
    foreach ($name in @($AllowedDirectories)) {
        if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -cne $name -or
            -not $directoryNames.Add($name) -or $fileNames.Contains($name)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description has an invalid cleanup directory allowlist entry: $name"
        }
    }
    try { $topLevelEntries = @(Get-ChildItem -LiteralPath $Path -Force) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateCleanupInspect' -Message "Unable to inspect ${Description}: $Path" -InnerException $_.Exception }
    foreach ($child in $topLevelEntries) {
        $isReparse = (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $allowed = if ($child.PSIsContainer) { $directoryNames.Contains([string]$child.Name) } else { $fileNames.Contains([string]$child.Name) }
        if ($isReparse -or -not $allowed) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description contains an unexpected, wrong-type, or reparse top-level entry and will not be recursively removed: $($child.FullName)"
        }
    }
    if ($RequireAll -and $topLevelEntries.Count -ne ($fileNames.Count + $directoryNames.Count)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description no longer contains its exact owned top-level set: $Path"
    }
    # Ordinary descendants remain inside atomically claimed roots; reparse points are the only filesystem escape.
    try { $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -Force) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateCleanupInspect' -Message "Unable to inspect ${Description}: $Path" -InnerException $_.Exception }
    foreach ($child in $entries) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "$Description contains a reparse point and will not be recursively removed: $($child.FullName)"
        }
    }
    try { [IO.Directory]::Delete($Path, $true) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateCleanup' -Message "Unable to remove ${Description}: $Path" -InnerException $_.Exception }
}

function Invoke-PshGoal6CandidateReportCleanup {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowNull()][object] $ExpectedState
    )

    $entry = Get-PshLifecyclePathEntry -Path $Path -Description 'candidate report'
    if (-not [bool]$entry.Exists) { return }
    if (-not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "Candidate report changed to an unsafe entry: $Path"
    }
    if ($null -ne $ExpectedState) {
        $actual = Get-PshLifecycleFileSha256 -Path $Path
        if ([int64]$actual.Length -ne [int64]$ExpectedState.Length -or [string]$actual.Sha256 -cne [string]$ExpectedState.Sha256) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "Candidate report no longer matches the file published by this invocation: $Path"
        }
    }
    try { [IO.File]::Delete($Path) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateCleanup' -Message "Unable to remove candidate report: $Path" -InnerException $_.Exception }
}

function Invoke-PshGoal6CandidateCleanupActions {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Actions)

    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Actions)) {
        $label = [string]$item.Label
        try {
            $action = [scriptblock]$item.Action
            & $action | Out-Null
        }
        catch {
            $failures.Add([pscustomobject][ordered]@{
                    Label = $label
                    Message = [string]$_.Exception.Message
                    ErrorRecord = $_
                })
        }
    }
    return $failures.ToArray()
}

function Assert-PshGoal6CandidateExactFileSet {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string[]] $ExpectedNames,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ExpectedNames) {
        if (-not $expected.Add($name)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateContract' -Message "$Description contains a duplicate expected name: $name"
        }
    }
    try { $entries = @(Get-ChildItem -LiteralPath $Root -Force) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateInspect' -Message "Unable to inspect ${Description}: $Root" -InnerException $_.Exception }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or -not $expected.Contains([string]$entry.Name)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateContract' -Message "$Description contains an unexpected, non-file, or reparse entry: $($entry.Name)"
        }
    }
    if ($entries.Count -ne $expected.Count) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateContract' -Message "$Description does not contain exactly $($expected.Count) required files."
    }
}

function Invoke-PshGoal6CandidatePublishedCleanup {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object[]] $ExpectedAssets
    )

    $expectedNames = @($ExpectedAssets | ForEach-Object { [string]$_.name })
    Assert-PshGoal6CandidateExactFileSet -Root $Path -ExpectedNames $expectedNames -Description 'published candidate root'
    foreach ($asset in $ExpectedAssets) {
        $assetPath = Join-Path $Path ([string]$asset.name)
        $actual = Get-PshLifecycleFileSha256 -Path $assetPath
        if ([int64]$actual.Length -ne [int64]$asset.length -or [string]$actual.Sha256 -cne [string]$asset.sha256) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCleanupUnsafe' -Message "Published candidate asset no longer matches this invocation and will not be removed: $assetPath"
        }
    }
    Invoke-PshGoal6CandidateTreeCleanup -Path $Path -Description 'published candidate root' -AllowedFiles $expectedNames -RequireAll
}

function Invoke-PshGoal6CandidateCatalogBuild {
    param(
        [Parameter(Mandatory = $true)][object] $CatalogCommand,
        [Parameter(Mandatory = $true)][string] $ContentRoot,
        [Parameter(Mandatory = $true)][object[]] $Members,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ([IO.File]::Exists($ContentRoot) -or [IO.Directory]::Exists($ContentRoot) -or [IO.File]::Exists($CatalogPath) -or [IO.Directory]::Exists($CatalogPath)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCatalogOutputExists' -Message "$Description staging output already exists."
    }
    [void][IO.Directory]::CreateDirectory($ContentRoot)
    $contentEntry = Get-PshLifecyclePathEntry -Path $ContentRoot -Description "$Description content root"
    if (-not [bool]$contentEntry.IsDirectory -or [bool]$contentEntry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCatalogMember' -Message "$Description content root is unsafe: $ContentRoot"
    }
    $expectedNames = New-Object System.Collections.Generic.List[string]
    foreach ($member in $Members) {
        $name = [string]$member.Name
        if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -cne $name -or $expectedNames.Contains($name)) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCatalogMember' -Message "$Description has an invalid or duplicate member name: $name"
        }
        $expectedNames.Add($name)
        $source = Resolve-PshGoal6CandidateFile -Path ([string]$member.SourcePath) -Description "$Description member '$name'"
        [IO.File]::Copy($source, (Join-Path $ContentRoot $name), $false)
    }
    Assert-PshGoal6CandidateExactFileSet -Root $ContentRoot -ExpectedNames $expectedNames.ToArray() -Description "$Description content root"
    try { [void](& $CatalogCommand -Path $ContentRoot -CatalogFilePath $CatalogPath -CatalogVersion 2.0 -ErrorAction Stop) }
    catch { Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCatalogCreate' -Message "Unable to create ${Description}." -InnerException $_.Exception }
    $catalogEntry = Get-PshLifecyclePathEntry -Path $CatalogPath -Description $Description
    if (-not [bool]$catalogEntry.IsRegularFile -or [bool]$catalogEntry.IsReparsePoint -or ([IO.FileInfo]$CatalogPath).Length -le 0) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateCatalogCreate' -Message "$Description was not created as a non-empty regular file: $CatalogPath"
    }
    return $CatalogPath
}

function Write-PshGoal6CandidateReportTemp {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Value)

    $parent = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateReportPath' -Message 'Candidate report path must have a parent directory.'
    }
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [void](Assert-PshLifecycleNoReparseAncestors -Path $Path -Description 'candidate report')
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes((ConvertTo-PshCanonicalJson -InputObject $Value) + "`n")
    $expectedSha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes
    $stream = $null
    $created = $false
    $writeError = $null
    $disposeFailures = @()
    try {
        $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write), ([IO.FileShare]::None))
        $created = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch { $writeError = $_ }
    finally {
        $disposeActions = New-Object System.Collections.Generic.List[object]
        if ($null -ne $stream) {
            $disposeActions.Add([pscustomobject]@{ Label = 'candidate report stream dispose'; Action = { $stream.Dispose() } })
        }
        $disposeFailures = @(Invoke-PshGoal6CandidateCleanupActions -Actions $disposeActions.ToArray())
    }
    if ($null -eq $writeError -and $disposeFailures.Count -gt 0) {
        $writeError = $disposeFailures[0].ErrorRecord
    }
    if ($null -ne $writeError) {
        $cleanupDiagnostic = ''
        if ($created -and ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))) {
            if ([IO.File]::Exists($Path)) {
                try { [IO.File]::Delete($Path) }
                catch { $cleanupDiagnostic = " Temporary report cleanup also failed: $($_.Exception.Message)" }
            }
            else { $cleanupDiagnostic = ' Temporary report changed to a directory and was not removed.' }
        }
        $disposeDiagnostic = if ($disposeFailures.Count -eq 0) { '' } else {
            ' Dispose failures: ' + [string]::Join('; ', @($disposeFailures | ForEach-Object { "[$([string]$_.Label)] $([string]$_.Message)" }))
        }
        $failureDiagnostics = @{}
        if (-not [string]::IsNullOrWhiteSpace($disposeDiagnostic)) { $failureDiagnostics['PshDisposeDiagnostics'] = $disposeDiagnostic.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cleanupDiagnostic)) { $failureDiagnostics['PshCleanupDiagnostics'] = $cleanupDiagnostic.Trim() }
        Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateReportWrite' -Message ("Unable to write candidate report temp file: $Path" + $disposeDiagnostic + $cleanupDiagnostic) -InnerException $writeError.Exception -Diagnostics $failureDiagnostics
    }
    try { $state = Get-PshLifecycleFileSha256 -Path $Path }
    catch {
        $verificationError = $_
        $cleanupDiagnostic = ''
        if ($created -and ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))) {
            if ([IO.File]::Exists($Path)) {
                try { [IO.File]::Delete($Path) }
                catch { $cleanupDiagnostic = " Temporary report cleanup also failed: $($_.Exception.Message)" }
            }
            else { $cleanupDiagnostic = ' Temporary report changed to a directory and was not removed.' }
        }
        Invoke-PshGoal6CandidateFailure -ExitCode 3 -ErrorId 'PshGoal6CandidateReportWrite' -Message ("Unable to verify candidate report temp file: $Path" + $cleanupDiagnostic) -InnerException $verificationError.Exception
    }
    if ([int64]$state.Length -ne [int64]$bytes.Length -or [string]$state.Sha256 -cne $expectedSha256) {
        $cleanupDiagnostic = ''
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
            if ([IO.File]::Exists($Path)) {
                try { [IO.File]::Delete($Path) }
                catch { $cleanupDiagnostic = " Temporary report cleanup also failed: $($_.Exception.Message)" }
            }
            else { $cleanupDiagnostic = ' Temporary report changed to a directory and was not removed.' }
        }
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateReportWrite' -Message ("Candidate report temp file failed its byte verification: $Path" + $cleanupDiagnostic)
    }
    return [pscustomobject][ordered]@{ Path = $Path; Length = [int64]$state.Length; Sha256 = [string]$state.Sha256 }
}

$RepositoryRoot = Resolve-PshGoal6CandidateDirectory -Path $RepositoryRoot -Description 'repository root'
$Version = Assert-PshLifecycleSemVer -Value $Version -Description 'candidate version'
if ($Version -ceq '0.0.1-test') {
    Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidatePublicVersion' -Message 'The public candidate version must not be 0.0.1-test.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Invoke-PshGoal6CandidateFailure -ExitCode 4 -ErrorId 'PshGoal6CandidateCatalogUnavailable' -Message 'Goal 6 candidate creation requires Windows file-catalog APIs.'
}
$newCatalogCommand = Get-Command -Name New-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
$testCatalogCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
if ($null -eq $newCatalogCommand -or $null -eq $testCatalogCommand) {
    Invoke-PshGoal6CandidateFailure -ExitCode 4 -ErrorId 'PshGoal6CandidateCatalogUnavailable' -Message 'New-FileCatalog and Test-FileCatalog are required on this Windows runtime.'
}

$inputs = [ordered]@{
    OnlineInstaller = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'src/install/install.ps1') -Description 'online installer'
    OfflineInstaller = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'src/install/install-offline.ps1') -Description 'offline installer'
    ShellInstaller = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'src/install/install.sh') -Description 'shell installer'
    Uninstaller = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'src/install/Uninstall-Psh.ps1') -Description 'uninstaller'
    Bootstrapper = Resolve-PshGoal6CandidateFile -Path $BootstrapperPath -Description 'AnyCPU bootstrapper'
    ReleaseNotes = Resolve-PshGoal6CandidateFile -Path $ReleaseNotesPath -Description 'English release notes'
    ReleaseNotesZhCn = Resolve-PshGoal6CandidateFile -Path $ReleaseNotesZhCnPath -Description 'Simplified Chinese release notes'
}
$buildScript = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'scripts/Build-PshPackages.ps1') -Description 'package build script'
$indexScript = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'scripts/Generate-PshReleaseIndex.ps1') -Description 'release index script'
$artifactScript = Resolve-PshGoal6CandidateFile -Path (Join-Path $RepositoryRoot 'scripts/Test-PshReleaseArtifacts.ps1') -Description 'release artifact verification script'

$CandidateRoot = Assert-PshGoal6CandidateOutputPath -Path $CandidateRoot -Description 'candidate root'
$ReportPath = Assert-PshGoal6CandidateOutputPath -Path $ReportPath -Description 'candidate report'
if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {
    $WorkingRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-candidate-' + [Guid]::NewGuid().ToString('N'))
}
$WorkingRoot = Assert-PshGoal6CandidateOutputPath -Path $WorkingRoot -Description 'candidate working root'
Assert-PshGoal6CandidateOutputIsolation -CandidateRoot $CandidateRoot -ReportPath $ReportPath -WorkingRoot $WorkingRoot -RepositoryRoot $RepositoryRoot

$expectedPackageNames = @(
    "psh-$Version-core",
    "psh-$Version-full-win-x64",
    "psh-$Version-full-win-arm64"
)
$expectedAssetNames = @(
    'install.ps1',
    'install.sh',
    'psh-installer.exe',
    "psh-$Version-core.zip",
    "psh-$Version-full-win-x64.zip",
    "psh-$Version-full-win-arm64.zip",
    'sbom.spdx.json',
    'THIRD_PARTY_NOTICES.md',
    'RELEASE_NOTES.md',
    'RELEASE_NOTES.zh-CN.md',
    "psh-release-$Version.json",
    'SHA256SUMS',
    "psh-release-$Version.cat"
)
$workingCleanupFiles = @("psh-release-$Version.cat")
$workingCleanupDirectories = @(
    'pre-sign-build',
    'package-catalogs',
    'package-catalog-inputs',
    'final-build',
    'release-catalog-input'
)

$workingOwned = $false
$candidateStagingOwned = $false
$reportTempOwned = $false
$candidatePublished = $false
$reportPublished = $false
$candidateStagingRoot = $null
$reportTempPath = $null
$reportState = $null
$assetRecords = $null
try {
    New-PshGoal6CandidateOwnedDirectory -Path $WorkingRoot -Description 'candidate working root'
    $workingOwned = $true
    $workingEntry = Get-PshLifecyclePathEntry -Path $WorkingRoot -Description 'candidate working root'
    if (-not [bool]$workingEntry.IsDirectory -or [bool]$workingEntry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "Candidate working root is unsafe: $WorkingRoot"
    }
    $preSignOutputRoot = Join-Path $WorkingRoot 'pre-sign-build'
    $commonBuildParameters = @{
        Version = $Version
        SourceCommit = $SourceCommit
        OnlineInstallerPath = [string]$inputs.OnlineInstaller
        OfflineInstallerPath = [string]$inputs.OfflineInstaller
        ShellInstallerPath = [string]$inputs.ShellInstaller
        UninstallerPath = [string]$inputs.Uninstaller
        BootstrapperPath = [string]$inputs.Bootstrapper
        ReleaseNotesPath = [string]$inputs.ReleaseNotes
        ReleaseNotesZhCnPath = [string]$inputs.ReleaseNotesZhCn
        RepositoryRoot = $RepositoryRoot
    }
    $preSignParameters = @{} + $commonBuildParameters
    $preSignParameters['OutputRoot'] = $preSignOutputRoot
    $preSignState = @(& $buildScript @preSignParameters)[-1]
    if ([int]$preSignState.code -ne 4 -or [string]$preSignState.phase -cne 'pre-sign') {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidatePreSign' -Message 'Package pre-sign build returned an unexpected phase or code.'
    }
    $packageRecords = @($preSignState.packages)
    if ($packageRecords.Count -ne 3 -or @($packageRecords | Where-Object { [bool]$_.testOnly }).Count -ne 0) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidatePackageContract' -Message 'Package pre-sign build did not produce exactly three public packages.'
    }

    $packageCatalogRoot = Join-Path $WorkingRoot 'package-catalogs'
    $packageCatalogInputRoot = Join-Path $WorkingRoot 'package-catalog-inputs'
    [void][IO.Directory]::CreateDirectory($packageCatalogRoot)
    [void][IO.Directory]::CreateDirectory($packageCatalogInputRoot)
    foreach ($expectedPackageName in $expectedPackageNames) {
        $packageMatches = @($packageRecords | Where-Object { [string]$_.name -ceq $expectedPackageName })
        if ($packageMatches.Count -ne 1) {
            Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidatePackageContract' -Message "Package pre-sign build is missing the exact slot '$expectedPackageName'."
        }
        $manifestPath = Join-Path $preSignOutputRoot (Join-Path ([string]$packageMatches[0].stagingRelativePath) 'package.manifest.json')
        [void](Invoke-PshGoal6CandidateCatalogBuild -CatalogCommand $newCatalogCommand -ContentRoot (Join-Path $packageCatalogInputRoot $expectedPackageName) -Members @(
                [pscustomobject]@{ Name = 'package.manifest.json'; SourcePath = $manifestPath }
            ) -CatalogPath (Join-Path $packageCatalogRoot ($expectedPackageName + '.manifest.cat')) -Description "package catalog '$expectedPackageName'")
    }
    Assert-PshGoal6CandidateExactFileSet -Root $packageCatalogRoot -ExpectedNames @($expectedPackageNames | ForEach-Object { $_ + '.manifest.cat' }) -Description 'package catalog root'

    $finalBuildOutputRoot = Join-Path $WorkingRoot 'final-build'
    $finalBuildParameters = @{} + $commonBuildParameters
    $finalBuildParameters['OutputRoot'] = $finalBuildOutputRoot
    $finalBuildParameters['Finalize'] = $true
    $finalBuildParameters['PackageCatalogRoot'] = $packageCatalogRoot
    $finalBuildState = @(& $buildScript @finalBuildParameters)[-1]
    if ([int]$finalBuildState.code -ne 0 -or [string]$finalBuildState.phase -cne 'finalized-with-verified-catalog-membership' -or -not [bool]$finalBuildState.catalogMembershipVerified) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateFinalBuild' -Message 'Final package build did not verify package catalog membership.'
    }

    $releaseAssetsRoot = Resolve-PshGoal6CandidateDirectory -Path (Join-Path $finalBuildOutputRoot 'release-assets') -Description 'final build release assets root'
    $initialIndexState = @(& $indexScript -ReleaseAssetsRoot $releaseAssetsRoot -Version $Version -SourceCommit $SourceCommit -RepositoryRoot $RepositoryRoot)[-1]
    if ([int]$initialIndexState.code -ne 4 -or [string]$initialIndexState.phase -cne 'catalog-deferred') {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateIndex' -Message 'Initial release index generation returned an unexpected phase or code.'
    }
    $releaseCatalogPath = Join-Path $WorkingRoot "psh-release-$Version.cat"
    [void](Invoke-PshGoal6CandidateCatalogBuild -CatalogCommand $newCatalogCommand -ContentRoot (Join-Path $WorkingRoot 'release-catalog-input') -Members @(
            [pscustomobject]@{ Name = "psh-release-$Version.json"; SourcePath = (Join-Path $releaseAssetsRoot "psh-release-$Version.json") },
            [pscustomobject]@{ Name = 'SHA256SUMS'; SourcePath = (Join-Path $releaseAssetsRoot 'SHA256SUMS') }
        ) -CatalogPath $releaseCatalogPath -Description 'release catalog')
    $finalIndexState = @(& $indexScript -ReleaseAssetsRoot $releaseAssetsRoot -Version $Version -SourceCommit $SourceCommit -RepositoryRoot $RepositoryRoot -Finalize -ReleaseCatalogPath $releaseCatalogPath)[-1]
    if ([int]$finalIndexState.code -ne 0 -or [string]$finalIndexState.phase -cne 'finalized-with-verified-catalog-membership' -or -not [bool]$finalIndexState.catalogMembershipVerified) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateIndexFinalize' -Message 'Final release index generation did not verify release catalog membership.'
    }
    Assert-PshGoal6CandidateExactFileSet -Root $releaseAssetsRoot -ExpectedNames $expectedAssetNames -Description 'final build release asset root'
    $buildVerification = @(& $artifactScript -ReleaseAssetsRoot $releaseAssetsRoot -Version $Version -SourceCommit $SourceCommit -RepositoryRoot $RepositoryRoot -Mode Release)[-1]
    if ([int]$buildVerification.code -ne 0 -or [string]$buildVerification.phase -cne 'release-catalog-membership-verified' -or -not [bool]$buildVerification.catalogMembershipVerified) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateVerification' -Message 'Final build release artifact verification did not pass catalog membership gates.'
    }

    $candidateStagingRoot = New-PshGoal6CandidateUniqueSiblingPath -DestinationPath $CandidateRoot -Purpose 'staging'
    New-PshGoal6CandidateOwnedDirectory -Path $candidateStagingRoot -Description 'candidate staging root'
    $candidateStagingOwned = $true
    $candidateEntry = Get-PshLifecyclePathEntry -Path $candidateStagingRoot -Description 'candidate staging root'
    if (-not [bool]$candidateEntry.IsDirectory -or [bool]$candidateEntry.IsReparsePoint) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateOutputPath' -Message "Candidate staging root is unsafe: $candidateStagingRoot"
    }
    foreach ($assetName in $expectedAssetNames) {
        $source = Resolve-PshGoal6CandidateFile -Path (Join-Path $releaseAssetsRoot $assetName) -Description "candidate source asset '$assetName'"
        [IO.File]::Copy($source, (Join-Path $candidateStagingRoot $assetName), $false)
    }
    Assert-PshGoal6CandidateExactFileSet -Root $candidateStagingRoot -ExpectedNames $expectedAssetNames -Description 'candidate staging root'
    $candidateVerification = @(& $artifactScript -ReleaseAssetsRoot $candidateStagingRoot -Version $Version -SourceCommit $SourceCommit -RepositoryRoot $RepositoryRoot -Mode Release)[-1]
    if ([int]$candidateVerification.code -ne 0 -or [string]$candidateVerification.phase -cne 'release-catalog-membership-verified' -or
        -not [bool]$candidateVerification.catalogMembershipVerified -or [int]$candidateVerification.assetCount -ne 13 -or [int]$candidateVerification.packageCount -ne 3) {
        Invoke-PshGoal6CandidateFailure -ExitCode 5 -ErrorId 'PshGoal6CandidateVerification' -Message 'Copied candidate did not pass the exact 13-asset release verification contract.'
    }

    $assetRecords = New-Object System.Collections.Generic.List[object]
    foreach ($assetName in $expectedAssetNames) {
        $assetPath = Join-Path $candidateStagingRoot $assetName
        $state = Get-PshLifecycleFileSha256 -Path $assetPath
        $assetRecords.Add([pscustomobject][ordered]@{ name = $assetName; length = [int64]$state.Length; sha256 = [string]$state.Sha256 })
    }
    $report = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $Version
        sourceCommit = $SourceCommit
        phase = 'candidate-verified'
        code = 0
        assetContract = 'exact-13-public-assets-before-provenance-attestation'
        assetCount = 13
        packageCount = 3
        catalogMembershipVerified = $true
        authenticodeStatus = $candidateVerification.authenticodeStatus
        provenanceAttestation = 'external-workflow-gate'
        phases = [pscustomobject][ordered]@{
            preSignBuild = [string]$preSignState.phase
            finalPackageBuild = [string]$finalBuildState.phase
            initialIndex = [string]$initialIndexState.phase
            finalIndex = [string]$finalIndexState.phase
            releaseVerification = [string]$candidateVerification.phase
        }
        assets = $assetRecords.ToArray()
    }

    $reportTempPath = New-PshGoal6CandidateUniqueSiblingPath -DestinationPath $ReportPath -Purpose 'tmp'
    $reportState = Write-PshGoal6CandidateReportTemp -Path $reportTempPath -Value $report
    $reportTempOwned = $true

    Invoke-PshGoal6CandidateTreeCleanup -Path $WorkingRoot -Description 'candidate working root' -AllowedFiles $workingCleanupFiles -AllowedDirectories $workingCleanupDirectories -RequireAll
    $workingOwned = $false
    Move-PshGoal6CandidateDirectoryAtomically -Source $candidateStagingRoot -Destination $CandidateRoot -Description 'candidate root'
    $candidateStagingOwned = $false
    $candidatePublished = $true
    Move-PshGoal6CandidateFileAtomically -Source $reportTempPath -Destination $ReportPath -Description 'candidate report'
    $reportTempOwned = $false
    $reportPublished = $true
    Write-Output ([pscustomobject][ordered]@{
            schemaVersion = 1
            product = 'Psh'
            version = $Version
            sourceCommit = $SourceCommit
            phase = 'candidate-verified'
            code = 0
            candidateRoot = $CandidateRoot
            reportPath = $ReportPath
            assetCount = 13
            packageCount = 3
            catalogMembershipVerified = $true
            authenticodeStatus = $candidateVerification.authenticodeStatus
        })
}
catch {
    $primaryError = $_
    $cleanupActions = New-Object System.Collections.Generic.List[object]
    if ($workingOwned) {
        $cleanupActions.Add([pscustomobject]@{ Label = 'candidate working root'; Action = {
                    Invoke-PshGoal6CandidateTreeCleanup -Path $WorkingRoot -Description 'candidate working root' -AllowedFiles $workingCleanupFiles -AllowedDirectories $workingCleanupDirectories
                } })
    }
    if ($candidateStagingOwned) {
        $cleanupActions.Add([pscustomobject]@{ Label = 'candidate staging root'; Action = {
                    Invoke-PshGoal6CandidateTreeCleanup -Path $candidateStagingRoot -Description 'candidate staging root' -AllowedFiles $expectedAssetNames
                } })
    }
    if ($reportTempOwned) {
        $cleanupActions.Add([pscustomobject]@{ Label = 'candidate report temp file'; Action = {
                    Invoke-PshGoal6CandidateReportCleanup -Path $reportTempPath -ExpectedState $reportState
                } })
    }
    if ($candidatePublished) {
        $cleanupActions.Add([pscustomobject]@{ Label = 'published candidate root'; Action = {
                    Invoke-PshGoal6CandidatePublishedCleanup -Path $CandidateRoot -ExpectedAssets $assetRecords.ToArray()
                } })
    }
    if ($reportPublished) {
        $cleanupActions.Add([pscustomobject]@{ Label = 'published candidate report'; Action = {
                    Invoke-PshGoal6CandidateReportCleanup -Path $ReportPath -ExpectedState $reportState
                } })
    }
    $cleanupFailures = @(Invoke-PshGoal6CandidateCleanupActions -Actions $cleanupActions.ToArray())
    if ($cleanupFailures.Count -gt 0) {
        $diagnostics = [string]::Join('; ', @($cleanupFailures | ForEach-Object { "[$([string]$_.Label)] $([string]$_.Message)" }))
        $combined = New-Object Exception("$($primaryError.Exception.Message) Cleanup failures: $diagnostics", $primaryError.Exception)
        $metadataException = $primaryError.Exception
        while ($null -ne $metadataException -and $metadataException -is [Exception]) {
            if ($metadataException.Data.Contains('PshExitCode')) {
                $combined.Data['PshExitCode'] = $metadataException.Data['PshExitCode']
                $combined.Data['PshErrorId'] = $metadataException.Data['PshErrorId']
                break
            }
            $metadataException = $metadataException.InnerException
        }
        $combined.Data['PshCleanupDiagnostics'] = $diagnostics
        throw $combined
    }
    throw $primaryError
}
