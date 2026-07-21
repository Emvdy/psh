# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$script:Goal5Assertions = 0
$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
. $lifecyclePath

function Assert-PshGoal5 {
    param([Parameter(Mandatory = $true)][bool] $Condition, [Parameter(Mandatory = $true)][string] $Message)
    $script:Goal5Assertions++
    if (-not $Condition) { throw "Goal 5 package lifecycle failed: $Message" }
}

function Assert-PshGoal5Failure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $Label,
        [Parameter()][string] $ErrorId
    )
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        $metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_
        Assert-PshGoal5 ([int]$metadata.ExitCode -eq $ExitCode) "$Label used exit code $($metadata.ExitCode), expected $ExitCode."
        if (-not [string]::IsNullOrEmpty($ErrorId)) {
            Assert-PshGoal5 ([string]$metadata.ErrorId -ceq $ErrorId) "$Label used error id $($metadata.ErrorId), expected $ErrorId."
        }
    }
    Assert-PshGoal5 $failed "$Label unexpectedly succeeded."
}

function Write-PshGoal5Text {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-PshGoal5FileRecord {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelativePath, [Parameter(Mandatory = $true)][string] $Role)
    $path = Join-Path $Root $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $hash = Get-PshLifecycleFileSha256 -Path $path
    return [pscustomobject][ordered]@{
        relativePath = $RelativePath
        length       = [int64]$hash.Length
        sha256       = [string]$hash.Sha256
        role         = $Role
    }
}

function Copy-PshGoal5JsonObject {
    param([Parameter(Mandatory = $true)][object] $InputObject)
    return (ConvertTo-PshCanonicalJson -InputObject $InputObject) | ConvertFrom-Json
}

function Get-PshGoal5IndependentTreeHash {
    param([Parameter(Mandatory = $true)][object[]] $Files)
    $paths = @($Files | ForEach-Object { [string]$_.relativePath })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    foreach ($path in $paths) {
        $entry = @($Files | Where-Object { [string]$_.relativePath -ceq $path })[0]
        [void]$builder.Append($path)
        [void]$builder.Append("`t")
        [void]$builder.Append(([int64]$entry.length).ToString([Globalization.CultureInfo]::InvariantCulture))
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$entry.sha256)
        [void]$builder.Append("`n")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($builder.ToString())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

Assert-PshGoal5 (Test-Path -LiteralPath $lifecyclePath -PathType Leaf) 'PackageLifecycle.ps1 is missing.'
$publicFunctions = @(
    'Read-PshPackageManifest', 'Test-PshPackageTree', 'Get-PshPackageTreeDigest',
    'Write-PshCanonicalJsonAtomic', 'Enter-PshInstallRootLock', 'Exit-PshInstallRootLock',
    'Read-PshOwnershipState', 'Write-PshOwnershipState', 'Remove-PshOwnershipState',
    'Read-PshTransactionState', 'Write-PshTransactionState', 'Remove-PshTransactionState',
    'Get-PshRecoveryDecision', 'Get-PshLifecycleErrorMetadata'
)
foreach ($name in $publicFunctions) {
    Assert-PshGoal5 ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "Public helper is missing: $name"
}

$canonical = ConvertTo-PshCanonicalJson -InputObject ([ordered]@{ z = '中文 path'; a = @($true, $null, 2) })
Assert-PshGoal5 ($canonical -ceq '{"a":[true,null,2],"z":"中文 path"}') 'Canonical JSON did not sort keys ordinally or preserve Unicode.'
Assert-PshGoal5 ((Get-PshCanonicalJsonSha256 -InputObject ([ordered]@{ b = 2; a = 1 })) -ceq '43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777') 'Canonical JSON SHA256 is unstable.'
$canonicalEscapeInput = [ordered]@{
    quote = [string][char]0x22
    backslash = [string][char]0x5C
    newline = "`n"
    tab = "`t"
    backspace = [string][char]0x08
    formfeed = [string][char]0x0C
    carriageReturn = "`r"
    control = [string][char]0x01
    windowsPath = 'C:\Users\中文 路径\Psh'
}
$canonicalEscapes = ConvertTo-PshCanonicalJson -InputObject $canonicalEscapeInput
$expectedCanonicalEscapes = '{"backslash":"\\","backspace":"\b","carriageReturn":"\r","control":"\u0001","formfeed":"\f","newline":"\n","quote":"\"","tab":"\t","windowsPath":"C:\\Users\\中文 路径\\Psh"}'
Assert-PshGoal5 ($canonicalEscapes -ceq $expectedCanonicalEscapes) 'Canonical JSON string escapes are not byte-exact.'
$canonicalEscapeRoundTrip = $canonicalEscapes | ConvertFrom-Json -ErrorAction Stop
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.quote -ceq [string]$canonicalEscapeInput.quote) 'Canonical quote escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.backslash -ceq [string]$canonicalEscapeInput.backslash) 'Canonical backslash escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.newline -ceq [string]$canonicalEscapeInput.newline) 'Canonical newline escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.tab -ceq [string]$canonicalEscapeInput.tab) 'Canonical tab escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.backspace -ceq [string]$canonicalEscapeInput.backspace) 'Canonical backspace escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.formfeed -ceq [string]$canonicalEscapeInput.formfeed) 'Canonical form-feed escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.carriageReturn -ceq [string]$canonicalEscapeInput.carriageReturn) 'Canonical carriage-return escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.control -ceq [string]$canonicalEscapeInput.control) 'Canonical generic control escape did not round-trip.'
Assert-PshGoal5 ([string]$canonicalEscapeRoundTrip.windowsPath -ceq [string]$canonicalEscapeInput.windowsPath) 'Canonical Windows path did not round-trip.'
$canonicalEscapeHash = Get-PshCanonicalJsonSha256 -InputObject $canonicalEscapeInput
Assert-PshGoal5 ($canonicalEscapeHash -ceq '06f0e443cc92130299e8c37939ba00fe9025216d1d9177dd05ed38864abbe4b1') 'Canonical escaped-string SHA256 changed from the frozen value.'
Assert-PshGoal5 ((Get-PshCanonicalJsonSha256 -InputObject $canonicalEscapeInput) -ceq $canonicalEscapeHash) 'Canonical escaped-string SHA256 is not stable across calls.'

foreach ($case in @(
    @{ Path = '/absolute'; Id = 'PshAbsolutePath' },
    @{ Path = 'C:/absolute'; Id = 'PshAbsolutePath' },
    @{ Path = '.'; Id = 'PshTraversalPath' },
    @{ Path = 'a/../b'; Id = 'PshTraversalPath' },
    @{ Path = 'a\b'; Id = 'PshBackslashPath' },
    @{ Path = 'con.txt'; Id = 'PshReservedPathName' },
    @{ Path = 'folder/LPT9.log'; Id = 'PshReservedPathName' },
    @{ Path = "line`nbreak"; Id = 'PshControlPath' },
    @{ Path = 'trailing.'; Id = 'PshTrailingPathCharacter' }
)) {
    $pathValue = [string]$case.Path
    Assert-PshGoal5Failure -Action { Assert-PshLifecycleRelativePath -Value $pathValue -Description 'fixture path' } -ExitCode 5 -ErrorId ([string]$case.Id) -Label "unsafe path '$pathValue'"
}
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void](Assert-PshLifecycleRelativePath -Value 'Payload/File.txt' -Description 'fixture path' -Seen $seenPaths)
Assert-PshGoal5Failure -Action { Assert-PshLifecycleRelativePath -Value 'payload/file.TXT' -Description 'fixture path' -Seen $seenPaths } -ExitCode 5 -ErrorId PshDuplicatePath -Label 'case-insensitive duplicate path'

$temporaryBase = [IO.Path]::GetTempPath()
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and [IO.Directory]::Exists('/private/tmp')) {
    $temporaryBase = '/private/tmp'
}
$temporaryRoot = Join-Path $temporaryBase ('psh-goal5-lifecycle-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $packageRoot = Join-Path $temporaryRoot 'package with 中文'
    [void][IO.Directory]::CreateDirectory($packageRoot)
    $fixtureFiles = [ordered]@{
        'payload/Psh/Psh.psd1' = @{ Text = "@{ ModuleVersion = '0.1.0' }`n"; Role = 'payload' }
        'payload/Psh/Psh.psm1' = @{ Text = "function Get-PshFixture { 'ok' }`n"; Role = 'payload' }
        'install-offline.ps1'  = @{ Text = "# offline installer`n"; Role = 'entrypoint' }
        'uninstall.ps1'        = @{ Text = "# uninstaller`n"; Role = 'entrypoint' }
        'install.sh'           = @{ Text = "#!/bin/sh`nexit 0`n"; Role = 'entrypoint' }
        'psh-installer.exe'    = @{ Text = 'AnyCPU fixture'; Role = 'bootstrapper' }
        'LICENSE'              = @{ Text = "GPL-3.0-or-later`n"; Role = 'license' }
        'sbom.spdx.json'       = @{ Text = "{}`n"; Role = 'sbom' }
    }
    foreach ($relative in $fixtureFiles.Keys) {
        Write-PshGoal5Text -Path (Join-Path $packageRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Text ([string]$fixtureFiles[$relative].Text)
    }
    $records = @($fixtureFiles.Keys | ForEach-Object { Get-PshGoal5FileRecord -Root $packageRoot -RelativePath $_ -Role ([string]$fixtureFiles[$_].Role) })
    $treeSha = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $records })
    Assert-PshGoal5 ($treeSha -ceq (Get-PshGoal5IndependentTreeHash -Files $records)) 'Tree digest does not match the frozen canonical line algorithm.'
    $bootstrapRecord = @($records | Where-Object relativePath -CEQ 'psh-installer.exe')[0]
    $manifest = [pscustomobject][ordered]@{
        schemaVersion         = 1
        product               = 'Psh'
        version               = '0.1.0-test.1'
        edition               = 'Core'
        architecture          = 'any'
        payloadRoot           = 'payload'
        files                 = $records
        treeSha256            = $treeSha
        entrypoints           = [pscustomobject][ordered]@{
            offlinePowerShell   = 'install-offline.ps1'
            uninstallPowerShell = 'uninstall.ps1'
            shell               = 'install.sh'
            bootstrapper        = 'psh-installer.exe'
        }
        testOnly              = $true
        source                = [pscustomobject][ordered]@{
            repository = 'https://github.com/Emvdy/psh'
            commit     = '0123456789abcdef0123456789abcdef01234567'
        }
        bootstrapper          = [pscustomobject][ordered]@{
            relativePath = 'psh-installer.exe'
            sha256       = [string]$bootstrapRecord.sha256
            anyCpu       = $true
        }
        nativeToolsLockSha256 = $null
    }
    $manifestPath = Join-Path $packageRoot 'package.manifest.json'
    $manifestWrite = Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $manifest
    Assert-PshGoal5 ([string]$manifestWrite.Sha256 -match '\A[0-9a-f]{64}\z') 'Atomic manifest writer did not return a SHA256.'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    Assert-PshGoal5 (-not ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF)) 'Atomic JSON writer emitted a UTF-8 BOM.'
    Assert-PshGoal5 ($manifestBytes[$manifestBytes.Length - 1] -eq 0x0A) 'Atomic JSON writer did not emit one LF terminator.'
    $parsedManifest = Read-PshPackageManifest -Path $manifestPath
    Assert-PshGoal5 ([string]$parsedManifest.version -ceq '0.1.0-test.1' -and [string]$parsedManifest.architecture -ceq 'any') 'Valid Core manifest did not round-trip.'
    $verification = Test-PshPackageTree -PackageRoot $packageRoot -Manifest $parsedManifest
    Assert-PshGoal5 ([bool]$verification.Verified -and [int]$verification.FileCount -eq $records.Count -and [string]$verification.TreeSha256 -ceq $treeSha) 'Valid package tree did not verify.'

    # Existing-file replacement exercises File.Replace, not only first-write Move.
    $manifestWrite2 = Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $manifest
    Assert-PshGoal5 ([IO.File]::Exists($manifestPath) -and [string]$manifestWrite2.Sha256 -ceq [string]$manifestWrite.Sha256) 'Atomic replacement changed canonical bytes.'

    $modulePath = Join-Path $packageRoot 'payload/Psh/Psh.psm1'
    $originalModule = [IO.File]::ReadAllBytes($modulePath)
    [IO.File]::WriteAllText($modulePath, 'tampered', (New-Object Text.UTF8Encoding($false)))
    Assert-PshGoal5Failure -Action { Test-PshPackageTree -PackageRoot $packageRoot -Manifest $parsedManifest } -ExitCode 5 -ErrorId PshPackageFileMismatch -Label 'tampered package file'
    [IO.File]::WriteAllBytes($modulePath, $originalModule)
    Write-PshGoal5Text -Path (Join-Path $packageRoot 'unexpected.txt') -Text 'extra'
    Assert-PshGoal5Failure -Action { Test-PshPackageTree -PackageRoot $packageRoot -Manifest $parsedManifest } -ExitCode 5 -ErrorId PshPackageFileSet -Label 'unexpected package file'
    [IO.File]::Delete((Join-Path $packageRoot 'unexpected.txt'))

    $unknownManifest = Copy-PshGoal5JsonObject $manifest
    $unknownManifest | Add-Member -NotePropertyName unknownField -NotePropertyValue $true
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $unknownManifest | Out-Null
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshUnknownField -Label 'unknown manifest field'
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $manifest | Out-Null

    $duplicateJson = '{"schemaVersion":1,"schemaVersion":1}'
    [IO.File]::WriteAllText($manifestPath, $duplicateJson, (New-Object Text.UTF8Encoding($false)))
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshDuplicateField -Label 'duplicate JSON key'
    $caseDuplicateJson = '{"schemaVersion":1,"SchemaVersion":1}'
    [IO.File]::WriteAllText($manifestPath, $caseDuplicateJson, (New-Object Text.UTF8Encoding($false)))
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshDuplicateField -Label 'case-variant duplicate JSON key'
    $missingProductManifest = Copy-PshGoal5JsonObject $manifest
    $missingProductManifest.PSObject.Properties.Remove('product')
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $missingProductManifest | Out-Null
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshMissingField -Label 'missing ordinary required manifest field'
    $missingNullableManifest = Copy-PshGoal5JsonObject $manifest
    $missingNullableManifest.PSObject.Properties.Remove('nativeToolsLockSha256')
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $missingNullableManifest | Out-Null
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshMissingField -Label 'missing nullable required manifest field'
    $bom = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-PshCanonicalJson $manifest), $bom)
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshJsonBom -Label 'BOM package manifest'
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $manifest | Out-Null

    $caseManifest = Copy-PshGoal5JsonObject $manifest
    $caseManifest.files[1].relativePath = ([string]$caseManifest.files[0].relativePath).ToUpperInvariant()
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $caseManifest | Out-Null
    Assert-PshGoal5Failure -Action { Read-PshPackageManifest -Path $manifestPath } -ExitCode 5 -ErrorId PshDuplicatePath -Label 'case-insensitive manifest path collision'
    Write-PshCanonicalJsonAtomic -Path $manifestPath -InputObject $manifest | Out-Null

    $linkTarget = Join-Path $temporaryRoot 'outside.txt'
    Write-PshGoal5Text -Path $linkTarget -Text 'outside'
    $linkPath = Join-Path $packageRoot 'payload/link.txt'
    $linkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
        $linkCreated = $true
    }
    catch { }
    if ($linkCreated) {
        Assert-PshGoal5Failure -Action { Get-PshPackageTreeEntries -PackageRoot $packageRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'package reparse point'
        [IO.File]::Delete($linkPath)
    }
    $brokenLinkPath = Join-Path $packageRoot 'payload/broken-link.txt'
    $brokenLinkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $brokenLinkPath -Target (Join-Path $temporaryRoot 'missing-link-target.txt') -ErrorAction Stop | Out-Null
        $brokenLinkCreated = $true
    }
    catch { }
    if ($brokenLinkCreated) {
        $brokenEntry = Get-PshLifecyclePathEntry -Path $brokenLinkPath -Description 'broken symbolic link'
        Assert-PshGoal5 ([bool]$brokenEntry.Exists -and [bool]$brokenEntry.IsReparsePoint) 'Dangling symbolic link was misclassified as a missing path.'
        Assert-PshGoal5Failure -Action { Assert-PshLifecycleNoReparseAncestors -Path $brokenLinkPath -Description 'broken symbolic link' } -ExitCode 5 -ErrorId PshReparsePoint -Label 'dangling symbolic link'
        [IO.File]::Delete($brokenLinkPath)
    }

    $installRoot = Join-Path $temporaryRoot 'install root'
    [void][IO.Directory]::CreateDirectory($installRoot)
    $lockA = Enter-PshInstallRootLock -InstallRoot $installRoot
    try {
        Assert-PshGoal5 ([bool]$lockA.Acquired -and [string]$lockA.Name -match '\APsh\.InstallRoot\.[0-9a-f]{64}\z') 'Install-root mutex metadata is invalid.'
        Assert-PshGoal5 ([string]$lockA.Name -ceq (Get-PshInstallRootMutexName -InstallRoot ($installRoot + [IO.Path]::DirectorySeparatorChar))) 'Equivalent install roots produced different mutex names.'
    }
    finally { Exit-PshInstallRootLock -Lock $lockA }
    Assert-PshGoal5Failure -Action { Get-PshLifecycleNormalizedRoot -Path 'relative/install-root' } -ExitCode 5 -ErrorId PshInvalidRoot -Label 'relative lifecycle root'
    $missingLeafRoot = Join-Path $installRoot 'not-yet/leaf'
    Assert-PshGoal5 ([string](Get-PshLifecycleNormalizedRoot -Path $missingLeafRoot) -ceq [IO.Path]::GetFullPath($missingLeafRoot)) 'Missing lifecycle leaf under a real parent was rejected.'
    $aliasRoot = Join-Path $temporaryRoot 'install-root-alias'
    $aliasCreated = $false
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            New-Item -ItemType SymbolicLink -Path $aliasRoot -Target $installRoot -ErrorAction Stop | Out-Null
            $aliasCreated = $true
        }
    }
    catch { }
    if ($aliasCreated) {
        Assert-PshGoal5Failure -Action { Get-PshLifecycleNormalizedRoot -Path $aliasRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'symlink alias lifecycle root'
        Assert-PshGoal5Failure -Action { Get-PshLifecycleNormalizedRoot -Path (Join-Path $aliasRoot 'missing/leaf') } -ExitCode 5 -ErrorId PshReparsePoint -Label 'symlink ancestor with missing leaf'
        Assert-PshGoal5Failure -Action { Get-PshLifecycleStatePath -InstallRoot $aliasRoot -Kind ownership } -ExitCode 5 -ErrorId PshReparsePoint -Label 'symlink alias state path'
        Assert-PshGoal5Failure -Action { Get-PshRecoveryCurrentObservation -InstallRoot $aliasRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'symlink alias current observation'
        Assert-PshGoal5Failure -Action { Get-PshInstallRootMutexName -InstallRoot $aliasRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'symlink alias mutex name'
        [IO.File]::Delete($aliasRoot)
    }
    $filesystemRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($installRoot))
    $normalizedFilesystemRoot = Get-PshLifecycleNormalizedRoot -Path $filesystemRoot
    Assert-PshGoal5 (-not [string]::IsNullOrEmpty($normalizedFilesystemRoot) -and [string]$normalizedFilesystemRoot -ceq [string]$filesystemRoot) 'Filesystem-root normalization produced an empty or changed root.'
    Assert-PshGoal5 ((Get-PshInstallRootMutexName -InstallRoot $filesystemRoot) -match '\APsh\.InstallRoot\.[0-9a-f]{64}\z') 'Filesystem root did not produce a valid mutex name.'
    $caseMutexA = Get-PshInstallRootMutexName -InstallRoot (Join-Path $temporaryRoot 'CaseRoot')
    $caseMutexB = Get-PshInstallRootMutexName -InstallRoot (Join-Path $temporaryRoot 'caseroot')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Assert-PshGoal5 ([string]$caseMutexA -ceq [string]$caseMutexB) 'Windows install-root mutex names did not use case-insensitive identity.'
    }
    else {
        Assert-PshGoal5 ([string]$caseMutexA -cne [string]$caseMutexB) 'Case-sensitive platform install-root mutex names collapsed distinct roots.'
    }

    $installedFileHash = Get-PshLifecycleFileSha256 -Path (Join-Path $packageRoot 'payload/Psh/Psh.psd1')
    $versionFiles = @([pscustomobject][ordered]@{
        relativePath = 'Psh/Psh.psd1'
        length       = [int64]$installedFileHash.Length
        sha256       = [string]$installedFileHash.Sha256
    })
    $versionTree = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $versionFiles })
    $ownership = [pscustomobject][ordered]@{
        schemaVersion = 1
        product       = 'Psh'
        installRoot   = [IO.Path]::GetFullPath($installRoot)
        activeVersion = '0.1.0-test.1'
        rollbackOrder = @()
        stableFiles   = @([pscustomobject][ordered]@{
            relativePath = 'bootstrap.ps1'; disposition = 'created'; originalExisted = $false
            originalLength = $null; originalSha256 = $null; backupFileName = $null
            installedLength = [int64]1; installedSha256 = ('1' * 64)
        })
        config        = [pscustomobject][ordered]@{
            relativePath = 'config.psd1'; disposition = 'created'; originalExisted = $false
            originalLength = $null; originalSha256 = $null; backupFileName = $null
            installedLength = [int64]1; installedSha256 = ('2' * 64)
        }
        versions      = @([pscustomobject][ordered]@{
            version = '0.1.0-test.1'; edition = 'Core'; architecture = 'any'
            relativeRoot = 'versions/0.1.0-test.1'; archiveSha256 = $null
            packageManifestSha256 = [string]$manifestWrite.Sha256; treeSha256 = $versionTree
            files = $versionFiles
        })
        components    = [pscustomobject][ordered]@{
            profile = [pscustomobject][ordered]@{ stateRelativePath = 'profile-state'; installed = $true }
            psReadLineProjection = [pscustomobject][ordered]@{ stateRelativePath = 'psreadline-projection-state'; installed = $false }
        }
    }
    $ownershipWrite = Write-PshOwnershipState -InstallRoot $installRoot -State $ownership
    $ownershipRead = Read-PshOwnershipState -InstallRoot $installRoot
    Assert-PshGoal5 ([string]$ownershipRead.activeVersion -ceq '0.1.0-test.1' -and [string]$ownershipWrite.Sha256 -ceq (Get-PshOwnershipStateSha256 -InstallRoot $installRoot)) 'ownership.json did not validate, round-trip, and hash canonically.'
    $badOwnership = Copy-PshGoal5JsonObject $ownership
    $badOwnership.components.profile | Add-Member -NotePropertyName extra -NotePropertyValue 1
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $badOwnership } -ExitCode 5 -ErrorId PshUnknownField -Label 'unknown ownership nested field'
    $nullConfigOwnership = Copy-PshGoal5JsonObject $ownership
    $nullConfigOwnership.config = $null
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $nullConfigOwnership } -ExitCode 5 -ErrorId PshInvalidObject -Label 'null ownership config'
    $nullStableOwnership = Copy-PshGoal5JsonObject $ownership
    $nullStableOwnership.stableFiles = @($null)
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $nullStableOwnership } -ExitCode 5 -ErrorId PshInvalidObject -Label 'null ownership stable entry'
    $badStablePath = Copy-PshGoal5JsonObject $ownership
    $badStablePath.stableFiles[0].relativePath = 'current.json'
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $badStablePath } -ExitCode 5 -ErrorId PshOwnershipStablePath -Label 'reserved stable ownership path'
    $badConfigPath = Copy-PshGoal5JsonObject $ownership
    $badConfigPath.config.relativePath = 'settings/config.psd1'
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $badConfigPath } -ExitCode 5 -ErrorId PshOwnershipConfigPath -Label 'non-root config ownership path'
    $badVersionRoot = Copy-PshGoal5JsonObject $ownership
    $badVersionRoot.versions[0].relativeRoot = 'versions/other'
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $badVersionRoot } -ExitCode 5 -ErrorId PshOwnershipVersionRoot -Label 'mismatched ownership version root'
    $relativeRootOwnership = Copy-PshGoal5JsonObject $ownership
    $relativeRootOwnership.installRoot = 'relative/install-root'
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $relativeRootOwnership } -ExitCode 5 -ErrorId PshOwnershipRoot -Label 'relative ownership install root'
    Assert-PshGoal5Failure -Action {
        Assert-PshLifecycleNoPathOverlap -Paths @(
            [pscustomobject]@{ Path = 'versions/1.0.0'; Category = 'version' },
            [pscustomobject]@{ Path = 'versions/1.0.0/metadata'; Category = 'metadata' }
        )
    } -ExitCode 5 -ErrorId PshOwnershipPathOverlap -Label 'ownership parent-child path overlap'
    $trailingRootOwnership = Copy-PshGoal5JsonObject $ownership
    $trailingRootOwnership.installRoot = $installRoot + [IO.Path]::DirectorySeparatorChar
    Write-PshOwnershipState -InstallRoot ($installRoot + [IO.Path]::DirectorySeparatorChar) -State $trailingRootOwnership | Out-Null
    $normalizedTrailingOwnership = Read-PshOwnershipState -InstallRoot $installRoot
    Assert-PshGoal5 ([string]$normalizedTrailingOwnership.installRoot -ceq (Get-PshLifecycleNormalizedRoot -Path $installRoot)) 'ownership installRoot retained a non-canonical trailing separator.'
    $ownershipWrite = Write-PshOwnershipState -InstallRoot $installRoot -State $ownership
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $installRoot -State $null } -ExitCode 5 -ErrorId PshOwnershipNull -Label 'implicit ownership deletion'

    $transactionId = ([Guid]::NewGuid()).ToString('N')
    $transaction = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        transactionId = $transactionId
        operation = 'install'
        phase = 'staged'
        oldCurrent = [pscustomobject][ordered]@{ exists = $false; version = $null; sha256 = $null }
        targetVersion = '0.1.0-test.1'
        stageRelativePath = ('.staging/' + $transactionId)
        publishedRelativePath = $null
        ownershipBeforeSha256 = [string]$ownershipWrite.Sha256
        startedUtc = '2026-07-21T00:00:00Z'
    }
    $transactionWrite = Write-PshTransactionState -InstallRoot $installRoot -State $transaction
    $transactionRead = Read-PshTransactionState -InstallRoot $installRoot
    Assert-PshGoal5 ([string]$transactionWrite.Sha256 -ceq (Get-PshTransactionStateSha256 -InstallRoot $installRoot) -and [string]$transactionRead.phase -ceq 'staged') 'transaction.json did not validate, round-trip, and hash canonically.'
    $decision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $transactionRead
    Assert-PshGoal5 ([string]$decision.Action -ceq 'DiscardStage' -and [bool]$decision.Safe) 'Staged recovery decision is wrong.'
    $published = Copy-PshGoal5JsonObject $transaction
    $published.phase = 'published'; $published.publishedRelativePath = 'versions/0.1.0-test.1'
    Assert-PshGoal5 ([string](Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published).Action -ceq 'RemovePublished') 'Published recovery decision is wrong.'
    $switched = Copy-PshGoal5JsonObject $published
    $switched.phase = 'switched'
    $transitionedOwnershipHash = ('3' * 64)
    $targetCurrentSha256 = Get-PshLifecycleCanonicalCurrentSha256 -Version '0.1.0-test.1'
    Assert-PshGoal5 ([string](Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $switched -CurrentVersion '0.1.0-test.1' -CurrentSha256 $targetCurrentSha256 -OwnershipSha256 $transitionedOwnershipHash).Action -ceq 'CompleteCommit') 'Switched recovery decision is wrong.'
    Assert-PshGoal5 ([string](Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -CurrentVersion '0.1.0-test.1' -CurrentSha256 $targetCurrentSha256 -OwnershipSha256 $transitionedOwnershipHash).Action -ceq 'CompleteCommit') 'Published transaction with target current was incorrectly removable.'
    Assert-PshGoal5 (-not [bool](Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $switched -CurrentVersion '9.9.9' -OwnershipSha256 $transitionedOwnershipHash).Safe) 'Conflicting switched recovery was marked safe.'
    $missingStateDecision = Get-PshRecoveryDecision -InstallRoot (Join-Path $temporaryRoot 'missing-recovery-root') -Transaction $published -CurrentVersion '0.1.0-test.1'
    Assert-PshGoal5 ([string]$missingStateDecision.Action -ceq 'Inspect' -and -not [bool]$missingStateDecision.Safe) 'Recovery without necessary ownership state was marked safe.'

    $currentPath = Join-Path $installRoot 'current.json'
    $currentWrite = Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 1; version = '0.1.0-test.1' })
    [byte[]]$canonicalCurrentBytes = Get-PshLifecycleCanonicalCurrentBytes -Version '0.1.0-test.1'
    [byte[]]$diskCurrentBytes = [IO.File]::ReadAllBytes($currentPath)
    $diskCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    $canonicalCurrentText = (New-Object Text.UTF8Encoding($false, $true)).GetString($canonicalCurrentBytes)
    [byte[]]$windowsNewlineBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($canonicalCurrentText.Substring(0, $canonicalCurrentText.Length - 1) + "`r`n")
    [IO.File]::WriteAllBytes($currentPath, $windowsNewlineBytes)
    $windowsNewlineObservation = Get-PshRecoveryCurrentObservation -InstallRoot $installRoot
    $windowsNewlineDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 (
        [string]$diskCurrentDecision.Action -ceq 'CompleteCommit' -and [bool]$diskCurrentDecision.Safe -and
        [string]$currentWrite.Sha256 -ceq [string]$targetCurrentSha256 -and
        [Convert]::ToBase64String($diskCurrentBytes) -ceq [Convert]::ToBase64String($canonicalCurrentBytes) -and
        $diskCurrentBytes.Length -gt 0 -and $diskCurrentBytes[$diskCurrentBytes.Length - 1] -eq 0x0A -and
        @($diskCurrentBytes | Where-Object { $_ -eq 0x0D }).Count -eq 0 -and
        -not [bool]$windowsNewlineObservation.Available -and [string]$windowsNewlineDecision.Action -ceq 'Inspect' -and -not [bool]$windowsNewlineDecision.Safe
    ) 'Canonical current.json write/hash/snapshot contract did not remain UTF-8 without BOM and with LF-only bytes.'
    Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 1; version = '0.1.0-test.1' }) | Out-Null
    $ownershipObservation = Get-PshRecoveryOwnershipObservation -InstallRoot $installRoot
    Assert-PshGoal5 ([bool]$ownershipObservation.Available -and [string]$ownershipObservation.ActiveVersion -ceq '0.1.0-test.1') 'Recovery ownership observation did not expose the validated activeVersion.'

    $mismatchOwnership = Copy-PshGoal5JsonObject $ownership
    $mismatchOwnership.activeVersion = '0.2.0'
    $mismatchVersion = Copy-PshGoal5JsonObject $mismatchOwnership.versions[0]
    $mismatchVersion.version = '0.2.0'
    $mismatchVersion.relativeRoot = 'versions/0.2.0'
    $mismatchOwnership.versions = @($mismatchOwnership.versions) + @($mismatchVersion)
    Write-PshOwnershipState -InstallRoot $installRoot -State $mismatchOwnership | Out-Null
    $mismatchDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published
    Assert-PshGoal5 ([string]$mismatchDecision.Action -ceq 'Inspect' -and -not [bool]$mismatchDecision.Safe) 'Schema-valid ownership activeVersion mismatch permitted install recovery completion.'
    $nullActiveOwnership = Copy-PshGoal5JsonObject $ownership
    $nullActiveOwnership.activeVersion = $null
    Write-PshOwnershipState -InstallRoot $installRoot -State $nullActiveOwnership | Out-Null
    $nullActiveDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published
    Assert-PshGoal5 ([string]$nullActiveDecision.Action -ceq 'Inspect' -and -not [bool]$nullActiveDecision.Safe) 'Null ownership activeVersion permitted recovery completion.'
    $inconsistentOwnership = Copy-PshGoal5JsonObject $ownership
    $inconsistentOwnership.activeVersion = '0.2.0'
    Write-PshCanonicalJsonAtomic -Path (Join-Path $installRoot 'ownership.json') -InputObject $inconsistentOwnership | Out-Null
    $inconsistentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published
    Assert-PshGoal5 ([string]$inconsistentDecision.Action -ceq 'Inspect' -and -not [bool]$inconsistentDecision.Safe) 'Inconsistent ownership versions record permitted recovery completion.'
    $ownershipWrite = Write-PshOwnershipState -InstallRoot $installRoot -State $ownership

    [IO.File]::WriteAllText($currentPath, '{"schemaVersion":1,"version":"0.1.0-test.1","version":"0.1.0-test.1"}', (New-Object Text.UTF8Encoding($false)))
    $duplicateCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$duplicateCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$duplicateCurrentDecision.Safe) 'Duplicate-key current.json permitted automatic recovery.'
    [IO.File]::WriteAllText($currentPath, '{"schemaVersion":1,"version":"0.1.0-test.1"}', (New-Object Text.UTF8Encoding($true)))
    $bomCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$bomCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$bomCurrentDecision.Safe) 'BOM current.json permitted automatic recovery.'
    [IO.File]::WriteAllBytes($currentPath, [byte[]]@(0xFF, 0xFE, 0xFD))
    $utf8CurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$utf8CurrentDecision.Action -ceq 'Inspect' -and -not [bool]$utf8CurrentDecision.Safe) 'Invalid-UTF8 current.json permitted automatic recovery.'
    Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 1; version = '0.1.0-test.1'; extra = $true }) | Out-Null
    $shapeCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$shapeCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$shapeCurrentDecision.Safe) 'Extra-field current.json permitted automatic recovery.'
    Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 2; version = '0.1.0-test.1' }) | Out-Null
    $schemaCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$schemaCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$schemaCurrentDecision.Safe) 'Unsupported current.json schema permitted automatic recovery.'
    Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 1; version = 'not-semver' }) | Out-Null
    $versionCurrentDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$versionCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$versionCurrentDecision.Safe) 'Invalid current.json version permitted automatic recovery.'

    $upgradeId = ([Guid]::NewGuid()).ToString('N')
    $upgrade = [pscustomobject][ordered]@{
        schemaVersion = 1; product = 'Psh'; transactionId = $upgradeId; operation = 'upgrade'; phase = 'published'
        oldCurrent = [pscustomobject][ordered]@{ exists = $true; version = '0.1.0-test.1'; sha256 = ('4' * 64) }
        targetVersion = '0.2.0'; stageRelativePath = ('.staging/' + $upgradeId); publishedRelativePath = 'versions/0.2.0'
        ownershipBeforeSha256 = [string]$ownershipWrite.Sha256; startedUtc = '2026-07-21T00:00:01Z'
    }
    Assert-PshGoal5 ([string](Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $upgrade -CurrentVersion '0.1.0-test.1' -CurrentSha256 ('4' * 64) -OwnershipSha256 ([string]$ownershipWrite.Sha256)).Action -ceq 'RemovePublished') 'Exact old state did not permit published rollback.'
    $wrongOldHash = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $upgrade -CurrentVersion '0.1.0-test.1' -CurrentSha256 ('5' * 64) -OwnershipSha256 ([string]$ownershipWrite.Sha256)
    Assert-PshGoal5 ([string]$wrongOldHash.Action -ceq 'Inspect' -and -not [bool]$wrongOldHash.Safe) 'Old-current SHA mismatch permitted automatic recovery.'
    $diskOldCurrentWrite = Write-PshCanonicalJsonAtomic -Path $currentPath -InputObject ([ordered]@{ schemaVersion = 1; version = '0.1.0-test.1' })
    $diskUpgrade = Copy-PshGoal5JsonObject $upgrade
    $diskUpgrade.oldCurrent.sha256 = [string]$diskOldCurrentWrite.Sha256
    $diskOldDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $diskUpgrade -OwnershipSha256 ([string]$ownershipWrite.Sha256)
    Assert-PshGoal5 ([string]$diskOldDecision.Action -ceq 'RemovePublished' -and [bool]$diskOldDecision.Safe) 'Recovery did not hash the same strict current.json byte snapshot that it validated.'
    $upgradeMismatchDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $upgrade -CurrentVersion '0.2.0' -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$upgradeMismatchDecision.Action -ceq 'Inspect' -and -not [bool]$upgradeMismatchDecision.Safe) 'Ownership activeVersion mismatch permitted upgrade recovery completion.'
    [IO.File]::Delete($currentPath)

    foreach ($invalidTransaction in @(
        @{ Label = 'install without target'; ErrorId = 'PshTransactionTarget'; Mutate = { param($value) $value.targetVersion = $null } },
        @{ Label = 'install without stage'; ErrorId = 'PshTransactionStagePath'; Mutate = { param($value) $value.stageRelativePath = $null } },
        @{ Label = 'published without path'; ErrorId = 'PshTransactionPublishedPath'; Mutate = { param($value) $value.phase = 'published'; $value.publishedRelativePath = $null } },
        @{ Label = 'unknown phase'; ErrorId = 'PshTransactionPhase'; Mutate = { param($value) $value.phase = 'prepared' } },
        @{ Label = 'null oldCurrent'; ErrorId = 'PshInvalidObject'; Mutate = { param($value) $value.oldCurrent = $null } },
        @{ Label = 'D-form transaction ID'; ErrorId = 'PshTransactionId'; Mutate = { param($value) $value.transactionId = ([Guid]::NewGuid()).ToString('D').ToLowerInvariant() } },
        @{ Label = 'uppercase transaction ID'; ErrorId = 'PshTransactionId'; Mutate = { param($value) $value.transactionId = ([Guid]::NewGuid()).ToString('N').ToUpperInvariant() } },
        @{ Label = 'stage path transaction mismatch'; ErrorId = 'PshTransactionStagePath'; Mutate = { param($value) $value.stageRelativePath = ('.staging/' + ([Guid]::NewGuid()).ToString('N')) } }
    )) {
        $invalid = Copy-PshGoal5JsonObject $transaction
        & $invalidTransaction.Mutate $invalid
        Assert-PshGoal5Failure -Action { Write-PshTransactionState -InstallRoot $installRoot -State $invalid } -ExitCode 5 -ErrorId ([string]$invalidTransaction.ErrorId) -Label ([string]$invalidTransaction.Label)
    }

    $rollbackId = ([Guid]::NewGuid()).ToString('N')
    $rollbackTransaction = [pscustomobject][ordered]@{
        schemaVersion = 1; product = 'Psh'; transactionId = $rollbackId; operation = 'rollback'; phase = 'staged'
        oldCurrent = [pscustomobject][ordered]@{ exists = $true; version = '0.2.0'; sha256 = ('6' * 64) }
        targetVersion = '0.1.0-test.1'; stageRelativePath = $null; publishedRelativePath = 'versions/0.1.0-test.1'
        ownershipBeforeSha256 = [string]$ownershipWrite.Sha256; startedUtc = '2026-07-21T00:00:02Z'
    }
    Write-PshTransactionState -InstallRoot $installRoot -State $rollbackTransaction | Out-Null
    $rollbackRecovery = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $rollbackTransaction -CurrentVersion '0.1.0-test.1' -CurrentSha256 $targetCurrentSha256 -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$rollbackRecovery.Action -ceq 'CompleteCommit' -and [bool]$rollbackRecovery.Safe) 'Completed rollback was not recoverable.'
    Write-PshOwnershipState -InstallRoot $installRoot -State $mismatchOwnership | Out-Null
    $rollbackMismatchDecision = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $rollbackTransaction -CurrentVersion '0.1.0-test.1' -CurrentSha256 $targetCurrentSha256 -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$rollbackMismatchDecision.Action -ceq 'Inspect' -and -not [bool]$rollbackMismatchDecision.Safe) 'Ownership activeVersion mismatch permitted rollback recovery completion.'
    Write-PshOwnershipState -InstallRoot $installRoot -State $ownership | Out-Null
    $badRollback = Copy-PshGoal5JsonObject $rollbackTransaction
    $badRollback.stageRelativePath = ('.staging/' + $rollbackId)
    Assert-PshGoal5Failure -Action { Write-PshTransactionState -InstallRoot $installRoot -State $badRollback } -ExitCode 5 -ErrorId PshTransactionRollbackPaths -Label 'rollback with staging path'

    $uninstall = Copy-PshGoal5JsonObject $transaction
    $uninstall.operation = 'uninstall'; $uninstall.targetVersion = $null; $uninstall.stageRelativePath = $null; $uninstall.publishedRelativePath = $null; $uninstall.ownershipBeforeSha256 = [string]$ownershipWrite.Sha256
    Write-PshTransactionState -InstallRoot $installRoot -State $uninstall | Out-Null
    Assert-PshGoal5 ([string](Read-PshTransactionState -InstallRoot $installRoot).operation -ceq 'uninstall') 'Nullable uninstall transaction fields were rejected.'
    $uninstallRecovery = Get-PshRecoveryDecision -InstallRoot $installRoot -Transaction $uninstall
    Assert-PshGoal5 ([string]$uninstallRecovery.Action -ceq 'Inspect' -and -not [bool]$uninstallRecovery.Safe) 'In-flight uninstall was marked safe for automatic recovery.'
    $badUninstall = Copy-PshGoal5JsonObject $uninstall
    $badUninstall.targetVersion = '0.1.0-test.1'
    Assert-PshGoal5Failure -Action { Write-PshTransactionState -InstallRoot $installRoot -State $badUninstall } -ExitCode 5 -ErrorId PshTransactionUninstallShape -Label 'uninstall with target version'
    Assert-PshGoal5Failure -Action { Write-PshTransactionState -InstallRoot $installRoot -State $null } -ExitCode 5 -ErrorId PshTransactionNull -Label 'implicit transaction deletion'
    $removedTransaction = Remove-PshTransactionState -InstallRoot $installRoot
    Assert-PshGoal5 ([bool]$removedTransaction.Removed -and $null -eq (Read-PshTransactionState -InstallRoot $installRoot)) 'Explicit transaction removal failed.'
    $removedOwnership = Remove-PshOwnershipState -InstallRoot $installRoot
    Assert-PshGoal5 ([bool]$removedOwnership.Removed -and $null -eq (Read-PshOwnershipState -InstallRoot $installRoot)) 'Explicit ownership removal failed.'
    Assert-PshGoal5 (-not [bool](Remove-PshTransactionState -InstallRoot $installRoot).Removed) 'Repeated transaction removal was not idempotent.'

    $nonRegularRoot = Join-Path $temporaryRoot 'non-regular-state-root'
    [void][IO.Directory]::CreateDirectory($nonRegularRoot)
    $nonRegularOwnershipPath = Join-Path $nonRegularRoot 'ownership.json'
    [void][IO.Directory]::CreateDirectory($nonRegularOwnershipPath)
    $nonRegularOwnership = Copy-PshGoal5JsonObject $ownership
    $nonRegularOwnership.installRoot = [IO.Path]::GetFullPath($nonRegularRoot)
    Assert-PshGoal5Failure -Action { Read-PshOwnershipState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'ownership directory read'
    Assert-PshGoal5Failure -Action { Get-PshOwnershipStateSha256 -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'ownership directory hash'
    Assert-PshGoal5Failure -Action { Write-PshOwnershipState -InstallRoot $nonRegularRoot -State $nonRegularOwnership } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'ownership directory write'
    Assert-PshGoal5Failure -Action { Remove-PshOwnershipState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'ownership directory removal'
    Assert-PshGoal5 ([IO.Directory]::Exists($nonRegularOwnershipPath)) 'Ownership directory was altered by fail-closed state handling.'
    $unavailableOwnershipDecision = Get-PshRecoveryDecision -InstallRoot $nonRegularRoot -Transaction $published -CurrentVersion '0.1.0-test.1'
    Assert-PshGoal5 ([string]$unavailableOwnershipDecision.Action -ceq 'Inspect' -and -not [bool]$unavailableOwnershipDecision.Safe) 'Non-regular ownership state was treated as absent during recovery.'
    [IO.Directory]::Delete($nonRegularOwnershipPath)

    $nonRegularTransactionPath = Join-Path $nonRegularRoot 'transaction.json'
    [void][IO.Directory]::CreateDirectory($nonRegularTransactionPath)
    Assert-PshGoal5Failure -Action { Read-PshTransactionState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'transaction directory read'
    Assert-PshGoal5Failure -Action { Get-PshTransactionStateSha256 -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'transaction directory hash'
    Assert-PshGoal5Failure -Action { Write-PshTransactionState -InstallRoot $nonRegularRoot -State $transaction } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'transaction directory write'
    Assert-PshGoal5Failure -Action { Remove-PshTransactionState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'transaction directory removal'
    Assert-PshGoal5Failure -Action { Get-PshRecoveryDecision -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshNotRegularFile -Label 'transaction directory recovery read'
    Assert-PshGoal5 ([IO.Directory]::Exists($nonRegularTransactionPath)) 'Transaction directory was altered by fail-closed state handling.'
    [IO.Directory]::Delete($nonRegularTransactionPath)

    $nonRegularCurrentPath = Join-Path $nonRegularRoot 'current.json'
    [void][IO.Directory]::CreateDirectory($nonRegularCurrentPath)
    $unavailableCurrentDecision = Get-PshRecoveryDecision -InstallRoot $nonRegularRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
    Assert-PshGoal5 ([string]$unavailableCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$unavailableCurrentDecision.Safe) 'Non-regular current state was treated as absent during recovery.'
    [IO.Directory]::Delete($nonRegularCurrentPath)

    $stateLinkTarget = Join-Path $temporaryRoot 'state-link-target.json'
    [IO.File]::WriteAllText($stateLinkTarget, '{"schemaVersion":1,"version":"0.1.0-test.1"}', (New-Object Text.UTF8Encoding($false)))
    $stateLinksCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $nonRegularOwnershipPath -Target $stateLinkTarget -ErrorAction Stop | Out-Null
        $stateLinksCreated = $true
    }
    catch { }
    if ($stateLinksCreated) {
        Assert-PshGoal5Failure -Action { Read-PshOwnershipState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'ownership link read'
        Assert-PshGoal5Failure -Action { Remove-PshOwnershipState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'ownership link removal'
        Assert-PshGoal5 ([IO.File]::Exists($stateLinkTarget)) 'Fail-closed ownership removal changed the link target.'
        [IO.File]::Delete($nonRegularOwnershipPath)
        New-Item -ItemType SymbolicLink -Path $nonRegularTransactionPath -Target $stateLinkTarget -ErrorAction Stop | Out-Null
        Assert-PshGoal5Failure -Action { Read-PshTransactionState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'transaction link read'
        Assert-PshGoal5Failure -Action { Remove-PshTransactionState -InstallRoot $nonRegularRoot } -ExitCode 5 -ErrorId PshReparsePoint -Label 'transaction link removal'
        [IO.File]::Delete($nonRegularTransactionPath)
        New-Item -ItemType SymbolicLink -Path $nonRegularCurrentPath -Target $stateLinkTarget -ErrorAction Stop | Out-Null
        $linkedCurrentDecision = Get-PshRecoveryDecision -InstallRoot $nonRegularRoot -Transaction $published -OwnershipSha256 $transitionedOwnershipHash
        Assert-PshGoal5 ([string]$linkedCurrentDecision.Action -ceq 'Inspect' -and -not [bool]$linkedCurrentDecision.Safe) 'Linked current state was treated as absent during recovery.'
        [IO.File]::Delete($nonRegularCurrentPath)
    }
}
finally {
    if ([IO.Directory]::Exists($temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ("Goal 5 package lifecycle passed: {0} assertions" -f $script:Goal5Assertions)
