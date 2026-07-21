# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Reactivates a retained, locally installed Psh version.

.DESCRIPTION
Rollback is deliberately offline-only.  It never downloads or resolves a
package.  The selected version must be present in the Psh ownership record and
must still match every recorded file hash before current.json is switched.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string] $Version,

    [Parameter()]
    [string] $InstallRoot,

    [Parameter()]
    [AllowNull()]
    [string[]] $ProfilePath,

    [Parameter()]
    [AllowNull()]
    [string[]] $ModuleRoot,

    [Parameter()]
    [string] $ProjectionStateRoot,

    [Parameter()]
    [switch] $Offline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path -Path $PSScriptRoot -ChildPath 'PackageLifecycle.ps1'
if (-not [IO.File]::Exists($lifecyclePath)) { throw "Psh package lifecycle helpers were not found: $lifecyclePath" }
. $lifecyclePath

$script:VersionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'

function Get-PshRollbackProperty {
    param([AllowNull()][object] $InputObject, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { return ,@($property.Value) }
    return $property.Value
}

function Stop-PshRollback {
    param([Parameter(Mandatory = $true)][int] $Code, [Parameter(Mandatory = $true)][string] $Message, [string] $Kind = 'RuntimeError')
    $global:LASTEXITCODE = $Code
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['PshExitCode'] = $Code
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = ('PshLifecycle.{0}' -f $Kind)
    throw $exception
}

function Assert-PshRollbackNoPendingTransaction {
    param([Parameter(Mandatory = $true)][string] $Root)
    $transaction = Read-PshTransactionState -InstallRoot $Root
    if ($null -eq $transaction) { return }
    $decision = Get-PshRecoveryDecision -InstallRoot $Root -Transaction $transaction
    $action = [string](Get-PshRollbackProperty $decision 'Action')
    $safe = [bool](Get-PshRollbackProperty $decision 'Safe')
    if ($safe -and $action -ceq 'None') { return }
    $operation = [string](Get-PshRollbackProperty $transaction 'operation')
    $transactionId = [string](Get-PshRollbackProperty $transaction 'transactionId')
    $reason = [string](Get-PshRollbackProperty $decision 'Reason')
    $message = "An unfinished Psh $operation transaction ($transactionId) requires recovery before rollback: action=$action; $reason"
    if ($safe) { Stop-PshRollback -Code 3 -Kind 'RuntimeError' -Message $message }
    Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message $message
}

function Resolve-PshRollbackPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    try {
        $provider = $null; $drive = $null
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    }
    catch { Stop-PshRollback -Code 5 -Kind 'PathFailure' -Message ("{0} is not a filesystem path: {1}" -f $Description, $Path) }
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem' -or -not [IO.Path]::IsPathRooted($full)) { Stop-PshRollback -Code 5 -Kind 'PathFailure' -Message ("{0} must be an absolute filesystem path: {1}" -f $Description, $Path) }
    return [IO.Path]::GetFullPath($full)
}

function Assert-PshRollbackRootNotFilesystemRoot {
    param([Parameter(Mandatory = $true)][string] $Root)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $filesystemRoot = [IO.Path]::GetFullPath([IO.Path]::GetPathRoot($Root)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($normalizedRoot, $filesystemRoot, $comparison)) {
        Stop-PshRollback -Code 5 -Kind 'PathFailure' -Message "InstallRoot must not be the filesystem root: $Root"
    }
}

function Assert-PshRollbackSafePath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [switch] $AllowMissing
    )
    try {
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch { Stop-PshRollback -Code 5 -Kind 'PathFailure' -Message ("{0} is not a valid filesystem path: {1}" -f $Description, $Path) }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $fullRoot, $comparison) -and -not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        Stop-PshRollback -Code 5 -Kind 'PathFailure' -Message ("{0} escapes InstallRoot: {1}" -f $Description, $Path)
    }
    $current = $fullRoot
    if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
        try { $attributes = [IO.File]::GetAttributes($current) } catch { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $current) }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} contains a reparse point: {1}" -f $Description, $current) }
    }
    $relative = $fullPath.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($relative)) { return $fullPath }
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (-not ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current))) {
            if ($AllowMissing) { break }
            Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
        try { $attributes = [IO.File]::GetAttributes($current) } catch { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $current) }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} contains a reparse point: {1}" -f $Description, $current) }
    }
    return $fullPath
}

function Assert-PshRollbackDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [switch] $AllowMissing
    )
    $fullPath = Assert-PshRollbackSafePath -Root $Root -Path $Path -Description $Description -AllowMissing
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $relative = $fullPath.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = $fullRoot
    if ([IO.File]::Exists($current)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is a file: {1}" -f $Description, $current) }
    if ([string]::IsNullOrWhiteSpace($relative)) { return $fullPath }
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is obstructed by a file: {1}" -f $Description, $current) }
        if (-not [IO.Directory]::Exists($current)) {
            if ($AllowMissing) { break }
            Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
    }
    return $fullPath
}

function Get-PshRollbackHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PshRollbackBytesHash {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Enter-PshRollbackProjectionLock {
    param([Parameter(Mandatory = $true)][string] $StateRoot)
    $normalized = ([IO.Path]::GetFullPath($StateRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).ToUpperInvariant()
    $utf8 = New-Object Text.UTF8Encoding($false)
    $mutexName = 'Psh.PSReadLineProjection.' + (Get-PshRollbackBytesHash -Bytes $utf8.GetBytes($normalized))
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for PSReadLine projection state: $StateRoot" }
        return [pscustomobject]@{ Mutex = $mutex; Acquired = $true; Name = $mutexName }
    }
    catch {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        throw
    }
}

function Exit-PshRollbackProjectionLock {
    param([Parameter(Mandatory = $true)][pscustomobject] $Lock)
    try {
        if ([bool]$Lock.Acquired) {
            $Lock.Mutex.ReleaseMutex()
            $Lock.Acquired = $false
        }
    }
    finally { $Lock.Mutex.Dispose() }
}

function Read-PshRollbackCurrent {
    param([Parameter(Mandatory = $true)][string] $Root)
    $path = Join-Path $Root 'current.json'
    $snapshot = Read-PshStrictJsonSnapshot -Path $path -Description 'current state' -AllowMissing -RequireLf
    if ($null -eq $snapshot) { return [pscustomobject][ordered]@{ exists = $false; version = $null; sha256 = $null; bytes = (New-Object byte[] 0) } }
    $document = $snapshot.Document
    Assert-PshLifecycleAllowedProperties -InputObject $document -Allowed @('schemaVersion', 'version') -Description 'current state'
    Assert-PshLifecycleRequiredProperties -InputObject $document -Required @('schemaVersion', 'version') -Description 'current state'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $document 'schemaVersion') -Description 'current schemaVersion' -NonNegative) -ne 1) {
        Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'current.json schemaVersion must be 1.'
    }
    $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $document 'version') -Description 'current version'
    return [pscustomobject][ordered]@{ exists = $true; version = $version; sha256 = [string]$snapshot.Sha256; bytes = [byte[]]$snapshot.Bytes }
}

function Get-PshRollbackVersionEntry {
    param([Parameter(Mandatory = $true)][object] $Ownership, [Parameter(Mandatory = $true)][string] $Version)
    $versions = Get-PshRollbackProperty $Ownership 'versions'
    foreach ($candidate in @($versions)) {
        if ($null -ne $candidate -and [string](Get-PshRollbackProperty $candidate 'version') -ceq $Version) { return $candidate }
    }
    return $null
}

function Assert-PshRollbackVersion {
    param([Parameter(Mandatory = $true)][string] $VersionRoot, [Parameter(Mandatory = $true)][object] $Entry)
    if (-not [IO.Directory]::Exists($VersionRoot)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version is missing: $VersionRoot" }
    if (([IO.File]::GetAttributes($VersionRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version is a reparse point: $VersionRoot" }
    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $expectedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $records = New-Object System.Collections.Generic.List[object]
    $files = Get-PshRollbackProperty $Entry 'files'
    foreach ($file in @($files)) {
        $relative = [string](Get-PshRollbackProperty $file 'relativePath')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version contains an unsafe path: $relative" }
        $relative = $relative.Replace('\', '/')
        if (-not $expectedFiles.Add($relative)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version contains a duplicate path: $relative" }
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        while (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = $expectedDirectories.Add($parent.Replace('\', '/'))
            $parent = [IO.Path]::GetDirectoryName($parent.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
        $path = Join-Path $VersionRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($path)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version file is missing: $path" }
        if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version file is a reparse point: $path" }
        $expectedLength = Get-PshRollbackProperty $file 'length'
        if ($null -ne $expectedLength -and (Get-Item -LiteralPath $path).Length -ne [long]$expectedLength) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version length changed: $path" }
        $expectedHash = [string](Get-PshRollbackProperty $file 'sha256')
        if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and (Get-PshRollbackHash -Path $path) -cne $expectedHash.ToLowerInvariant()) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version hash changed: $path" }
        $records.Add([pscustomobject][ordered]@{ relativePath = $relative; length = [long](Get-Item -LiteralPath $path).Length; sha256 = $expectedHash.ToLowerInvariant() })
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $VersionRoot -Recurse -Force)) {
        $itemRelative = [IO.Path]::GetFullPath($item.FullName).Substring([IO.Path]::GetFullPath($VersionRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
        if (([IO.File]::GetAttributes($item.FullName) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version contains a reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) {
            if (-not $expectedDirectories.Contains($itemRelative)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version contains an unknown directory: $itemRelative" }
        }
        elseif (-not $expectedFiles.Contains($itemRelative)) {
            Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version contains an unknown file: $itemRelative"
        }
    }
    $actualTree = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $records.ToArray() })
    if ($actualTree -cne ([string](Get-PshRollbackProperty $Entry 'treeSha256')).ToLowerInvariant()) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Retained version tree digest changed: $VersionRoot" }
}

function Get-PshRollbackDefaultModules {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) { return @() }
    return @((Join-Path (Join-Path $documents 'WindowsPowerShell') 'Modules'), (Join-Path (Join-Path $documents 'PowerShell') 'Modules'))
}

function Invoke-PshRollbackScript {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object[]] $Arguments)
    return @(& $Path @Arguments)
}

function Find-PshRollbackScript {
    param([Parameter(Mandatory = $true)][string] $VersionRoot, [Parameter(Mandatory = $true)][string] $Name)
    foreach ($candidate in @(
            (Join-Path $VersionRoot ('profile/' + $Name)),
            (Join-Path $VersionRoot ('src/profile/' + $Name)))) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Get-PshRollbackScriptStatus {
    param([Parameter(Mandatory = $true)][string] $Path, [AllowNull()][string] $ExpectedSha256)
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $null; Reason = 'script has no ownership hash' } }
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $null; Reason = 'script is missing' } }
    try {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $null; Reason = 'script is a reparse point' } }
        $hash = Get-PshRollbackHash -Path $Path
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $hash -cne $ExpectedSha256.ToLowerInvariant()) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $hash; Reason = 'script hash changed' } }
        return [pscustomobject][ordered]@{ Trusted = $true; RestartRequired = $false; Sha256 = $hash; Reason = 'script is verified' }
    }
    catch { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $true; Sha256 = $null; Reason = 'script could not be read' } }
}

function Get-PshRollbackScriptPair {
    param(
        [Parameter(Mandatory = $true)][string] $VersionRoot,
        [Parameter(Mandatory = $true)][object] $VersionEntry,
        [Parameter(Mandatory = $true)][string] $InstallName,
        [Parameter(Mandatory = $true)][string] $UninstallName,
        [Parameter(Mandatory = $true)][string] $Description
    )
    $installPath = Find-PshRollbackScript -VersionRoot $VersionRoot -Name $InstallName
    $uninstallPath = Find-PshRollbackScript -VersionRoot $VersionRoot -Name $UninstallName
    if ($null -eq $installPath -or $null -eq $uninstallPath) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description requires paired installer and uninstaller scripts." }
    $installExpectedSha256 = $null
    $uninstallExpectedSha256 = $null
    foreach ($scriptCandidate in @(
            [pscustomobject]@{ Path = $installPath; Slot = 'install' },
            [pscustomobject]@{ Path = $uninstallPath; Slot = 'uninstall' })) {
        if ([IO.Path]::GetFullPath($scriptCandidate.Path).StartsWith([IO.Path]::GetFullPath($VersionRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $(if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
            $relative = [IO.Path]::GetFullPath($scriptCandidate.Path).Substring([IO.Path]::GetFullPath($VersionRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
            $found = $false
            foreach ($file in @((Get-PshRollbackProperty $VersionEntry 'files'))) {
                if ([string](Get-PshRollbackProperty $file 'relativePath') -ceq $relative) {
                    if ([string]$scriptCandidate.Slot -ceq 'install') { $installExpectedSha256 = [string](Get-PshRollbackProperty $file 'sha256') } else { $uninstallExpectedSha256 = [string](Get-PshRollbackProperty $file 'sha256') }
                    $found = $true
                    break
                }
            }
            if (-not $found) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description script is not present in owned version metadata: $relative" }
        }
    }
    $installStatus = Get-PshRollbackScriptStatus -Path $installPath -ExpectedSha256 $installExpectedSha256
    $uninstallStatus = Get-PshRollbackScriptStatus -Path $uninstallPath -ExpectedSha256 $uninstallExpectedSha256
    $directoryComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [bool](Get-PshRollbackProperty $installStatus 'Trusted') -or -not [bool](Get-PshRollbackProperty $uninstallStatus 'Trusted') -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($installPath), [IO.Path]::GetDirectoryName($uninstallPath), $directoryComparison)) {
        Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description paired scripts are not trusted."
    }
    return [pscustomobject][ordered]@{
        InstallPath = [IO.Path]::GetFullPath($installPath)
        InstallSha256 = [string](Get-PshRollbackProperty $installStatus 'Sha256')
        UninstallPath = [IO.Path]::GetFullPath($uninstallPath)
        UninstallSha256 = [string](Get-PshRollbackProperty $uninstallStatus 'Sha256')
    }
}

function Find-PshRollbackProjectionSource {
    param([Parameter(Mandatory = $true)][string] $VersionRoot)
    foreach ($candidate in @(
            (Join-Path $VersionRoot 'Psh/Dependencies/PSReadLine/2.4.5'),
            (Join-Path $VersionRoot 'Dependencies/PSReadLine/2.4.5'),
            (Join-Path $VersionRoot 'PSReadLine/2.4.5'))) {
        if ([IO.Directory]::Exists($candidate)) {
            Assert-PshRollbackSafePath -Root $VersionRoot -Path $candidate -Description 'PSReadLine projection source' | Out-Null
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Copy-PshRollbackObject {
    param([Parameter(Mandatory = $true)][object] $InputObject)
    return (($InputObject | ConvertTo-Json -Depth 64 -Compress) | ConvertFrom-Json -ErrorAction Stop)
}

function Write-PshRollbackBytesCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "$Description disappeared before compensation." }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Description became a reparse point before compensation." }
    if ((Get-PshRollbackHash -Path $Path) -cne $ExpectedSha256) { throw "$Description changed before compensation." }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $operationId = ([Guid]::NewGuid()).ToString('N')
    $temporaryPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupPath = Join-Path $parent ('.{0}.{1}.bak' -f [IO.Path]::GetFileName($Path), $operationId)
    $recoveryPath = Join-Path $parent ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupOwned = $false
    $recoveryOwned = $false
    $targetSha256 = Get-PshRollbackBytesHash -Bytes $Bytes
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        if ([IO.File]::Exists($backupPath) -and (Get-PshRollbackHash -Path $backupPath) -ceq $ExpectedSha256) {
            $backupOwned = $true
        }
        else {
            if ([IO.File]::Exists($Path) -and (Get-PshRollbackHash -Path $Path) -ceq $targetSha256 -and [IO.File]::Exists($backupPath)) {
                try {
                    [IO.File]::Replace($backupPath, $Path, $recoveryPath)
                    if ([IO.File]::Exists($recoveryPath) -and (Get-PshRollbackHash -Path $recoveryPath) -ceq $targetSha256) { $recoveryOwned = $true }
                }
                catch { }
            }
            throw "$Description changed at the atomic compensation point. Recovery evidence was retained."
        }
        if (-not [IO.File]::Exists($Path) -or (Get-PshRollbackHash -Path $Path) -cne $targetSha256) {
            $backupOwned = $false
            throw "$Description did not retain the expected compensation bytes. Recovery evidence was retained."
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try { if ((Get-PshRollbackHash -Path $temporaryPath) -ceq $targetSha256) { [IO.File]::Delete($temporaryPath) } } catch {}
        }
        if ($backupOwned -and [IO.File]::Exists($backupPath)) {
            try { if ((Get-PshRollbackHash -Path $backupPath) -ceq $ExpectedSha256) { [IO.File]::Delete($backupPath) } } catch {}
        }
        if ($recoveryOwned -and [IO.File]::Exists($recoveryPath)) {
            try { if ((Get-PshRollbackHash -Path $recoveryPath) -ceq $targetSha256) { [IO.File]::Delete($recoveryPath) } } catch {}
        }
    }
}

function Write-PshRollbackFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][bool] $ExpectedExisted,
        [AllowNull()][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description
    )
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $operationId = ([Guid]::NewGuid()).ToString('N')
    $temporaryPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupPath = Join-Path $parent ('.{0}.{1}.bak' -f [IO.Path]::GetFileName($Path), $operationId)
    $recoveryPath = Join-Path $parent ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupOwned = $false
    $recoveryOwned = $false
    $targetSha256 = Get-PshRollbackBytesHash -Bytes $Bytes
    try {
        if ([IO.Directory]::Exists($Path)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description is a directory." }
        $liveExists = [IO.File]::Exists($Path)
        if ($ExpectedExisted) {
            if (-not $liveExists -or (Get-PshRollbackHash -Path $Path) -cne $ExpectedSha256) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before the CAS write." }
        }
        elseif ($liveExists) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared before the expected-absent CAS write." }
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if ($ExpectedExisted) {
            try { [IO.File]::Replace($temporaryPath, $Path, $backupPath) }
            catch {
                $nowMatches = $false
                if ([IO.File]::Exists($Path)) { try { $nowMatches = (Get-PshRollbackHash -Path $Path) -ceq $ExpectedSha256 } catch {} }
                if (-not $nowMatches) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS write point." }
                Stop-PshRollback -Code 3 -Kind 'RuntimeError' -Message "$Description could not be replaced: $($_.Exception.Message)"
            }
            if (-not [IO.File]::Exists($backupPath)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description replacement produced no verifiable backup." }
            if ((Get-PshRollbackHash -Path $backupPath) -cne $ExpectedSha256) {
                if ([IO.File]::Exists($Path) -and (Get-PshRollbackHash -Path $Path) -ceq $targetSha256) {
                    try {
                        [IO.File]::Replace($backupPath, $Path, $recoveryPath)
                        if ([IO.File]::Exists($recoveryPath) -and (Get-PshRollbackHash -Path $recoveryPath) -ceq $targetSha256) { $recoveryOwned = $true }
                    }
                    catch { }
                }
                Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS write point; recovery evidence was retained."
            }
            $backupOwned = $true
        }
        else {
            try { [IO.File]::Move($temporaryPath, $Path) }
            catch {
                if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared at the atomic expected-absent CAS write point." }
                Stop-PshRollback -Code 3 -Kind 'RuntimeError' -Message "$Description could not be created: $($_.Exception.Message)"
            }
        }
        if (-not [IO.File]::Exists($Path) -or (Get-PshRollbackHash -Path $Path) -cne $targetSha256) {
            $backupOwned = $false
            Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description did not retain the transaction bytes after the CAS write."
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try { if ((Get-PshRollbackHash -Path $temporaryPath) -ceq $targetSha256) { [IO.File]::Delete($temporaryPath) } } catch {}
        }
        if ($backupOwned -and [IO.File]::Exists($backupPath)) {
            try { if ((Get-PshRollbackHash -Path $backupPath) -ceq $ExpectedSha256) { [IO.File]::Delete($backupPath) } } catch {}
        }
        if ($recoveryOwned -and [IO.File]::Exists($recoveryPath)) {
            try { if ((Get-PshRollbackHash -Path $recoveryPath) -ceq $targetSha256) { [IO.File]::Delete($recoveryPath) } } catch {}
        }
    }
}

function Remove-PshRollbackFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) -or (Get-PshRollbackHash -Path $Path) -cne $ExpectedSha256) {
        Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before the CAS removal."
    }
    $recoveryPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), ([Guid]::NewGuid().ToString('N')))
    [IO.File]::Move($Path, $recoveryPath)
    if ((Get-PshRollbackHash -Path $recoveryPath) -cne $ExpectedSha256) {
        if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { [IO.File]::Move($recoveryPath, $Path) }
        Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS removal point."
    }
    try {
        if ((Get-PshRollbackHash -Path $recoveryPath) -cne $ExpectedSha256) {
            Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "$Description recovery evidence changed before deletion."
        }
        [IO.File]::Delete($recoveryPath)
    }
    catch {
        if ($null -ne $_.Exception.Data['PshExitCode']) { throw }
        Stop-PshRollback -Code 3 -Kind 'RuntimeError' -Message "$Description was detached but its recovery file could not be deleted: $recoveryPath"
    }
}

function ConvertTo-PshRollbackCanonicalBytes {
    param([Parameter(Mandatory = $true)][object] $InputObject)
    $json = (ConvertTo-PshCanonicalJson -InputObject $InputObject) + "`n"
    return ,((New-Object System.Text.UTF8Encoding($false)).GetBytes($json))
}

function Get-PshRollbackCurrentBytes {
    param([Parameter(Mandatory = $true)][string] $Version)
    [byte[]]$bytes = Get-PshLifecycleCanonicalCurrentBytes -Version $Version
    return ,$bytes
}

$lock = $null
$root = $null
$journal = $null
$journalWritten = $false
$confirmed = $false
$projectionLock = $null
$projectionOldUninstallAttempted = $false
$projectionOldInstallCompleted = $false
$projectionTargetInstallAttempted = $false
$projectionManifestExpectedSha256 = $null
$ownershipWriteAttempted = $false
$pointerWriteAttempted = $false
try {
    $root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Stop-PshRollback -Code 4 -Kind 'MissingDependency' -Message 'LOCALAPPDATA is unavailable.' }
        Join-Path $env:LOCALAPPDATA 'Psh'
    } else { Resolve-PshRollbackPath -Path $InstallRoot -Description 'InstallRoot' }
    Assert-PshRollbackRootNotFilesystemRoot -Root $root
    if (-not [IO.Directory]::Exists($root)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Psh installation root is missing: $root" }
    Assert-PshRollbackDirectoryPath -Root $root -Path $root -Description 'InstallRoot' | Out-Null
    $lock = Enter-PshInstallRootLock -InstallRoot $root
    Assert-PshRollbackNoPendingTransaction -Root $root

    $ownershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
    if ($null -eq $ownershipSnapshot) { return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'rollback'; status = 'notInstalled' } }
    $ownership = Get-PshRollbackProperty $ownershipSnapshot 'Document'
    $ownershipBeforeSha256 = [string](Get-PshRollbackProperty $ownershipSnapshot 'Sha256')
    [byte[]]$ownershipBeforeBytes = [byte[]](Get-PshRollbackProperty $ownershipSnapshot 'Bytes')
    $ownershipBefore = Copy-PshRollbackObject -InputObject $ownership
    $current = Read-PshRollbackCurrent -Root $root
    if (-not [bool]$current.exists) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Rollback requires an existing verified current.json.' }
    $activeVersion = [string](Get-PshRollbackProperty $ownership 'activeVersion')
    if ([string]$current.version -cne $activeVersion) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'current.json does not select ownership.activeVersion.' }

    $versionsRoot = Join-Path $root 'versions'
    foreach ($directoryCheck in @(
            [pscustomobject]@{ Path = $versionsRoot; Description = 'Versions root' },
            [pscustomobject]@{ Path = (Join-Path $root '.staging'); Description = 'Staging root' },
            [pscustomobject]@{ Path = (Join-Path $root '.quarantine'); Description = 'Quarantine root' },
            [pscustomobject]@{ Path = (Join-Path $root '.lifecycle'); Description = 'Lifecycle root' },
            [pscustomobject]@{ Path = (Join-Path (Join-Path $root '.lifecycle') 'backups'); Description = 'Lifecycle backup root' })) {
        Assert-PshRollbackDirectoryPath -Root $root -Path $directoryCheck.Path -Description $directoryCheck.Description -AllowMissing | Out-Null
    }

    $rollbackOrder = Get-PshRollbackProperty $ownership 'rollbackOrder'
    $targetVersion = $Version
    if ([string]::IsNullOrWhiteSpace($targetVersion)) {
        $targetVersion = $null
        foreach ($candidateRollback in @($rollbackOrder)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidateRollback) -and [string]$candidateRollback -cne [string]$current.version) { $targetVersion = [string]$candidateRollback; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($targetVersion)) { return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'rollback'; status = 'noRetainedVersion'; currentVersion = $current.version } }
    if ($targetVersion -notmatch $script:VersionPattern) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Invalid rollback version: $targetVersion" }
    if ([string]$current.version -ceq $targetVersion) { return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'rollback'; status = 'alreadyCurrent'; version = $targetVersion } }

    $targetEntry = Get-PshRollbackVersionEntry -Ownership $ownership -Version $targetVersion
    if ($null -eq $targetEntry) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Version is not owned by this installation: $targetVersion" }
    $oldEntry = Get-PshRollbackVersionEntry -Ownership $ownership -Version $activeVersion
    if ($null -eq $oldEntry) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Current version is not owned by this installation: $activeVersion" }
    $targetRoot = Join-Path $versionsRoot $targetVersion
    $oldRoot = Join-Path $versionsRoot $activeVersion
    Assert-PshRollbackDirectoryPath -Root $root -Path $targetRoot -Description 'Rollback target version' | Out-Null
    Assert-PshRollbackDirectoryPath -Root $root -Path $oldRoot -Description 'Current version' | Out-Null
    Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
    Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry

    $setCurrent = $null
    foreach ($candidate in @((Join-Path $targetRoot 'install/Set-PshCurrentVersion.ps1'), (Join-Path $targetRoot 'Set-PshCurrentVersion.ps1'))) {
        if ([IO.File]::Exists($candidate)) { $setCurrent = [IO.Path]::GetFullPath($candidate); break }
    }
    if ($null -eq $setCurrent) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Set-PshCurrentVersion.ps1 is unavailable in the retained version.' }
    $setCurrentRelative = $setCurrent.Substring([IO.Path]::GetFullPath($targetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
    $setCurrentExpectedSha256 = $null
    foreach ($file in @((Get-PshRollbackProperty $targetEntry 'files'))) {
        if ([string](Get-PshRollbackProperty $file 'relativePath') -ceq $setCurrentRelative) { $setCurrentExpectedSha256 = [string](Get-PshRollbackProperty $file 'sha256'); break }
    }
    if ([string]::IsNullOrWhiteSpace($setCurrentExpectedSha256)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message "Set-PshCurrentVersion.ps1 is not present in retained metadata: $setCurrentRelative" }
    $setCurrentStatus = Get-PshRollbackScriptStatus -Path $setCurrent -ExpectedSha256 $setCurrentExpectedSha256
    if (-not [bool](Get-PshRollbackProperty $setCurrentStatus 'Trusted')) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Set-PshCurrentVersion.ps1 is not trusted.' }
    $setCurrent = [IO.Path]::GetFullPath($setCurrent)
    $setCurrentSha256 = [string](Get-PshRollbackProperty $setCurrentStatus 'Sha256')
    [byte[]]$targetCurrentBytes = Get-PshRollbackCurrentBytes -Version $targetVersion
    $targetCurrentSha256 = Get-PshRollbackBytesHash -Bytes $targetCurrentBytes

    $modules = @(if ($PSBoundParameters.ContainsKey('ModuleRoot')) { @($ModuleRoot) } else { @(Get-PshRollbackDefaultModules) })
    $projectionState = if ([string]::IsNullOrWhiteSpace($ProjectionStateRoot)) { Join-Path $root 'psreadline-projection-state' } else { Resolve-PshRollbackPath -Path $ProjectionStateRoot -Description 'ProjectionStateRoot' }
    if ([IO.Path]::GetFullPath($projectionState).StartsWith([IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $(if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        Assert-PshRollbackDirectoryPath -Root $root -Path $projectionState -Description 'Projection state root' -AllowMissing | Out-Null
    }
    $projectionEnabled = [bool](Get-PshRollbackProperty (Get-PshRollbackProperty (Get-PshRollbackProperty $ownership 'components') 'psReadLineProjection') 'installed')
    $oldProjectionPair = $null
    $targetProjectionPair = $null
    $oldProjectionSource = $null
    $targetProjectionSource = $null
    $projectionManifestPath = Join-Path $projectionState 'manifest.json'
    $projectionManifestExisted = $false
    [byte[]]$projectionManifestBytes = New-Object byte[] 0
    $projectionManifestSha256 = $null
    if ($projectionEnabled) {
        $projectionLock = Enter-PshRollbackProjectionLock -StateRoot $projectionState
        if ($modules.Count -eq 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Installed PSReadLine projection state requires at least one module root.' }
        $oldProjectionPair = Get-PshRollbackScriptPair -VersionRoot $oldRoot -VersionEntry $oldEntry -InstallName 'Install-PshPSReadLineProjection.ps1' -UninstallName 'Uninstall-PshPSReadLineProjection.ps1' -Description 'Current PSReadLine projection'
        $targetProjectionPair = Get-PshRollbackScriptPair -VersionRoot $targetRoot -VersionEntry $targetEntry -InstallName 'Install-PshPSReadLineProjection.ps1' -UninstallName 'Uninstall-PshPSReadLineProjection.ps1' -Description 'Target PSReadLine projection'
        $oldProjectionSource = Find-PshRollbackProjectionSource -VersionRoot $oldRoot
        $targetProjectionSource = Find-PshRollbackProjectionSource -VersionRoot $targetRoot
        if ($null -eq $oldProjectionSource -or $null -eq $targetProjectionSource) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Rollback projection sources are missing.' }
        if (-not [IO.File]::Exists($projectionManifestPath) -or [IO.Directory]::Exists($projectionManifestPath)) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Installed projection state manifest is missing.' }
        if (([IO.File]::GetAttributes($projectionManifestPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state manifest is a reparse point.' }
        $projectionManifestExisted = $true
        $projectionManifestBytes = [IO.File]::ReadAllBytes($projectionManifestPath)
        $projectionManifestSha256 = Get-PshRollbackBytesHash -Bytes $projectionManifestBytes
        Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry
        Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
        try { $null = @(& $oldProjectionPair.UninstallPath -ModuleRoot $modules -StateRoot $projectionState -WhatIf -Confirm:$false) }
        catch { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message ("Projection rollback preflight failed: {0}" -f $_.Exception.Message) }
    }

    $newRollback = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($rollbackOrder)) { if ([string]$v -cne $targetVersion -and [string]$v -cne [string]$current.version) { $newRollback.Add([string]$v) } }
    $newRollback.Insert(0, [string]$current.version)
    $transitionedOwnership = Copy-PshRollbackObject -InputObject $ownership
    $transitionedOwnership.activeVersion = $targetVersion
    $transitionedOwnership.rollbackOrder = $newRollback.ToArray()
    $transitionedOwnership = Assert-PshOwnershipDocument -State $transitionedOwnership -InstallRoot $root
    [byte[]]$transitionedOwnershipBytes = ConvertTo-PshRollbackCanonicalBytes -InputObject $transitionedOwnership
    $transitionedOwnershipSha256 = Get-PshRollbackBytesHash -Bytes $transitionedOwnershipBytes

    $confirmed = $PSCmdlet.ShouldProcess($root, "Switch Psh from $activeVersion to retained version $targetVersion")
    if (-not $confirmed) {
        return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'rollback'; status = 'noChanges'; whatIf = [bool]$WhatIfPreference; confirmed = $false; version = $targetVersion; currentVersion = $activeVersion }
    }

    $journal = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        transactionId = ([Guid]::NewGuid()).ToString('N')
        operation = 'rollback'
        phase = 'staged'
        oldCurrent = [pscustomobject][ordered]@{ exists = $true; version = [string]$current.version; sha256 = [string]$current.sha256 }
        targetVersion = $targetVersion
        stageRelativePath = $null
        publishedRelativePath = ('versions/' + $targetVersion)
        ownershipBeforeSha256 = $ownershipBeforeSha256
        startedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    $journal = Assert-PshTransactionDocument -State $journal
    [byte[]]$journalBytes = ConvertTo-PshRollbackCanonicalBytes -InputObject $journal
    $journalSha256 = Get-PshRollbackBytesHash -Bytes $journalBytes
    Write-PshRollbackFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $root -Kind transaction) -ExpectedExisted $false -ExpectedSha256 $null -Bytes $journalBytes -Description 'rollback transaction journal'
    $journalWritten = $true

    if ($projectionEnabled) {
        Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry
        $oldUninstallStatus = Get-PshRollbackScriptStatus -Path $oldProjectionPair.UninstallPath -ExpectedSha256 $oldProjectionPair.UninstallSha256
        if (-not [bool](Get-PshRollbackProperty $oldUninstallStatus 'Trusted')) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Current projection uninstaller changed after preflight.' }
        $projectionOldUninstallAttempted = $true
        $null = @(& $oldProjectionPair.UninstallPath -ModuleRoot $modules -StateRoot $projectionState -Confirm:$false)
        Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry
        Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
        $targetInstallStatus = Get-PshRollbackScriptStatus -Path $targetProjectionPair.InstallPath -ExpectedSha256 $targetProjectionPair.InstallSha256
        if (-not [bool](Get-PshRollbackProperty $targetInstallStatus 'Trusted')) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Target projection installer changed after preflight.' }
        $projectionTargetInstallAttempted = $true
        $null = @(& $targetProjectionPair.InstallPath -SourcePath $targetProjectionSource -ModuleRoot $modules -StateRoot $projectionState -Confirm:$false)
        Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
        Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry
    }

    $ownershipWriteAttempted = $true
    Write-PshRollbackFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $root -Kind ownership) -ExpectedExisted $true -ExpectedSha256 $ownershipBeforeSha256 -Bytes $transitionedOwnershipBytes -Description 'ownership.json'
    if ((Get-PshOwnershipStateSha256 -InstallRoot $root) -cne $transitionedOwnershipSha256) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Transitioned ownership state hash is unexpected.' }
    $journal.phase = 'switched'
    $journal = Assert-PshTransactionDocument -State $journal
    [byte[]]$journalBytes = ConvertTo-PshRollbackCanonicalBytes -InputObject $journal
    $nextJournalSha256 = Get-PshRollbackBytesHash -Bytes $journalBytes
    Write-PshRollbackFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $root -Kind transaction) -ExpectedExisted $true -ExpectedSha256 $journalSha256 -Bytes $journalBytes -Description 'rollback transaction journal'
    $journalSha256 = $nextJournalSha256
    $setCurrentLiveStatus = Get-PshRollbackScriptStatus -Path $setCurrent -ExpectedSha256 $setCurrentSha256
    if (-not [bool](Get-PshRollbackProperty $setCurrentLiveStatus 'Trusted')) { Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'Set-PshCurrentVersion.ps1 changed after preflight.' }
    Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
    $pointerWriteAttempted = $true
    $null = @(& $setCurrent -Version $targetVersion -InstallRoot $root -ExpectedCurrentSha256 ([string]$current.sha256) -Confirm:$false)
    Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
    $targetObservation = Read-PshRollbackCurrent -Root $root
    if (-not [bool]$targetObservation.exists -or [string]$targetObservation.version -cne $targetVersion -or [string]$targetObservation.sha256 -cne $targetCurrentSha256) {
        Stop-PshRollback -Code 5 -Kind 'IntegrityFailure' -Message 'current.json did not reach the expected rollback target state.'
    }
    Remove-PshRollbackFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $root -Kind transaction) -ExpectedSha256 $journalSha256 -Description 'rollback transaction journal'
    $journalWritten = $false
    return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'rollback'; status = 'switched'; version = $targetVersion; previousVersion = $activeVersion; offline = $true }
}
catch {
    $failure = $_
    if (-not $journalWritten) { throw }
    $issues = New-Object System.Collections.Generic.List[string]
    $issues.Add(('Rollback failed: {0}' -f $failure.Exception.Message))
    $integrityConflict = $false
    $restartRequired = $true
    $failureCodeValue = $failure.Exception.Data['PshExitCode']
    if ($null -ne $failureCodeValue -and [int]$failureCodeValue -eq 5) { $integrityConflict = $true; $restartRequired = $false }
    $currentRestored = $true
    $ownershipRestored = $true
    $metadataReady = $true
    $currentState = 'old'
    $ownershipState = 'old'

    # Inspect both metadata files before changing either one.  A divergent
    # file blocks all component compensation so an external writer's state is
    # never overwritten by a partial rollback.
    try {
        $liveCurrent = Read-PshRollbackCurrent -Root $root
        $liveOwnershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
        if ($null -eq $liveOwnershipSnapshot) { throw 'ownership.json is unavailable during compensation.' }
        $liveOwnershipSha = [string]$liveOwnershipSnapshot.Sha256
        if ([bool]$pointerWriteAttempted) {
            if ([bool]$liveCurrent.exists -and [string]$liveCurrent.sha256 -ceq $targetCurrentSha256) { $currentState = 'target' }
            elseif ([bool]$liveCurrent.exists -and [string]$liveCurrent.sha256 -ceq [string]$current.sha256) { $currentState = 'old' }
            else { $metadataReady = $false; $integrityConflict = $true; $issues.Add('current.json diverged from both the old and target states.') }
        }
        elseif (-not [bool]$liveCurrent.exists -or [string]$liveCurrent.sha256 -cne [string]$current.sha256) {
            $metadataReady = $false; $integrityConflict = $true; $issues.Add('current.json changed before the pointer switch was attempted.')
        }
        if ([bool]$ownershipWriteAttempted) {
            if ($liveOwnershipSha -ceq $transitionedOwnershipSha256) { $ownershipState = 'target' }
            elseif ($liveOwnershipSha -ceq $ownershipBeforeSha256) { $ownershipState = 'old' }
            else { $metadataReady = $false; $integrityConflict = $true; $issues.Add('ownership.json diverged from both the old and transitioned states.') }
        }
        elseif ($liveOwnershipSha -cne $ownershipBeforeSha256) {
            $metadataReady = $false; $integrityConflict = $true; $issues.Add('ownership.json changed before the ownership write was attempted.')
        }
    }
    catch {
        $metadataReady = $false
        if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true } else { $restartRequired = $true }
        $issues.Add("Metadata compensation preflight: $($_.Exception.Message)")
    }

    if ($metadataReady) {
        try {
            if ($currentState -ceq 'target') {
                Write-PshRollbackBytesCas -Path (Join-Path $root 'current.json') -ExpectedSha256 $targetCurrentSha256 -Bytes ([byte[]]$current.bytes) -Description 'current.json'
            }
            $afterCurrent = Read-PshRollbackCurrent -Root $root
            if (-not [bool]$afterCurrent.exists -or [string]$afterCurrent.sha256 -cne [string]$current.sha256) { throw 'current.json compensation did not restore the old bytes.' }
        }
        catch { $currentRestored = $false; $metadataReady = $false; $integrityConflict = $true; $issues.Add("Current pointer compensation: $($_.Exception.Message)") }
        if ($metadataReady) {
            try {
                if ($ownershipState -ceq 'target') {
                    Write-PshRollbackBytesCas -Path (Join-Path $root 'ownership.json') -ExpectedSha256 $transitionedOwnershipSha256 -Bytes $ownershipBeforeBytes -Description 'ownership.json'
                }
                $afterOwnership = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
                if ($null -eq $afterOwnership -or [string]$afterOwnership.Sha256 -cne $ownershipBeforeSha256) { throw 'ownership.json compensation did not restore the old bytes.' }
            }
            catch {
                $ownershipRestored = $false; $metadataReady = $false; $integrityConflict = $true; $issues.Add("Ownership compensation: $($_.Exception.Message)")
                try {
                    $liveOwnershipAfterFailure = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
                    $liveCurrentAfterFailure = Read-PshRollbackCurrent -Root $root
                    if ($null -ne $liveOwnershipAfterFailure -and [string]$liveOwnershipAfterFailure.Sha256 -ceq $transitionedOwnershipSha256 -and [bool]$liveCurrentAfterFailure.exists -and [string]$liveCurrentAfterFailure.sha256 -ceq [string]$current.sha256) {
                        Write-PshRollbackFileCas -Path (Join-Path $root 'current.json') -ExpectedExisted $true -ExpectedSha256 ([string]$current.sha256) -Bytes $targetCurrentBytes -Description 'current.json consistency recovery'
                        $consistentCurrent = Read-PshRollbackCurrent -Root $root
                        if (-not [bool]$consistentCurrent.exists -or [string]$consistentCurrent.sha256 -cne $targetCurrentSha256) { throw 'current.json did not return to the rollback target state.' }
                        $issues.Add('Current pointer was returned to the rollback target because ownership compensation could not complete.')
                    }
                }
                catch { $issues.Add("Metadata consistency recovery: $($_.Exception.Message)") }
            }
        }
    }
    else {
        $currentRestored = $false
        $ownershipRestored = $false
        $issues.Add('Metadata CAS conflict detected; component compensation was skipped.')
    }

    $projectionRestored = $true
    if ($metadataReady) {
        if ($projectionEnabled -and $projectionTargetInstallAttempted) {
            try { Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry } catch { $projectionRestored = $false; $integrityConflict = $true; $issues.Add("Target version integrity before component rollback: $($_.Exception.Message)") }
            if ($projectionRestored) {
                $targetUninstallStatus = Get-PshRollbackScriptStatus -Path $targetProjectionPair.UninstallPath -ExpectedSha256 $targetProjectionPair.UninstallSha256
                if (-not [bool](Get-PshRollbackProperty $targetUninstallStatus 'Trusted')) {
                    $projectionRestored = $false; $integrityConflict = $true; $issues.Add('Target projection could not be removed because its paired uninstaller changed.')
                }
                else {
                    try {
                        $null = @(& $targetProjectionPair.UninstallPath -ModuleRoot $modules -StateRoot $projectionState -Confirm:$false)
                        Assert-PshRollbackVersion -VersionRoot $targetRoot -Entry $targetEntry
                    }
                    catch { $projectionRestored = $false; $restartRequired = $true; $issues.Add("Target projection removal: $($_.Exception.Message)") }
                }
            }
        }
        if ($projectionEnabled -and $projectionOldUninstallAttempted -and $projectionRestored) {
            try { Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry } catch { $projectionRestored = $false; $integrityConflict = $true; $issues.Add("Previous version integrity before component restore: $($_.Exception.Message)") }
            if ($projectionRestored) {
                $oldInstallStatus = Get-PshRollbackScriptStatus -Path $oldProjectionPair.InstallPath -ExpectedSha256 $oldProjectionPair.InstallSha256
                if (-not [bool](Get-PshRollbackProperty $oldInstallStatus 'Trusted')) {
                    $projectionRestored = $false; $integrityConflict = $true; $issues.Add('Previous projection could not be restored because its paired installer changed.')
                }
                else {
                    try {
                        $null = @(& $oldProjectionPair.InstallPath -SourcePath $oldProjectionSource -ModuleRoot $modules -StateRoot $projectionState -Confirm:$false)
                        if (-not [IO.File]::Exists($projectionManifestPath) -or [IO.Directory]::Exists($projectionManifestPath)) {
                            throw 'Previous projection installer did not leave a manifest.'
                        }
                        $projectionManifestExpectedSha256 = Get-PshRollbackHash -Path $projectionManifestPath
                        # Read twice while the projection mutex is held.  A
                        # changing image is not attributable to this transaction.
                        if ((Get-PshRollbackHash -Path $projectionManifestPath) -cne $projectionManifestExpectedSha256) {
                            throw 'Previous projection manifest changed after the trusted installer returned.'
                        }
                        $projectionOldInstallCompleted = $true
                        Assert-PshRollbackVersion -VersionRoot $oldRoot -Entry $oldEntry
                    }
                    catch { $projectionRestored = $false; $restartRequired = $true; $issues.Add("Previous projection installation: $($_.Exception.Message)") }
                }
            }
        }
        if ($projectionEnabled -and $projectionManifestExisted -and $projectionRestored -and $projectionOldInstallCompleted) {
            try {
                if (-not [IO.File]::Exists($projectionManifestPath)) { throw 'Projection manifest is absent after component compensation.' }
                if ([string]::IsNullOrWhiteSpace($projectionManifestExpectedSha256)) {
                    throw 'Previous projection manifest output was not recorded.'
                }
                if ((Get-PshRollbackHash -Path $projectionManifestPath) -cne $projectionManifestExpectedSha256) {
                    throw 'Projection manifest changed after the trusted previous-version installer output.'
                }
                if ($projectionManifestExpectedSha256 -cne $projectionManifestSha256) {
                    Write-PshRollbackBytesCas -Path $projectionManifestPath -ExpectedSha256 $projectionManifestExpectedSha256 -Bytes $projectionManifestBytes -Description 'Projection manifest'
                }
            }
            catch { $projectionRestored = $false; $restartRequired = $true; $issues.Add("Projection state rollback: $($_.Exception.Message)") }
        }
    }

    $rollbackClean = $metadataReady -and $projectionRestored -and $ownershipRestored -and $currentRestored
    if ($rollbackClean) {
        try {
            Remove-PshRollbackFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $root -Kind transaction) -ExpectedSha256 $journalSha256 -Description 'rollback transaction journal'
            $journalWritten = $false
        }
        catch { $rollbackClean = $false; $restartRequired = $true; $issues.Add("Transaction journal cleanup: $($_.Exception.Message)") }
    }
    $code = if ($integrityConflict) { 5 } else { 3 }
    $global:LASTEXITCODE = $code
    $failure.Exception.Data['PshExitCode'] = $code
    $failure.Exception.Data['PshErrorKind'] = if ($integrityConflict) { 'IntegrityFailure' } else { 'RuntimeError' }
    $failure.Exception.Data['PshErrorId'] = 'PshLifecycle.RollbackIncomplete'
    $failure.Exception.Data['PshRollbackIncomplete'] = (-not $rollbackClean)
    $failure.Exception.Data['PshRecoveryRequired'] = (-not $rollbackClean)
    $failure.Exception.Data['PshRestartRequired'] = $restartRequired
    $failure.Exception.Data['PshRollbackIssues'] = [string]::Join(' | ', $issues.ToArray())
    throw $failure
}
finally {
    if ($null -ne $projectionLock) { try { Exit-PshRollbackProjectionLock -Lock $projectionLock } catch {} }
    if ($null -ne $lock) { Exit-PshInstallRootLock -Lock $lock }
}
