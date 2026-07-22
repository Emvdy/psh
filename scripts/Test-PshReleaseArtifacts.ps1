# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ReleaseAssetsRoot,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string] $SourceCommit,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('BuildStage', 'Release')][string] $Mode = 'BuildStage',
    [AllowNull()][string] $ReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
$trustPath = Join-Path $RepositoryRoot 'src/install/ReleaseTrust.ps1'
if (-not [IO.File]::Exists($lifecyclePath) -or -not [IO.File]::Exists($trustPath)) {
    throw 'Package lifecycle or release trust helpers are missing.'
}
. $lifecyclePath
. $trustPath

function Throw-PshReleaseArtifactError {
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][Exception] $InnerException
    )

    $exception = if ($null -eq $InnerException) { New-Object Exception($Message) } else { New-Object Exception($Message, $InnerException) }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorId'] = $ErrorId
    throw $exception
}

function Resolve-PshReleaseArtifactFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseArtifactError -ExitCode 4 -ErrorId 'PshReleaseArtifactMissing' -Message "$Description must be an existing regular non-reparse file: $full"
    }
    return $full
}

function Resolve-PshReleaseArtifactDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseArtifactError -ExitCode 4 -ErrorId 'PshReleaseArtifactMissing' -Message "$Description must be an existing non-reparse directory: $full"
    }
    return $full
}

function Get-PshReleaseArtifactFileState {
    param([Parameter(Mandatory = $true)][string] $Path)

    $state = Get-PshLifecycleFileSha256 -Path $Path
    if ([int64]$state.Length -le 0) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactEmpty' -Message "Release artifact must not be empty: $Path"
    }
    return [pscustomobject][ordered]@{ Length = [int64]$state.Length; Sha256 = [string]$state.Sha256 }
}

function ConvertFrom-PshReleaseArtifactUtf8 {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactBom' -Message "$Description must be UTF-8 without a BOM."
    }
    try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
    catch { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactUtf8' -Message "$Description is not valid UTF-8." -InnerException $_.Exception }
}

function Get-PshReleaseArtifactZipState {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchiveEntry] $Entry,
        [Parameter(Mandatory = $true)][int64] $CaptureLimit
    )

    if ([int64]$Entry.Length -lt 0 -or [int64]$Entry.Length -gt 1073741824) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipSize' -Message "ZIP entry length is outside the verification limit: $($Entry.FullName)"
    }
    $input = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    $capture = if ($CaptureLimit -gt 0) { New-Object IO.MemoryStream } else { $null }
    try {
        $buffer = New-Object byte[] 65536
        [int64]$total = 0
        while ($true) {
            $read = $input.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt 1073741824) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipSize' -Message "ZIP entry expands beyond the verification limit: $($Entry.FullName)"
            }
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            if ($null -ne $capture -and $capture.Length -lt $CaptureLimit) {
                $remaining = $CaptureLimit - $capture.Length
                $capture.Write($buffer, 0, [int][Math]::Min([int64]$read, $remaining))
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($total -ne [int64]$Entry.Length) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipLength' -Message "ZIP entry length changed while reading: $($Entry.FullName)"
        }
        return [pscustomobject][ordered]@{
            Length = $total
            Sha256 = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
            CapturedBytes = if ($null -eq $capture) { $null } else { $capture.ToArray() }
            FullyCaptured = $null -ne $capture -and $total -le $CaptureLimit
        }
    }
    finally {
        if ($null -ne $capture) { $capture.Dispose() }
        $sha.Dispose()
        $input.Dispose()
    }
}

function Get-PshReleaseArtifactPeMachine {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes, [Parameter(Mandatory = $true)][string] $Description)

    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPe' -Message "$Description has no valid MZ header."
    }
    $offset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($offset -lt 0 -or $offset + 6 -gt $Bytes.Length -or
        $Bytes[$offset] -ne 0x50 -or $Bytes[$offset + 1] -ne 0x45 -or $Bytes[$offset + 2] -ne 0 -or $Bytes[$offset + 3] -ne 0) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPe' -Message "$Description has no valid PE header in the captured prefix."
    }
    return ('0x{0:X4}' -f [BitConverter]::ToUInt16($Bytes, $offset + 4))
}

function Assert-PshReleaseOfflineScript {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)

    $text = ConvertFrom-PshReleaseArtifactUtf8 -Bytes $Bytes -Description 'offline installer'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseOfflineParse' -Message 'Offline installer has parser errors.'
    }
    $forbiddenCommands = @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'curl', 'curl.exe', 'wget', 'wget.exe', 'iwr', 'irm')
    $networkCommands = @($ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                return [string]$node.GetCommandName() -iin $forbiddenCommands
            }, $true))
    $networkTypes = @($ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return $false }
                return [string]$node.TypeName.FullName -imatch '(^|\.)Net\.(Http|WebClient|WebRequest|HttpWebRequest)'
            }, $true))
    if ($networkCommands.Count -ne 0 -or $networkTypes.Count -ne 0) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseOfflineNetwork' -Message 'Offline installer contains a network command or network transport type.'
    }
}

function Assert-PshReleaseEmbeddedInstaller {
    param(
        [Parameter(Mandatory = $true)][string] $InstallerPath,
        [Parameter(Mandatory = $true)][string] $Repository
    )

    $bytes = [IO.File]::ReadAllBytes($InstallerPath)
    $text = ConvertFrom-PshReleaseArtifactUtf8 -Bytes $bytes -Description 'public online installer'
    $beginMatches = @([regex]::Matches($text, '(?m)^# PSH_EMBED_HELPERS_BEGIN\r?$'))
    $endMatches = @([regex]::Matches($text, '(?m)^# PSH_EMBED_HELPERS_END\r?$'))
    if ($beginMatches.Count -ne 1 -or $endMatches.Count -ne 1 -or $beginMatches[0].Index -ge $endMatches[0].Index) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseEmbeddedMarkers' -Message 'Public online installer does not preserve exactly one ordered helper marker pair.'
    }
    $start = $beginMatches[0].Index + $beginMatches[0].Length
    if ($start -ge $text.Length -or $text[$start] -cne "`n") {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseEmbeddedMarkers' -Message 'Public online installer begin marker has no following helper content line.'
    }
    $start++
    $expectedBuilder = New-Object Text.StringBuilder
    foreach ($relative in @('src/install/PackageLifecycle.ps1', 'src/install/ReleaseTrust.ps1', 'src/install/PackageAcquisition.ps1')) {
        $path = Resolve-PshReleaseArtifactFile -Path (Join-Path $Repository $relative) -Description "embedded helper source '$relative'"
        [void]$expectedBuilder.Append((ConvertFrom-PshReleaseArtifactUtf8 -Bytes ([IO.File]::ReadAllBytes($path)) -Description "embedded helper source '$relative'"))
    }
    $actualEmbedded = $text.Substring($start, $endMatches[0].Index - $start)
    if ($actualEmbedded -cne $expectedBuilder.ToString()) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseEmbeddedBytes' -Message 'Public online installer helper block does not equal the three fixed original library sources.'
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseEmbeddedParse' -Message 'Public online installer has parser errors after helper embedding.'
    }
    $dynamic = @($ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                $name = [string]$node.GetCommandName()
                if ($name -ieq 'Invoke-Expression' -or $name -ieq 'iex') { return $true }
                if ($name -ieq 'Add-Type') {
                    return [string]$node.Extent.Text -notmatch '(?i)\A\s*Add-Type\s+-AssemblyName\s+System\.IO\.Compression(?:\.FileSystem)?(?:\s|$)'
                }
                return $false
            }, $true))
    if ($dynamic.Count -ne 0 -or $text -match '(?i)\[\s*scriptblock\s*\]\s*::\s*create\s*\(' -or
        $text -match '(?i)\bAdd-Type\s+(?:-TypeDefinition|-MemberDefinition|-Path)\b') {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseEmbeddedDynamicExecution' -Message 'Public online installer exposes a forbidden dynamic execution surface.'
    }
}

function Read-PshReleaseNativeLockFromBytes {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-native-lock-' + [Guid]::NewGuid().ToString('N'))
    $path = Join-Path $temporaryRoot 'native-tools.lock.json'
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    try {
        [IO.File]::WriteAllBytes($path, $Bytes)
        $snapshot = Read-PshStrictJsonSnapshot -Path $path -Description 'native tools lock from package'
        $lock = $snapshot.Document
        Assert-PshLifecycleAllowedProperties -InputObject $lock -Allowed @('schemaVersion', 'manifest', 'toolRoot', 'tools') -Description 'native tools lock'
        Assert-PshLifecycleRequiredProperties -InputObject $lock -Required @('schemaVersion', 'manifest', 'toolRoot', 'tools') -Description 'native tools lock'
        if ([int]$lock.schemaVersion -ne 1 -or [string]$lock.toolRoot -cne 'tools' -or
            (@($lock.tools | ForEach-Object { [string]$_.name }) -join '|') -cne 'bat|fd|jq|rg') {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseNativeLock' -Message 'Packaged native tools lock has an invalid top-level identity or tool set.'
        }
        return $lock
    }
    finally {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        if ([IO.Directory]::Exists($temporaryRoot)) { try { [IO.Directory]::Delete($temporaryRoot, $false) } catch { } }
    }
}

function Get-PshReleasePackageVerification {
    param(
        [Parameter(Mandatory = $true)][string] $PackagePath,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion,
        [Parameter(Mandatory = $true)][string] $ExpectedEdition,
        [Parameter(Mandatory = $true)][string] $ExpectedArchitecture,
        [Parameter(Mandatory = $true)][string] $ExpectedCommit,
        [Parameter(Mandatory = $true)][string[]] $ExpectedLicensePaths
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($PackagePath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    try { $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true, (New-Object Text.UTF8Encoding($false, $true))) }
    catch {
        $stream.Dispose()
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipOpen' -Message "Unable to open package ZIP: $PackagePath" -InnerException $_.Exception
    }
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $entryStates = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.EndsWith('/', [StringComparison]::Ordinal)) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipEntry' -Message "Package ZIP contains a non-file or non-canonical entry: $name"
            }
            try { $normalized = Assert-PshLifecycleRelativePath -Value $name -Description 'package ZIP entry' -Seen $seen }
            catch { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipEntry' -Message "Package ZIP contains an unsafe or duplicate entry: $name" -InnerException $_.Exception }
            [int64]$attributes = [int]$entry.ExternalAttributes
            if ($attributes -lt 0) { $attributes += 4294967296 }
            $unixType = ($attributes -shr 16) -band 0xF000
            if (($unixType -ne 0 -and $unixType -ne 0x8000) -or (($attributes -band 0x400) -ne 0)) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactZipReparse' -Message "Package ZIP entry is a symlink, reparse point, or special file: $normalized"
            }
            $captureLimit = 0
            if ($normalized -cin @('package.manifest.json', 'package.manifest.cat', 'install-offline.ps1', 'payload/Psh/Tools/native-tools.lock.json')) { $captureLimit = 16777216 }
            elseif ($normalized.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $captureLimit = 1048576 }
            $entryStates[$normalized] = Get-PshReleaseArtifactZipState -Entry $entry -CaptureLimit $captureLimit
        }
        foreach ($required in @('package.manifest.json', 'package.manifest.cat')) {
            if (-not $entryStates.ContainsKey($required) -or -not [bool]$entryStates[$required].FullyCaptured -or [int64]$entryStates[$required].Length -le 0) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactSidecar' -Message "Package ZIP is missing a complete non-empty root sidecar: $required"
            }
        }
        $catalogEntries = @($entryStates.Keys | Where-Object { $_.EndsWith('.cat', [StringComparison]::OrdinalIgnoreCase) })
        if ($catalogEntries.Count -ne 1 -or $catalogEntries[0] -cne 'package.manifest.cat') {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactSidecar' -Message 'package.manifest.cat must be the only catalog sidecar in the package ZIP.'
        }

        $manifestBytes = [byte[]]$entryStates['package.manifest.json'].CapturedBytes
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-package-manifest-' + [Guid]::NewGuid().ToString('N'))
        $manifestPath = Join-Path $temporaryRoot 'package.manifest.json'
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        try {
            [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
            $snapshot = Read-PshStrictJsonSnapshot -Path $manifestPath -Description 'package manifest from release ZIP'
            $manifest = Read-PshPackageManifest -Path $manifestPath -Snapshot $snapshot
        }
        finally {
            if ([IO.File]::Exists($manifestPath)) { [IO.File]::Delete($manifestPath) }
            if ([IO.Directory]::Exists($temporaryRoot)) { try { [IO.Directory]::Delete($temporaryRoot, $false) } catch { } }
        }
        if ([string]$manifest.version -cne $ExpectedVersion -or [string]$manifest.edition -cne $ExpectedEdition -or
            [string]$manifest.architecture -cne $ExpectedArchitecture -or [bool]$manifest.testOnly -or
            [string]$manifest.source.repository -cne 'https://github.com/Emvdy/psh' -or [string]$manifest.source.commit -cne $ExpectedCommit) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactIdentity' -Message "Package manifest identity does not match public slot: $PackagePath"
        }
        if ($entryStates.Count -ne @($manifest.files).Count + 2) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactFileSet' -Message "Package ZIP has missing or extra files relative to its manifest: $PackagePath"
        }
        foreach ($file in @($manifest.files)) {
            $relative = [string]$file.relativePath
            if ([string]::Equals($relative, 'package.manifest.cat', [StringComparison]::OrdinalIgnoreCase) -or -not $entryStates.ContainsKey($relative)) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactFileSet' -Message "Package manifest refers to an invalid or missing entry: $relative"
            }
            $state = $entryStates[$relative]
            if ([int64]$state.Length -ne [int64]$file.length -or [string]$state.Sha256 -cne [string]$file.sha256) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactHash' -Message "Package ZIP entry does not match its manifest: $relative"
            }
        }

        foreach ($requiredPrefix in @('payload/Psh/', 'payload/install/', 'payload/profile/')) {
            if (@($entryStates.Keys | Where-Object { $_.StartsWith($requiredPrefix, [StringComparison]::Ordinal) }).Count -eq 0) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPayload' -Message "Package payload is missing required tree: $requiredPrefix"
            }
        }
        foreach ($requiredRoot in @('install.ps1', 'install-offline.ps1', 'install.sh', 'uninstall.ps1', 'psh-installer.exe', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'sbom.spdx.json')) {
            if (-not $entryStates.ContainsKey($requiredRoot)) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactPayload' -Message "Package is missing required root file: $requiredRoot"
            }
        }
        $actualLicenses = @($entryStates.Keys | Where-Object { $_.StartsWith('licenses/', [StringComparison]::Ordinal) })
        $expectedLicenseSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($expectedLicense in $ExpectedLicensePaths) { [void]$expectedLicenseSet.Add([string]$expectedLicense) }
        $unexpectedLicenses = @($actualLicenses | Where-Object { -not $expectedLicenseSet.Contains([string]$_) })
        if ($actualLicenses.Count -ne $expectedLicenseSet.Count -or $unexpectedLicenses.Count -ne 0) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseArtifactLicenses' -Message 'Package license tree is incomplete or contains unexpected files.'
        }
        $offlineState = $entryStates['install-offline.ps1']
        if (-not [bool]$offlineState.FullyCaptured) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseOfflineSize' -Message 'Offline installer is too large for static network verification.'
        }
        Assert-PshReleaseOfflineScript -Bytes ([byte[]]$offlineState.CapturedBytes)

        $toolsPrefix = 'payload/Psh/Tools'
        $toolsEntries = @($entryStates.Keys | Where-Object {
                [string]::Equals($_, $toolsPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $_.StartsWith($toolsPrefix + '/', [StringComparison]::OrdinalIgnoreCase)
            })
        if ($ExpectedEdition -ceq 'Core') {
            if ($toolsEntries.Count -ne 0 -or $null -ne $manifest.nativeToolsLockSha256) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseCoreTools' -Message 'Core package contains a Tools path or native lock hash.'
            }
        }
        else {
            $lockPath = 'payload/Psh/Tools/native-tools.lock.json'
            if (-not $entryStates.ContainsKey($lockPath) -or -not [bool]$entryStates[$lockPath].FullyCaptured -or
                [string]$entryStates[$lockPath].Sha256 -cne [string]$manifest.nativeToolsLockSha256) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseFullLock' -Message 'Full package native lock is missing or does not match its manifest.'
            }
            $lock = Read-PshReleaseNativeLockFromBytes -Bytes ([byte[]]$entryStates[$lockPath].CapturedBytes)
            $expectedMachine = if ($ExpectedArchitecture -ceq 'win-x64') { '0x8664' } else { '0xAA64' }
            $otherArchitecture = if ($ExpectedArchitecture -ceq 'win-x64') { 'win-arm64' } else { 'win-x64' }
            foreach ($tool in @($lock.tools)) {
                $artifact = $tool.artifacts.$ExpectedArchitecture
                $expectedRelative = 'payload/Psh/Tools/' + [string]$artifact.installedPath
                if (-not $entryStates.ContainsKey($expectedRelative)) {
                    Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseFullTool' -Message "Full package is missing native tool: $expectedRelative"
                }
                $toolState = $entryStates[$expectedRelative]
                if ([string]$artifact.peMachine -cne $expectedMachine -or [string]$artifact.installedSha256 -cne [string]$toolState.Sha256 -or
                    (Get-PshReleaseArtifactPeMachine -Bytes ([byte[]]$toolState.CapturedBytes) -Description $expectedRelative) -cne $expectedMachine) {
                    Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseFullArchitecture' -Message "Full package native tool has the wrong bytes or PE architecture: $expectedRelative"
                }
            }
            if (@($toolsEntries | Where-Object { $_.StartsWith("payload/Psh/Tools/$otherArchitecture/", [StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseFullArchitecture' -Message "Full package contains tools for the other architecture: $otherArchitecture"
            }
            $expectedToolEntries = @($lock.tools).Count + 1
            if ($toolsEntries.Count -ne $expectedToolEntries) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseFullToolSet' -Message 'Full package Tools tree contains missing or extra files.'
            }
        }

        return [pscustomobject][ordered]@{
            Name = [IO.Path]::GetFileName($PackagePath)
            Manifest = $manifest
            ManifestBytes = $manifestBytes
            ManifestSha256 = Get-PshLifecycleSha256Bytes -Bytes $manifestBytes
            CatalogBytes = [byte[]]$entryStates['package.manifest.cat'].CapturedBytes
            BootstrapperSha256 = [string]$entryStates['psh-installer.exe'].Sha256
            OnlineInstallerSha256 = [string]$entryStates['install.ps1'].Sha256
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Get-PshReleaseArtifactAuthenticodeStatus {
    param([Parameter(Mandatory = $true)][string] $CatalogPath)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return 'Unavailable' }
    $signatureCommand = Get-Command -Name Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $signatureCommand) { return 'Unavailable' }
    try {
        $signature = & $signatureCommand -FilePath $CatalogPath -ErrorAction Stop
        if ($null -eq $signature -or $null -eq $signature.PSObject.Properties['Status']) { return 'Unknown' }
        return [string]$signature.Status
    }
    catch { return 'InspectionFailed' }
}

function Invoke-PshReleaseCatalogContentCleanup {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $ExpectedNames
    )

    $entry = Get-PshLifecyclePathEntry -Path $Path -Description 'release catalog verification root'
    if (-not [bool]$entry.Exists) { return }
    if (-not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseCatalogCleanupUnsafe' -Message "Catalog verification root changed to an unsafe entry: $Path"
    }
    try { $children = @(Get-ChildItem -LiteralPath $Path -Force) }
    catch { Throw-PshReleaseArtifactError -ExitCode 3 -ErrorId 'PshReleaseCatalogCleanupInspect' -Message "Unable to inspect catalog verification root: $Path" -InnerException $_.Exception }
    foreach ($child in $children) {
        if ($child.PSIsContainer -or (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or [string]$child.Name -cnotin $ExpectedNames) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseCatalogCleanupUnsafe' -Message "Catalog verification root contains an unexpected entry: $($child.FullName)"
        }
    }
    try {
        foreach ($name in $ExpectedNames) {
            $childPath = Join-Path $Path $name
            if ([IO.File]::Exists($childPath)) { [IO.File]::Delete($childPath) }
        }
        [IO.Directory]::Delete($Path, $false)
    }
    catch { Throw-PshReleaseArtifactError -ExitCode 3 -ErrorId 'PshReleaseCatalogCleanup' -Message "Unable to remove catalog verification root: $Path" -InnerException $_.Exception }
}

function Invoke-PshReleaseCatalogMembershipVerification {
    param(
        [Parameter(Mandatory = $true)][object] $CatalogCommand,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][object[]] $Members,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $CatalogPath = Resolve-PshReleaseArtifactFile -Path $CatalogPath -Description "$Description catalog"
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-release-membership-' + [Guid]::NewGuid().ToString('N'))
    $temporaryRoot = Assert-PshLifecycleNoReparseAncestors -Path $temporaryRoot -Description "$Description verification root"
    if ([IO.File]::Exists($temporaryRoot) -or [IO.Directory]::Exists($temporaryRoot)) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description verification root already exists: $temporaryRoot"
    }
    $expectedNames = New-Object System.Collections.Generic.List[string]
    try {
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $rootEntry = Get-PshLifecyclePathEntry -Path $temporaryRoot -Description "$Description verification root"
        if (-not [bool]$rootEntry.IsDirectory -or [bool]$rootEntry.IsReparsePoint) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description verification root is unsafe: $temporaryRoot"
        }
        foreach ($member in $Members) {
            $name = [string]$member.Name
            if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -cne $name -or $expectedNames.Contains($name)) {
                Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description has an invalid or duplicate member name: $name"
            }
            $expectedNames.Add($name)
            $destination = Join-Path $temporaryRoot $name
            if ($null -ne $member.PSObject.Properties['SourcePath']) {
                $source = Resolve-PshReleaseArtifactFile -Path ([string]$member.SourcePath) -Description "$Description member '$name'"
                [IO.File]::Copy($source, $destination, $false)
            }
            elseif ($null -ne $member.PSObject.Properties['Bytes']) {
                [IO.File]::WriteAllBytes($destination, [byte[]]$member.Bytes)
            }
            else { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description member '$name' has no source bytes." }
        }
        try { $validationResults = @(& $CatalogCommand -CatalogFilePath $CatalogPath -Path $temporaryRoot -Detailed -ErrorAction Stop) }
        catch { Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description membership verification failed." -InnerException $_.Exception }
        $statusResults = @($validationResults | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Status'] })
        if ($statusResults.Count -eq 1) { $validation = $statusResults[0] }
        elseif ($validationResults.Count -eq 1) { $validation = $validationResults[0] }
        else {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description membership verification returned an ambiguous result set (raw=$($validationResults.Count), status=$($statusResults.Count))."
        }
        $status = if ($null -ne $validation -and $null -ne $validation.PSObject.Properties['Status']) { [string]$validation.Status } else { [string]$validation }
        if ($status -cne 'ValidationPassed') {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId $ErrorId -Message "$Description does not cover its exact required member set: $status"
        }
    }
    finally { Invoke-PshReleaseCatalogContentCleanup -Path $temporaryRoot -ExpectedNames $expectedNames.ToArray() }
    return Get-PshReleaseArtifactAuthenticodeStatus -CatalogPath $CatalogPath
}

function Test-PshReleasePackageCatalogSet {
    param(
        [Parameter(Mandatory = $true)][object] $CatalogCommand,
        [Parameter(Mandatory = $true)][object[]] $Packages
    )

    $statuses = New-Object System.Collections.Generic.List[object]
    foreach ($package in $Packages) {
        $catalogPath = Join-Path ([IO.Path]::GetTempPath()) ('psh-package-catalog-' + [Guid]::NewGuid().ToString('N') + '.cat')
        $catalogPath = Assert-PshLifecycleNoReparseAncestors -Path $catalogPath -Description 'temporary package catalog'
        if ([IO.File]::Exists($catalogPath) -or [IO.Directory]::Exists($catalogPath)) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleasePackageCatalogPath' -Message "Temporary package catalog path already exists: $catalogPath"
        }
        try {
            [IO.File]::WriteAllBytes($catalogPath, [byte[]]$package.CatalogBytes)
            $status = Invoke-PshReleaseCatalogMembershipVerification -CatalogCommand $CatalogCommand -CatalogPath $catalogPath -Members @(
                [pscustomobject]@{ Name = 'package.manifest.json'; Bytes = [byte[]]$package.ManifestBytes }
            ) -ErrorId 'PshReleasePackageCatalogMembership' -Description "package catalog '$($package.Name)'"
            $statuses.Add([pscustomobject][ordered]@{ package = [string]$package.Name; status = [string]$status })
        }
        finally {
            $entry = Get-PshLifecyclePathEntry -Path $catalogPath -Description 'temporary package catalog'
            if ([bool]$entry.Exists) {
                if (-not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
                    Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleasePackageCatalogCleanupUnsafe' -Message "Temporary package catalog changed to an unsafe entry: $catalogPath"
                }
                try { [IO.File]::Delete($catalogPath) }
                catch { Throw-PshReleaseArtifactError -ExitCode 3 -ErrorId 'PshReleasePackageCatalogCleanup' -Message "Unable to remove temporary package catalog: $catalogPath" -InnerException $_.Exception }
            }
        }
    }
    return $statuses.ToArray()
}

function Write-PshReleaseArtifactReport {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object] $Value)

    $full = [IO.Path]::GetFullPath($Path)
    [void](Assert-PshLifecycleNoReparseAncestors -Path $full -Description 'release artifact report')
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseReportExists' -Message "Release artifact report already exists: $full"
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($full, ((ConvertTo-PshCanonicalJson -InputObject $Value) + "`n"), (New-Object Text.UTF8Encoding($false)))
}

$RepositoryRoot = Resolve-PshReleaseArtifactDirectory -Path $RepositoryRoot -Description 'repository root'
$ReleaseAssetsRoot = Resolve-PshReleaseArtifactDirectory -Path $ReleaseAssetsRoot -Description 'release assets root'
$Version = Assert-PshLifecycleSemVer -Value $Version -Description 'release version'
if ($Version -ceq '0.0.1-test') {
    Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseTestVersion' -Message 'Synthetic test version must never be verified as a public release.'
}
$fileCatalogCommand = $null
if ($Mode -ceq 'Release') {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshReleaseArtifactError -ExitCode 4 -ErrorId 'PshReleaseCatalogVerificationUnavailable' -Message 'Release mode requires Windows Test-FileCatalog membership verification.'
    }
    $fileCatalogCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $fileCatalogCommand) {
        Throw-PshReleaseArtifactError -ExitCode 4 -ErrorId 'PshReleaseCatalogVerificationUnavailable' -Message 'Test-FileCatalog is unavailable on this Windows runtime.'
    }
}

$contentSpecs = @(
    [pscustomobject]@{ Name = 'install.ps1'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'install.sh'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'psh-installer.exe'; Role = 'installer'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = "psh-$Version-core.zip"; Role = 'package'; Edition = 'Core'; Architecture = 'any' },
    [pscustomobject]@{ Name = "psh-$Version-full-win-x64.zip"; Role = 'package'; Edition = 'Full'; Architecture = 'win-x64' },
    [pscustomobject]@{ Name = "psh-$Version-full-win-arm64.zip"; Role = 'package'; Edition = 'Full'; Architecture = 'win-arm64' },
    [pscustomobject]@{ Name = 'sbom.spdx.json'; Role = 'sbom'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'THIRD_PARTY_NOTICES.md'; Role = 'notice'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'RELEASE_NOTES.md'; Role = 'other'; Edition = $null; Architecture = $null },
    [pscustomobject]@{ Name = 'RELEASE_NOTES.zh-CN.md'; Role = 'other'; Edition = $null; Architecture = $null }
)
$indexName = "psh-release-$Version.json"
$catalogName = "psh-release-$Version.cat"
$expectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($spec in $contentSpecs) { [void]$expectedNames.Add([string]$spec.Name) }
[void]$expectedNames.Add($indexName)
[void]$expectedNames.Add('SHA256SUMS')
if ($Mode -ceq 'Release') { [void]$expectedNames.Add($catalogName) }
$actualEntries = @(Get-ChildItem -LiteralPath $ReleaseAssetsRoot -Force)
foreach ($entry in $actualEntries) {
    if ($entry.PSIsContainer -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or -not $expectedNames.Contains([string]$entry.Name)) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseAssetSet' -Message "Release root contains an unexpected, non-file, or reparse entry: $($entry.Name)"
    }
}
if ($actualEntries.Count -ne $expectedNames.Count) {
    Throw-PshReleaseArtifactError -ExitCode 4 -ErrorId 'PshReleaseAssetSet' -Message 'Release root does not contain the exact required public asset set for this verification mode.'
}

$indexPath = Resolve-PshReleaseArtifactFile -Path (Join-Path $ReleaseAssetsRoot $indexName) -Description 'release index'
$checksumPath = Resolve-PshReleaseArtifactFile -Path (Join-Path $ReleaseAssetsRoot 'SHA256SUMS') -Description 'SHA256SUMS'
$index = Read-PshReleaseIndex -Path $indexPath
$checksums = Read-PshSha256Sums -Path $checksumPath
[void](Assert-PshReleaseIndexChecksums -Index $index -Checksums $checksums)
if ([string]$index.version -cne $Version -or [string]$index.sourceCommit -cne $SourceCommit -or @($index.assets).Count -ne $contentSpecs.Count) {
    Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseIndexIdentity' -Message 'Release index version, commit, or asset count does not match the candidate.'
}

$expectedLicensePaths = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'licenses') -Recurse -Force -File | ForEach-Object {
        $root = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'licenses')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        'licenses/' + $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    })
$packageVerifications = New-Object System.Collections.Generic.List[object]
$publicBootstrapper = Get-PshReleaseArtifactFileState -Path (Join-Path $ReleaseAssetsRoot 'psh-installer.exe')
$publicInstaller = Get-PshReleaseArtifactFileState -Path (Join-Path $ReleaseAssetsRoot 'install.ps1')
Assert-PshReleaseEmbeddedInstaller -InstallerPath (Join-Path $ReleaseAssetsRoot 'install.ps1') -Repository $RepositoryRoot

for ($i = 0; $i -lt $contentSpecs.Count; $i++) {
    $spec = $contentSpecs[$i]
    $asset = @($index.assets)[$i]
    if ([string]$asset.name -cne [string]$spec.Name -or [string]$asset.role -cne [string]$spec.Role) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseAssetOrder' -Message "Release index asset order or role changed at position $i."
    }
    $path = Resolve-PshReleaseArtifactFile -Path (Join-Path $ReleaseAssetsRoot ([string]$spec.Name)) -Description "release asset '$($spec.Name)'"
    $state = Get-PshReleaseArtifactFileState -Path $path
    if ([int64]$state.Length -ne [int64]$asset.length -or [string]$state.Sha256 -cne [string]$asset.sha256) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseAssetHash' -Message "Release asset does not match index length/SHA256: $($spec.Name)"
    }
    if ([string]$spec.Role -ceq 'package') {
        $verification = Get-PshReleasePackageVerification -PackagePath $path -ExpectedVersion $Version -ExpectedEdition ([string]$spec.Edition) -ExpectedArchitecture ([string]$spec.Architecture) -ExpectedCommit $SourceCommit -ExpectedLicensePaths $expectedLicensePaths
        if ($null -eq $asset.package -or [string]$asset.package.packageManifestSha256 -cne [string]$verification.ManifestSha256 -or
            [string]$asset.package.treeSha256 -cne [string]$verification.Manifest.treeSha256 -or [bool]$asset.package.testOnly) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleasePackageIndex' -Message "Release index package metadata does not match ZIP manifest: $($spec.Name)"
        }
        if ([string]$verification.BootstrapperSha256 -cne [string]$publicBootstrapper.Sha256 -or
            [string]$verification.OnlineInstallerSha256 -cne [string]$publicInstaller.Sha256) {
            Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseCommonEntrypoints' -Message "Package does not contain the same bootstrapper/online installer bytes as public assets: $($spec.Name)"
        }
        $packageVerifications.Add($verification)
    }
    elseif ($null -ne $asset.package) {
        Throw-PshReleaseArtifactError -ExitCode 5 -ErrorId 'PshReleaseAssetPackage' -Message "Non-package release asset has package metadata: $($spec.Name)"
    }
}

$phase = 'static-verified-catalog-membership-deferred'
$code = 4
$releaseAuthenticodeStatus = $null
$packageAuthenticodeStatuses = @()
if ($Mode -ceq 'Release') {
    $catalogPath = Resolve-PshReleaseArtifactFile -Path (Join-Path $ReleaseAssetsRoot $catalogName) -Description 'release catalog'
    $releaseAuthenticodeStatus = Invoke-PshReleaseCatalogMembershipVerification -CatalogCommand $fileCatalogCommand -CatalogPath $catalogPath -Members @(
        [pscustomobject]@{ Name = $indexName; SourcePath = $indexPath },
        [pscustomobject]@{ Name = 'SHA256SUMS'; SourcePath = $checksumPath }
    ) -ErrorId 'PshReleaseCatalogMembership' -Description 'release catalog'
    $packageAuthenticodeStatuses = @(Test-PshReleasePackageCatalogSet -CatalogCommand $fileCatalogCommand -Packages $packageVerifications.ToArray())
    $phase = 'release-catalog-membership-verified'
    $code = 0
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    product = 'Psh'
    version = $Version
    sourceCommit = $SourceCommit
    mode = $Mode
    phase = $phase
    code = $code
    assetCount = $actualEntries.Count
    packageCount = $packageVerifications.Count
    indexSha256 = [string](Get-PshReleaseArtifactFileState -Path $indexPath).Sha256
    checksumsSha256 = [string](Get-PshReleaseArtifactFileState -Path $checksumPath).Sha256
    catalogMembershipVerified = ($Mode -ceq 'Release' -and $code -eq 0)
    authenticodeStatus = if ($Mode -cne 'Release') { $null } else {
        [pscustomobject][ordered]@{
            informationalOnly = $true
            releaseCatalog = [string]$releaseAuthenticodeStatus
            packageCatalogs = $packageAuthenticodeStatuses
        }
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    Write-PshReleaseArtifactReport -Path $ReportPath -Value $result
}
Write-Output $result
