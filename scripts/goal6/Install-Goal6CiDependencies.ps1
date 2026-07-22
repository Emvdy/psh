# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$LockPath = (Join-Path $PSScriptRoot 'ci-dependencies.lock.json'),
    [ValidateSet('all', 'gitleaks', 'psscriptanalyzer')][string]$DependencyId = 'all',
    [string]$SummaryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

function Invoke-PshGoal6Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-PshGoal6PinnedUrl -Url $Url -Description 'CI dependency download URL'
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }

    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ([IO.File]::Exists($Destination)) { [IO.File]::Delete($Destination) }
            $client = New-Object Net.WebClient
            $client.Headers['User-Agent'] = 'Psh-Goal6-CI-Dependency-Acquisition/1'
            try {
                $client.DownloadFile($Url, $Destination)
                return
            }
            catch {
                if ($attempt -eq 4) { throw }
                Start-Sleep -Seconds 2
            }
            finally { $client.Dispose() }
        }
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $previousProtocol }
}

function Expand-PshGoal6Archive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-PshGoal6Condition (-not [IO.File]::Exists($DestinationRoot) -and -not [IO.Directory]::Exists($DestinationRoot)) "Archive destination already exists: $DestinationRoot"
    [void][IO.Directory]::CreateDirectory($DestinationRoot)
    $destinationFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = [IO.File]::OpenRead($ArchivePath)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            foreach ($entry in @($archive.Entries)) {
                $rawEntryName = ([string]$entry.FullName).Replace('\', '/')
                $isDirectory = $rawEntryName.EndsWith('/', [StringComparison]::Ordinal)
                $entryName = $rawEntryName.TrimEnd('/')
                if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
                Assert-PshGoal6Condition (-not [IO.Path]::IsPathRooted($entryName)) "Archive contains a rooted entry: $entryName"
                $segments = @($entryName.Split('/'))
                Assert-PshGoal6Condition ($segments -notcontains '.' -and $segments -notcontains '..') "Archive contains a traversal entry: $entryName"
                Assert-PshGoal6Condition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Archive contains an empty path segment: $entryName"
                Assert-PshGoal6Condition ($entryName -notmatch '[:*?"<>|]') "Archive contains an invalid entry path: $entryName"
                Assert-PshGoal6Condition ($seen.Add($entryName)) "Archive contains a case-insensitive duplicate entry: $entryName"
                $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                Assert-PshGoal6Condition ($unixType -ne 0xA000) "Archive contains a symbolic link: $entryName"
                Assert-PshGoal6Condition (($entry.ExternalAttributes -band 0x400) -eq 0) "Archive contains a reparse-point entry: $entryName"

                $target = [IO.Path]::GetFullPath((Join-Path $destinationFull $entryName.Replace('/', [IO.Path]::DirectorySeparatorChar)))
                Assert-PshGoal6Condition ($target.StartsWith($destinationFull + [IO.Path]::DirectorySeparatorChar, $comparison)) "Archive entry escapes its destination: $entryName"
                if ($isDirectory) {
                    if (-not [IO.Directory]::Exists($target)) { [void][IO.Directory]::CreateDirectory($target) }
                    continue
                }
                $targetParent = [IO.Path]::GetDirectoryName($target)
                if (-not [IO.Directory]::Exists($targetParent)) { [void][IO.Directory]::CreateDirectory($targetParent) }
                Assert-PshGoal6Condition (-not [IO.File]::Exists($target) -and -not [IO.Directory]::Exists($target)) "Archive extraction target already exists: $entryName"
                $sourceStream = $entry.Open()
                $targetStream = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $sourceStream.CopyTo($targetStream) }
                finally { $targetStream.Dispose(); $sourceStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Install-PshGoal6Dependency {
    param(
        [Parameter(Mandatory = $true)][object]$Dependency,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$DownloadRoot
    )

    $id = [string]$Dependency.id
    $packagePath = Join-Path $DownloadRoot ([string]$Dependency.package.fileName)
    Invoke-PshGoal6Download -Url ([string]$Dependency.package.url) -Destination $packagePath
    Assert-PshGoal6Condition ([int64](Get-Item -LiteralPath $packagePath).Length -eq [int64]$Dependency.package.size) "$id package size mismatches."
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $packagePath) -ceq [string]$Dependency.package.sha256) "$id package SHA256 mismatches."

    if ($id -ceq 'psscriptanalyzer') {
        Assert-PshGoal6Condition ((Get-PshGoal6Sha512Base64 -Path $packagePath) -ceq [string]$Dependency.package.gallerySha512Base64) 'PSScriptAnalyzer Gallery SHA512 mismatches.'
    }
    else {
        $checksumsPath = Join-Path $DownloadRoot 'gitleaks-checksums.txt'
        Invoke-PshGoal6Download -Url ([string]$Dependency.package.checksumsUrl) -Destination $checksumsPath
        Assert-PshGoal6Condition ([int64](Get-Item -LiteralPath $checksumsPath).Length -eq [int64]$Dependency.package.checksumsSize) 'gitleaks checksums file size mismatches.'
        Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $checksumsPath) -ceq [string]$Dependency.package.checksumsSha256) 'gitleaks checksums file SHA256 mismatches.'
        $checksumText = Get-PshGoal6StrictText -Path $checksumsPath
        $expectedLine = '{0}  {1}' -f [string]$Dependency.package.sha256, [string]$Dependency.package.fileName
        Assert-PshGoal6Condition (@($checksumText.Replace("`r`n", "`n").Split("`n") | Where-Object { $_ -ceq $expectedLine }).Count -eq 1) 'gitleaks official checksums do not contain the locked Windows x64 asset hash.'
    }

    $installedRelativePath = [string]$Dependency.package.installedRelativePath
    $installedParentRelativePath = [IO.Path]::GetDirectoryName($installedRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)).Replace('\', '/')
    $extractRoot = Resolve-PshGoal6RelativePath -Root $StagingRoot -RelativePath $installedParentRelativePath -Description "$id extraction root"
    Expand-PshGoal6Archive -ArchivePath $packagePath -DestinationRoot $extractRoot

    $installedPath = Resolve-PshGoal6RelativePath -Root $StagingRoot -RelativePath $installedRelativePath -Description "$id installed path"
    Assert-PshGoal6Condition ([IO.File]::Exists($installedPath)) "$id installed entry is missing."
    Assert-PshGoal6Condition ([int64](Get-Item -LiteralPath $installedPath).Length -eq [int64]$Dependency.package.installedSize) "$id installed entry size mismatches."
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $installedPath) -ceq [string]$Dependency.package.installedSha256) "$id installed entry SHA256 mismatches."

    $archiveLicensePath = Join-Path $extractRoot ([string]$Dependency.license.archivePath)
    Assert-PshGoal6Condition ([IO.File]::Exists($archiveLicensePath)) "$id archive license is missing."
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $archiveLicensePath) -ceq [string]$Dependency.license.sha256) "$id archive license SHA256 mismatches."
    $retainedLicensePath = Resolve-PshGoal6RelativePath -Root $RepositoryRootPath -RelativePath ([string]$Dependency.license.retainedPath) -Description "$id retained license"
    Assert-PshGoal6Condition ((Get-PshGoal6Sha256 -Path $archiveLicensePath) -ceq (Get-PshGoal6Sha256 -Path $retainedLicensePath)) "$id archive and retained licenses differ."

    if ($id -ceq 'gitleaks') {
        Assert-PshGoal6Condition ((Get-PshGoal6PeMachine -Path $installedPath) -ceq [string]$Dependency.package.peMachine) 'gitleaks executable is not Windows x64.'
    }
    else {
        $manifest = Import-PowerShellDataFile -LiteralPath $installedPath -ErrorAction Stop
        Assert-PshGoal6Condition ([string]$manifest.ModuleVersion -ceq [string]$Dependency.version) 'PSScriptAnalyzer module manifest version mismatches.'
    }

    return [pscustomobject][ordered]@{
        id = $id
        version = [string]$Dependency.version
        packageSha256 = [string]$Dependency.package.sha256
        installedRelativePath = $installedRelativePath
        installedSha256 = [string]$Dependency.package.installedSha256
        license = [string]$Dependency.license.spdxId
        licenseSha256 = [string]$Dependency.license.sha256
    }
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$destinationRootPath = [IO.Path]::GetFullPath($DestinationRoot)
if ([string]::IsNullOrWhiteSpace($SummaryPath)) { $SummaryPath = $destinationRootPath + '.install-summary.json' }
$summaryPathFull = [IO.Path]::GetFullPath($SummaryPath)
$stagingRoot = $destinationRootPath + '.staging-' + [Guid]::NewGuid().ToString('N')
$DependencyId = $DependencyId.ToLowerInvariant()
$summary = [ordered]@{
    schemaVersion = 1
    gate = 'goal6-ci-dependency-install'
    status = 'failed'
    destinationRoot = $destinationRootPath
    dependencies = @()
    error = $null
}

try {
    Assert-PshGoal6Condition (-not [IO.File]::Exists($destinationRootPath) -and -not [IO.Directory]::Exists($destinationRootPath)) "Dependency destination already exists: $destinationRootPath"
    Assert-PshGoal6Condition (-not [IO.File]::Exists($stagingRoot) -and -not [IO.Directory]::Exists($stagingRoot)) "Dependency staging path already exists: $stagingRoot"
    $destinationParent = [IO.Path]::GetDirectoryName($destinationRootPath)
    if (-not [IO.Directory]::Exists($destinationParent)) { [void][IO.Directory]::CreateDirectory($destinationParent) }
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    $downloadRoot = Join-Path $stagingRoot '_downloads'
    [void][IO.Directory]::CreateDirectory($downloadRoot)

    $lock = Read-PshGoal6DependencyLock -RepositoryRoot $repositoryRootPath -LockPath ([IO.Path]::GetFullPath($LockPath))
    $selected = if ($DependencyId -ceq 'all') { @($lock.dependencies) } else { @(Get-PshGoal6Dependency -Lock $lock -Id $DependencyId) }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($dependency in $selected) {
        $records.Add((Install-PshGoal6Dependency -Dependency $dependency -RepositoryRootPath $repositoryRootPath -StagingRoot $stagingRoot -DownloadRoot $downloadRoot))
    }

    if ([IO.Directory]::Exists($downloadRoot)) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
    Move-Item -LiteralPath $stagingRoot -Destination $destinationRootPath
    $summary.status = 'passed'
    $summary.dependencies = $records.ToArray()
    Write-PshGoal6Json -Path $summaryPathFull -InputObject ([pscustomobject]$summary)
    Write-Output ('Installed and verified {0} Goal 6 CI dependencies at {1}.' -f $records.Count, $destinationRootPath)
}
catch {
    $summary.error = [string]$_.Exception.Message
    try { Write-PshGoal6Json -Path $summaryPathFull -InputObject ([pscustomobject]$summary) }
    catch { Write-Verbose ('Unable to write the dependency failure summary: {0}' -f $_.Exception.Message) }
    if ([IO.Directory]::Exists($stagingRoot)) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
