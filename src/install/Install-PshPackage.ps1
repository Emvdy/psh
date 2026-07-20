# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Installs one already extracted and verified Psh offline package.

.DESCRIPTION
The package is verified before it is copied to a same-volume staging
directory.  The payload is then published as an immutable
versions/<version> directory.  Profile and PSReadLine projection transactions
are given explicit targets, ownership is journaled, and current.json is
switched last through Set-PshCurrentVersion.ps1.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $PackageRoot,

    [Parameter()]
    [string] $InstallRoot,

    [Parameter()]
    [ValidateSet('Core', 'Full')]
    [string] $Edition,

    [Parameter()]
    [string] $Version,

    [Parameter()]
    [AllowNull()]
    [string[]] $ProfilePath,

    [Parameter()]
    [AllowNull()]
    [string[]] $ModuleRoot,

    [Parameter()]
    [string] $ProfileStateRoot,

    [Parameter()]
    [string] $ProjectionStateRoot,

    [Parameter()]
    [ValidatePattern('\A[0-9a-fA-F]{64}\z')]
    [string] $ArchiveSha256,

    [Parameter()]
    [switch] $Offline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path -Path $PSScriptRoot -ChildPath 'PackageLifecycle.ps1'
if (-not [IO.File]::Exists($lifecyclePath)) {
    throw "Psh package lifecycle helpers were not found: $lifecyclePath"
}
. $lifecyclePath

$script:InstallWhatIfWasDefined = $null -ne (Get-Variable -Name WhatIfPreference -Scope 0 -ErrorAction SilentlyContinue)
$script:InstallOriginalWhatIfPreference = if ($script:InstallWhatIfWasDefined) { [bool]$WhatIfPreference } else { $false }
$script:InstallWhatIfRequested = $script:InstallOriginalWhatIfPreference
$WhatIfPreference = $false
$script:VersionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
$script:LifecycleInstallRoot = $null
$script:CreatedPaths = New-Object System.Collections.Generic.List[string]
$script:StableMutations = New-Object System.Collections.Generic.List[object]
$script:PublishedVersionRoot = $null
$script:PublishedVersionWasNew = $false
$script:LifecycleTransactionWritten = $false
$script:LifecycleTransactionSha256 = $null

function Get-PshInstallProperty {
    param([AllowNull()][object] $InputObject, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { return ,@($property.Value) }
    return $property.Value
}

function Stop-PshLifecycleInstall {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $Kind = 'RuntimeError'
    )
    $global:LASTEXITCODE = $Code
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['PshExitCode'] = $Code
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = ('PshLifecycle.{0}' -f $Kind)
    throw $exception
}

function Assert-PshInstallNoPendingTransaction {
    param([Parameter(Mandatory = $true)][string] $Root)
    $transaction = Read-PshTransactionState -InstallRoot $Root
    if ($null -eq $transaction) { return }
    $decision = Get-PshRecoveryDecision -InstallRoot $Root -Transaction $transaction
    $action = [string](Get-PshInstallProperty $decision 'Action')
    $safe = [bool](Get-PshInstallProperty $decision 'Safe')
    if ($safe -and $action -ceq 'None') { return }
    $operation = [string](Get-PshInstallProperty $transaction 'operation')
    $transactionId = [string](Get-PshInstallProperty $transaction 'transactionId')
    $reason = [string](Get-PshInstallProperty $decision 'Reason')
    $message = "An unfinished Psh $operation transaction ($transactionId) requires recovery before installation: action=$action; $reason"
    if ($safe) { Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message $message }
    Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message $message
}

function Get-PshInstallRollbackScriptStatus {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $ExpectedSha256)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Reason = 'the script is missing' } }
    try {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Reason = 'the script is a reparse point' } }
        if ((Get-PshLifecycleHash -Path $Path) -cne $ExpectedSha256) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Reason = 'the script hash changed' } }
        return [pscustomobject][ordered]@{ Trusted = $true; RestartRequired = $false; Reason = 'the script hash is unchanged' }
    }
    catch { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $true; Reason = 'the script could not be read' } }
}

function Resolve-PshLifecyclePath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    try {
        $provider = $null
        $drive = $null
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref] $provider, [ref] $drive)
    }
    catch { Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message ("{0} is not a filesystem path: {1}" -f $Description, $Path) }
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem' -or -not [IO.Path]::IsPathRooted($full)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message ("{0} must resolve to an absolute filesystem path: {1}" -f $Description, $Path)
    }
    return [IO.Path]::GetFullPath($full)
}

function Assert-PshInstallRootNotFilesystemRoot {
    param([Parameter(Mandatory = $true)][string] $Root)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $filesystemRoot = [IO.Path]::GetFullPath([IO.Path]::GetPathRoot($Root)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($normalizedRoot, $filesystemRoot, $comparison)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message "InstallRoot must not be the filesystem root: $Root"
    }
}

function Assert-PshInstallSafePath {
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
    catch { Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message ("{0} is not a valid filesystem path: {1}" -f $Description, $Path) }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $fullRoot, $comparison) -and -not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message ("{0} escapes InstallRoot: {1}" -f $Description, $Path)
    }
    $ancestor = $fullRoot
    while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
        if ([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) {
            try { $ancestorAttributes = [IO.File]::GetAttributes($ancestor) }
            catch { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $ancestor) }
            if (($ancestorAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} parent chain contains a reparse point: {1}" -f $Description, $ancestor)
            }
        }
        $parentAncestor = [IO.Path]::GetDirectoryName($ancestor)
        if ([string]::IsNullOrWhiteSpace($parentAncestor) -or [string]::Equals($parentAncestor, $ancestor, $comparison)) { break }
        $ancestor = $parentAncestor
    }
    $relative = $fullPath.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = $fullRoot
    if ([string]::IsNullOrWhiteSpace($relative)) { return $fullPath }
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        $exists = [IO.File]::Exists($current) -or [IO.Directory]::Exists($current)
        if (-not $exists) {
            if ($AllowMissing) { break }
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $current) }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} contains a reparse point: {1}" -f $Description, $current)
        }
    }
    return $fullPath
}

function Assert-PshInstallDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [switch] $AllowMissing
    )
    $fullPath = Assert-PshInstallSafePath -Root $Root -Path $Path -Description $Description -AllowMissing
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $relative = $fullPath.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = $fullRoot
    if ([IO.File]::Exists($current)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is a file: {1}" -f $Description, $current) }
    if ([string]::IsNullOrWhiteSpace($relative)) { return $fullPath }
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is obstructed by a file: {1}" -f $Description, $current) }
        if (-not [IO.Directory]::Exists($current)) {
            if ($AllowMissing) { break }
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
    }
    return $fullPath
}

function Get-PshInstallVersionRelativePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [IO.Path]::GetFullPath($Path).Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
}

function Assert-PshInstallOwnedVersionTree {
    param([Parameter(Mandatory = $true)][string] $VersionRoot, [Parameter(Mandatory = $true)][object] $Entry)
    $versionsRoot = [IO.Path]::GetDirectoryName($VersionRoot)
    Assert-PshInstallSafePath -Root $script:LifecycleInstallRoot -Path $versionsRoot -Description 'Versions root' -AllowMissing | Out-Null
    Assert-PshInstallSafePath -Root $script:LifecycleInstallRoot -Path $VersionRoot -Description 'Installed version' | Out-Null
    if (-not [IO.Directory]::Exists($VersionRoot)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version is missing: $VersionRoot" }
    $expectedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $expectedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $records = New-Object System.Collections.Generic.List[object]
    $files = Get-PshInstallProperty $Entry 'files'
    foreach ($file in @($files)) {
        $relative = [string](Get-PshInstallProperty $file 'relativePath')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version contains an unsafe path: $relative" }
        $relative = $relative.Replace('\', '/')
        if (-not $expectedFiles.Add($relative)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version contains a duplicate path: $relative" }
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        while (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = $expectedDirectories.Add($parent.Replace('\', '/'))
            $parent = [IO.Path]::GetDirectoryName($parent.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
        $path = Join-Path $VersionRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-PshInstallSafePath -Root $VersionRoot -Path $path -Description 'Installed version file' | Out-Null
        if (-not [IO.File]::Exists($path)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version file is missing: $path" }
        $attributes = [IO.File]::GetAttributes($path)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version file is a reparse point: $path" }
        $expectedLength = Get-PshInstallProperty $file 'length'
        if ($null -ne $expectedLength -and (Get-Item -LiteralPath $path).Length -ne [long]$expectedLength) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version file length changed: $path" }
        $expectedHash = [string](Get-PshInstallProperty $file 'sha256')
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or (Get-PshLifecycleHash -Path $path) -cne $expectedHash.ToLowerInvariant()) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version file hash changed: $path" }
        $records.Add([pscustomobject][ordered]@{ relativePath = $relative; length = [long](Get-Item -LiteralPath $path).Length; sha256 = $expectedHash.ToLowerInvariant() })
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $VersionRoot -Recurse -Force)) {
        Assert-PshInstallSafePath -Root $VersionRoot -Path $item.FullName -Description 'Installed version tree' | Out-Null
        $relative = Get-PshInstallVersionRelativePath -Root $VersionRoot -Path $item.FullName
        $attributes = [IO.File]::GetAttributes($item.FullName)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version tree contains a reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) {
            if (-not $expectedDirectories.Contains($relative)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version contains an unknown directory: $relative" }
        }
        elseif (-not $expectedFiles.Contains($relative)) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version contains an unknown file: $relative"
        }
    }
    $expectedTree = [string](Get-PshInstallProperty $Entry 'treeSha256')
    $actualTree = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $records.ToArray() })
    if ([string]::IsNullOrWhiteSpace($expectedTree) -or $actualTree -cne $expectedTree.ToLowerInvariant()) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Installed version tree digest changed: $VersionRoot" }
}

function Assert-PshInstallPublishedFile {
    param(
        [Parameter(Mandatory = $true)][string] $VersionRoot,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object[]] $Files,
        [Parameter(Mandatory = $true)][string] $Description
    )
    Assert-PshInstallSafePath -Root $VersionRoot -Path $Path -Description $Description | Out-Null
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description is missing: $Path" }
    Assert-PshLifecycleNoReparse -Path $Path -Description $Description
    $relative = Get-PshInstallVersionRelativePath -Root $VersionRoot -Path $Path
    $record = $null
    foreach ($candidate in @($Files)) {
        if ([string](Get-PshInstallProperty $candidate 'relativePath') -ceq $relative) { $record = $candidate; break }
    }
    if ($null -eq $record) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description is not present in published ownership metadata: $relative" }
    if ((Get-Item -LiteralPath $Path).Length -ne [long](Get-PshInstallProperty $record 'length') -or (Get-PshLifecycleHash -Path $Path) -cne [string](Get-PshInstallProperty $record 'sha256')) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed after publication: $relative"
    }
    return $record
}

function Test-PshLifecycleWithinRoot {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($fullPath, $fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-PshLifecycleNoReparse {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return }
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is a reparse point: {1}" -f $Description, $Path)
    }
}

function Get-PshLifecycleHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PshLifecycleBytesHash {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-PshLifecycleBytes {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][byte[]] $Bytes)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $parent -Description 'Psh lifecycle parent' -AllowMissing | Out-Null
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $parent -Description 'Psh lifecycle parent' | Out-Null
    }
    $tmp = Join-Path -Path $parent -ChildPath ('.psh-write.{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
    $expectedTmpHash = Get-PshLifecycleBytesHash -Bytes $Bytes
    $expectedBackupHash = $null
    try {
        [IO.File]::WriteAllBytes($tmp, $Bytes)
        if ([IO.File]::Exists($Path)) {
            $expectedBackupHash = Get-PshLifecycleHash -Path $Path
            $bak = Join-Path -Path $parent -ChildPath ('.psh-write.{0}.bak' -f ([Guid]::NewGuid().ToString('N')))
            try { [IO.File]::Replace($tmp, $Path, $bak) }
            finally {
                if ([IO.File]::Exists($bak)) {
                    try { if ((Get-PshLifecycleHash -Path $bak) -ceq $expectedBackupHash) { [IO.File]::Delete($bak) } } catch {}
                }
            }
        }
        else { [IO.File]::Move($tmp, $Path) }
    }
    finally {
        if ([IO.File]::Exists($tmp)) {
            try { if ((Get-PshLifecycleHash -Path $tmp) -ceq $expectedTmpHash) { [IO.File]::Delete($tmp) } } catch {}
        }
    }
}

function Restore-PshLifecycleFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][bool] $OriginalExisted,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $OriginalBytes,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "$Description disappeared before compensation." }
    Assert-PshLifecycleNoReparse -Path $Path -Description $Description
    if ((Get-PshLifecycleHash -Path $Path) -cne $ExpectedSha256) { throw "$Description changed before compensation." }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $operationId = ([Guid]::NewGuid()).ToString('N')
    if (-not $OriginalExisted) {
        $recoveryPath = Join-Path $parent ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), $operationId)
        try {
            [IO.File]::Move($Path, $recoveryPath)
            $recoveryHash = Get-PshLifecycleHash -Path $recoveryPath
            if ($recoveryHash -cne $ExpectedSha256) {
                # Put the observed bytes back whenever the destination is still
                # absent. If another writer appeared, retain both artifacts.
                $restoredObservedBytes = $false
                if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
                    try { [IO.File]::Move($recoveryPath, $Path); $restoredObservedBytes = $true } catch { }
                }
                if ($restoredObservedBytes) { throw "$Description changed at the atomic compensation point; the observed bytes were restored to the live path." }
                throw "$Description changed at the atomic compensation point. Recovery evidence was retained: $recoveryPath"
            }
            if ((Get-PshLifecycleHash -Path $recoveryPath) -cne $ExpectedSha256) {
                throw "$Description recovery evidence changed before deletion. Recovery evidence was retained: $recoveryPath"
            }
            [IO.File]::Delete($recoveryPath)
            return
        }
        catch {
            if ($_.Exception.Message -like '*Recovery evidence was retained*') { throw }
            throw "$Description could not be removed during compensation: $($_.Exception.Message)"
        }
    }
    $temporaryPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupPath = Join-Path $parent ('.{0}.{1}.bak' -f [IO.Path]::GetFileName($Path), $operationId)
    $recoveryPath = Join-Path $parent ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), $operationId)
    $backupOwned = $false
    $recoveryOwned = $false
    $expectedRecoveryHash = Get-PshLifecycleBytesHash -Bytes $OriginalBytes
    $expectedTemporaryHash = $expectedRecoveryHash
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $OriginalBytes)
        [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        if ([IO.File]::Exists($backupPath) -and (Get-PshLifecycleHash -Path $backupPath) -ceq $ExpectedSha256) {
            $backupOwned = $true
        }
        else {
            # Do not remove a backup whose contents cannot be proven to be the
            # pre-compensation bytes. It is recovery evidence, not ours.
            if ([IO.File]::Exists($Path) -and (Get-PshLifecycleHash -Path $Path) -ceq (Get-PshLifecycleBytesHash -Bytes $OriginalBytes)) {
                try {
                    [IO.File]::Replace($backupPath, $Path, $recoveryPath)
                    if ([IO.File]::Exists($recoveryPath) -and (Get-PshLifecycleHash -Path $recoveryPath) -ceq $expectedRecoveryHash) {
                        $recoveryOwned = $true
                    }
                }
                catch { }
            }
            throw "$Description changed at the atomic compensation point. Recovery evidence was retained."
        }
        if (-not [IO.File]::Exists($Path) -or (Get-PshLifecycleHash -Path $Path) -cne $expectedRecoveryHash) {
            $backupOwned = $false
            throw "$Description did not retain the expected compensation bytes. Recovery evidence was retained."
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try { if ((Get-PshLifecycleHash -Path $temporaryPath) -ceq $expectedTemporaryHash) { [IO.File]::Delete($temporaryPath) } } catch {}
        }
        if ($backupOwned -and [IO.File]::Exists($backupPath)) {
            try { if ((Get-PshLifecycleHash -Path $backupPath) -ceq $ExpectedSha256) { [IO.File]::Delete($backupPath) } } catch {}
        }
        if ($recoveryOwned -and [IO.File]::Exists($recoveryPath)) {
            try { if ((Get-PshLifecycleHash -Path $recoveryPath) -ceq $expectedRecoveryHash) { [IO.File]::Delete($recoveryPath) } } catch {}
        }
    }
}

function Write-PshLifecycleFileCas {
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
    $targetSha256 = Get-PshLifecycleBytesHash -Bytes $Bytes
    $temporarySha256 = $targetSha256
    try {
        $liveExists = [IO.File]::Exists($Path)
        if ([IO.Directory]::Exists($Path)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description is a directory." }
        if ($ExpectedExisted) {
            if (-not $liveExists) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description disappeared before the CAS write." }
            Assert-PshLifecycleNoReparse -Path $Path -Description $Description
            if ((Get-PshLifecycleHash -Path $Path) -cne $ExpectedSha256) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before the CAS write." }
        }
        elseif ($liveExists) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared before the expected-absent CAS write." }
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if ($ExpectedExisted) {
            try {
                [IO.File]::Replace($temporaryPath, $Path, $backupPath)
            }
            catch {
                $nowExists = [IO.File]::Exists($Path)
                $nowMatches = $false
                if ($nowExists) { try { $nowMatches = (Get-PshLifecycleHash -Path $Path) -ceq $ExpectedSha256 } catch {} }
                if (-not $nowExists -or -not $nowMatches) {
                    Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS write point."
                }
                Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "$Description could not be replaced: $($_.Exception.Message)"
            }
            if (-not [IO.File]::Exists($backupPath)) {
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS write point; no backup evidence was produced."
            }
            $backupHash = Get-PshLifecycleHash -Path $backupPath
            if ($backupHash -cne $ExpectedSha256) {
                # The backup may contain bytes installed by a concurrent actor.
                # Put those bytes back if the live target is still ours; retain
                # the recovery artifact if the reverse replace is not provable.
                if ([IO.File]::Exists($Path) -and (Get-PshLifecycleHash -Path $Path) -ceq $targetSha256) {
                    try {
                        [IO.File]::Replace($backupPath, $Path, $recoveryPath)
                        if ([IO.File]::Exists($recoveryPath) -and (Get-PshLifecycleHash -Path $recoveryPath) -ceq $targetSha256) {
                            $recoveryOwned = $true
                        }
                    }
                    catch { }
                }
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS write point; backup evidence was retained."
            }
            $backupOwned = $true
        }
        else {
            try { [IO.File]::Move($temporaryPath, $Path) }
            catch {
                if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
                    Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared at the atomic expected-absent CAS write point."
                }
                Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "$Description could not be created: $($_.Exception.Message)"
            }
        }
        if (-not [IO.File]::Exists($Path) -or (Get-PshLifecycleHash -Path $Path) -cne $targetSha256) {
            $backupOwned = $false
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description did not retain the transaction bytes after the CAS write."
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try { if ((Get-PshLifecycleHash -Path $temporaryPath) -ceq $temporarySha256) { [IO.File]::Delete($temporaryPath) } } catch {}
        }
        if ($backupOwned -and [IO.File]::Exists($backupPath)) {
            try { if ((Get-PshLifecycleHash -Path $backupPath) -ceq $ExpectedSha256) { [IO.File]::Delete($backupPath) } } catch {}
        }
        if ($recoveryOwned -and [IO.File]::Exists($recoveryPath)) {
            try { if ((Get-PshLifecycleHash -Path $recoveryPath) -ceq $targetSha256) { [IO.File]::Delete($recoveryPath) } } catch {}
        }
    }
}

function Remove-PshLifecycleFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description disappeared before the CAS removal." }
    Assert-PshLifecycleNoReparse -Path $Path -Description $Description
    if ((Get-PshLifecycleHash -Path $Path) -cne $ExpectedSha256) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before the CAS removal." }
    $recoveryPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) ('.{0}.{1}.recovery' -f [IO.Path]::GetFileName($Path), ([Guid]::NewGuid().ToString('N')))
    try { [IO.File]::Move($Path, $recoveryPath) }
    catch {
        if (-not [IO.File]::Exists($Path) -or (Get-PshLifecycleHash -Path $Path) -cne $ExpectedSha256) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS removal point."
        }
        Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "$Description could not be detached: $($_.Exception.Message)"
    }
    if ((Get-PshLifecycleHash -Path $recoveryPath) -cne $ExpectedSha256) {
        if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
            try { [IO.File]::Move($recoveryPath, $Path) } catch { }
        }
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the atomic CAS removal point; recovery evidence was retained."
    }
    try {
        if ((Get-PshLifecycleHash -Path $recoveryPath) -cne $ExpectedSha256) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description recovery evidence changed before deletion: $recoveryPath"
        }
        [IO.File]::Delete($recoveryPath)
    }
    catch {
        if ($null -ne $_.Exception.Data['PshExitCode']) { throw }
        Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "$Description was detached but its recovery file could not be deleted: $recoveryPath"
    }
}

function Remove-PshInstallOwnedVersionTree {
    param(
        [Parameter(Mandatory = $true)][string] $VersionRoot,
        [Parameter(Mandatory = $true)][object] $Entry
    )
    Assert-PshInstallSafePath -Root $script:LifecycleInstallRoot -Path $VersionRoot -Description 'Version rollback quarantine' | Out-Null
    if (-not [IO.Directory]::Exists($VersionRoot) -or [IO.File]::Exists($VersionRoot)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine is missing: $VersionRoot"
    }

    $expectedFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $knownDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @((Get-PshInstallProperty $Entry 'files'))) {
        $relative = [string](Get-PshInstallProperty $file 'relativePath')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine contains an unsafe path: $relative"
        }
        $relative = $relative.Replace('\', '/')
        if (-not $expectedFiles.ContainsKey($relative)) {
            $expectedFiles.Add($relative, $file)
        }
        else {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine contains a duplicate path: $relative"
        }
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        while (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = $knownDirectories.Add($parent.Replace('\', '/'))
            $parent = [IO.Path]::GetDirectoryName($parent.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
    }

    # Verify the complete tree before detaching any file.  This makes a
    # quarantine with an unexpected file, directory, or reparse point fail
    # closed before compensation starts deleting owned bytes.
    foreach ($item in @(Get-ChildItem -LiteralPath $VersionRoot -Recurse -Force -ErrorAction Stop)) {
        Assert-PshInstallSafePath -Root $VersionRoot -Path $item.FullName -Description 'Version rollback quarantine item' | Out-Null
        Assert-PshLifecycleNoReparse -Path $item.FullName -Description 'Version rollback quarantine item'
        $relative = Get-PshInstallVersionRelativePath -Root $VersionRoot -Path $item.FullName
        if ($item.PSIsContainer) {
            if (-not $knownDirectories.Contains($relative)) {
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine contains an unknown directory: $($item.FullName)"
            }
            continue
        }
        if (-not $expectedFiles.ContainsKey($relative)) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine contains unknown content: $($item.FullName)"
        }
        $record = $expectedFiles[$relative]
        $expectedLength = Get-PshInstallProperty $record 'length'
        if ($null -ne $expectedLength -and (Get-Item -LiteralPath $item.FullName).Length -ne [long]$expectedLength) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine file length changed: $($item.FullName)"
        }
        if ((Get-PshLifecycleHash -Path $item.FullName) -cne [string](Get-PshInstallProperty $record 'sha256')) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine file hash changed: $($item.FullName)"
        }
    }

    foreach ($relative in @($expectedFiles.Keys)) {
        $path = Join-Path $VersionRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine file disappeared: $path"
        }
        Remove-PshLifecycleFileCas -Path $path -ExpectedSha256 ([string](Get-PshInstallProperty $expectedFiles[$relative] 'sha256')) -Description 'Version rollback quarantine file'
    }

    # Re-scan after file CAS removals.  Any content that appeared during the
    # deletion pass is evidence of a concurrent writer and must remain.
    $remainingDirectories = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $VersionRoot -Recurse -Force -ErrorAction Stop)) {
        Assert-PshInstallSafePath -Root $VersionRoot -Path $item.FullName -Description 'Version rollback quarantine remainder' | Out-Null
        Assert-PshLifecycleNoReparse -Path $item.FullName -Description 'Version rollback quarantine remainder'
        $relative = Get-PshInstallVersionRelativePath -Root $VersionRoot -Path $item.FullName
        if (-not $item.PSIsContainer -or -not $knownDirectories.Contains($relative)) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine retained unexpected content: $($item.FullName)"
        }
        $remainingDirectories.Add([IO.Path]::GetFullPath($item.FullName))
    }
    foreach ($directory in @($remainingDirectories.ToArray() | Sort-Object { $_.Length } -Descending)) {
        try { [IO.Directory]::Delete($directory, $false) }
        catch {
            if ([IO.File]::Exists($directory)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine directory was replaced by a file: $directory" }
            if ([IO.Directory]::Exists($directory)) {
                try {
                    if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -gt 0) {
                        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine directory gained unknown content: $directory"
                    }
                } catch { if ($null -ne $_.Exception.Data['PshExitCode']) { throw } }
            }
            Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "Version rollback quarantine directory could not be removed: $directory"
        }
    }
    try { [IO.Directory]::Delete($VersionRoot, $false) }
    catch {
        if ([IO.File]::Exists($VersionRoot)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine root was replaced by a file: $VersionRoot" }
        if ([IO.Directory]::Exists($VersionRoot)) {
            try {
                if (@(Get-ChildItem -LiteralPath $VersionRoot -Force -ErrorAction Stop).Count -gt 0) {
                    Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version rollback quarantine root gained unknown content: $VersionRoot"
                }
            } catch { if ($null -ne $_.Exception.Data['PshExitCode']) { throw } }
        }
        Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "Version rollback quarantine root could not be removed: $VersionRoot"
    }
    if ([IO.Directory]::Exists($VersionRoot) -or [IO.File]::Exists($VersionRoot)) {
        Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "Version rollback quarantine root remained after cleanup: $VersionRoot"
    }
}

function Remove-PshLifecycleOwnedStage {
    param(
        [Parameter(Mandatory = $true)][string] $StageRoot,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][string] $ManifestSha256
    )
    if (-not [IO.Directory]::Exists($StageRoot)) { return }
    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $StageRoot -Description 'Staging transaction root' | Out-Null
    $pathComparer = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $expectedFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' $pathComparer
    $knownDirectories = New-Object 'System.Collections.Generic.HashSet[string]' $pathComparer
    $manifestRelative = 'package' + [IO.Path]::DirectorySeparatorChar + 'package.manifest.json'
    $expectedFiles.Add($manifestRelative, [pscustomobject][ordered]@{ length = $null; sha256 = $ManifestSha256 })
    foreach ($file in @((Get-PshInstallProperty $Manifest 'files'))) {
        $relative = [string](Get-PshInstallProperty $file 'relativePath')
        $stageRelative = 'package' + [IO.Path]::DirectorySeparatorChar + $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $expectedFiles.Add($stageRelative, [pscustomobject][ordered]@{ length = [long](Get-PshInstallProperty $file 'length'); sha256 = [string](Get-PshInstallProperty $file 'sha256'); payload = $relative.StartsWith('payload/', [StringComparison]::Ordinal) })
    }
    foreach ($relative in @($expectedFiles.Keys)) {
        $parent = [IO.Path]::GetDirectoryName($relative)
        while (-not [string]::IsNullOrWhiteSpace($parent)) {
            $null = $knownDirectories.Add($parent)
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }
    $directories = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $StageRoot -Recurse -Force)) {
        Assert-PshLifecycleNoReparse -Path $item.FullName -Description 'Staging transaction item'
        $relative = [IO.Path]::GetFullPath($item.FullName).Substring([IO.Path]::GetFullPath($StageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($item.PSIsContainer) {
            if (-not $knownDirectories.Contains($relative)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Staging transaction contains an unknown directory: $($item.FullName)" }
            $directories.Add([IO.Path]::GetFullPath($item.FullName))
        }
        elseif (-not $expectedFiles.ContainsKey($relative)) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Staging transaction contains unknown content: $($item.FullName)"
        }
        else {
            $record = $expectedFiles[$relative]
            $expectedLength = Get-PshInstallProperty $record 'length'
            if (($null -ne $expectedLength -and (Get-Item -LiteralPath $item.FullName).Length -ne [long]$expectedLength) -or (Get-PshLifecycleHash -Path $item.FullName) -cne [string](Get-PshInstallProperty $record 'sha256')) {
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Staging transaction contains changed content: $($item.FullName)"
            }
        }
    }
    foreach ($relative in @($expectedFiles.Keys)) {
        $path = Join-Path $StageRoot $relative
        if (-not [IO.File]::Exists($path)) {
            if (-not [bool](Get-PshInstallProperty $expectedFiles[$relative] 'payload')) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Expected staging file disappeared during cleanup: $path" }
            continue
        }
        Remove-PshLifecycleFileCas -Path $path -ExpectedSha256 ([string](Get-PshInstallProperty $expectedFiles[$relative] 'sha256')) -Description 'staged package file'
    }
    foreach ($directory in @($directories.ToArray() | Sort-Object { $_.Length } -Descending)) {
        try { [IO.Directory]::Delete($directory, $false) }
        catch { Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "Staging directory was not empty during cleanup and was retained: $directory" }
    }
    try { [IO.Directory]::Delete($StageRoot, $false) }
    catch { Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message "Staging transaction root was not empty during cleanup and was retained: $StageRoot" }
}

function Get-PshLifecycleDefaultProfiles {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) { return @() }
    return @(
        (Join-Path (Join-Path $documents 'WindowsPowerShell') 'profile.ps1')
        (Join-Path (Join-Path $documents 'PowerShell') 'profile.ps1')
    )
}

function Get-PshLifecycleDefaultModuleRoots {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) { return @() }
    return @(
        (Join-Path (Join-Path $documents 'WindowsPowerShell') 'Modules')
        (Join-Path (Join-Path $documents 'PowerShell') 'Modules')
    )
}

function Resolve-PshLifecycleCandidate {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $PayloadRoot,
        [Parameter(Mandatory = $true)][string[]] $RelativeCandidates,
        [Parameter(Mandatory = $true)][string] $Description
    )
    foreach ($relative in $RelativeCandidates) {
        $candidate = Join-Path -Path $PackageRoot -ChildPath ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ([IO.File]::Exists($candidate)) {
            Assert-PshLifecycleNoReparse -Path $candidate -Description $Description
            return [IO.Path]::GetFullPath($candidate)
        }
        $candidate = Join-Path -Path $PayloadRoot -ChildPath ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ([IO.File]::Exists($candidate)) {
            Assert-PshLifecycleNoReparse -Path $candidate -Description $Description
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-PshInstallConfigEdition {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        $editionValue = if ($data -is [Collections.IDictionary] -and $data.Contains('Edition')) { $data['Edition'] } else {
            $editionProperty = $data.PSObject.Properties['Edition']
            if ($null -ne $editionProperty) { $editionProperty.Value } else { $null }
        }
        if ($editionValue -isnot [string]) { throw 'Edition is missing or not a string.' }
        return [string]$editionValue
    }
    catch { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} could not be parsed as a trusted config: {1}" -f $Description, $_.Exception.Message) }
}

function Invoke-PshLifecycleScript {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][object[]] $Arguments)
    $output = @(& $Path @Arguments)
    return $output
}

function Read-PshLifecycleCurrent {
    param([Parameter(Mandatory = $true)][string] $Root)
    $path = Join-Path -Path $Root -ChildPath 'current.json'
    $snapshot = Read-PshStrictJsonSnapshot -Path $path -Description 'current state' -AllowMissing
    if ($null -eq $snapshot) {
        return [pscustomobject][ordered]@{ exists = $false; version = $null; sha256 = $null; bytes = (New-Object byte[] 0) }
    }
    $doc = $snapshot.Document
    Assert-PshLifecycleAllowedProperties -InputObject $doc -Allowed @('schemaVersion', 'version') -Description 'current state'
    Assert-PshLifecycleRequiredProperties -InputObject $doc -Required @('schemaVersion', 'version') -Description 'current state'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $doc 'schemaVersion') -Description 'current schemaVersion' -NonNegative) -ne 1) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'current.json schemaVersion must be 1.'
    }
    $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $doc 'version') -Description 'current version'
    return [pscustomobject][ordered]@{ exists = $true; version = $version; sha256 = [string]$snapshot.Sha256; bytes = [byte[]]$snapshot.Bytes }
}

function Get-PshLifecycleCurrentBytes {
    param([Parameter(Mandatory = $true)][string] $Version)
    $document = [ordered]@{ schemaVersion = 1; version = $Version }
    $json = ($document | ConvertTo-Json -Compress) + [Environment]::NewLine
    return ,((New-Object System.Text.UTF8Encoding($false)).GetBytes($json))
}

function New-PshLifecycleJournal {
    param([Parameter(Mandatory = $true)][string] $TransactionId, [Parameter(Mandatory = $true)][string] $Operation, [Parameter(Mandatory = $true)][string] $TargetVersion, [Parameter(Mandatory = $true)][object] $Current, [AllowNull()][object] $StageRelativePath, [AllowNull()][object] $PublishedRelativePath, [AllowNull()][object] $OwnershipBeforeSha256)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        transactionId = $TransactionId
        operation = $Operation
        phase = 'staged'
        oldCurrent = $Current
        targetVersion = $TargetVersion
        stageRelativePath = $StageRelativePath
        publishedRelativePath = $PublishedRelativePath
        ownershipBeforeSha256 = $OwnershipBeforeSha256
        startedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Save-PshLifecycleJournal {
    param([Parameter(Mandatory = $true)][object] $Journal)
    $validated = Assert-PshTransactionDocument -State $Journal
    $json = (ConvertTo-PshCanonicalJson -InputObject $validated) + "`n"
    [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $sha256 = Get-PshLifecycleBytesHash -Bytes $bytes
    Write-PshLifecycleFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $script:LifecycleInstallRoot -Kind transaction) -ExpectedExisted $script:LifecycleTransactionWritten -ExpectedSha256 $script:LifecycleTransactionSha256 -Bytes $bytes -Description 'transaction journal'
    $script:LifecycleTransactionWritten = $true
    $script:LifecycleTransactionSha256 = $sha256
}

function Get-PshLifecycleOwnershipHash {
    param([AllowNull()][object] $Ownership)
    if ($null -eq $Ownership) { return $null }
    $json = $Ownership | ConvertTo-Json -Depth 30 -Compress
    return Get-PshLifecycleBytesHash -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
}

function Get-PshLifecycleOwnedVersion {
    param([AllowNull()][object] $Ownership, [Parameter(Mandatory = $true)][string] $Version)
    if ($null -eq $Ownership) { return $null }
    $ownedVersions = Get-PshInstallProperty $Ownership 'versions'
    foreach ($candidate in @($ownedVersions)) {
        if ($null -ne $candidate -and [string](Get-PshInstallProperty $candidate 'version') -ceq $Version) { return $candidate }
    }
    return $null
}

function Install-PshLifecycleStableFile {
    param(
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][AllowNull()][object] $ExistingEntry,
        [Parameter()][AllowNull()][object] $ExpectedSourceEntry,
        [switch] $PreserveUnknown
    )
    $target = Join-Path -Path $script:LifecycleInstallRoot -ChildPath ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    Assert-PshInstallSafePath -Root $script:LifecycleInstallRoot -Path $target -Description 'Stable file target' -AllowMissing | Out-Null
    $sourceBytes = [IO.File]::ReadAllBytes($SourcePath)
    $sourceHash = Get-PshLifecycleBytesHash -Bytes $sourceBytes
    if ($null -ne $ExpectedSourceEntry) {
        $expectedLength = [long](Get-PshInstallProperty $ExpectedSourceEntry 'length')
        $expectedHash = [string](Get-PshInstallProperty $ExpectedSourceEntry 'sha256')
        if ($sourceBytes.LongLength -ne $expectedLength -or $sourceHash -cne $expectedHash) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Published source changed while planning stable file: $RelativePath"
        }
    }
    $existing = [IO.File]::Exists($target)
    if ([IO.Directory]::Exists($target)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Stable file target is a directory: $target" }
    if ($existing) { Assert-PshLifecycleNoReparse -Path $target -Description 'Stable file target' }
    $priorBytes = if ($existing) { [IO.File]::ReadAllBytes($target) } else { New-Object byte[] 0 }
    $priorHash = if ($existing) { Get-PshLifecycleBytesHash -Bytes $priorBytes } else { $null }
    $ownedInstalledHash = [string](Get-PshInstallProperty $ExistingEntry 'installedSha256')
    $disposition = if ($existing) { 'reused' } else { 'created' }
    $changed = $false
    $backupName = [string](Get-PshInstallProperty $ExistingEntry 'backupFileName')

    if ($null -ne $ExistingEntry -and [string](Get-PshInstallProperty $ExistingEntry 'disposition') -ceq 'replaced') {
        if ([string]::IsNullOrWhiteSpace($backupName)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned replaced stable file has no backup: $RelativePath" }
        $backupRoot = Join-Path (Join-Path $script:LifecycleInstallRoot '.lifecycle') 'backups'
        Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $backupRoot -Description 'Stable backup root' | Out-Null
        $backupPath = Join-Path $backupRoot $backupName
        Assert-PshInstallSafePath -Root $backupRoot -Path $backupPath -Description 'Stable backup' | Out-Null
        if ([IO.Directory]::Exists($backupPath) -or -not [IO.File]::Exists($backupPath)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned stable backup is missing or is not a regular file: $backupPath" }
        Assert-PshLifecycleNoReparse -Path $backupPath -Description 'Stable backup'
        $expectedOriginalLength = [long](Get-PshInstallProperty $ExistingEntry 'originalLength')
        $expectedOriginalSha256 = [string](Get-PshInstallProperty $ExistingEntry 'originalSha256')
        if ((Get-Item -LiteralPath $backupPath).Length -ne $expectedOriginalLength -or (Get-PshLifecycleHash -Path $backupPath) -cne $expectedOriginalSha256) {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned stable backup no longer matches ownership metadata: $backupPath"
        }
    }

    if ($existing -and $priorHash -cne $sourceHash) {
        if ($null -ne $ExistingEntry -and [string](Get-PshInstallProperty $ExistingEntry 'disposition') -ceq 'reused') {
            if ($PreserveUnknown) {
                return [pscustomobject][ordered]@{ Entry = $ExistingEntry; Mutation = $null; Changed = $false }
            }
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "A reused stable file differs from the verified package: $target"
        }
        if ($null -ne $ExistingEntry -and -not [string]::IsNullOrWhiteSpace($ownedInstalledHash) -and $priorHash -ceq $ownedInstalledHash) {
            if ($script:InstallWhatIfRequested) { return [pscustomobject][ordered]@{ Entry = $ExistingEntry; Mutation = $null; Changed = $false } }
            $oldDisposition = [string](Get-PshInstallProperty $ExistingEntry 'disposition')
            if ($oldDisposition -ceq 'created') {
                $disposition = 'created'
            }
            else {
                $disposition = 'replaced'
                if ([string]::IsNullOrWhiteSpace($backupName)) {
                    $backupName = 'stable-{0}.bin' -f ([Guid]::NewGuid().ToString('N'))
                    $backupRoot = Join-Path (Join-Path $script:LifecycleInstallRoot '.lifecycle') 'backups'
                    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $backupRoot -Description 'Stable backup root' -AllowMissing | Out-Null
                    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
                    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $backupRoot -Description 'Stable backup root' | Out-Null
                    Write-PshLifecycleFileCas -Path (Join-Path $backupRoot $backupName) -ExpectedExisted $false -ExpectedSha256 $null -Bytes $priorBytes -Description 'Stable backup'
                }
            }
            Write-PshLifecycleFileCas -Path $target -ExpectedExisted $existing -ExpectedSha256 $priorHash -Bytes $sourceBytes -Description 'Stable file target'
            $changed = $true
        }
        elseif ($PreserveUnknown) {
            return [pscustomobject][ordered]@{
                Entry = [pscustomobject][ordered]@{ relativePath = $RelativePath; disposition = 'reused'; originalExisted = $true; originalLength = [long]$priorBytes.LongLength; originalSha256 = $priorHash; backupFileName = $null; installedLength = [long]$priorBytes.LongLength; installedSha256 = $priorHash }
                Mutation = $null; Changed = $false
            }
        }
        else {
            Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Unowned stable file differs from the verified package: $target"
        }
    }
    elseif (-not $existing) {
        if ($script:InstallWhatIfRequested) { return [pscustomobject][ordered]@{ Entry = [pscustomobject][ordered]@{ relativePath = $RelativePath; disposition = 'created'; originalExisted = $false; originalLength = $null; originalSha256 = $null; backupFileName = $null; installedLength = [long]$sourceBytes.LongLength; installedSha256 = $sourceHash }; Mutation = $null; Changed = $false } }
        Write-PshLifecycleFileCas -Path $target -ExpectedExisted $false -ExpectedSha256 $null -Bytes $sourceBytes -Description 'Stable file target'
        $changed = $true
    }

    $entry = if ($null -ne $ExistingEntry) {
        $recordedDisposition = if ($changed) { $disposition } else { [string](Get-PshInstallProperty $ExistingEntry 'disposition') }
        [pscustomobject][ordered]@{
            relativePath = $RelativePath; disposition = $recordedDisposition; originalExisted = [bool](Get-PshInstallProperty $ExistingEntry 'originalExisted'); originalLength = Get-PshInstallProperty $ExistingEntry 'originalLength'; originalSha256 = Get-PshInstallProperty $ExistingEntry 'originalSha256'; backupFileName = if ($recordedDisposition -ceq 'replaced') { if ($null -ne $backupName) { $backupName } else { Get-PshInstallProperty $ExistingEntry 'backupFileName' } } else { $null }; installedLength = [long]$sourceBytes.LongLength; installedSha256 = $sourceHash
        }
    }
    else {
        [pscustomobject][ordered]@{ relativePath = $RelativePath; disposition = $disposition; originalExisted = $existing; originalLength = if ($existing) { [long]$priorBytes.LongLength } else { $null }; originalSha256 = $priorHash; backupFileName = if ($disposition -ceq 'replaced') { $backupName } else { $null }; installedLength = [long]$sourceBytes.LongLength; installedSha256 = $sourceHash }
    }
    $mutation = if ($changed) { [pscustomobject][ordered]@{ Path = $target; Existed = $existing; Bytes = $priorBytes; InstalledHash = $sourceHash } } else { $null }
    return [pscustomobject][ordered]@{ Entry = $entry; Mutation = $mutation; Changed = $changed }
}

function Merge-PshLifecycleVersions {
    param([AllowNull()][object] $Ownership, [Parameter(Mandatory = $true)][object] $VersionEntry, [Parameter(Mandatory = $true)][string] $ActiveVersion)
    $list = New-Object System.Collections.Generic.List[object]
    $ownedVersions = Get-PshInstallProperty $Ownership 'versions'
    foreach ($item in @($ownedVersions)) {
        if ($null -ne $item -and [string](Get-PshInstallProperty $item 'version') -cne $ActiveVersion) { $list.Add($item) }
    }
    $list.Add($VersionEntry)
    return $list.ToArray()
}

function New-PshLifecycleOwnership {
    param([AllowNull()][object] $Previous, [Parameter(Mandatory = $true)][object] $Manifest, [Parameter(Mandatory = $true)][object] $VersionEntry, [Parameter(Mandatory = $true)][object[]] $StableEntries, [AllowNull()][object] $ConfigEntry, [Parameter(Mandatory = $true)][bool] $ProfileInstalled, [Parameter(Mandatory = $true)][bool] $ProjectionInstalled)
    $oldActive = [string](Get-PshInstallProperty $Previous 'activeVersion')
    $rollback = New-Object System.Collections.Generic.List[string]
    $seenRollback = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $previousRollback = Get-PshInstallProperty $Previous 'rollbackOrder'
    foreach ($v in @($previousRollback)) { if (-not [string]::IsNullOrWhiteSpace([string]$v) -and [string]$v -cne [string]$Manifest.version -and $seenRollback.Add([string]$v)) { $rollback.Add([string]$v) } }
    if (-not [string]::IsNullOrWhiteSpace($oldActive) -and $oldActive -cne [string]$Manifest.version) { if ($seenRollback.Add($oldActive)) { $rollback.Insert(0, $oldActive) } }
    $combinedStable = New-Object System.Collections.Generic.List[object]
    $newStableNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($StableEntries)) { $null = $newStableNames.Add([string](Get-PshInstallProperty $entry 'relativePath')) }
    $previousStable = Get-PshInstallProperty $Previous 'stableFiles'
    foreach ($entry in @($previousStable)) {
        if ($null -ne $entry -and -not $newStableNames.Contains([string](Get-PshInstallProperty $entry 'relativePath'))) { $combinedStable.Add($entry) }
    }
    foreach ($entry in @($StableEntries)) { $combinedStable.Add($entry) }
    $effectiveConfig = if ($null -ne $ConfigEntry) { $ConfigEntry } else { Get-PshInstallProperty $Previous 'config' }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        installRoot = $script:LifecycleInstallRoot
        activeVersion = [string]$Manifest.version
        rollbackOrder = $rollback.ToArray()
        stableFiles = $combinedStable.ToArray()
        config = $effectiveConfig
        versions = @(Merge-PshLifecycleVersions -Ownership $Previous -VersionEntry $VersionEntry -ActiveVersion ([string]$Manifest.version))
        components = [pscustomobject][ordered]@{
            profile = [pscustomobject][ordered]@{ stateRelativePath = 'profile-state'; installed = $ProfileInstalled }
            psReadLineProjection = [pscustomobject][ordered]@{ stateRelativePath = 'psreadline-projection-state'; installed = $ProjectionInstalled }
        }
    }
}

$lock = $null
$journal = $null
$oldOwnership = $null
$oldOwnershipBytes = New-Object byte[] 0
$oldOwnershipSha256 = $null
$oldCurrent = $null
$stageRoot = $null
$versionRoot = $null
$profileInstalled = $false
$projectionInstalled = $false
$profileWasInstalledBefore = $false
$projectionWasInstalledBefore = $false
$ownershipWritten = $false
$pointerSwitched = $false
$ownershipWriteAttempted = $false
$pointerWriteAttempted = $false
$ownershipAfterSha256 = $null
$targetCurrentSha256 = $null
$setCurrentPath = $null
$profileUninstallPath = $null
$projectionUninstallPath = $null
$profileUninstallSha256 = $null
$projectionUninstallSha256 = $null
$resolvedProfilesForRollback = @()
$resolvedModulesForRollback = @()
$profileStateForRollback = $null
$projectionStateForRollback = $null
$stableEntries = New-Object System.Collections.Generic.List[object]
$configEntry = $null
$idempotent = $false
$versionFiles = New-Object System.Collections.Generic.List[object]
$versionTreeSha = $null
$publishedVersionEntryForChecks = $null

try {
    $script:LifecycleInstallRoot = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Stop-PshLifecycleInstall -Code 4 -Kind 'MissingDependency' -Message 'LOCALAPPDATA is unavailable.' }
        Join-Path $env:LOCALAPPDATA 'Psh'
    } else { Resolve-PshLifecyclePath -Path $InstallRoot -Description 'InstallRoot' }
    Assert-PshInstallRootNotFilesystemRoot -Root $script:LifecycleInstallRoot
    $packageRootResolved = Resolve-PshLifecyclePath -Path $PackageRoot -Description 'PackageRoot'
    if (-not [IO.Directory]::Exists($packageRootResolved)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "PackageRoot is not a directory: $packageRootResolved" }
    Assert-PshLifecycleNoReparse -Path $packageRootResolved -Description 'PackageRoot'
    Assert-PshLifecycleNoReparse -Path $script:LifecycleInstallRoot -Description 'InstallRoot'
    if ((Test-PshLifecycleWithinRoot -Path $script:LifecycleInstallRoot -Root $packageRootResolved) -or (Test-PshLifecycleWithinRoot -Path $packageRootResolved -Root $script:LifecycleInstallRoot)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'PathFailure' -Message 'PackageRoot and InstallRoot must not overlap.'
    }

    $lock = Enter-PshInstallRootLock -InstallRoot $script:LifecycleInstallRoot
    Assert-PshInstallNoPendingTransaction -Root $script:LifecycleInstallRoot
    $manifestPath = Join-Path $packageRootResolved 'package.manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Package manifest is missing: $manifestPath" }
    $manifestSnapshot = Read-PshStrictJsonSnapshot -Path $manifestPath -Description 'Package manifest'
    $manifest = Read-PshPackageManifest -Path $manifestPath -Snapshot $manifestSnapshot
    if ([int](Get-PshInstallProperty $manifest 'schemaVersion') -ne 1 -or [string](Get-PshInstallProperty $manifest 'product') -cne 'Psh') { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Unsupported Psh package manifest.' }
    if ([string](Get-PshInstallProperty $manifest 'payloadRoot') -cne 'payload') { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "payloadRoot must be 'payload'." }
    if ([string]$manifest.version -notmatch $script:VersionPattern) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Invalid package version: $($manifest.version)" }
    if ($PSBoundParameters.ContainsKey('Version') -and $Version -cne [string]$manifest.version) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Requested version does not match package manifest.' }
    if ($PSBoundParameters.ContainsKey('Edition') -and $Edition -cne [string]$manifest.edition) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Requested edition does not match package manifest.' }
    if ([string]$manifest.edition -notin @('Core', 'Full')) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Package edition is invalid.' }
    if ([string]$manifest.architecture -notin @('any', 'win-x64', 'win-arm64')) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Package architecture is invalid.' }
    $arch = [string]$env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = [string]$env:PROCESSOR_ARCHITECTURE }
    if ([string]$manifest.architecture -eq 'win-x64' -and $arch -match '(?i)ARM64|AARCH64') { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'An x64 package cannot run on ARM64.' }
    if ([string]$manifest.architecture -eq 'win-arm64' -and $arch -notmatch '(?i)ARM64|AARCH64') { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'An ARM64 package cannot run on this architecture.' }

    $verification = Test-PshPackageTree -PackageRoot $packageRootResolved -Manifest $manifest
    if ($null -ne $verification -and $null -ne (Get-PshInstallProperty $verification 'Verified') -and -not [bool](Get-PshInstallProperty $verification 'Verified')) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Package tree verification failed.' }
    if ((Get-PshLifecycleHash -Path $manifestPath) -cne [string]$manifestSnapshot.Sha256) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Package manifest changed during initial verification.' }
    [byte[]]$manifestBytes = [byte[]]$manifestSnapshot.Bytes
    $manifestHash = [string]$manifestSnapshot.Sha256
    $payloadRoot = Join-Path $packageRootResolved 'payload'
    if (-not [IO.Directory]::Exists($payloadRoot)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Package payload is missing: $payloadRoot" }
    Assert-PshLifecycleNoReparse -Path $payloadRoot -Description 'Package payload'
    foreach ($file in @($manifest.files)) {
        $relativePath = [string](Get-PshInstallProperty $file 'relativePath')
        if ($relativePath.StartsWith('payload/', [StringComparison]::Ordinal)) {
            $versionFiles.Add([pscustomobject][ordered]@{
                relativePath = $relativePath.Substring('payload/'.Length)
                length = [long](Get-PshInstallProperty $file 'length')
                sha256 = [string](Get-PshInstallProperty $file 'sha256')
            })
        }
    }
    if ($versionFiles.Count -eq 0) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'The package contains no payload files.' }
    $versionTreeSha = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $versionFiles.ToArray() })
    $publishedVersionEntryForChecks = [pscustomobject][ordered]@{ files = $versionFiles.ToArray(); treeSha256 = $versionTreeSha }

    $oldOwnershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $script:LifecycleInstallRoot -Kind ownership
    if ($null -ne $oldOwnershipSnapshot) {
        $oldOwnership = $oldOwnershipSnapshot.Document
        [byte[]]$oldOwnershipBytes = [byte[]]$oldOwnershipSnapshot.Bytes
        $oldOwnershipSha256 = [string]$oldOwnershipSnapshot.Sha256
    }
    $oldCurrent = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
    $oldComponents = Get-PshInstallProperty $oldOwnership 'components'
    $profileWasInstalledBefore = [bool](Get-PshInstallProperty (Get-PshInstallProperty $oldComponents 'profile') 'installed')
    $projectionWasInstalledBefore = [bool](Get-PshInstallProperty (Get-PshInstallProperty $oldComponents 'psReadLineProjection') 'installed')
    $existingEntry = Get-PshLifecycleOwnedVersion -Ownership $oldOwnership -Version ([string]$manifest.version)
    $versionsRoot = Join-Path $script:LifecycleInstallRoot 'versions'
    $versionRoot = Join-Path $versionsRoot ([string]$manifest.version)
    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $versionsRoot -Description 'Versions root' -AllowMissing | Out-Null
    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $versionRoot -Description 'Installed version path' -AllowMissing | Out-Null
    foreach ($directoryCheck in @(
            [pscustomobject]@{ Path = (Join-Path $script:LifecycleInstallRoot '.staging'); Description = 'Staging root' },
            [pscustomobject]@{ Path = (Join-Path $script:LifecycleInstallRoot '.quarantine'); Description = 'Quarantine root' },
            [pscustomobject]@{ Path = (Join-Path $script:LifecycleInstallRoot '.lifecycle'); Description = 'Lifecycle root' },
            [pscustomobject]@{ Path = (Join-Path (Join-Path $script:LifecycleInstallRoot '.lifecycle') 'backups'); Description = 'Stable backup root' })) {
        Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $directoryCheck.Path -Description $directoryCheck.Description -AllowMissing | Out-Null
    }
    if ([IO.File]::Exists($versionRoot)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "A version path is a file: $versionRoot" }
    if ([IO.Directory]::Exists($versionRoot)) {
        if ($null -eq $existingEntry) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "An unowned version directory already exists: $versionRoot" }
        if ([string](Get-PshInstallProperty $existingEntry 'edition') -cne [string]$manifest.edition -or [string](Get-PshInstallProperty $existingEntry 'architecture') -cne [string]$manifest.architecture -or [string](Get-PshInstallProperty $existingEntry 'packageManifestSha256') -cne $manifestHash) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'The same version is already installed with a different edition or package hash.' }
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $existingEntry
        $idempotent = $true
    }

    $stageId = ([Guid]::NewGuid()).ToString('N')
    $stageRoot = Join-Path (Join-Path $script:LifecycleInstallRoot '.staging') $stageId
    $stagePayload = Join-Path $stageRoot 'payload'
    $stageRelative = '.staging/' + $stageId
    $publishedRelative = 'versions/' + [string]$manifest.version
    $operation = if ($oldCurrent.exists -and [string]$oldCurrent.version -cne [string]$manifest.version) { 'upgrade' } else { 'install' }
    $ownershipBeforeHash = $oldOwnershipSha256
    $journalCurrent = [pscustomobject][ordered]@{ exists = [bool]$oldCurrent.exists; version = $oldCurrent.version; sha256 = $oldCurrent.sha256 }
    $journal = New-PshLifecycleJournal -TransactionId $stageId -Operation $operation -TargetVersion ([string]$manifest.version) -Current $journalCurrent -StageRelativePath $stageRelative -PublishedRelativePath $publishedRelative -OwnershipBeforeSha256 $ownershipBeforeHash
    if ($script:InstallWhatIfRequested) {
        return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'install'; whatIf = $true; version = [string]$manifest.version; edition = [string]$manifest.edition; installRoot = $script:LifecycleInstallRoot }
    }
    if ([IO.File]::Exists($script:LifecycleInstallRoot)) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "InstallRoot is a file: $script:LifecycleInstallRoot"
    }
    [IO.Directory]::CreateDirectory($script:LifecycleInstallRoot) | Out-Null
    Assert-PshLifecycleNoReparse -Path $script:LifecycleInstallRoot -Description 'InstallRoot'
    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path (Join-Path $script:LifecycleInstallRoot '.staging') -Description 'Staging root' -AllowMissing | Out-Null
    Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $stageRoot -Description 'Staging transaction root' -AllowMissing | Out-Null
    if (-not $idempotent) {
        if ($PSCmdlet.ShouldProcess($stageRoot, 'Stage and verify Psh package payload')) {
            [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $stageRoot -Description 'Staging transaction root' | Out-Null
            $stagePackageRoot = Join-Path $stageRoot 'package'
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $stagePackageRoot -Description 'Staged package root' -AllowMissing | Out-Null
            Copy-Item -LiteralPath $packageRootResolved -Destination $stagePackageRoot -Recurse -Force
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $stagePackageRoot -Description 'Staged package root' | Out-Null
            $stagedManifestPath = Join-Path $stagePackageRoot 'package.manifest.json'
            $stagedManifestSnapshot = Read-PshStrictJsonSnapshot -Path $stagedManifestPath -Description 'Staged package manifest'
            $null = Read-PshPackageManifest -Path $stagedManifestPath -Snapshot $stagedManifestSnapshot
            if ([string]$stagedManifestSnapshot.Sha256 -cne $manifestHash) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Staged package manifest differs from the initially verified manifest.' }
            $stageVerification = Test-PshPackageTree -PackageRoot $stagePackageRoot -Manifest $manifest
            if ($null -eq $stageVerification -or -not [bool](Get-PshInstallProperty $stageVerification 'Verified')) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Staged package tree verification did not return a verified result.' }
            $stagePayload = Join-Path $stagePackageRoot 'payload'
            Assert-PshLifecycleNoReparse -Path $stagePayload -Description 'Staged payload'
            Save-PshLifecycleJournal -Journal $journal
        }
        else {
            return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'install'; whatIf = $true; version = [string]$manifest.version; edition = [string]$manifest.edition }
        }
    }
    else { Save-PshLifecycleJournal -Journal $journal }

    if (-not $idempotent) {
        [IO.Directory]::CreateDirectory($versionsRoot) | Out-Null
        Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $versionsRoot -Description 'Versions root' | Out-Null
        if ([IO.Directory]::Exists($versionRoot)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message "Version appeared concurrently: $versionRoot" }
        Move-Item -LiteralPath $stagePayload -Destination $versionRoot
        $script:PublishedVersionRoot = $versionRoot
        $script:PublishedVersionWasNew = $true
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
        $journal.phase = 'published'
        Save-PshLifecycleJournal -Journal $journal
    }
    else { $script:PublishedVersionRoot = $versionRoot }
    Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks

    $entrypoints = Get-PshInstallProperty $manifest 'entrypoints'
    $bootstrapSource = Resolve-PshLifecycleCandidate -PackageRoot $versionRoot -PayloadRoot $versionRoot -RelativeCandidates @('bootstrap.ps1', 'install/bootstrap.ps1') -Description 'Published bootstrap entrypoint'
    $configSource = Resolve-PshLifecycleCandidate -PackageRoot $versionRoot -PayloadRoot $versionRoot -RelativeCandidates @('config.psd1', 'install/config.psd1') -Description 'Published config template'
    if ($null -eq $bootstrapSource -or $null -eq $configSource) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Published package is missing a required bootstrap or config payload.' }
    $bootstrapRecord = Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $bootstrapSource -Files $versionFiles.ToArray() -Description 'Published bootstrap entrypoint'
    $configRecord = Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $configSource -Files $versionFiles.ToArray() -Description 'Published config template'
    if ((Get-PshInstallConfigEdition -Path $configSource -Description 'Published config template') -cne [string]$manifest.edition) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Published config Edition does not match package manifest edition.'
    }
    if ($null -ne $bootstrapSource) {
        $oldStable = $null
        $ownedStable = Get-PshInstallProperty $oldOwnership 'stableFiles'
        foreach ($candidateStable in @($ownedStable)) { if ($null -ne $candidateStable -and [string](Get-PshInstallProperty $candidateStable 'relativePath') -ceq 'bootstrap.ps1') { $oldStable = $candidateStable; break } }
        $stableResult = Install-PshLifecycleStableFile -RelativePath 'bootstrap.ps1' -SourcePath $bootstrapSource -ExistingEntry $oldStable -ExpectedSourceEntry $bootstrapRecord
        if ($null -eq $stableResult -or $null -eq (Get-PshInstallProperty $stableResult 'Entry')) { Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message 'Stable bootstrap planning returned no ownership entry.' }
        $stableEntries.Add($stableResult.Entry)
        if ($null -ne $stableResult.Mutation) { $script:StableMutations.Add($stableResult.Mutation) }
    }
    if ($null -ne $configSource) {
        $oldConfig = Get-PshInstallProperty $oldOwnership 'config'
        $configTarget = Join-Path $script:LifecycleInstallRoot 'config.psd1'
        if ([IO.File]::Exists($configTarget)) {
            if ((Get-PshInstallConfigEdition -Path $configTarget -Description 'Existing config') -cne [string]$manifest.edition) {
                Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Existing config Edition does not match package manifest edition.'
            }
        }
        $configResult = Install-PshLifecycleStableFile -RelativePath 'config.psd1' -SourcePath $configSource -ExistingEntry $oldConfig -ExpectedSourceEntry $configRecord -PreserveUnknown
        if ($null -eq $configResult -or $null -eq (Get-PshInstallProperty $configResult 'Entry')) { Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message 'Config planning returned no ownership entry.' }
        $configEntry = $configResult.Entry
        if ($null -ne $configResult.Mutation) { $script:StableMutations.Add($configResult.Mutation) }
    }

    $profileScript = Resolve-PshLifecycleCandidate -PackageRoot $versionRoot -PayloadRoot $versionRoot -RelativeCandidates @('profile/Install-PshProfile.ps1', 'src/profile/Install-PshProfile.ps1') -Description 'Published profile installer'
    $resolvedProfiles = @(if ($PSBoundParameters.ContainsKey('ProfilePath')) { @($ProfilePath) } else { @(Get-PshLifecycleDefaultProfiles) })
    $profileState = if ([string]::IsNullOrWhiteSpace($ProfileStateRoot)) { Join-Path $script:LifecycleInstallRoot 'profile-state' } else { Resolve-PshLifecyclePath -Path $ProfileStateRoot -Description 'ProfileStateRoot' }
    $resolvedProfilesForRollback = $resolvedProfiles
    $profileStateForRollback = $profileState
    if ($null -ne $profileScript) {
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileScript -Files $versionFiles.ToArray() -Description 'Published profile installer' | Out-Null
        $profileUninstallPath = Join-Path ([IO.Path]::GetDirectoryName($profileScript)) 'Uninstall-PshProfile.ps1'
        if ([IO.File]::Exists($profileUninstallPath)) {
            $profileUninstallPath = [IO.Path]::GetFullPath($profileUninstallPath)
            $profileUninstallRecord = Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileUninstallPath -Files $versionFiles.ToArray() -Description 'Published profile uninstaller'
            $profileUninstallSha256 = [string](Get-PshInstallProperty $profileUninstallRecord 'sha256')
        }
        else { $profileUninstallPath = $null }
    }
    if ($null -ne $profileScript -and $resolvedProfiles.Count -gt 0) {
        if ($null -eq $profileUninstallPath) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'The profile installer requires a paired Uninstall-PshProfile.ps1 in the same verified directory.' }
        $null = Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileScript -Files $versionFiles.ToArray() -Description 'Published profile installer'
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
        Assert-PshLifecycleNoReparse -Path $profileScript -Description 'Profile installer'
        $null = @(& $profileScript -ProfilePath $resolvedProfiles -StateRoot $profileState -WhatIf:$script:InstallWhatIfRequested -Confirm:$false)
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileScript -Files $versionFiles.ToArray() -Description 'Published profile installer' | Out-Null
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
        if (-not $script:InstallWhatIfRequested) { $profileInstalled = $true }
    }
    if (($resolvedProfiles.Count -gt 0 -or $profileWasInstalledBefore) -and ($null -eq $profileScript -or $null -eq $profileUninstallPath)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Published package is missing the paired profile installer payload.' }
    if ($null -ne $profileScript) {
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileScript -Files $versionFiles.ToArray() -Description 'Published profile installer' | Out-Null
        if ($null -ne $profileUninstallPath) { Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $profileUninstallPath -Files $versionFiles.ToArray() -Description 'Published profile uninstaller' | Out-Null }
    }

    $projectionInstallScript = Resolve-PshLifecycleCandidate -PackageRoot $versionRoot -PayloadRoot $versionRoot -RelativeCandidates @('profile/Install-PshPSReadLineProjection.ps1', 'src/profile/Install-PshPSReadLineProjection.ps1') -Description 'Published PSReadLine projection installer'
    $resolvedModules = @(if ($PSBoundParameters.ContainsKey('ModuleRoot')) { @($ModuleRoot) } else { @(Get-PshLifecycleDefaultModuleRoots) })
    $projectionState = if ([string]::IsNullOrWhiteSpace($ProjectionStateRoot)) { Join-Path $script:LifecycleInstallRoot 'psreadline-projection-state' } else { Resolve-PshLifecyclePath -Path $ProjectionStateRoot -Description 'ProjectionStateRoot' }
    $resolvedModulesForRollback = $resolvedModules
    $projectionStateForRollback = $projectionState
    if ($null -ne $projectionInstallScript) {
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionInstallScript -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection installer' | Out-Null
        $projectionUninstallPath = Join-Path ([IO.Path]::GetDirectoryName($projectionInstallScript)) 'Uninstall-PshPSReadLineProjection.ps1'
        if ([IO.File]::Exists($projectionUninstallPath)) {
            $projectionUninstallPath = [IO.Path]::GetFullPath($projectionUninstallPath)
            $projectionUninstallRecord = Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionUninstallPath -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection uninstaller'
            $projectionUninstallSha256 = [string](Get-PshInstallProperty $projectionUninstallRecord 'sha256')
        }
        else { $projectionUninstallPath = $null }
    }
    $sourceReadLine = $null
    foreach ($candidate in @(
            (Join-Path $versionRoot 'Psh/Dependencies/PSReadLine/2.4.5'),
            (Join-Path $versionRoot 'Dependencies/PSReadLine/2.4.5'),
            (Join-Path $versionRoot 'PSReadLine/2.4.5')) ) {
        if ([IO.Directory]::Exists($candidate)) { $sourceReadLine = $candidate; break }
    }
    if (($resolvedModules.Count -gt 0 -or $projectionWasInstalledBefore) -and ($null -eq $projectionInstallScript -or $null -eq $projectionUninstallPath -or $null -eq $sourceReadLine)) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Published package is missing the PSReadLine projection payload.' }
    if ($null -ne $projectionInstallScript) {
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionInstallScript -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection installer' | Out-Null
        if ($null -ne $projectionUninstallPath) { Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionUninstallPath -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection uninstaller' | Out-Null }
    }
    if ($null -ne $projectionInstallScript -and $null -ne $sourceReadLine -and $resolvedModules.Count -gt 0) {
        if ($null -eq $projectionUninstallPath) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'The PSReadLine projection installer requires a paired Uninstall-PshPSReadLineProjection.ps1 in the same verified directory.' }
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionInstallScript -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection installer' | Out-Null
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
        Assert-PshLifecycleNoReparse -Path $projectionInstallScript -Description 'PSReadLine projection installer'
        $null = @(& $projectionInstallScript -SourcePath $sourceReadLine -ModuleRoot $resolvedModules -StateRoot $projectionState -WhatIf:$script:InstallWhatIfRequested -Confirm:$false)
        Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $projectionInstallScript -Files $versionFiles.ToArray() -Description 'Published PSReadLine projection installer' | Out-Null
        Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
        if (-not $script:InstallWhatIfRequested) { $projectionInstalled = $true }
    }

    $profileInstalled = $profileInstalled -or $profileWasInstalledBefore
    $projectionInstalled = $projectionInstalled -or $projectionWasInstalledBefore
    Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
    $versionEntry = [pscustomobject][ordered]@{
        version = [string]$manifest.version; edition = [string]$manifest.edition; architecture = [string]$manifest.architecture; relativeRoot = $publishedRelative; archiveSha256 = if ([string]::IsNullOrWhiteSpace($ArchiveSha256)) { $null } else { $ArchiveSha256.ToLowerInvariant() }; packageManifestSha256 = $manifestHash; treeSha256 = $versionTreeSha; files = $versionFiles.ToArray()
    }
    $ownership = New-PshLifecycleOwnership -Previous $oldOwnership -Manifest $manifest -VersionEntry $versionEntry -StableEntries $stableEntries.ToArray() -ConfigEntry $configEntry -ProfileInstalled $profileInstalled -ProjectionInstalled $projectionInstalled
    if ($null -eq $ownership -or @($ownership).Count -ne 1) {
        Stop-PshLifecycleInstall -Code 3 -Kind 'RuntimeError' -Message ("Ownership builder returned {0} items (stable={1}, config={2}, versions={3})." -f @($ownership).Count, $stableEntries.Count, ($null -ne $configEntry), $versionFiles.Count)
    }
    $ownership = Assert-PshOwnershipDocument -State $ownership -InstallRoot $script:LifecycleInstallRoot
    $ownershipJson = (ConvertTo-PshCanonicalJson -InputObject $ownership) + "`n"
    [byte[]]$ownershipAfterBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($ownershipJson)
    $ownershipAfterSha256 = Get-PshLifecycleBytesHash -Bytes $ownershipAfterBytes
    if ($script:InstallWhatIfRequested) {
        return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'install'; whatIf = $true; version = [string]$manifest.version; edition = [string]$manifest.edition }
    }
    $ownershipWriteAttempted = $true
    Write-PshLifecycleFileCas -Path (Join-Path $script:LifecycleInstallRoot 'ownership.json') -ExpectedExisted ($null -ne $oldOwnership) -ExpectedSha256 $oldOwnershipSha256 -Bytes $ownershipAfterBytes -Description 'ownership.json'
    $ownershipWritten = $true
    $writtenOwnershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $script:LifecycleInstallRoot -Kind ownership
    if ($null -eq $writtenOwnershipSnapshot -or [string]$writtenOwnershipSnapshot.Sha256 -cne $ownershipAfterSha256) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Written ownership state did not match the expected transaction bytes.' }

    $setCurrent = Resolve-PshLifecycleCandidate -PackageRoot $versionRoot -PayloadRoot $versionRoot -RelativeCandidates @('install/Set-PshCurrentVersion.ps1', 'Set-PshCurrentVersion.ps1') -Description 'Published current-version switcher'
    if ($null -eq $setCurrent) { Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'Set-PshCurrentVersion.ps1 is unavailable.' }
    Assert-PshInstallPublishedFile -VersionRoot $versionRoot -Path $setCurrent -Files $versionFiles.ToArray() -Description 'Published current-version switcher' | Out-Null
    Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
    $setCurrentPath = $setCurrent
    $targetCurrentBytes = Get-PshLifecycleCurrentBytes -Version ([string]$manifest.version)
    $targetCurrentSha256 = Get-PshLifecycleBytesHash -Bytes $targetCurrentBytes
    $journal.phase = 'switched'
    Save-PshLifecycleJournal -Journal $journal
    $pointerWriteAttempted = $true
    $expectedCurrentSha256 = if ([bool]$oldCurrent.exists) { [string]$oldCurrent.sha256 } else { '' }
    $null = @(& $setCurrent -Version ([string]$manifest.version) -InstallRoot $script:LifecycleInstallRoot -ExpectedCurrentSha256 $expectedCurrentSha256 -Confirm:$false)
    $targetCurrent = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
    if (-not [bool]$targetCurrent.exists -or [string]$targetCurrent.version -cne [string]$manifest.version -or [string]$targetCurrent.sha256 -cne $targetCurrentSha256) {
        Stop-PshLifecycleInstall -Code 5 -Kind 'IntegrityFailure' -Message 'current.json did not reach the expected installed version state.'
    }
    Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
    $pointerSwitched = $true
    if ($null -ne $stageRoot -and [IO.Directory]::Exists($stageRoot)) { Remove-PshLifecycleOwnedStage -StageRoot $stageRoot -Manifest $manifest -ManifestSha256 $manifestHash }
    Remove-PshLifecycleFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $script:LifecycleInstallRoot -Kind transaction) -ExpectedSha256 $script:LifecycleTransactionSha256 -Description 'transaction journal'
    $script:LifecycleTransactionWritten = $false
    $script:LifecycleTransactionSha256 = $null
    return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'install'; whatIf = $false; idempotent = $idempotent; version = [string]$manifest.version; edition = [string]$manifest.edition; installRoot = $script:LifecycleInstallRoot }
}
catch {
    $failure = $_
    $rollbackClean = $true
    $rollbackIntegrityConflict = $false
    $rollbackRestartRequired = $false
    $rollbackIssues = New-Object System.Collections.Generic.List[string]
    $metadataReady = $true
    $currentState = 'old'
    $ownershipState = if ($null -eq $oldOwnership) { 'oldAbsent' } else { 'old' }
    try {
        $liveCurrent = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
        $currentOldMatches = if ([bool]$oldCurrent.exists) { [bool]$liveCurrent.exists -and [string]$liveCurrent.sha256 -ceq [string]$oldCurrent.sha256 } else { -not [bool]$liveCurrent.exists }
        $currentTargetMatches = [bool]$pointerWriteAttempted -and [bool]$liveCurrent.exists -and [string]$liveCurrent.sha256 -ceq [string]$targetCurrentSha256
        if ($currentOldMatches) { $currentState = 'old' }
        elseif ($currentTargetMatches) { $currentState = 'target' }
        else { $metadataReady = $false; $rollbackIntegrityConflict = $true; $rollbackIssues.Add('current.json diverged from both the pre-install and transaction target states.') }

        $liveOwnershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $script:LifecycleInstallRoot -Kind ownership
        $ownershipOldMatches = if ($null -eq $oldOwnership) { $null -eq $liveOwnershipSnapshot } else { $null -ne $liveOwnershipSnapshot -and [string]$liveOwnershipSnapshot.Sha256 -ceq $oldOwnershipSha256 }
        $ownershipTargetMatches = [bool]$ownershipWriteAttempted -and $null -ne $liveOwnershipSnapshot -and [string]$liveOwnershipSnapshot.Sha256 -ceq [string]$ownershipAfterSha256
        if ($ownershipOldMatches) { $ownershipState = if ($null -eq $oldOwnership) { 'oldAbsent' } else { 'old' } }
        elseif ($ownershipTargetMatches) { $ownershipState = 'target' }
        else { $metadataReady = $false; $rollbackIntegrityConflict = $true; $rollbackIssues.Add('ownership.json diverged from both the pre-install and transaction target states.') }
    }
    catch {
        $metadataReady = $false
        $rollbackIntegrityConflict = $true
        $rollbackIssues.Add("Metadata compensation preflight: $($_.Exception.Message)")
    }

    if ($metadataReady) {
        try {
            if ($currentState -ceq 'target') {
                Restore-PshLifecycleFileCas -Path (Join-Path $script:LifecycleInstallRoot 'current.json') -ExpectedSha256 $targetCurrentSha256 -OriginalExisted ([bool]$oldCurrent.exists) -OriginalBytes ([byte[]]$oldCurrent.bytes) -Description 'current.json'
            }
            $restoredCurrent = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
            $restoredCurrentMatches = if ([bool]$oldCurrent.exists) { [bool]$restoredCurrent.exists -and [string]$restoredCurrent.sha256 -ceq [string]$oldCurrent.sha256 } else { -not [bool]$restoredCurrent.exists }
            if (-not $restoredCurrentMatches) { throw 'current.json compensation did not restore the exact pre-install state.' }
        }
        catch {
            $metadataReady = $false
            $rollbackClean = $false
            $rollbackIntegrityConflict = $true
            $rollbackIssues.Add("Current pointer compensation: $($_.Exception.Message)")
        }
        if ($metadataReady) {
            try {
                if ($ownershipState -ceq 'target') {
                    Restore-PshLifecycleFileCas -Path (Join-Path $script:LifecycleInstallRoot 'ownership.json') -ExpectedSha256 $ownershipAfterSha256 -OriginalExisted ($null -ne $oldOwnership) -OriginalBytes $oldOwnershipBytes -Description 'ownership.json'
                }
                $restoredOwnershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $script:LifecycleInstallRoot -Kind ownership
                $restoredOwnershipMatches = if ($null -eq $oldOwnership) { $null -eq $restoredOwnershipSnapshot } else { $null -ne $restoredOwnershipSnapshot -and [string]$restoredOwnershipSnapshot.Sha256 -ceq $oldOwnershipSha256 }
                if (-not $restoredOwnershipMatches) { throw 'ownership.json compensation did not restore the exact pre-install state.' }
            }
            catch {
                $metadataReady = $false
                $rollbackClean = $false
                $rollbackIntegrityConflict = $true
                $rollbackIssues.Add("Ownership compensation: $($_.Exception.Message)")
                # If ownership is still the exact transaction image while the
                # current pointer was restored, try to keep the two metadata
                # files in the transaction state rather than leaving a known
                # old-current/new-ownership split.
                try {
                    $liveOwnershipAfterFailure = Read-PshLifecycleStateSnapshot -InstallRoot $script:LifecycleInstallRoot -Kind ownership
                    $liveCurrentAfterFailure = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
                    $ownershipStillTarget = $null -ne $liveOwnershipAfterFailure -and [string]$liveOwnershipAfterFailure.Sha256 -ceq $ownershipAfterSha256
                    $currentStillOld = if ([bool]$oldCurrent.exists) { [bool]$liveCurrentAfterFailure.exists -and [string]$liveCurrentAfterFailure.sha256 -ceq [string]$oldCurrent.sha256 } else { -not [bool]$liveCurrentAfterFailure.exists }
                    if ($ownershipStillTarget -and $currentStillOld) {
                        [byte[]]$currentForwardBytes = Get-PshLifecycleCurrentBytes -Version ([string]$manifest.version)
                        $currentForwardSha256 = Get-PshLifecycleBytesHash -Bytes $currentForwardBytes
                        Write-PshLifecycleFileCas -Path (Join-Path $script:LifecycleInstallRoot 'current.json') -ExpectedExisted ([bool]$oldCurrent.exists) -ExpectedSha256 ([string]$oldCurrent.sha256) -Bytes $currentForwardBytes -Description 'current.json consistency recovery'
                        $consistentCurrent = Read-PshLifecycleCurrent -Root $script:LifecycleInstallRoot
                        if (-not [bool]$consistentCurrent.exists -or [string]$consistentCurrent.sha256 -cne $currentForwardSha256) { throw 'current.json did not return to the transaction target state.' }
                        $rollbackIssues.Add('Current pointer was returned to the transaction state because ownership compensation could not complete.')
                    }
                }
                catch { $rollbackIssues.Add("Metadata consistency recovery: $($_.Exception.Message)") }
            }
        }
    }
    $metadataConflict = -not $metadataReady
    if ($metadataConflict) {
        $rollbackClean = $false
        $rollbackIssues.Add('Metadata CAS conflict detected; component, version-tree, and stable-file destructive compensation was skipped.')
    }
    if (-not $metadataConflict) {
    if ($projectionInstalled -and -not $projectionWasInstalledBefore -and $resolvedModulesForRollback.Count -gt 0) {
        $projectionRollbackStatus = if ($null -eq $projectionUninstallPath) { [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Reason = 'the script path is unavailable' } } else { Get-PshInstallRollbackScriptStatus -Path $projectionUninstallPath -ExpectedSha256 $projectionUninstallSha256 }
        if (-not [bool](Get-PshInstallProperty $projectionRollbackStatus 'Trusted')) {
            $rollbackClean = $false
            if ([bool](Get-PshInstallProperty $projectionRollbackStatus 'RestartRequired')) { $rollbackRestartRequired = $true } else { $rollbackIntegrityConflict = $true }
            $rollbackIssues.Add(('The paired PSReadLine projection uninstaller was not executed because {0}.' -f [string](Get-PshInstallProperty $projectionRollbackStatus 'Reason')))
        }
        else {
            try {
                Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
                $null = @(& $projectionUninstallPath -ModuleRoot $resolvedModulesForRollback -StateRoot $projectionStateForRollback -Confirm:$false)
                Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
            }
            catch {
                $rollbackClean = $false
                $rollbackRestartRequired = $true
                $rollbackIssues.Add('The PSReadLine projection installation could not be rolled back.')
            }
        }
    }
    if ($profileInstalled -and -not $profileWasInstalledBefore -and $resolvedProfilesForRollback.Count -gt 0) {
        $profileRollbackStatus = if ($null -eq $profileUninstallPath) { [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Reason = 'the script path is unavailable' } } else { Get-PshInstallRollbackScriptStatus -Path $profileUninstallPath -ExpectedSha256 $profileUninstallSha256 }
        if (-not [bool](Get-PshInstallProperty $profileRollbackStatus 'Trusted')) {
            $rollbackClean = $false
            if ([bool](Get-PshInstallProperty $profileRollbackStatus 'RestartRequired')) { $rollbackRestartRequired = $true } else { $rollbackIntegrityConflict = $true }
            $rollbackIssues.Add(('The paired profile uninstaller was not executed because {0}.' -f [string](Get-PshInstallProperty $profileRollbackStatus 'Reason')))
        }
        else {
            try {
                Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
                $null = @(& $profileUninstallPath -ProfilePath $resolvedProfilesForRollback -StateRoot $profileStateForRollback -Confirm:$false)
                Assert-PshInstallOwnedVersionTree -VersionRoot $versionRoot -Entry $publishedVersionEntryForChecks
            }
            catch {
                $rollbackClean = $false
                $rollbackRestartRequired = $true
                $rollbackIssues.Add('The profile installation could not be rolled back.')
            }
        }
    }
    if ($null -ne $script:PublishedVersionRoot -and $script:PublishedVersionWasNew -and [IO.Directory]::Exists($script:PublishedVersionRoot)) {
        $publishedVersionRollbackVerified = $false
        try {
            Assert-PshInstallOwnedVersionTree -VersionRoot $script:PublishedVersionRoot -Entry $publishedVersionEntryForChecks
            $publishedVersionRollbackVerified = $true
        }
        catch {
            $rollbackClean = $false
            $rollbackIntegrityConflict = $true
            $rollbackIssues.Add("The newly published version changed after publication and was preserved: $($_.Exception.Message)")
        }
        if ($publishedVersionRollbackVerified) {
        try {
            $quarantineRoot = Join-Path (Join-Path $script:LifecycleInstallRoot '.quarantine') ([Guid]::NewGuid().ToString('N'))
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path (Join-Path $script:LifecycleInstallRoot '.quarantine') -Description 'Rollback quarantine root' -AllowMissing | Out-Null
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $quarantineRoot -Description 'Rollback quarantine transaction' -AllowMissing | Out-Null
            [IO.Directory]::CreateDirectory($quarantineRoot) | Out-Null
            Assert-PshInstallDirectoryPath -Root $script:LifecycleInstallRoot -Path $quarantineRoot -Description 'Rollback quarantine transaction' | Out-Null
            $quarantinedVersionRoot = Join-Path $quarantineRoot 'version'
            Move-Item -LiteralPath $script:PublishedVersionRoot -Destination $quarantinedVersionRoot
            Assert-PshInstallOwnedVersionTree -VersionRoot $quarantinedVersionRoot -Entry $publishedVersionEntryForChecks
            Remove-PshInstallOwnedVersionTree -VersionRoot $quarantinedVersionRoot -Entry $publishedVersionEntryForChecks
            try { [IO.Directory]::Delete($quarantineRoot, $false) }
            catch {
                $rollbackClean = $false
                if ([IO.File]::Exists($quarantineRoot) -or ([IO.Directory]::Exists($quarantineRoot) -and @(Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction SilentlyContinue).Count -gt 0)) {
                    $rollbackIntegrityConflict = $true
                    $rollbackIssues.Add('The failed version quarantine root gained unknown content and was retained.')
                }
                else {
                    $rollbackRestartRequired = $true
                    $rollbackIssues.Add("The failed version quarantine root was retained: $($_.Exception.Message)")
                }
            }
        }
        catch {
            $rollbackClean = $false
            if ($_.Exception.Data['PshExitCode'] -eq 5) { $rollbackIntegrityConflict = $true } else { $rollbackRestartRequired = $true }
            $rollbackIssues.Add("The newly published version could not be safely quarantined during rollback: $($_.Exception.Message)")
        }
        }
    }
    for ($mutationIndex = $script:StableMutations.Count - 1; $mutationIndex -ge 0; $mutationIndex--) {
        $mutation = $script:StableMutations[$mutationIndex]
        $mutationPath = [string](Get-PshInstallProperty $mutation 'Path')
        $mutationExisted = [bool](Get-PshInstallProperty $mutation 'Existed')
        $installedHash = [string](Get-PshInstallProperty $mutation 'InstalledHash')
        try {
            if ($mutationExisted) {
                if (-not [IO.File]::Exists($mutationPath)) {
                    $rollbackClean = $false
                    $rollbackIntegrityConflict = $true
                    $rollbackIssues.Add("A stable file disappeared before rollback and was not recreated: $mutationPath")
                    continue
                }
                if (([IO.File]::GetAttributes($mutationPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-PshLifecycleHash -Path $mutationPath) -cne $installedHash) {
                    $rollbackClean = $false
                    $rollbackIntegrityConflict = $true
                    $rollbackIssues.Add("A stable file changed after installation and was preserved: $mutationPath")
                    continue
                }
                Restore-PshLifecycleFileCas -Path $mutationPath -ExpectedSha256 $installedHash -OriginalExisted $true -OriginalBytes ([byte[]](Get-PshInstallProperty $mutation 'Bytes')) -Description "Stable file $mutationPath"
            }
            elseif ([IO.Directory]::Exists($mutationPath)) {
                $rollbackClean = $false
                $rollbackIntegrityConflict = $true
                $rollbackIssues.Add("A new directory replaced an installed stable file and was preserved: $mutationPath")
            }
            elseif ([IO.File]::Exists($mutationPath)) {
                if (([IO.File]::GetAttributes($mutationPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-PshLifecycleHash -Path $mutationPath) -cne $installedHash) {
                    $rollbackClean = $false
                    $rollbackIntegrityConflict = $true
                    $rollbackIssues.Add("A newly installed stable file changed and was preserved: $mutationPath")
                    continue
                }
                Restore-PshLifecycleFileCas -Path $mutationPath -ExpectedSha256 $installedHash -OriginalExisted $false -OriginalBytes (New-Object byte[] 0) -Description "Stable file $mutationPath"
            }
        }
        catch {
            $rollbackClean = $false
            $rollbackRestartRequired = $true
            $rollbackIssues.Add("A stable file could not be rolled back: $mutationPath")
        }
    }
    if ($null -ne $stageRoot -and [IO.Directory]::Exists($stageRoot)) {
        try { Remove-PshLifecycleOwnedStage -StageRoot $stageRoot -Manifest $manifest -ManifestSha256 $manifestHash }
        catch {
            $rollbackClean = $false
            if ($_.Exception.Data['PshExitCode'] -eq 5) { $rollbackIntegrityConflict = $true } else { $rollbackRestartRequired = $true }
            $rollbackIssues.Add("The package staging directory could not be removed: $($_.Exception.Message)")
        }
    }
    }
    if ($rollbackClean -and $script:LifecycleTransactionWritten -and $null -ne $script:LifecycleInstallRoot -and [IO.Directory]::Exists($script:LifecycleInstallRoot)) {
        try {
            Remove-PshLifecycleFileCas -Path (Get-PshLifecycleStatePath -InstallRoot $script:LifecycleInstallRoot -Kind transaction) -ExpectedSha256 $script:LifecycleTransactionSha256 -Description 'transaction journal'
            $script:LifecycleTransactionWritten = $false
            $script:LifecycleTransactionSha256 = $null
        }
        catch {
            $rollbackClean = $false
            $rollbackRestartRequired = $true
            $rollbackIssues.Add('The lifecycle transaction journal could not be cleared.')
        }
    }
    if (-not $rollbackClean) {
        $rollbackCode = if ($rollbackIntegrityConflict) { 5 } else { 3 }
        $global:LASTEXITCODE = $rollbackCode
        $failure.Exception.Data['PshExitCode'] = $rollbackCode
        $failure.Exception.Data['PshErrorKind'] = if ($rollbackIntegrityConflict) { 'IntegrityFailure' } else { 'RuntimeError' }
        $failure.Exception.Data['PshErrorId'] = 'PshLifecycle.RollbackIncomplete'
        $failure.Exception.Data['PshRollbackIncomplete'] = $true
        $failure.Exception.Data['PshRecoveryRequired'] = $true
        $failure.Exception.Data['PshRestartRequired'] = $rollbackRestartRequired
        $failure.Exception.Data['PshRollbackIssues'] = [string]::Join(' | ', $rollbackIssues.ToArray())
    }
    throw $failure
}
finally {
    if ($script:InstallWhatIfWasDefined) { $WhatIfPreference = $script:InstallOriginalWhatIfPreference }
    else { Remove-Variable -Name WhatIfPreference -Scope 0 -ErrorAction SilentlyContinue }
    if ($null -ne $lock) { Exit-PshInstallRootLock -Lock $lock }
}
