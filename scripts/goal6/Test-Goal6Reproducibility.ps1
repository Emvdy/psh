# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ReleaseNotesPath,
    [Parameter(Mandatory = $true)][string]$ReleaseNotesZhCnPath,
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$MSBuildPath,
    [switch]$IncludeTestFixtures
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Goal6.Common.ps1')

function Get-PshGoal6RelativeBuildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    Assert-PshGoal6Condition ($pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) "Build path escapes its run root: $Path"
    return $pathFull.Substring($rootFull.Length + 1).Replace('\', '/')
}

function Get-PshGoal6StreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-PshGoal6OrderedString {
    param([Parameter(Mandatory = $true)][object[]]$Values)

    [string[]]$ordered = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    return $ordered
}

function Write-PshGoal6CatalogFixture {
    param(
        [Parameter(Mandatory = $true)][string]$CatalogRoot,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [Parameter(Mandatory = $true)][string]$Commit,
        [switch]$WithTestFixtures
    )

    [void][IO.Directory]::CreateDirectory($CatalogRoot)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(
            ('psh-{0}-core' -f $PackageVersion),
            ('psh-{0}-full-win-x64' -f $PackageVersion),
            ('psh-{0}-full-win-arm64' -f $PackageVersion)
        )) { $names.Add($name) }
    if ($WithTestFixtures) {
        foreach ($name in @('psh-0.0.1-test-core', 'psh-0.0.1-test-full-win-x64', 'psh-0.0.1-test-full-win-arm64')) { $names.Add($name) }
    }
    foreach ($name in $names) {
        $catalogPath = Join-Path $CatalogRoot ($name + '.manifest.cat')
        Write-PshGoal6Text -Path $catalogPath -Text ("Psh Goal 6 reproducibility-only catalog fixture`npackage=$name`nsource=$Commit`n")
    }
}

function Invoke-PshGoal6IndependentBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryRootPath,
        [Parameter(Mandatory = $true)][string]$PackageVersion,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$EnglishReleaseNotes,
        [Parameter(Mandatory = $true)][string]$ChineseReleaseNotes,
        [AllowNull()][string]$RequestedMSBuildPath,
        [switch]$WithTestFixtures
    )

    Assert-PshGoal6Condition (-not [IO.File]::Exists($RunRoot) -and -not [IO.Directory]::Exists($RunRoot)) "Independent build root already exists: $RunRoot"
    [void][IO.Directory]::CreateDirectory($RunRoot)
    $bootstrapperRoot = Join-Path $RunRoot 'bootstrapper'
    [void][IO.Directory]::CreateDirectory($bootstrapperRoot)
    $onlineInstaller = Join-Path $RepositoryRootPath 'src/install/install.ps1'
    $offlineInstaller = Join-Path $RepositoryRootPath 'src/install/install-offline.ps1'
    $shellInstaller = Join-Path $RepositoryRootPath 'src/install/install.sh'
    $uninstaller = Join-Path $RepositoryRootPath 'src/install/Uninstall-Psh.ps1'
    $bootstrapperPath = Join-Path $bootstrapperRoot 'psh-installer.exe'
    $hashSourcePath = Join-Path $bootstrapperRoot 'EmbeddedScriptHashes.g.cs'
    $bootstrapperScript = Join-Path $RepositoryRootPath 'scripts/Build-PshBootstrapper.ps1'
    $bootstrapperParameters = @{
        OnlineScriptPath = $onlineInstaller
        OfflineScriptPath = $offlineInstaller
        OutputPath = $bootstrapperPath
        HashSourcePath = $hashSourcePath
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedMSBuildPath)) { $bootstrapperParameters['MSBuildPath'] = $RequestedMSBuildPath }
    $bootstrapperOutput = @(& $bootstrapperScript @bootstrapperParameters 2>&1)
    Write-PshGoal6Text -Path (Join-Path $RunRoot 'bootstrapper-build.log') -Text ((@($bootstrapperOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    Assert-PshGoal6Condition ([IO.File]::Exists($bootstrapperPath) -and [int64](Get-Item -LiteralPath $bootstrapperPath).Length -gt 0) 'Independent bootstrapper build produced no executable.'

    $catalogRoot = Join-Path $RunRoot 'catalogs'
    Write-PshGoal6CatalogFixture -CatalogRoot $catalogRoot -PackageVersion $PackageVersion -Commit $Commit -WithTestFixtures:$WithTestFixtures
    $packageOutputRoot = Join-Path $RunRoot 'package-build'
    $packageBuildScript = Join-Path $RepositoryRootPath 'scripts/Build-PshPackages.ps1'
    $packageParameters = @{
        OutputRoot = $packageOutputRoot
        Version = $PackageVersion
        SourceCommit = $Commit
        OnlineInstallerPath = $onlineInstaller
        OfflineInstallerPath = $offlineInstaller
        ShellInstallerPath = $shellInstaller
        UninstallerPath = $uninstaller
        BootstrapperPath = $bootstrapperPath
        ReleaseNotesPath = $EnglishReleaseNotes
        ReleaseNotesZhCnPath = $ChineseReleaseNotes
        RepositoryRoot = $RepositoryRootPath
        PackageCatalogRoot = $catalogRoot
        Finalize = $true
    }
    if ($WithTestFixtures) { $packageParameters['IncludeTestFixtures'] = $true }
    $packageOutput = @(& $packageBuildScript @packageParameters 2>&1)
    Write-PshGoal6Text -Path (Join-Path $RunRoot 'package-build.log') -Text ((@($packageOutput | ForEach-Object { [string]$_ }) -join "`n") + "`n")
    Assert-PshGoal6Condition ([IO.File]::Exists((Join-Path $packageOutputRoot 'pre-sign-build.json'))) 'Independent package build produced no build state.'
    return [pscustomobject][ordered]@{
        runRoot = $RunRoot
        bootstrapperPath = $bootstrapperPath
        bootstrapperSha256 = Get-PshGoal6Sha256 -Path $bootstrapperPath
        packageOutputRoot = $packageOutputRoot
    }
}

function Get-PshGoal6NormalizedArchiveManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = [IO.File]::OpenRead($ArchivePath)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $entryNames = Get-PshGoal6OrderedString -Values @($archive.Entries | ForEach-Object { ([string]$_.FullName).Replace('\', '/') })
            $entryByName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
            foreach ($entry in @($archive.Entries)) { $entryByName[([string]$entry.FullName).Replace('\', '/')] = $entry }
            foreach ($entryName in $entryNames) {
                if ($entryName.EndsWith('/', [StringComparison]::Ordinal)) { continue }
                Assert-PshGoal6Condition (-not [IO.Path]::IsPathRooted($entryName)) "Archive contains a rooted entry: $entryName"
                $segments = @($entryName.Split('/'))
                Assert-PshGoal6Condition ($segments -notcontains '.' -and $segments -notcontains '..') "Archive contains a traversal entry: $entryName"
                Assert-PshGoal6Condition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "Archive contains an empty path segment: $entryName"
                Assert-PshGoal6Condition ($seen.Add($entryName)) "Archive contains a case-insensitive duplicate entry: $entryName"
                $entry = $entryByName[$entryName]
                $entryStream = $entry.Open()
                try { $sha256 = Get-PshGoal6StreamSha256 -Stream $entryStream }
                finally { $entryStream.Dispose() }
                $entries.Add([pscustomobject][ordered]@{
                        path = $entryName
                        length = [int64]$entry.Length
                        sha256 = $sha256
                    })
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{
        path = Get-PshGoal6RelativeBuildPath -Root $RunRoot -Path $ArchivePath
        containerSha256Informational = Get-PshGoal6Sha256 -Path $ArchivePath
        containerMetadataCompared = $false
        entries = $entries.ToArray()
    }
}

function Get-PshGoal6BuildManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RunName,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$BootstrapperSha256
    )

    $files = New-Object System.Collections.Generic.List[object]
    $archives = New-Object System.Collections.Generic.List[object]
    $ignored = New-Object System.Collections.Generic.List[string]
    $allFiles = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Force -File | Sort-Object FullName)
    foreach ($file in $allFiles) {
        $relativePath = Get-PshGoal6RelativeBuildPath -Root $RunRoot -Path $file.FullName
        if ($relativePath -in @('bootstrapper-build.log', 'package-build.log')) { $ignored.Add($relativePath); continue }
        if ([IO.Path]::GetExtension($relativePath) -ieq '.zip') {
            $archives.Add((Get-PshGoal6NormalizedArchiveManifest -RunRoot $RunRoot -ArchivePath $file.FullName))
            continue
        }
        $files.Add([pscustomobject][ordered]@{
                path = $relativePath
                length = [int64]$file.Length
                sha256 = Get-PshGoal6Sha256 -Path $file.FullName
            })
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        run = $RunName
        scope = 'independent-bootstrapper-and-finalized-package-build'
        bootstrapperSha256 = $BootstrapperSha256
        stableFiles = $files.ToArray()
        normalizedArchives = $archives.ToArray()
        ignoredFiles = $ignored.ToArray()
        archiveComparisonPolicy = 'Compare entry paths, uncompressed lengths, and entry SHA256 values; record but do not gate on ZIP container hashes or timestamps.'
    }
}

function Compare-PshGoal6BuildManifest {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second
    )

    $differences = New-Object System.Collections.Generic.List[object]
    if ([string]$First.bootstrapperSha256 -cne [string]$Second.bootstrapperSha256) {
        $differences.Add([pscustomobject][ordered]@{ kind = 'bootstrapper-sha256'; path = 'bootstrapper/psh-installer.exe'; first = [string]$First.bootstrapperSha256; second = [string]$Second.bootstrapperSha256 })
    }

    $firstFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $secondFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($file in @($First.stableFiles)) { $firstFiles[[string]$file.path] = $file }
    foreach ($file in @($Second.stableFiles)) { $secondFiles[[string]$file.path] = $file }
    $filePaths = Get-PshGoal6OrderedString -Values @((@($firstFiles.Keys) + @($secondFiles.Keys)) | Sort-Object -Unique)
    foreach ($path in $filePaths) {
        if (-not $firstFiles.ContainsKey($path)) { $differences.Add([pscustomobject][ordered]@{ kind = 'stable-file-missing-first'; path = $path; first = $null; second = [string]$secondFiles[$path].sha256 }); continue }
        if (-not $secondFiles.ContainsKey($path)) { $differences.Add([pscustomobject][ordered]@{ kind = 'stable-file-missing-second'; path = $path; first = [string]$firstFiles[$path].sha256; second = $null }); continue }
        if ([int64]$firstFiles[$path].length -ne [int64]$secondFiles[$path].length -or [string]$firstFiles[$path].sha256 -cne [string]$secondFiles[$path].sha256) {
            $differences.Add([pscustomobject][ordered]@{ kind = 'stable-file-content'; path = $path; first = ('{0}:{1}' -f [int64]$firstFiles[$path].length, [string]$firstFiles[$path].sha256); second = ('{0}:{1}' -f [int64]$secondFiles[$path].length, [string]$secondFiles[$path].sha256) })
        }
    }

    $firstArchives = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $secondArchives = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($archive in @($First.normalizedArchives)) { $firstArchives[[string]$archive.path] = $archive }
    foreach ($archive in @($Second.normalizedArchives)) { $secondArchives[[string]$archive.path] = $archive }
    $archivePaths = Get-PshGoal6OrderedString -Values @((@($firstArchives.Keys) + @($secondArchives.Keys)) | Sort-Object -Unique)
    foreach ($archivePath in $archivePaths) {
        if (-not $firstArchives.ContainsKey($archivePath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-missing-first'; path = $archivePath; first = $null; second = 'present' }); continue }
        if (-not $secondArchives.ContainsKey($archivePath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-missing-second'; path = $archivePath; first = 'present'; second = $null }); continue }
        $firstEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $secondEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($entry in @($firstArchives[$archivePath].entries)) { $firstEntries[[string]$entry.path] = $entry }
        foreach ($entry in @($secondArchives[$archivePath].entries)) { $secondEntries[[string]$entry.path] = $entry }
        $entryPaths = Get-PshGoal6OrderedString -Values @((@($firstEntries.Keys) + @($secondEntries.Keys)) | Sort-Object -Unique)
        foreach ($entryPath in $entryPaths) {
            $qualifiedPath = $archivePath + '!' + $entryPath
            if (-not $firstEntries.ContainsKey($entryPath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-entry-missing-first'; path = $qualifiedPath; first = $null; second = [string]$secondEntries[$entryPath].sha256 }); continue }
            if (-not $secondEntries.ContainsKey($entryPath)) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-entry-missing-second'; path = $qualifiedPath; first = [string]$firstEntries[$entryPath].sha256; second = $null }); continue }
            if ([int64]$firstEntries[$entryPath].length -ne [int64]$secondEntries[$entryPath].length -or [string]$firstEntries[$entryPath].sha256 -cne [string]$secondEntries[$entryPath].sha256) {
                $differences.Add([pscustomobject][ordered]@{ kind = 'archive-entry-content'; path = $qualifiedPath; first = ('{0}:{1}' -f [int64]$firstEntries[$entryPath].length, [string]$firstEntries[$entryPath].sha256); second = ('{0}:{1}' -f [int64]$secondEntries[$entryPath].length, [string]$secondEntries[$entryPath].sha256) })
            }
        }
    }
    return $differences.ToArray()
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$outputRootPath = [IO.Path]::GetFullPath($OutputRoot)
$comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
Assert-PshGoal6Condition (-not [string]::Equals($outputRootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $repositoryRootPath, $comparison) -and -not $outputRootPath.StartsWith($repositoryRootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) 'Reproducibility OutputRoot must be outside the repository worktree.'
Assert-PshGoal6Condition (-not [IO.File]::Exists($outputRootPath) -and -not [IO.Directory]::Exists($outputRootPath)) "Reproducibility output root already exists: $outputRootPath"
foreach ($inputPath in @($ReleaseNotesPath, $ReleaseNotesZhCnPath)) { Assert-PshGoal6Condition ([IO.File]::Exists([IO.Path]::GetFullPath($inputPath))) "Release notes input is missing: $inputPath" }
[void][IO.Directory]::CreateDirectory($outputRootPath)
$manifestOne = $null
$manifestTwo = $null
$differences = @()
$failure = $null

try {
    $firstRun = Invoke-PshGoal6IndependentBuild -RunRoot (Join-Path $outputRootPath 'run-1') -RepositoryRootPath $repositoryRootPath -PackageVersion $Version -Commit $SourceCommit -EnglishReleaseNotes ([IO.Path]::GetFullPath($ReleaseNotesPath)) -ChineseReleaseNotes ([IO.Path]::GetFullPath($ReleaseNotesZhCnPath)) -RequestedMSBuildPath $MSBuildPath -WithTestFixtures:$IncludeTestFixtures
    $manifestOne = Get-PshGoal6BuildManifest -RunName 'run-1' -RunRoot ([string]$firstRun.runRoot) -BootstrapperSha256 ([string]$firstRun.bootstrapperSha256)
    Write-PshGoal6Json -Path (Join-Path $outputRootPath 'build-1.manifest.json') -InputObject $manifestOne

    $secondRun = Invoke-PshGoal6IndependentBuild -RunRoot (Join-Path $outputRootPath 'run-2') -RepositoryRootPath $repositoryRootPath -PackageVersion $Version -Commit $SourceCommit -EnglishReleaseNotes ([IO.Path]::GetFullPath($ReleaseNotesPath)) -ChineseReleaseNotes ([IO.Path]::GetFullPath($ReleaseNotesZhCnPath)) -RequestedMSBuildPath $MSBuildPath -WithTestFixtures:$IncludeTestFixtures
    $manifestTwo = Get-PshGoal6BuildManifest -RunName 'run-2' -RunRoot ([string]$secondRun.runRoot) -BootstrapperSha256 ([string]$secondRun.bootstrapperSha256)
    Write-PshGoal6Json -Path (Join-Path $outputRootPath 'build-2.manifest.json') -InputObject $manifestTwo
    $differences = @(Compare-PshGoal6BuildManifest -First $manifestOne -Second $manifestTwo)
}
catch { $failure = [string]$_.Exception.Message }

Write-PshGoal6Json -Path (Join-Path $outputRootPath 'reproducibility-diff.json') -InputObject $differences
$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    gate = 'reproducibility'
    status = if ($null -eq $failure -and $differences.Count -eq 0 -and $null -ne $manifestOne -and $null -ne $manifestTwo) { 'passed' } else { 'failed' }
    buildCount = 2
    existingBuildScripts = @('scripts/Build-PshBootstrapper.ps1', 'scripts/Build-PshPackages.ps1')
    bootstrapperBuiltIndependentlyTwice = $true
    packageBuildInvokedIndependentlyTwice = $true
    catalogInputs = 'deterministic reproducibility-only fixtures; not release trust evidence'
    stableFilePolicy = 'Compare relative paths, lengths, and per-file SHA256; exclude build logs and ZIP container bytes.'
    archivePolicy = 'Stream-extract normalized file entries and compare path, uncompressed length, and SHA256; ignore container timestamps and do not gate on whole-ZIP hashes.'
    firstStableFileCount = if ($null -eq $manifestOne) { 0 } else { @($manifestOne.stableFiles).Count }
    secondStableFileCount = if ($null -eq $manifestTwo) { 0 } else { @($manifestTwo.stableFiles).Count }
    firstArchiveCount = if ($null -eq $manifestOne) { 0 } else { @($manifestOne.normalizedArchives).Count }
    secondArchiveCount = if ($null -eq $manifestTwo) { 0 } else { @($manifestTwo.normalizedArchives).Count }
    differenceCount = $differences.Count
    manifests = @('build-1.manifest.json', 'build-2.manifest.json')
    diff = 'reproducibility-diff.json'
    error = $failure
}
$summaryPath = Join-Path $outputRootPath 'reproducibility-summary.json'
Write-PshGoal6Json -Path $summaryPath -InputObject $summary
if ($null -ne $failure) { throw "Reproducibility gate failed: $failure" }
if ($differences.Count -gt 0) { throw "Reproducibility gate found $($differences.Count) content difference(s). See $summaryPath" }
Write-Output ('Reproducibility gate passed: two independent bootstrapper/package builds produced identical stable file and normalized archive manifests.')
