# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$buildScript = Join-Path $RepositoryRoot 'scripts/Build-PshPackages.ps1'
$indexScript = Join-Path $RepositoryRoot 'scripts/Generate-PshReleaseIndex.ps1'
$artifactScript = Join-Path $RepositoryRoot 'scripts/Test-PshReleaseArtifacts.ps1'
$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$trustPath = Join-Path $RepositoryRoot 'src/install/ReleaseTrust.ps1'
if (-not [IO.File]::Exists($lifecyclePath) -or -not [IO.File]::Exists($trustPath)) { throw 'Package lifecycle or release trust helpers are missing.' }
. $lifecyclePath
. $trustPath

$script:Goal5PackageBuildAssertions = 0

function Assert-PshGoal5PackageBuild {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)

    $script:Goal5PackageBuildAssertions++
    if (-not $Condition) { throw "Goal 5 package build failed: $Message" }
}

function Get-PshGoal5FailureMetadata {
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshExitCode')) {
            return [pscustomobject]@{
                ExitCode = [int]$exception.Data['PshExitCode']
                ErrorId = [string]$exception.Data['PshErrorId']
            }
        }
        $exception = $exception.InnerException
    }
    return [pscustomobject]@{ ExitCode = 1; ErrorId = '' }
}

function Assert-PshGoal5PackageFailure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Label,
        [int] $ExitCode = 5
    )

    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        $metadata = Get-PshGoal5FailureMetadata -ErrorRecord $_
        Assert-PshGoal5PackageBuild ($metadata.ExitCode -eq $ExitCode) "$Label used exit code $($metadata.ExitCode), expected $ExitCode."
    }
    Assert-PshGoal5PackageBuild $failed "$Label unexpectedly succeeded."
}

function New-PshGoal5Directory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $full = [IO.Path]::GetFullPath($Path)
    [void](Assert-PshLifecycleNoReparseAncestors -Path $full -Description 'Goal 5 package build directory')
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { throw "Fixture path already exists: $full" }
    [void][IO.Directory]::CreateDirectory($full)
    return $full
}

function Write-PshGoal5Text {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function New-PshGoal5PeFixture {
    param([Parameter(Mandatory = $true)][string] $Path)

    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    $bytes[0x82] = 0
    $bytes[0x83] = 0
    [BitConverter]::GetBytes([uint16]0x014C).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Copy-PshGoal5ReleaseRoot {
    param([Parameter(Mandatory = $true)][string] $Source, [Parameter(Mandatory = $true)][string] $Destination)

    [void](New-PshGoal5Directory -Path $Destination)
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Force -File)) {
        $target = Join-Path $Destination $file.Name
        $linked = $false
        try {
            [void](New-Item -ItemType HardLink -Path $target -Target $file.FullName -ErrorAction Stop)
            $linked = $true
        }
        catch { }
        if (-not $linked) { [IO.File]::Copy($file.FullName, $target, $false) }
    }
}

function Set-PshGoal5OwnedFileBytes {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][byte[]] $Bytes)

    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-PshGoal5ZipMutation {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [hashtable] $Overrides = @{},
        [AllowNull()][object] $AdditionalEntry
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporary = $Path + '.mutation-' + [Guid]::NewGuid().ToString('N')
    $inputStream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    $outputStream = New-Object IO.FileStream($temporary, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None))
    try {
        $sourceArchive = New-Object IO.Compression.ZipArchive($inputStream, [IO.Compression.ZipArchiveMode]::Read, $true, (New-Object Text.UTF8Encoding($false, $true)))
        $targetArchive = New-Object IO.Compression.ZipArchive($outputStream, [IO.Compression.ZipArchiveMode]::Create, $true, (New-Object Text.UTF8Encoding($false)))
        try {
            foreach ($sourceEntry in @($sourceArchive.Entries)) {
                $source = $sourceEntry.Open()
                $memory = New-Object IO.MemoryStream
                try { $source.CopyTo($memory); $bytes = $memory.ToArray() }
                finally { $memory.Dispose(); $source.Dispose() }
                if ($Overrides.ContainsKey([string]$sourceEntry.FullName)) { $bytes = [byte[]]$Overrides[[string]$sourceEntry.FullName] }
                $targetEntry = $targetArchive.CreateEntry([string]$sourceEntry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                $targetEntry.LastWriteTime = $sourceEntry.LastWriteTime
                $targetEntry.ExternalAttributes = $sourceEntry.ExternalAttributes
                $target = $targetEntry.Open()
                try { $target.Write($bytes, 0, $bytes.Length) }
                finally { $target.Dispose() }
            }
            if ($null -ne $AdditionalEntry) {
                $targetEntry = $targetArchive.CreateEntry([string]$AdditionalEntry.Name, [IO.Compression.CompressionLevel]::Optimal)
                $targetEntry.LastWriteTime = New-Object DateTimeOffset(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $targetEntry.ExternalAttributes = [int]$AdditionalEntry.ExternalAttributes
                $bytes = [byte[]]$AdditionalEntry.Bytes
                $target = $targetEntry.Open()
                try { $target.Write($bytes, 0, $bytes.Length) }
                finally { $target.Dispose() }
            }
        }
        finally { $targetArchive.Dispose(); $sourceArchive.Dispose() }
    }
    finally { $outputStream.Dispose(); $inputStream.Dispose() }
    [IO.File]::Delete($Path)
    [IO.File]::Move($temporary, $Path)
}

function Get-PshGoal5ZipEntryBytes {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $EntryName)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $matches = @($archive.Entries | Where-Object { [string]$_.FullName -ceq $EntryName })
        if ($matches.Count -ne 1) { throw "ZIP entry not found exactly once: $EntryName" }
        $input = $matches[0].Open()
        $memory = New-Object IO.MemoryStream
        try { $input.CopyTo($memory); return (, $memory.ToArray()) }
        finally { $memory.Dispose(); $input.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Update-PshGoal5ReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $AssetName,
        [AllowNull()][byte[]] $ManifestBytes
    )

    $indexPath = Join-Path $Root "psh-release-$Version.json"
    $index = [IO.File]::ReadAllText($indexPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json -ErrorAction Stop
    $matches = @($index.assets | Where-Object { [string]$_.name -ceq $AssetName })
    if ($matches.Count -ne 1) { throw "Release index asset is missing: $AssetName" }
    $assetPath = Join-Path $Root $AssetName
    $state = Get-PshLifecycleFileSha256 -Path $assetPath
    $matches[0].length = [int64]$state.Length
    $matches[0].sha256 = [string]$state.Sha256
    if ($null -ne $ManifestBytes) {
        $manifest = (New-Object Text.UTF8Encoding($false, $true)).GetString($ManifestBytes) | ConvertFrom-Json -ErrorAction Stop
        $matches[0].package.packageManifestSha256 = Get-PshLifecycleSha256Bytes -Bytes $ManifestBytes
        $matches[0].package.treeSha256 = [string]$manifest.treeSha256
    }
    Write-PshGoal5Text -Path $indexPath -Text ((ConvertTo-PshCanonicalJson -InputObject $index) + "`n")
    $checksumLines = @($index.assets | ForEach-Object { '{0}  {1}' -f [string]$_.sha256, [string]$_.name })
    Write-PshGoal5Text -Path (Join-Path $Root 'SHA256SUMS') -Text (([string]::Join("`n", $checksumLines)) + "`n")
}

function Test-PshGoal5StandaloneInstaller {
    param([Parameter(Mandatory = $true)][string] $InstallerPath, [Parameter(Mandatory = $true)][string] $IsolatedRoot)

    [void](New-PshGoal5Directory -Path $IsolatedRoot)
    $isolatedPath = Join-Path $IsolatedRoot 'install.ps1'
    [IO.File]::Copy($InstallerPath, $isolatedPath, $false)
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $isolatedPath
    try {
        return & $module {
            $required = @('Invoke-PshOnlineInstall', 'Confirm-PshReleaseTrustBundle', 'Save-PshTrustedReleaseAsset', 'Read-PshPackageManifest')
            foreach ($name in $required) {
                if ($null -eq (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) {
                    return [pscustomobject]@{ Loaded = $false; ExitCode = 1; ErrorId = "missing:$name" }
                }
            }
            try { Throw-PshOnlineEntryError -ExitCode 4 -Kind 'Dependency' -ErrorId 'PshStandaloneProbe' -Message 'standalone probe' }
            catch {
                $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
                return [pscustomobject]@{ Loaded = $true; ExitCode = [int]$metadata.ExitCode; ErrorId = [string]$metadata.ErrorId }
            }
        }
    }
    finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
}

foreach ($path in @($buildScript, $indexScript, $artifactScript, $lifecyclePath, $trustPath)) {
    Assert-PshGoal5PackageBuild ([IO.File]::Exists($path)) "Required package build file is missing: $path"
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-PshGoal5PackageBuild (@($errors).Count -eq 0) "PowerShell parser errors were found in $path"
}

$reportRootValue = [Environment]::GetEnvironmentVariable('PSH_GOAL5_REPORT_ROOT')
if ([string]::IsNullOrWhiteSpace($reportRootValue)) {
    $reportRootValue = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-报告 空格-' + [Guid]::NewGuid().ToString('N'))
}
$reportRoot = [IO.Path]::GetFullPath($reportRootValue)
[void](Assert-PshLifecycleNoReparseAncestors -Path $reportRoot -Description 'Goal 5 report root')
if (-not [IO.Directory]::Exists($reportRoot)) { [void][IO.Directory]::CreateDirectory($reportRoot) }
$preSignValue = [Environment]::GetEnvironmentVariable('PSH_GOAL5_PRE_SIGN_ROOT')
if ([string]::IsNullOrWhiteSpace($preSignValue)) { $preSignValue = Join-Path $reportRoot 'pre-sign-build' }
$preSignRoot = [IO.Path]::GetFullPath($preSignValue)
$reportPrefix = $reportRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
Assert-PshGoal5PackageBuild ($preSignRoot.StartsWith($reportPrefix, (Get-PshLifecyclePathComparison))) 'PSH_GOAL5_PRE_SIGN_ROOT must be inside PSH_GOAL5_REPORT_ROOT.'
Assert-PshGoal5PackageBuild (-not [IO.File]::Exists($preSignRoot) -and -not [IO.Directory]::Exists($preSignRoot)) 'Pre-sign report root must start absent.'

$workRoot = New-PshGoal5Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('psh-goal5-work-中文 空格-' + [Guid]::NewGuid().ToString('N')))
$fixtureRoot = New-PshGoal5Directory -Path (Join-Path $workRoot '输入 fixtures')
$bootstrapperPath = Join-Path $fixtureRoot 'psh-installer.exe'
$releaseNotesPath = Join-Path $fixtureRoot 'RELEASE_NOTES.md'
$releaseNotesZhPath = Join-Path $fixtureRoot 'RELEASE_NOTES.zh-CN.md'
New-PshGoal5PeFixture -Path $bootstrapperPath
Write-PshGoal5Text -Path $releaseNotesPath -Text "# Release 1.2.3`n"
Write-PshGoal5Text -Path $releaseNotesZhPath -Text "# 版本 1.2.3`n"

$version = '1.2.3'
$commit = '1234567890abcdef1234567890abcdef12345678'
$baseBuildParameters = @{
    Version = $version
    SourceCommit = $commit
    RepositoryRoot = $RepositoryRoot
    OnlineInstallerPath = (Join-Path $RepositoryRoot 'src/install/install.ps1')
    OfflineInstallerPath = (Join-Path $RepositoryRoot 'src/install/install-offline.ps1')
    ShellInstallerPath = (Join-Path $RepositoryRoot 'src/install/install.sh')
    UninstallerPath = (Join-Path $RepositoryRoot 'src/install/Uninstall-Psh.ps1')
    BootstrapperPath = $bootstrapperPath
    ReleaseNotesPath = $releaseNotesPath
    ReleaseNotesZhCnPath = $releaseNotesZhPath
}

$missingParameters = @{} + $baseBuildParameters
$missingParameters.OutputRoot = Join-Path $workRoot 'missing-input-output'
$missingParameters.ReleaseNotesPath = Join-Path $fixtureRoot 'missing-release-notes.md'
Assert-PshGoal5PackageFailure -Label 'missing required build input' -ExitCode 4 -Action { & $buildScript @missingParameters }
Assert-PshGoal5PackageBuild (-not [IO.Directory]::Exists([string]$missingParameters.OutputRoot)) 'Missing-input build created an output root.'

$firstParameters = @{} + $baseBuildParameters
$firstParameters.OutputRoot = $preSignRoot
$firstBuild = @(& $buildScript @firstParameters)[-1]
Assert-PshGoal5PackageBuild ([int]$firstBuild.code -eq 4 -and [string]$firstBuild.phase -ceq 'pre-sign') 'Pre-sign build did not report deferred code 4 state.'
Assert-PshGoal5PackageBuild (@($firstBuild.packages).Count -eq 3) 'Public pre-sign build did not create three package slots.'
Assert-PshGoal5PackageBuild (@(Get-ChildItem -LiteralPath $preSignRoot -Recurse -Force -File -Filter '*.cat').Count -eq 0) 'Pre-sign build fabricated a catalog.'

$secondRoot = Join-Path $workRoot 'determinism build 二'
$secondParameters = @{} + $baseBuildParameters
$secondParameters.OutputRoot = $secondRoot
$secondBuild = @(& $buildScript @secondParameters)[-1]
foreach ($package in @($firstBuild.packages)) {
    $relative = [string]$package.stagingRelativePath
    $firstManifest = Join-Path $preSignRoot (Join-Path $relative 'package.manifest.json')
    $secondManifest = Join-Path $secondRoot (Join-Path $relative 'package.manifest.json')
    Assert-PshGoal5PackageBuild ((Get-PshLifecycleFileSha256 -Path $firstManifest).Sha256 -ceq (Get-PshLifecycleFileSha256 -Path $secondManifest).Sha256) "Deterministic manifest bytes changed for $($package.name)."
    $firstDocument = Read-PshPackageManifest -Path $firstManifest
    $secondDocument = Read-PshPackageManifest -Path $secondManifest
    Assert-PshGoal5PackageBuild ([string]$firstDocument.treeSha256 -ceq [string]$secondDocument.treeSha256) "Deterministic treeSha256 changed for $($package.name)."
}
Assert-PshGoal5PackageBuild ([string]$firstBuild.onlineInstaller.embeddedSha256 -ceq [string]$secondBuild.onlineInstaller.embeddedSha256) 'Embedded online installer hash changed across deterministic builds.'

$catalogRoot = New-PshGoal5Directory -Path (Join-Path $workRoot '外部 package catalogs')
foreach ($name in @(
        "psh-$version-core", "psh-$version-full-win-x64", "psh-$version-full-win-arm64",
        'psh-0.0.1-test-core', 'psh-0.0.1-test-full-win-x64', 'psh-0.0.1-test-full-win-arm64'
    )) {
    Write-PshGoal5Text -Path (Join-Path $catalogRoot ($name + '.manifest.cat')) -Text "external catalog fixture for $name`n"
}
$finalRoot = Join-Path $workRoot 'finalized build 含 fixtures'
$finalParameters = @{} + $baseBuildParameters
$finalParameters.OutputRoot = $finalRoot
$finalParameters.IncludeTestFixtures = $true
$finalParameters.Finalize = $true
$finalParameters.PackageCatalogRoot = $catalogRoot
$finalBuild = @(& $buildScript @finalParameters)[-1]
Assert-PshGoal5PackageBuild (@($finalBuild.packages).Count -eq 6) 'Finalized fixture build did not create six internal package slots.'
Assert-PshGoal5PackageBuild (@($finalBuild.packages | Where-Object { [bool]$_.testOnly }).Count -eq 3) 'Finalized fixture build did not mark three synthetic package slots testOnly.'
$releaseRoot = Join-Path $finalRoot 'release-assets'
$publicNamesBeforeIndex = @(Get-ChildItem -LiteralPath $releaseRoot -Force -File | ForEach-Object { $_.Name })
Assert-PshGoal5PackageBuild (@($publicNamesBeforeIndex | Where-Object { $_ -match '0\.0\.1-test' }).Count -eq 0) 'Synthetic packages entered public release assets.'
Assert-PshGoal5PackageBuild (@($publicNamesBeforeIndex).Count -eq 10) 'Build did not emit exactly ten public content assets before index generation.'

$indexBuild = @(& $indexScript -ReleaseAssetsRoot $releaseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot)[-1]
Assert-PshGoal5PackageBuild ([int]$indexBuild.code -eq 4 -and [string]$indexBuild.phase -ceq 'catalog-deferred') 'Index generation did not report catalog-deferred code 4 state.'
Assert-PshGoal5PackageBuild (-not [IO.File]::Exists((Join-Path $releaseRoot "psh-release-$version.cat"))) 'Deferred index generation fabricated a release catalog.'
$indexDocument = Read-PshReleaseIndex -Path (Join-Path $releaseRoot "psh-release-$version.json")
Assert-PshGoal5PackageBuild (@($indexDocument.assets | Where-Object { [string]$_.name -match '0\.0\.1-test' -or ($null -ne $_.package -and [bool]$_.package.testOnly) }).Count -eq 0) 'Synthetic package metadata entered the public release index.'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $externalReleaseCatalog = Join-Path $fixtureRoot "psh-release-$version.external.cat"
    Write-PshGoal5Text -Path $externalReleaseCatalog -Text "external signed catalog placeholder`n"
    Assert-PshGoal5PackageFailure -Label 'non-Windows release catalog finalization' -ExitCode 4 -Action {
        & $indexScript -ReleaseAssetsRoot $releaseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Finalize -ReleaseCatalogPath $externalReleaseCatalog
    }
    Assert-PshGoal5PackageBuild (-not [IO.File]::Exists((Join-Path $releaseRoot "psh-release-$version.cat"))) 'Non-Windows finalization published an unverified release catalog.'
}

$artifactReportPath = Join-Path $reportRoot 'release-artifacts-report.json'
$artifactResult = @(& $artifactScript -ReleaseAssetsRoot $releaseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage -ReportPath $artifactReportPath)[-1]
Assert-PshGoal5PackageBuild ([int]$artifactResult.code -eq 4 -and [string]$artifactResult.phase -ceq 'static-verified-signatures-deferred') 'Build-stage release artifact verification did not return code 4 deferred state.'
Assert-PshGoal5PackageBuild ([int]$artifactResult.packageCount -eq 3 -and [int]$artifactResult.assetCount -eq 12) 'Build-stage release artifact verification counted the wrong assets or packages.'
Assert-PshGoal5PackageBuild ([IO.File]::Exists($artifactReportPath) -and ([IO.FileInfo]$artifactReportPath).Length -gt 0) 'Release artifact verification report is missing or empty.'

$standalone = Test-PshGoal5StandaloneInstaller -InstallerPath (Join-Path $releaseRoot 'install.ps1') -IsolatedRoot (Join-Path $workRoot 'standalone install asset')
Assert-PshGoal5PackageBuild ([bool]$standalone.Loaded -and [int]$standalone.ExitCode -eq 4 -and [string]$standalone.ErrorId -ceq 'PshStandaloneProbe') 'Self-contained install.ps1 did not load without adjacent helpers and preserve structured fail-closed metadata.'

$tamperRoot = Join-Path $workRoot 'mutation tamper'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $tamperRoot
$tamperPath = Join-Path $tamperRoot 'install.sh'
Set-PshGoal5OwnedFileBytes -Path $tamperPath -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes('# tampered'))
Assert-PshGoal5PackageFailure -Label 'tampered release asset' -Action { & $artifactScript -ReleaseAssetsRoot $tamperRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$missingRoot = Join-Path $workRoot 'mutation missing'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $missingRoot
[IO.File]::Delete((Join-Path $missingRoot 'install.sh'))
Assert-PshGoal5PackageFailure -Label 'missing release asset' -ExitCode 4 -Action { & $artifactScript -ReleaseAssetsRoot $missingRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$extraRoot = Join-Path $workRoot 'mutation extra'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $extraRoot
Write-PshGoal5Text -Path (Join-Path $extraRoot 'unexpected.txt') -Text "unexpected`n"
Assert-PshGoal5PackageFailure -Label 'extra release asset' -Action { & $artifactScript -ReleaseAssetsRoot $extraRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$coreName = "psh-$version-core.zip"
$duplicateRoot = Join-Path $workRoot 'mutation duplicate zip'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $duplicateRoot
$duplicateZip = Join-Path $duplicateRoot $coreName
New-PshGoal5ZipMutation -Path $duplicateZip -AdditionalEntry ([pscustomobject]@{ Name = 'INSTALL.PS1'; Bytes = [byte[]](1, 2, 3); ExternalAttributes = 0 })
Update-PshGoal5ReleaseMetadata -Root $duplicateRoot -Version $version -AssetName $coreName
Assert-PshGoal5PackageFailure -Label 'case-insensitive duplicate ZIP entry' -Action { & $artifactScript -ReleaseAssetsRoot $duplicateRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$slipRoot = Join-Path $workRoot 'mutation zip slip'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $slipRoot
$slipZip = Join-Path $slipRoot $coreName
New-PshGoal5ZipMutation -Path $slipZip -AdditionalEntry ([pscustomobject]@{ Name = '../escape.txt'; Bytes = [byte[]](1); ExternalAttributes = 0 })
Update-PshGoal5ReleaseMetadata -Root $slipRoot -Version $version -AssetName $coreName
Assert-PshGoal5PackageFailure -Label 'ZIP traversal entry' -Action { & $artifactScript -ReleaseAssetsRoot $slipRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$reparseRoot = Join-Path $workRoot 'mutation reparse zip'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $reparseRoot
$reparseZip = Join-Path $reparseRoot $coreName
$symlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2684354560), 0)
New-PshGoal5ZipMutation -Path $reparseZip -AdditionalEntry ([pscustomobject]@{ Name = 'payload/Psh/link'; Bytes = (New-Object Text.UTF8Encoding($false)).GetBytes('target'); ExternalAttributes = $symlinkAttributes })
Update-PshGoal5ReleaseMetadata -Root $reparseRoot -Version $version -AssetName $coreName
Assert-PshGoal5PackageFailure -Label 'ZIP symlink/reparse entry' -Action { & $artifactScript -ReleaseAssetsRoot $reparseRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$x64Name = "psh-$version-full-win-x64.zip"
$wrongArchitectureRoot = Join-Path $workRoot 'mutation wrong architecture'
Copy-PshGoal5ReleaseRoot -Source $releaseRoot -Destination $wrongArchitectureRoot
$wrongArchitectureZip = Join-Path $wrongArchitectureRoot $x64Name
$toolPath = 'payload/Psh/Tools/win-x64/bat/bat.exe'
$toolBytes = Get-PshGoal5ZipEntryBytes -Path $wrongArchitectureZip -EntryName $toolPath
$peOffset = [BitConverter]::ToInt32($toolBytes, 0x3C)
[BitConverter]::GetBytes([uint16]0xAA64).CopyTo($toolBytes, $peOffset + 4)
$manifestBytes = Get-PshGoal5ZipEntryBytes -Path $wrongArchitectureZip -EntryName 'package.manifest.json'
$manifest = (New-Object Text.UTF8Encoding($false, $true)).GetString($manifestBytes) | ConvertFrom-Json -ErrorAction Stop
$manifestEntry = @($manifest.files | Where-Object { [string]$_.relativePath -ceq $toolPath })
Assert-PshGoal5PackageBuild ($manifestEntry.Count -eq 1) 'Wrong-architecture fixture could not find the selected tool manifest entry.'
$manifestEntry[0].sha256 = Get-PshLifecycleSha256Bytes -Bytes $toolBytes
$manifest.treeSha256 = Get-PshPackageTreeDigest -Manifest $manifest
$newManifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-PshCanonicalJson -InputObject $manifest) + "`n")
$overrides = @{}
$overrides[$toolPath] = $toolBytes
$overrides['package.manifest.json'] = $newManifestBytes
New-PshGoal5ZipMutation -Path $wrongArchitectureZip -Overrides $overrides
Update-PshGoal5ReleaseMetadata -Root $wrongArchitectureRoot -Version $version -AssetName $x64Name -ManifestBytes $newManifestBytes
Assert-PshGoal5PackageFailure -Label 'wrong native tool architecture' -Action { & $artifactScript -ReleaseAssetsRoot $wrongArchitectureRoot -Version $version -SourceCommit $commit -RepositoryRoot $RepositoryRoot -Mode BuildStage }

$packageReport = [pscustomobject][ordered]@{
    schemaVersion = 1
    product = 'Psh'
    version = $version
    sourceCommit = $commit
    assertions = $script:Goal5PackageBuildAssertions + 3
    preSignRoot = $preSignRoot
    releaseAssetsRoot = $releaseRoot
    deterministicPackages = 3
    fixturePackages = 6
    publicPackages = 3
    indexPhase = [string]$indexBuild.phase
    artifactPhase = [string]$artifactResult.phase
    negativeCases = @('tamper', 'missing', 'extra', 'duplicate', 'zip-slip', 'reparse', 'wrong-architecture')
}
$packageReportPath = Join-Path $reportRoot 'package-build-report.json'
Assert-PshGoal5PackageBuild (-not [IO.File]::Exists($packageReportPath)) 'Package build report path already exists.'
Write-PshGoal5Text -Path $packageReportPath -Text ((ConvertTo-PshCanonicalJson -InputObject $packageReport) + "`n")
Assert-PshGoal5PackageBuild ([IO.File]::Exists($packageReportPath) -and ([IO.FileInfo]$packageReportPath).Length -gt 0) 'Package build report is missing or empty.'
Assert-PshGoal5PackageBuild (@(Get-ChildItem -LiteralPath $reportRoot -Force).Count -gt 0) 'Goal 5 report root is empty.'

Write-Output ("Goal 5 package build passed ({0} assertions); reports: {1}" -f $script:Goal5PackageBuildAssertions, $reportRoot)
