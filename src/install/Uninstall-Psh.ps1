# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Removes Psh-owned current-user installation content.

.DESCRIPTION
Only paths recorded in trusted ownership state and still matching their
recorded bytes are removed.  Exact owned trees are moved to a same-volume
quarantine before deletion.  Unknown or user-modified content is retained.
Profile restoration and PSReadLine projection removal are delegated to their
byte-preserving transaction scripts with explicit paths.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string] $InstallRoot,

    [Parameter()]
    [switch] $KeepConfig,

    [Parameter()]
    [AllowNull()]
    [string[]] $ProfilePath,

    [Parameter()]
    [AllowNull()]
    [string[]] $ModuleRoot,

    [Parameter()]
    [string] $ProfileStateRoot,

    [Parameter()]
    [string] $ProjectionStateRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path -Path $PSScriptRoot -ChildPath 'PackageLifecycle.ps1'
if (-not [IO.File]::Exists($lifecyclePath)) { throw "Psh package lifecycle helpers were not found: $lifecyclePath" }
. $lifecyclePath

$script:VersionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'

function Get-PshUninstallProperty {
    param([AllowNull()][object] $InputObject, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { return ,@($property.Value) }
    return $property.Value
}

function Stop-PshUninstall {
    param([Parameter(Mandatory = $true)][int] $Code, [Parameter(Mandatory = $true)][string] $Message, [string] $Kind = 'RuntimeError')
    $global:LASTEXITCODE = $Code
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['PshExitCode'] = $Code
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = ('PshLifecycle.{0}' -f $Kind)
    throw $exception
}

function Assert-PshUninstallNoPendingTransaction {
    param([Parameter(Mandatory = $true)][string] $Root)
    $transaction = Read-PshTransactionState -InstallRoot $Root
    if ($null -eq $transaction) { return }
    $decision = Get-PshRecoveryDecision -InstallRoot $Root -Transaction $transaction
    $action = [string](Get-PshUninstallProperty $decision 'Action')
    $safe = [bool](Get-PshUninstallProperty $decision 'Safe')
    if ($safe -and $action -ceq 'None') { return }
    $operation = [string](Get-PshUninstallProperty $transaction 'operation')
    $transactionId = [string](Get-PshUninstallProperty $transaction 'transactionId')
    $reason = [string](Get-PshUninstallProperty $decision 'Reason')
    $message = "An unfinished Psh $operation transaction ($transactionId) requires recovery before uninstall: action=$action; $reason"
    if ($safe) { Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message $message }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message $message
}

function Resolve-PshUninstallPath {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    try {
        $provider = $null; $drive = $null
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    }
    catch { Stop-PshUninstall -Code 5 -Kind 'PathFailure' -Message ("{0} is not a filesystem path: {1}" -f $Description, $Path) }
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem' -or -not [IO.Path]::IsPathRooted($full)) { Stop-PshUninstall -Code 5 -Kind 'PathFailure' -Message ("{0} must be an absolute filesystem path: {1}" -f $Description, $Path) }
    return [IO.Path]::GetFullPath($full)
}

function Assert-PshUninstallRootNotFilesystemRoot {
    param([Parameter(Mandatory = $true)][string] $Root)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $filesystemRoot = [IO.Path]::GetFullPath([IO.Path]::GetPathRoot($Root)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($normalizedRoot, $filesystemRoot, $comparison)) {
        Stop-PshUninstall -Code 5 -Kind 'PathFailure' -Message "InstallRoot must not be the filesystem root: $Root"
    }
}

function Test-PshUninstallWithinRoot {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($fullPath, $fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Get-PshUninstallPathComparison {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Get-PshUninstallPathComparer {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparer]::OrdinalIgnoreCase
    }
    return [StringComparer]::Ordinal
}

function Get-PshUninstallPathAttributesObservation {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )
    try {
        return [pscustomobject][ordered]@{ Exists = $true; Attributes = [IO.File]::GetAttributes($Path) }
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ Exists = $false; Attributes = $null }
    }
    catch [IO.DirectoryNotFoundException] {
        return [pscustomobject][ordered]@{ Exists = $false; Attributes = $null }
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $Path)
    }
}

function Assert-PshUninstallSafePath {
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
    catch { Stop-PshUninstall -Code 5 -Kind 'PathFailure' -Message ("{0} is not a valid filesystem path: {1}" -f $Description, $Path) }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $fullRoot, $comparison) -and -not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        Stop-PshUninstall -Code 5 -Kind 'PathFailure' -Message ("{0} escapes InstallRoot: {1}" -f $Description, $Path)
    }
    $ancestor = $fullRoot
    while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
        if ([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) {
            try { $ancestorAttributes = [IO.File]::GetAttributes($ancestor) }
            catch { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $ancestor) }
            if (($ancestorAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} parent chain contains a reparse point: {1}" -f $Description, $ancestor) }
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
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $current) }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} contains a reparse point: {1}" -f $Description, $current) }
    }
    return $fullPath
}

function Assert-PshUninstallDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [switch] $AllowMissing
    )
    $fullPath = Assert-PshUninstallSafePath -Root $Root -Path $Path -Description $Description -AllowMissing
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $relative = $fullPath.Substring($fullRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = $fullRoot
    if ([IO.File]::Exists($current)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is a file: {1}" -f $Description, $current)
    }
    if ([string]::IsNullOrWhiteSpace($relative)) { return $fullPath }
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if ([IO.File]::Exists($current)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} is obstructed by a file: {1}" -f $Description, $current)
        }
        if (-not [IO.Directory]::Exists($current)) {
            if ($AllowMissing) { break }
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} does not exist: {1}" -f $Description, $current)
        }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inspect {0}: {1}" -f $Description, $current) }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} contains a reparse point: {1}" -f $Description, $current)
        }
    }
    return $fullPath
}

function Get-PshUninstallHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PshUninstallBytesHash {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PshUninstallCanonicalCurrentSha256 {
    param([Parameter(Mandatory = $true)][string] $Version)
    return Get-PshLifecycleCanonicalCurrentSha256 -Version $Version
}

function Get-PshUninstallRelativePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)
    $rootUri = New-Object Uri(([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar))
    $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('\', '/')
}

function Test-PshUninstallFileUnlocked {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $stream.Dispose()
        return $true
    }
    catch { return $false }
}

function Test-PshUninstallVersionTree {
    param([Parameter(Mandatory = $true)][string] $VersionRoot, [Parameter(Mandatory = $true)][object] $VersionEntry)
    $unknown = New-Object System.Collections.Generic.List[string]
    $locked = New-Object System.Collections.Generic.List[string]
    $directoryComparer = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $owned = New-Object 'System.Collections.Generic.HashSet[string]' ($directoryComparer)
    $ownedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ($directoryComparer)
    $ownedPaths = New-Object System.Collections.Generic.List[string]
    if (-not [IO.Directory]::Exists($VersionRoot)) { return [pscustomobject][ordered]@{ Exact = $false; Unknown = @('missing version root'); OwnedFiles = @(); Locked = @() } }
    if (([IO.File]::GetAttributes($VersionRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject][ordered]@{ Exact = $false; Unknown = @('version root reparse point'); OwnedFiles = @(); Locked = @() } }
    $versionFiles = Get-PshUninstallProperty $VersionEntry 'files'
    foreach ($file in @($versionFiles)) {
        $relative = [string](Get-PshUninstallProperty $file 'relativePath')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { $unknown.Add("unsafe ownership path: $relative"); continue }
        $relative = $relative.Replace('\', '/')
        $null = $owned.Add($relative)
        $parentRelative = [IO.Path]::GetDirectoryName($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        while (-not [string]::IsNullOrWhiteSpace($parentRelative)) {
            $parentRelative = $parentRelative.Replace('\', '/')
            $null = $ownedDirectories.Add($parentRelative)
            $parentRelative = [IO.Path]::GetDirectoryName($parentRelative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
        $path = Join-Path $VersionRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($path)) { $unknown.Add("missing: $relative"); continue }
        if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $unknown.Add("reparse: $relative"); continue }
        $length = Get-PshUninstallProperty $file 'length'
        if ($null -ne $length -and (Get-Item -LiteralPath $path).Length -ne [long]$length) { $unknown.Add("length changed: $relative"); continue }
        $hash = [string](Get-PshUninstallProperty $file 'sha256')
        try { $actualHash = Get-PshUninstallHash -Path $path }
        catch { $locked.Add($path); continue }
        if ([string]::IsNullOrWhiteSpace($hash) -or $actualHash -cne $hash.ToLowerInvariant()) { $unknown.Add("hash changed: $relative"); continue }
        $ownedPaths.Add($path)
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $VersionRoot -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $unknown.Add("reparse: $(Get-PshUninstallRelativePath -Root $VersionRoot -Path $item.FullName)"); continue }
        if ($item.PSIsContainer) {
            $relative = Get-PshUninstallRelativePath -Root $VersionRoot -Path $item.FullName
            if (-not $ownedDirectories.Contains($relative)) { $unknown.Add("unknown directory: $relative") }
        }
        else {
            $relative = Get-PshUninstallRelativePath -Root $VersionRoot -Path $item.FullName
            if (-not $owned.Contains($relative)) { $unknown.Add("unknown: $relative") }
        }
    }
    return [pscustomobject][ordered]@{ Exact = ($unknown.Count -eq 0 -and $locked.Count -eq 0); Unknown = $unknown.ToArray(); OwnedFiles = $ownedPaths.ToArray(); Locked = $locked.ToArray() }
}

function Get-PshUninstallDefaultProfiles {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) { return @() }
    return @((Join-Path (Join-Path $documents 'WindowsPowerShell') 'profile.ps1'), (Join-Path (Join-Path $documents 'PowerShell') 'profile.ps1'))
}

function Get-PshUninstallDefaultModules {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) { return @() }
    return @((Join-Path (Join-Path $documents 'WindowsPowerShell') 'Modules'), (Join-Path (Join-Path $documents 'PowerShell') 'Modules'))
}

function Find-PshUninstallScript {
    param([Parameter(Mandatory = $true)][string] $VersionRoot, [Parameter(Mandatory = $true)][string] $Name)
    foreach ($candidate in @(
            (Join-Path $VersionRoot ('profile/' + $Name)),
            (Join-Path $VersionRoot ('src/profile/' + $Name))) ) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function New-PshUninstallRestartResult {
    param([Parameter(Mandatory = $true)][string] $Message, [string] $QuarantinePath)
    $global:LASTEXITCODE = 3
    return [pscustomobject][ordered]@{ success = $false; code = 3; operation = 'uninstall'; restartRequired = $true; recoveryRequired = $true; message = $Message; quarantinePath = $QuarantinePath }
}

function New-PshUninstallRecoveryResult {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][string] $QuarantinePath,
        [Parameter(Mandatory = $true)][bool] $RestartRequired,
        [Parameter(Mandatory = $true)][bool] $RollbackRestored,
        [bool] $RecoveryRequired = $true,
        [AllowNull()][string[]] $Issues
    )
    $global:LASTEXITCODE = $Code
    return [pscustomobject][ordered]@{ success = $false; code = $Code; operation = 'uninstall'; restartRequired = $RestartRequired; recoveryRequired = $RecoveryRequired; rollbackRestored = $RollbackRestored; message = $Message; issues = @($Issues); quarantinePath = $QuarantinePath }
}

function Get-PshUninstallScriptStatus {
    param([Parameter(Mandatory = $true)][string] $Path, [AllowNull()][string] $ExpectedSha256)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $null; Reason = 'script is missing' } }
    try {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $null; Reason = 'script is a reparse point' } }
        $hash = Get-PshUninstallHash -Path $Path
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $hash -cne $ExpectedSha256.ToLowerInvariant()) { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $false; Sha256 = $hash; Reason = 'script hash changed' } }
        return [pscustomobject][ordered]@{ Trusted = $true; RestartRequired = $false; Sha256 = $hash; Reason = 'script is verified' }
    }
    catch { return [pscustomobject][ordered]@{ Trusted = $false; RestartRequired = $true; Sha256 = $null; Reason = 'script could not be read' } }
}

function Get-PshUninstallCurrentObservation {
    param([Parameter(Mandatory = $true)][string] $Root)
    $observation = Get-PshRecoveryCurrentObservation -InstallRoot $Root
    if (-not [bool](Get-PshUninstallProperty $observation 'Available')) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("current.json could not be verified: {0}" -f [string](Get-PshUninstallProperty $observation 'Reason'))
    }
    if ([bool](Get-PshUninstallProperty $observation 'Exists')) {
        $version = [string](Get-PshUninstallProperty $observation 'Version')
        $expectedSha256 = Get-PshUninstallCanonicalCurrentSha256 -Version $version
        if ([string](Get-PshUninstallProperty $observation 'Sha256') -cne $expectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'current.json is valid JSON but is not the canonical Psh pointer byte image.'
        }
    }
    return $observation
}

function Preserve-PshUninstallRestoreConflict {
    param(
        [Parameter(Mandatory = $true)][string] $Original,
        [Parameter(Mandatory = $true)][string] $Quarantine
    )
    if (-not ([IO.File]::Exists($Original) -or [IO.Directory]::Exists($Original))) { return $null }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Quarantine))
    $evidence = Join-Path $parent ('.restore-conflict-{0}' -f ([Guid]::NewGuid().ToString('N')))
    try {
        if (-not ([IO.File]::Exists($evidence) -or [IO.Directory]::Exists($evidence))) {
            Move-Item -LiteralPath $Original -Destination $evidence
            return $evidence
        }
    }
    catch {}
    return $null
}

function Restore-PshUninstallMoves {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Moves)
    $errors = New-Object System.Collections.Generic.List[string]
    $integrityConflict = $false
    for ($index = $Moves.Count - 1; $index -ge 0; $index--) {
        $item = $Moves[$index]
        try {
            $originalExists = [IO.File]::Exists($item.Original) -or [IO.Directory]::Exists($item.Original)
            $quarantineExists = [IO.File]::Exists($item.Quarantine) -or [IO.Directory]::Exists($item.Quarantine)
            # Validate the isolated bytes before any user-visible path is
            # touched.  This also verifies every owned file in a version tree.
            Assert-PshUninstallQuarantineMove -Move $item
            if ([bool](Get-PshUninstallProperty $item 'Restored')) {
                if (-not $quarantineExists) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Quarantine item is missing during rollback.' }
                if (-not [IO.File]::Exists($item.Original)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Restored file is missing during rollback.' }
                # Detach the restored image through the same expected-byte CAS
                # used for metadata deletion.  A check followed by File.Delete
                # could delete a concurrently replaced user file.
                Remove-PshUninstallFileCas -Path ([string]$item.Original) -ExpectedSha256 ([string](Get-PshUninstallProperty $item 'RestoredSha256')) -Description 'restored user file'
                $originalExists = $false
            }
            if ($originalExists) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Original path was recreated during rollback.' }
            if ($quarantineExists) {
                # Recheck after any restored-file CAS operation; the initial
                # observation may be stale if another actor touched quarantine.
                $moveProbe = [pscustomobject][ordered]@{}
                foreach ($property in $item.PSObject.Properties) { $moveProbe | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
                $moveProbe.Restored = $false
                Assert-PshUninstallQuarantineMove -Move $moveProbe
                if ([IO.File]::Exists($item.Original) -or [IO.Directory]::Exists($item.Original)) {
                    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Original path was recreated immediately before rollback move.'
                }
                try { Move-Item -LiteralPath $item.Quarantine -Destination $item.Original }
                catch {
                    if ([IO.File]::Exists($item.Original) -or [IO.Directory]::Exists($item.Original) -or
                        -not ([IO.File]::Exists($item.Quarantine) -or [IO.Directory]::Exists($item.Quarantine))) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Rollback move lost its expected source/destination state; evidence was retained.'
                    }
                    throw
                }
                try {
                    if ([IO.File]::Exists($item.Quarantine) -or [IO.Directory]::Exists($item.Quarantine)) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Quarantine source remained after rollback move.'
                    }
                    $probe = [pscustomobject][ordered]@{}
                    foreach ($property in $item.PSObject.Properties) { $probe | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
                    $probe.Quarantine = [string]$item.Original
                    $probe.Restored = $false
                    Assert-PshUninstallQuarantineMove -Move $probe
                }
                catch {
                    # A concurrent replacement at the live path must never be
                    # accepted as restored package content.  Detach it to a
                    # unique evidence path when possible and retain the error.
                    if (-not ([IO.File]::Exists($item.Quarantine) -or [IO.Directory]::Exists($item.Quarantine))) {
                        $null = Preserve-PshUninstallRestoreConflict -Original ([string]$item.Original) -Quarantine ([string]$item.Quarantine)
                    }
                    throw
                }
            }
            elseif (-not $originalExists) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Quarantine item is missing during rollback.' }
        }
        catch {
            if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true }
            $errors.Add("$($item.Original): $($_.Exception.Message)")
        }
    }
    return [pscustomobject][ordered]@{ Success = ($errors.Count -eq 0); IntegrityConflict = $integrityConflict; Errors = $errors.ToArray() }
}

function Find-PshUninstallCompanionScript {
    param(
        [Parameter(Mandatory = $true)][string] $VersionRoot,
        [Parameter(Mandatory = $true)][object] $VersionEntry,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $path = Find-PshUninstallScript -VersionRoot $VersionRoot -Name $Name
    if ($null -eq $path) { return $null }
    if (-not (Test-PshUninstallWithinRoot -Path $path -Root $VersionRoot)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Component script escaped the owned version tree: $path"
    }
    $relative = Get-PshUninstallRelativePath -Root $VersionRoot -Path $path
    $expectedSha256 = $null
    foreach ($file in @((Get-PshUninstallProperty $VersionEntry 'files'))) {
        if ([string](Get-PshUninstallProperty $file 'relativePath') -ceq $relative) { $expectedSha256 = [string](Get-PshUninstallProperty $file 'sha256'); break }
    }
    if ([string]::IsNullOrWhiteSpace($expectedSha256)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Component script is not present in owned version metadata: $relative" }
    $status = Get-PshUninstallScriptStatus -Path $path -ExpectedSha256 $expectedSha256
    if (-not [bool](Get-PshUninstallProperty $status 'Trusted')) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Trusted Psh component script is unavailable: {0} ({1})" -f $path, [string](Get-PshUninstallProperty $status 'Reason'))
    }
    return [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($path); Sha256 = [string](Get-PshUninstallProperty $status 'Sha256') }
}

function Find-PshUninstallProjectionSource {
    param([Parameter(Mandatory = $true)][string] $VersionRoot)
    foreach ($candidate in @(
            (Join-Path $VersionRoot 'Psh/Dependencies/PSReadLine/2.4.5'),
            (Join-Path $VersionRoot 'Dependencies/PSReadLine/2.4.5'),
            (Join-Path $VersionRoot 'PSReadLine/2.4.5'))) {
        if ([IO.Directory]::Exists($candidate)) {
            Assert-PshUninstallSafePath -Root $VersionRoot -Path $candidate -Description 'PSReadLine projection source' | Out-Null
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Test-PshUninstallPathUnder {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    return Test-PshUninstallWithinRoot -Path $Path -Root $Root
}

function Get-PshUninstallRestorationScriptPath {
    param(
        [Parameter(Mandatory = $true)][string] $OriginalPath,
        [Parameter(Mandatory = $true)][string] $OriginalVersionRoot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]] $Moves
    )
    if (-not (Test-PshUninstallPathUnder -Path $OriginalPath -Root $OriginalVersionRoot)) { return $OriginalPath }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($move in $Moves) {
        if ([string]::Equals([string]$move.Original, [IO.Path]::GetFullPath($OriginalVersionRoot), $comparison)) {
            $relative = Get-PshUninstallRelativePath -Root $OriginalVersionRoot -Path $OriginalPath
            return Join-Path ([string]$move.Quarantine) ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
    }
    return $OriginalPath
}

function Assert-PshUninstallQuarantineMove {
    param([Parameter(Mandatory = $true)][object] $Move)
    $kind = [string](Get-PshUninstallProperty $Move 'Kind')
    $quarantinePath = [string](Get-PshUninstallProperty $Move 'Quarantine')
    if ($kind -ceq 'directory') {
        if (-not [IO.Directory]::Exists($quarantinePath) -or [IO.File]::Exists($quarantinePath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Quarantined directory is missing: $quarantinePath"
        }
        $tree = Test-PshUninstallVersionTree -VersionRoot $quarantinePath -VersionEntry (Get-PshUninstallProperty $Move 'Entry')
        if (-not [bool](Get-PshUninstallProperty $tree 'Exact')) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Quarantined owned version tree changed: $quarantinePath"
        }
    }
    else {
        if (-not [IO.File]::Exists($quarantinePath) -or [IO.Directory]::Exists($quarantinePath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Quarantined file is missing: $quarantinePath"
        }
        if (([IO.File]::GetAttributes($quarantinePath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Quarantined file is a reparse point: $quarantinePath"
        }
        $expectedSha256 = [string](Get-PshUninstallProperty $Move 'ExpectedSha256')
        if ((Get-PshUninstallHash -Path $quarantinePath) -cne $expectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Quarantined file changed: $quarantinePath"
        }
    }
    if ([bool](Get-PshUninstallProperty $Move 'Restored')) {
        $originalPath = [string](Get-PshUninstallProperty $Move 'Original')
        if (-not [IO.File]::Exists($originalPath) -or [IO.Directory]::Exists($originalPath) -or
            (Get-PshUninstallHash -Path $originalPath) -cne [string](Get-PshUninstallProperty $Move 'RestoredSha256')) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Restored user file changed during uninstall: $originalPath"
        }
    }
}

function Assert-PshUninstallQuarantineRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $ContentMoves,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $MetadataMoves
    )
    Assert-PshUninstallDirectoryPath -Root ([IO.Path]::GetDirectoryName($Root)) -Path $Root -Description 'Quarantine transaction root' | Out-Null
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' (Get-PshUninstallPathComparer)
    foreach ($move in @($ContentMoves.ToArray()) + @($MetadataMoves.ToArray())) {
        $path = [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $move 'Quarantine'))
        if (-not $expected.Add($path)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Duplicate quarantine destination: $path"
        }
        Assert-PshUninstallQuarantineMove -Move $move
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
        if (-not $expected.Contains([IO.Path]::GetFullPath($item.FullName))) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown content appeared in the uninstall quarantine: $($item.FullName)"
        }
    }
}

function Move-PshUninstallPathCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][ValidateSet('file', 'directory')][string] $Kind,
        [AllowNull()][string] $ExpectedSha256,
        [AllowNull()][object] $Entry,
        [Parameter(Mandatory = $true)][string] $Description,
        [AllowNull()][System.Collections.Generic.List[object]] $MoveList
    )
    if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description quarantine destination already exists: $Destination"
    }
    if ($Kind -ceq 'directory') {
        $tree = Test-PshUninstallVersionTree -VersionRoot $Path -VersionEntry $Entry
        if (-not [bool](Get-PshUninstallProperty $tree 'Exact')) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before quarantine."
        }
    }
    else {
        if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description disappeared before quarantine."
        }
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-PshUninstallHash -Path $Path) -cne $ExpectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before quarantine."
        }
    }
    Move-Item -LiteralPath $Path -Destination $Destination
    $move = [pscustomobject][ordered]@{
        Original = [IO.Path]::GetFullPath($Path)
        Quarantine = [IO.Path]::GetFullPath($Destination)
        Kind = $Kind
        Entry = $Entry
        ExpectedSha256 = $ExpectedSha256
        Restored = $false
        RestoredSha256 = $null
    }
    if ($null -ne $MoveList) { $MoveList.Add($move) }
    Assert-PshUninstallQuarantineMove -Move $move
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description remained at its live path after quarantine."
    }
    return $move
}

function Remove-PshUninstallFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description disappeared before CAS removal."
    }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-PshUninstallHash -Path $Path) -cne $ExpectedSha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before CAS removal."
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $recovery = Join-Path $parent ('.uninstall-{0}.recovery' -f ([Guid]::NewGuid().ToString('N')))
    $replacementTarget = [string]$env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH
    if (-not [string]::IsNullOrWhiteSpace($replacementTarget) -and
        [string]::Equals([IO.Path]::GetFullPath($replacementTarget), [IO.Path]::GetFullPath($Path), (Get-PshUninstallPathComparison))) {
        [IO.File]::WriteAllText($Path, "concurrent replacement`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_CAS_REPLACEMENT_PATH -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $Path -Destination $recovery
    try {
        if (-not [IO.File]::Exists($recovery) -or [IO.Directory]::Exists($recovery) -or
            ([IO.File]::GetAttributes($recovery) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-PshUninstallHash -Path $recovery) -cne $ExpectedSha256) {
            if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
                try { Move-Item -LiteralPath $recovery -Destination $Path } catch {}
            }
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed at the CAS removal point; recovery evidence was retained: $recovery"
        }
        if (-not [IO.File]::Exists($recovery) -or [IO.Directory]::Exists($recovery) -or
            ([IO.File]::GetAttributes($recovery) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-PshUninstallHash -Path $recovery) -cne $ExpectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed immediately before deletion; recovery evidence was retained: $recovery"
        }
        [IO.File]::Delete($recovery)
        if ([IO.File]::Exists($recovery) -or [IO.Directory]::Exists($recovery)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description deletion did not leave the recovery path absent: $recovery"
        }
    }
    catch {
        if ($_.Exception.Data['PshExitCode'] -eq 5) { throw }
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "$Description could not be removed: $($_.Exception.Message)"
    }
}

function Write-PshUninstallBytesAbsentCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [Parameter(Mandatory = $true)][string] $Description
    )
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared before expected-absent write."
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent ('.uninstall-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        try { [IO.File]::Move($temporary, $Path) }
        catch {
            if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description appeared at the atomic write point."
            }
            Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "$Description could not be written: $($_.Exception.Message)"
        }
        if (-not [IO.File]::Exists($Path) -or (Get-PshUninstallHash -Path $Path) -cne $ExpectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description did not retain its expected bytes."
        }
    }
    finally {
        if ([IO.File]::Exists($temporary) -or [IO.Directory]::Exists($temporary)) {
            Remove-PshUninstallFileCas -Path $temporary -ExpectedSha256 $ExpectedSha256 -Description "$Description temporary write artifact"
        }
    }
}

function Write-PshUninstallTransactionCas {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][object] $State)
    $validated = Assert-PshTransactionDocument -State $State
    $json = (ConvertTo-PshCanonicalJson -InputObject $validated) + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [byte[]]$bytes = $encoding.GetBytes($json)
    $sha256 = Get-PshUninstallBytesHash -Bytes $bytes
    Write-PshUninstallBytesAbsentCas -Path (Join-Path $Root 'transaction.json') -Bytes $bytes -ExpectedSha256 $sha256 -Description 'transaction journal'
    return $sha256
}

function Write-PshUninstallRestoredFileCas {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description
    )
    $sha256 = Get-PshUninstallBytesHash -Bytes $Bytes
    Write-PshUninstallBytesAbsentCas -Path $Path -Bytes $Bytes -ExpectedSha256 $sha256 -Description $Description
    return $sha256
}

function Remove-PshUninstallOwnedTreeCas {
    param([Parameter(Mandatory = $true)][object] $Move)
    Assert-PshUninstallQuarantineMove -Move $Move
    $root = [string](Get-PshUninstallProperty $Move 'Quarantine')
    $entry = Get-PshUninstallProperty $Move 'Entry'
    $expectedFiles = New-Object 'System.Collections.Generic.Dictionary[string,object]' (Get-PshUninstallPathComparer)
    $expectedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' (Get-PshUninstallPathComparer)
    foreach ($file in @((Get-PshUninstallProperty $entry 'files'))) {
        $relative = [string](Get-PshUninstallProperty $file 'relativePath')
        $path = [IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        $expectedFiles[$path] = $file
        $parent = [IO.Path]::GetDirectoryName($path)
        while (-not [string]::Equals($parent, [IO.Path]::GetFullPath($root), (Get-PshUninstallPathComparison))) {
            $null = $expectedDirectories.Add($parent)
            $next = [IO.Path]::GetDirectoryName($parent)
            if ([string]::IsNullOrWhiteSpace($next) -or [string]::Equals($next, $parent, (Get-PshUninstallPathComparison))) { break }
            $parent = $next
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        $full = [IO.Path]::GetFullPath($item.FullName)
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Reparse content appeared during quarantine cleanup: $full"
        }
        if ($item.PSIsContainer) {
            if (-not $expectedDirectories.Contains($full)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown directory appeared during quarantine cleanup: $full" }
        }
        elseif (-not $expectedFiles.ContainsKey($full)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown file appeared during quarantine cleanup: $full"
        }
    }
    foreach ($path in @($expectedFiles.Keys)) {
        $file = $expectedFiles[$path]
        $expectedSha256 = [string](Get-PshUninstallProperty $file 'sha256')
        if (-not [IO.File]::Exists($path) -or (Get-PshUninstallHash -Path $path) -cne $expectedSha256) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned quarantine file changed before cleanup: $path"
        }
        $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.cleanup-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        Move-Item -LiteralPath $path -Destination $temporary
        if ((Get-PshUninstallHash -Path $temporary) -cne $expectedSha256 -or [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned quarantine file changed at the cleanup point: $path"
        }
        Remove-PshUninstallFileCas -Path $temporary -ExpectedSha256 $expectedSha256 -Description "owned quarantine file $path"
    }
    $directories = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -ne 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown content remained in quarantine directory: $($directory.FullName)"
        }
        [IO.Directory]::Delete($directory.FullName, $false)
    }
    if (@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown content remained in quarantined version tree: $root"
    }
    [IO.Directory]::Delete($root, $false)
}

function Remove-PshUninstallQuarantineMoveCas {
    param([Parameter(Mandatory = $true)][object] $Move)
    Assert-PshUninstallQuarantineMove -Move $Move
    $source = [string](Get-PshUninstallProperty $Move 'Quarantine')
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($source)) ('.cleanup-{0}' -f ([Guid]::NewGuid().ToString('N')))
    if ([string](Get-PshUninstallProperty $Move 'Kind') -ceq 'directory') {
        Remove-PshUninstallOwnedTreeCas -Move $Move
        return
    }
    Move-Item -LiteralPath $source -Destination $temporary
    $probe = [pscustomobject][ordered]@{}
    foreach ($property in $Move.PSObject.Properties) { $probe | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    $probe.Quarantine = $temporary
    try {
        Assert-PshUninstallQuarantineMove -Move $probe
        Remove-PshUninstallFileCas -Path $temporary -ExpectedSha256 ([string](Get-PshUninstallProperty $Move 'ExpectedSha256')) -Description 'quarantined owned file'
    }
    catch {
        if (([IO.File]::Exists($temporary) -or [IO.Directory]::Exists($temporary)) -and -not ([IO.File]::Exists($source) -or [IO.Directory]::Exists($source))) {
            try { Move-Item -LiteralPath $temporary -Destination $source } catch {}
        }
        throw
    }
}

function Move-PshUninstallTransactionMarkerLast {
    param(
        [Parameter(Mandatory = $true)][object] $Move,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )
    Assert-PshUninstallQuarantineMove -Move $Move
    $source = [string](Get-PshUninstallProperty $Move 'Quarantine')
    $destination = [string](Get-PshUninstallProperty $Move 'Original')
    if ([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Transaction marker destination already exists: $destination"
    }
    if ((Get-PshUninstallHash -Path $source) -cne $ExpectedSha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Transaction marker changed before final recovery move: $source"
    }
    Move-Item -LiteralPath $source -Destination $destination
    if ([IO.File]::Exists($source) -or [IO.Directory]::Exists($source) -or
        -not [IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination) -or
        (Get-PshUninstallHash -Path $destination) -cne $ExpectedSha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Transaction marker failed post-move verification; recovery evidence was retained.'
    }
}

function Get-PshUninstallProfileManifestObservation {
    param([Parameter(Mandatory = $true)][string] $StateRoot)
    $stateRootObservation = Get-PshUninstallPathAttributesObservation -Path $StateRoot -Description 'profile state root'
    if ([bool]$stateRootObservation.Exists -and
        ([IO.FileAttributes]$stateRootObservation.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile state root is a reparse point: $StateRoot"
    }
    if ([bool]$stateRootObservation.Exists -and
        ([IO.FileAttributes]$stateRootObservation.Attributes -band [IO.FileAttributes]::Directory) -eq 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile state root is a file: $StateRoot"
    }
    $path = Join-Path $StateRoot 'manifest.json'
    if ([IO.Directory]::Exists($path)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile manifest path is a directory: $path"
    }
    if (-not [IO.File]::Exists($path)) {
        return [pscustomobject][ordered]@{ Exists = $false; Path = $path; Bytes = New-Object byte[] 0; Sha256 = $null }
    }
    if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile manifest is a reparse point: $path"
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
    $sha256 = Get-PshUninstallBytesHash -Bytes $bytes
    if (-not [IO.File]::Exists($path) -or [IO.Directory]::Exists($path) -or
        ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-PshUninstallHash -Path $path) -cne $sha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile manifest changed during exact-byte observation.'
    }
    return [pscustomobject][ordered]@{ Exists = $true; Path = $path; Bytes = $bytes; Sha256 = $sha256 }
}

function Get-PshUninstallProfileTargetObservation {
    param([Parameter(Mandatory = $true)][string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Directory]::Exists($fullPath)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile target path is a directory: $fullPath"
    }
    if (-not [IO.File]::Exists($fullPath)) {
        return [pscustomobject][ordered]@{ Path = $fullPath; Exists = $false; Bytes = New-Object byte[] 0; Sha256 = $null }
    }
    if (([IO.File]::GetAttributes($fullPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile target is a reparse point: $fullPath"
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    $sha256 = Get-PshUninstallBytesHash -Bytes $bytes
    if (-not [IO.File]::Exists($fullPath) -or [IO.Directory]::Exists($fullPath) -or
        ([IO.File]::GetAttributes($fullPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-PshUninstallHash -Path $fullPath) -cne $sha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Profile target changed during exact-byte observation: $fullPath"
    }
    return [pscustomobject][ordered]@{ Path = $fullPath; Exists = $true; Bytes = $bytes; Sha256 = $sha256 }
}

function Get-PshUninstallProfileTargetObservations {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Targets)
    $observations = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) { $observations.Add((Get-PshUninstallProfileTargetObservation -Path $target)) }
    return $observations.ToArray()
}

function Test-PshUninstallProfileTargetObservations {
    param([AllowNull()][object[]] $Expected)
    if ($null -eq $Expected) { return $false }
    foreach ($item in @($Expected)) {
        $actual = Get-PshUninstallProfileTargetObservation -Path ([string](Get-PshUninstallProperty $item 'Path'))
        if ([bool](Get-PshUninstallProperty $actual 'Exists') -ne [bool](Get-PshUninstallProperty $item 'Exists')) { return $false }
        if ([bool](Get-PshUninstallProperty $item 'Exists') -and
            [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $actual 'Bytes')) -cne [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $item 'Bytes'))) { return $false }
    }
    return $true
}

function Test-PshUninstallProfileObservationEqual {
    param(
        [Parameter(Mandatory = $true)][object] $Left,
        [Parameter(Mandatory = $true)][object] $Right
    )
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Left 'Path')),
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Right 'Path')),
        (Get-PshUninstallPathComparison))) { return $false }
    $leftExists = [bool](Get-PshUninstallProperty $Left 'Exists')
    if ($leftExists -ne [bool](Get-PshUninstallProperty $Right 'Exists')) { return $false }
    if (-not $leftExists) { return $true }
    return [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $Left 'Bytes')) -ceq
        [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $Right 'Bytes'))
}

function Get-PshUninstallProfileChildStateContract {
    param(
        [Parameter(Mandatory = $true)][object] $Child,
        [Parameter(Mandatory = $true)][string] $HelperPath
    )
    $preManifestBytes = [byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes')
    $preTargets = @($Child.PreUninstallTargetObservations)
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $HelperPath
    try {
        $contract = & $module {
            param($StateRoot, $ExpectedManifestBytes, $TargetObservations)
            $manifest = Read-PshProfileManifest -StateRoot $StateRoot
            if (-not [bool]$manifest.Exists -or
                [Convert]::ToBase64String([byte[]]$manifest.Bytes) -cne [Convert]::ToBase64String([byte[]]$ExpectedManifestBytes)) {
                throw 'Profile manifest changed before expected post-state derivation.'
            }
            $targetIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $postTargets = New-Object System.Collections.Generic.List[object]
            foreach ($observation in @($TargetObservations)) {
                $path = [string]$observation.Path
                [byte[]]$preBytes = [byte[]]$observation.Bytes
                $textInfo = Get-PshProfileTextInfo -Bytes $preBytes -Path $path
                $markerState = Get-PshProfileMarkerState -Text $textInfo.Text -Path $path
                $profileId = Get-PshProfileId -ProfilePath $path
                $null = $targetIds.Add($profileId)
                $entry = Find-PshManifestEntry -Entries @($manifest.Entries) -ProfileId $profileId
                $exists = [bool]$observation.Exists
                [byte[]]$postBytes = $preBytes
                if ($markerState.Present) {
                    if ($null -eq $entry) { throw "Managed profile block has no trusted manifest entry: $path" }
                    if ((Get-PshSha256Hex -Bytes $preBytes) -ceq [string]$entry.installedSha256) {
                        if ([bool]$entry.originalExisted) {
                            if (-not $manifest.BackupBytesById.ContainsKey($entry.profileId)) { throw "Trusted profile backup is missing: $path" }
                            $postBytes = [byte[]]$manifest.BackupBytesById[$entry.profileId]
                            $exists = $true
                        }
                        else {
                            $postBytes = New-Object byte[] 0
                            $exists = $false
                        }
                    }
                    else {
                        $postBytes = Remove-PshProfileBlockByte -TextInfo $textInfo -MarkerState $markerState
                        $exists = $true
                    }
                }
                $postTargets.Add([pscustomobject][ordered]@{ Path = $path; Exists = $exists; Bytes = $postBytes; Sha256 = Get-PshSha256Hex -Bytes $postBytes })
            }

            $preBackups = New-Object System.Collections.Generic.List[object]
            $postBackups = New-Object System.Collections.Generic.List[object]
            $remainingEntries = New-Object System.Collections.Generic.List[object]
            foreach ($entry in @($manifest.Entries)) {
                if (-not $manifest.BackupBytesById.ContainsKey($entry.profileId)) { throw "Trusted profile backup is missing: $($entry.profilePath)" }
                [byte[]]$backupBytes = [byte[]]$manifest.BackupBytesById[$entry.profileId]
                $backupPath = Join-Path $manifest.BackupRoot ([string]$entry.backupFileName)
                $preBackups.Add([pscustomobject][ordered]@{ Path = $backupPath; Exists = $true; Bytes = $backupBytes; Sha256 = Get-PshSha256Hex -Bytes $backupBytes })
                if ($targetIds.Contains([string]$entry.profileId)) {
                    $postBackups.Add([pscustomobject][ordered]@{ Path = $backupPath; Exists = $false; Bytes = New-Object byte[] 0; Sha256 = $null })
                }
                else {
                    $remainingEntries.Add($entry)
                    $postBackups.Add([pscustomobject][ordered]@{ Path = $backupPath; Exists = $true; Bytes = $backupBytes; Sha256 = Get-PshSha256Hex -Bytes $backupBytes })
                }
            }
            if ($remainingEntries.Count -ne 0) {
                throw 'Full package uninstall would leave one or more trusted profile entries managed.'
            }
            [byte[]]$postManifestBytes = ConvertTo-PshProfileManifestByte -Entries $remainingEntries.ToArray()
            return [pscustomobject][ordered]@{
                PostManifestBytes = $postManifestBytes
                PostManifestSha256 = Get-PshSha256Hex -Bytes $postManifestBytes
                PostTargetObservations = $postTargets.ToArray()
                PreBackupObservations = $preBackups.ToArray()
                PostBackupObservations = $postBackups.ToArray()
            }
        } ([string](Get-PshUninstallProperty $Child 'StateRoot')) $preManifestBytes $preTargets
        return $contract
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to derive exact profile post-state: {0}" -f $_.Exception.Message)
    }
    finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
}

function Assert-PshUninstallProfileTargetsCoverManifest {
    param(
        [Parameter(Mandatory = $true)][string] $StateRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Targets,
        [Parameter(Mandatory = $true)][string] $HelperPath
    )
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $HelperPath
    try {
        & $module {
            param($ProfileStateRoot, $RequestedTargets)
            $manifest = Read-PshProfileManifest -StateRoot $ProfileStateRoot
            $manifestIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($entry in @($manifest.Entries)) { $null = $manifestIds.Add([string]$entry.profileId) }
            $requestedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($target in @($RequestedTargets)) {
                if (-not $requestedIds.Add((Get-PshProfileId -ProfilePath ([string]$target)))) {
                    throw 'Requested profile targets contain a duplicate normalized path.'
                }
            }
            foreach ($profileId in $manifestIds) {
                if (-not $requestedIds.Contains($profileId)) { throw 'Requested profile targets omit a trusted managed profile.' }
            }
        } $StateRoot $Targets
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Profile uninstall target coverage is unsafe: {0}" -f $_.Exception.Message)
    }
    finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
}

function Enter-PshUninstallProfileStateLock {
    param(
        [Parameter(Mandatory = $true)][string] $StateRoot,
        [Parameter(Mandatory = $true)][string] $HelperPath
    )
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $HelperPath
    try {
        $inner = & $module { param($ProfileStateRoot) Enter-PshProfileTransactionLock -StateRoot $ProfileStateRoot } $StateRoot
        return [pscustomobject][ordered]@{ Module = $module; Inner = $inner }
    }
    catch {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message ("Unable to acquire the profile transaction lock: {0}" -f $_.Exception.Message)
    }
}

function Exit-PshUninstallProfileStateLock {
    param([AllowNull()][object] $Lock)
    if ($null -eq $Lock) { return }
    try { & $Lock.Module { param($InnerLock) Exit-PshProfileTransactionLock -Lock $InnerLock } $Lock.Inner }
    finally { Remove-Module $Lock.Module -Force -ErrorAction SilentlyContinue }
}

function Enter-PshUninstallProjectionStateLock {
    param(
        [Parameter(Mandatory = $true)][string] $StateRoot,
        [Parameter(Mandatory = $true)][string] $HelperPath
    )
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $HelperPath
    try {
        $inner = & $module { param($ProjectionStateRoot) Enter-PshPSReadLineProjectionLock -StateRoot $ProjectionStateRoot } $StateRoot
        return [pscustomobject][ordered]@{ Module = $module; Inner = $inner }
    }
    catch {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message ("Unable to acquire the PSReadLine projection transaction lock: {0}" -f $_.Exception.Message)
    }
}

function Exit-PshUninstallProjectionStateLock {
    param([AllowNull()][object] $Lock)
    if ($null -eq $Lock) { return }
    try { & $Lock.Module { param($InnerLock) Exit-PshPSReadLineProjectionLock -Lock $InnerLock } $Lock.Inner }
    finally { Remove-Module $Lock.Module -Force -ErrorAction SilentlyContinue }
}

function Get-PshUninstallProjectionChildStateContract {
    param(
        [Parameter(Mandatory = $true)][object] $Child,
        [Parameter(Mandatory = $true)][string] $HelperPath
    )
    $module = New-Module -ScriptBlock { param($Path) . $Path } -ArgumentList $HelperPath
    try {
        return & $module {
            param($StateRoot, $ModuleRoots, $SourcePath)
            $manifest = Read-PshPSReadLineProjectionManifest -StateRoot $StateRoot
            if (-not [bool]$manifest.Exists -or [string]$manifest.State -cne 'complete' -or [string]$manifest.Operation -cne 'install') {
                throw 'Projection state is not a complete trusted install manifest.'
            }
            if (-not (Test-PshPSReadLineProjectionTargetSetEqual -ModuleRoots @($ModuleRoots) -Targets @($manifest.Targets))) {
                throw 'Requested projection module roots differ from the trusted manifest.'
            }
            $source = Resolve-PshPSReadLineProjectionSource -SourcePath $SourcePath
            if ([string]$manifest.Fingerprint.TreeSha256 -cne [string]$source.Fingerprint.TreeSha256) {
                throw 'Projection source fingerprint differs from the trusted manifest.'
            }

            $preTargets = New-Object System.Collections.Generic.List[object]
            $postTargets = New-Object System.Collections.Generic.List[object]
            foreach ($entry in @($manifest.Targets)) {
                $state = Get-PshPSReadLineProjectionTargetState -ModuleRoot ([string]$entry.ModuleRoot)
                if (-not [bool]$state.Exists -or
                    -not (Test-PshPSReadLineProjectionPathEqual -Left ([string]$state.TargetPath) -Right ([string]$entry.TargetPath)) -or
                    [string]$state.Fingerprint.TreeSha256 -cne [string]$manifest.Fingerprint.TreeSha256) {
                    throw "A projection target differs from its trusted pre-child state: $($entry.TargetPath)"
                }
                $preTargets.Add([pscustomobject][ordered]@{
                    ModuleRoot = [string]$entry.ModuleRoot
                    ContainerPath = [string]$state.ContainerPath
                    TargetPath = [string]$entry.TargetPath
                    Disposition = [string]$entry.Disposition
                    CreatedParentPaths = @($entry.CreatedParentPaths)
                    Exists = $true
                    TreeSha256 = [string]$state.Fingerprint.TreeSha256
                })
                $postExists = [string]$entry.Disposition -ceq 'reused'
                $postTargets.Add([pscustomobject][ordered]@{
                    ModuleRoot = [string]$entry.ModuleRoot
                    ContainerPath = [string]$state.ContainerPath
                    TargetPath = [string]$entry.TargetPath
                    Disposition = [string]$entry.Disposition
                    CreatedParentPaths = @($entry.CreatedParentPaths)
                    Exists = $postExists
                    TreeSha256 = if ($postExists) { [string]$state.Fingerprint.TreeSha256 } else { $null }
                })
            }
            return [pscustomobject][ordered]@{
                PreManifestBytes = [byte[]]$manifest.Bytes
                PreManifestSha256 = Get-PshSha256Hex -Bytes ([byte[]]$manifest.Bytes)
                SourceTreeSha256 = [string]$source.Fingerprint.TreeSha256
                PreTargetObservations = $preTargets.ToArray()
                PostTargetObservations = $postTargets.ToArray()
            }
        } ([string](Get-PshUninstallProperty $Child 'StateRoot')) @($Child.Targets) ([string](Get-PshUninstallProperty $Child 'SourcePath'))
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to derive exact PSReadLine projection state: {0}" -f $_.Exception.Message)
    }
    finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
}

function Get-PshUninstallProjectionTargetObservation {
    param(
        [Parameter(Mandatory = $true)][string] $ModuleRoot,
        [Parameter(Mandatory = $true)][object] $Lock
    )
    try {
        return & $Lock.Module {
            param($Root)
            $state = Get-PshPSReadLineProjectionTargetState -ModuleRoot $Root
            return [pscustomobject][ordered]@{
                ModuleRoot = [string]$state.ModuleRoot
                ContainerPath = [string]$state.ContainerPath
                TargetPath = [string]$state.TargetPath
                Exists = [bool]$state.Exists
                TreeSha256 = if ([bool]$state.Exists) { [string]$state.Fingerprint.TreeSha256 } else { $null }
            }
        } $ModuleRoot
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to observe exact PSReadLine projection target state: {0}" -f $_.Exception.Message)
    }
}

function Test-PshUninstallProjectionTargetObservationEqual {
    param(
        [Parameter(Mandatory = $true)][object] $Left,
        [Parameter(Mandatory = $true)][object] $Right
    )
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Left 'ModuleRoot')),
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Right 'ModuleRoot')),
        (Get-PshUninstallPathComparison))) { return $false }
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Left 'TargetPath')),
        [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $Right 'TargetPath')),
        (Get-PshUninstallPathComparison))) { return $false }
    $leftExists = [bool](Get-PshUninstallProperty $Left 'Exists')
    if ($leftExists -ne [bool](Get-PshUninstallProperty $Right 'Exists')) { return $false }
    return -not $leftExists -or [string](Get-PshUninstallProperty $Left 'TreeSha256') -ceq [string](Get-PshUninstallProperty $Right 'TreeSha256')
}

function Test-PshUninstallProjectionTargetObservations {
    param(
        [Parameter(Mandatory = $true)][object[]] $Expected,
        [Parameter(Mandatory = $true)][object] $Lock
    )
    foreach ($item in @($Expected)) {
        $actual = Get-PshUninstallProjectionTargetObservation -ModuleRoot ([string](Get-PshUninstallProperty $item 'ModuleRoot')) -Lock $Lock
        if (-not (Test-PshUninstallProjectionTargetObservationEqual -Left $actual -Right $item)) { return $false }
    }
    return $true
}

function Test-PshUninstallProjectionCreatedParentsAbsent {
    param([Parameter(Mandatory = $true)][object[]] $Expected)
    foreach ($item in @($Expected)) {
        if ([string](Get-PshUninstallProperty $item 'Disposition') -cne 'created') { continue }
        foreach ($path in @((Get-PshUninstallProperty $item 'CreatedParentPaths'))) {
            $observation = Get-PshUninstallPathAttributesObservation -Path ([string]$path) -Description 'projection created parent'
            if (-not [bool]$observation.Exists) { continue }
            if (([IO.FileAttributes]$observation.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Projection created parent is a reparse point: $path"
            }
            return $false
        }
    }
    return $true
}

function Get-PshUninstallProjectionRestoreMode {
    param(
        [Parameter(Mandatory = $true)][object] $Child,
        [Parameter(Mandatory = $true)][object] $Lock
    )
    $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
    $stateRootObservation = Get-PshUninstallPathAttributesObservation -Path $stateRoot -Description 'projection state root'
    if ([bool]$stateRootObservation.Exists -and
        ([IO.FileAttributes]$stateRootObservation.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state root was replaced by a reparse point.'
    }
    if ([bool]$stateRootObservation.Exists -and
        ([IO.FileAttributes]$stateRootObservation.Attributes -band [IO.FileAttributes]::Directory) -eq 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state root was replaced by a file.'
    }
    try {
        $manifest = & $Lock.Module { param($StateRoot) Read-PshPSReadLineProjectionManifest -StateRoot $StateRoot } $stateRoot
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Projection manifest/state root is not safely observable: {0}" -f $_.Exception.Message)
    }
    [byte[]]$preBytes = [byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes')
    if ([bool](Get-PshUninstallProperty $manifest 'Exists') -and
        [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $manifest 'Bytes')) -ceq [Convert]::ToBase64String($preBytes)) {
        if (Test-PshUninstallProjectionTargetObservations -Expected @($Child.PreUninstallTargetObservations) -Lock $Lock) { return 'Pre' }
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection manifest returned to its pre-child bytes, but one or more targets did not.'
    }
    if (-not [bool](Get-PshUninstallProperty $manifest 'Exists')) {
        if ([bool]$stateRootObservation.Exists) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection manifest is absent, but the projection state root remains.'
        }
        if (-not (Test-PshUninstallProjectionTargetObservations -Expected @($Child.PostUninstallTargetObservations) -Lock $Lock)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection manifest is absent, but one or more targets differ from the exact post-child state.'
        }
        if (-not (Test-PshUninstallProjectionCreatedParentsAbsent -Expected @($Child.PostUninstallTargetObservations))) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection manifest and targets match Post, but a transaction-created parent remains.'
        }
        return 'Post'
    }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state matches neither the exact pre-child nor post-child image.'
}

function Restore-PshUninstallProjectionChildExact {
    param(
        [Parameter(Mandatory = $true)][object] $Child,
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][string] $SourcePath
    )
    $mode = Get-PshUninstallProjectionRestoreMode -Child $Child -Lock $Lock
    if ($mode -ceq 'Pre') { return }
    if ($mode -cne 'Post') {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection rollback requires an exact pre-child or post-child state.'
    }

    try {
        $sourceFingerprint = & $Lock.Module {
            param($Path, $ExpectedTreeSha256)
            $fingerprint = Get-PshPSReadLineProjectionTreeFingerprint -Root $Path -Description 'PSReadLine projection rollback source'
            if ([string]$fingerprint.TreeSha256 -cne $ExpectedTreeSha256) { throw 'Projection rollback source fingerprint changed.' }
            return $fingerprint
        } $SourcePath ([string](Get-PshUninstallProperty $Child 'SourceTreeSha256'))
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Projection rollback source is not trusted: {0}" -f $_.Exception.Message)
    }

    $completedTargets = New-Object System.Collections.Generic.List[object]
    $attemptedCreatedParentPaths = New-Object System.Collections.Generic.List[string]
    $currentTarget = $null
    $manifestWritten = $false
    $stateRootCreated = $false
    $rebuiltTargetCount = 0
    $restoreFailure = $null
    try {
        $preTargets = @($Child.PreUninstallTargetObservations)
        $postTargets = @($Child.PostUninstallTargetObservations)
        if ($preTargets.Count -ne $postTargets.Count) { throw 'Projection target restore contract cardinality changed.' }
        for ($index = 0; $index -lt $preTargets.Count; $index++) {
            $pre = $preTargets[$index]
            $post = $postTargets[$index]
            if (Test-PshUninstallProjectionTargetObservationEqual -Left $pre -Right $post) { continue }
            if (-not [bool](Get-PshUninstallProperty $pre 'Exists') -or [bool](Get-PshUninstallProperty $post 'Exists')) {
                throw 'Projection restore contract contains an unsupported target transition.'
            }
            $currentTarget = $pre
            foreach ($createdParentPath in @((Get-PshUninstallProperty $pre 'CreatedParentPaths'))) {
                $attemptedCreatedParentPaths.Add([string]$createdParentPath)
            }
            $injectPrecommitFailure = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE -ceq '1'
            if ($injectPrecommitFailure) {
                Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PRECOMMIT_FAILURE -ErrorAction SilentlyContinue
            }
            & $Lock.Module {
                param($Observation, $Fingerprint, $InjectPrecommitFailure)
                $plan = [pscustomobject][ordered]@{
                    ModuleRoot = [string]$Observation.ModuleRoot
                    ContainerPath = [string]$Observation.ContainerPath
                    TargetPath = [string]$Observation.TargetPath
                    Disposition = [string]$Observation.Disposition
                    CreatedParentPaths = @($Observation.CreatedParentPaths)
                }
                if ($InjectPrecommitFailure) {
                    [IO.Directory]::CreateDirectory([string]$plan.ModuleRoot) | Out-Null
                    [IO.Directory]::CreateDirectory([string]$plan.ContainerPath) | Out-Null
                    throw 'Injected projection restore failure before target commit.'
                }
                $null = New-PshPSReadLineProjectionTarget -Plan $plan -SourceFingerprint $Fingerprint
            } $pre $sourceFingerprint $injectPrecommitFailure
            $actual = Get-PshUninstallProjectionTargetObservation -ModuleRoot ([string](Get-PshUninstallProperty $pre 'ModuleRoot')) -Lock $Lock
            if (-not (Test-PshUninstallProjectionTargetObservationEqual -Left $actual -Right $pre)) { throw 'Rebuilt projection target did not retain its exact trusted tree.' }
            $rebuiltTargetCount++
            if ([string]$env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE -ceq [string]$rebuiltTargetCount) {
                Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Injected projection restore observation failure after target $rebuiltTargetCount."
            }
            $completedTargets.Add($pre)
            $currentTarget = $null
        }

        $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
        if (-not [IO.Directory]::Exists($stateRoot)) {
            if ([IO.File]::Exists($stateRoot)) { throw 'Projection state root became a file before manifest restore.' }
            [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
            $stateRootCreated = $true
        }
        & $Lock.Module {
            param($Root)
            Assert-PshNotReparsePoint -Path $Root -Description 'The projection rollback state root'
            Assert-PshPSReadLineProjectionStateRootClean -StateRoot $Root
        } $stateRoot
        $manifestPath = Join-Path $stateRoot 'manifest.json'
        Write-PshUninstallBytesAbsentCas -Path $manifestPath -Bytes ([byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes')) -ExpectedSha256 ([string](Get-PshUninstallProperty $Child 'PreUninstallManifestSha256')) -Description 'projection manifest rollback'
        $manifestWritten = $true
        if ((Get-PshUninstallProjectionRestoreMode -Child $Child -Lock $Lock) -cne 'Pre') { throw 'Exact projection compensation did not reach the pre-child state.' }
        return
    }
    catch { $restoreFailure = $_ }

    $compensationErrors = New-Object System.Collections.Generic.List[string]
    if ($null -ne $currentTarget) {
        try {
            $actual = Get-PshUninstallProjectionTargetObservation -ModuleRoot ([string](Get-PshUninstallProperty $currentTarget 'ModuleRoot')) -Lock $Lock
            $postTarget = @($Child.PostUninstallTargetObservations | Where-Object {
                [string]::Equals([string](Get-PshUninstallProperty $_ 'ModuleRoot'), [string](Get-PshUninstallProperty $currentTarget 'ModuleRoot'), (Get-PshUninstallPathComparison))
            })[0]
            if (Test-PshUninstallProjectionTargetObservationEqual -Left $actual -Right $currentTarget) { $completedTargets.Add($currentTarget) }
            elseif (-not (Test-PshUninstallProjectionTargetObservationEqual -Left $actual -Right $postTarget)) { $compensationErrors.Add('A projection target reached neither its exact pre-child nor post-child state.') }
        }
        catch { $compensationErrors.Add("Projection target transition outcome could not be classified: $($_.Exception.Message)") }
    }
    if (-not $manifestWritten) {
        try {
            $manifest = & $Lock.Module { param($Root) Read-PshPSReadLineProjectionManifest -StateRoot $Root } ([string](Get-PshUninstallProperty $Child 'StateRoot'))
            if ([bool]$manifest.Exists -and
                [Convert]::ToBase64String([byte[]]$manifest.Bytes) -ceq [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes'))) {
                $manifestWritten = $true
            }
            elseif ([bool]$manifest.Exists) { $compensationErrors.Add('Projection manifest reached an unexpected byte image during exact restore.') }
        }
        catch { $compensationErrors.Add("Projection manifest transition outcome could not be classified: $($_.Exception.Message)") }
    }
    if ($manifestWritten) {
        try {
            Remove-PshUninstallFileCas -Path (Join-Path ([string](Get-PshUninstallProperty $Child 'StateRoot')) 'manifest.json') -ExpectedSha256 ([string](Get-PshUninstallProperty $Child 'PreUninstallManifestSha256')) -Description 'projection manifest restore compensation'
        }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    for ($index = $completedTargets.Count - 1; $index -ge 0; $index--) {
        $target = $completedTargets[$index]
        try {
            & $Lock.Module {
                param($Observation)
                $state = Get-PshPSReadLineProjectionTargetState -ModuleRoot ([string]$Observation.ModuleRoot)
                if (-not [bool]$state.Exists -or [string]$state.Fingerprint.TreeSha256 -cne [string]$Observation.TreeSha256) {
                    throw 'Projection target changed before restore compensation.'
                }
                $quarantine = Move-PshPSReadLineProjectionToQuarantine -TargetPath ([string]$Observation.TargetPath)
                Remove-PshPSReadLineProjectionExactTree -Path $quarantine
                $post = Get-PshPSReadLineProjectionTargetState -ModuleRoot ([string]$Observation.ModuleRoot)
                if ([bool]$post.Exists) { throw 'Projection target remained after restore compensation.' }
            } $target
        }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    $createdParentPaths = @($attemptedCreatedParentPaths.ToArray())
    if ([string]$env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT -ceq '1') {
        Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_RESTORE_PARENT_CONFLICT -ErrorAction SilentlyContinue
        $conflictParents = @($createdParentPaths | Sort-Object -Property Length)
        if ($conflictParents.Count -eq 0) {
            $compensationErrors.Add('Projection parent-conflict injection found no transaction-created parent.')
        }
        else {
            try {
                [IO.Directory]::CreateDirectory([string]$conflictParents[0]) | Out-Null
                [IO.File]::WriteAllText((Join-Path ([string]$conflictParents[0]) 'concurrent-parent.bin'), "projection concurrent parent content`n", (New-Object System.Text.UTF8Encoding($false)))
            }
            catch { $compensationErrors.Add("Projection parent-conflict injection failed: $($_.Exception.Message)") }
        }
    }
    try { & $Lock.Module { param($Paths) Remove-PshPSReadLineProjectionEmptyParent -Paths @($Paths) } $createdParentPaths }
    catch { $compensationErrors.Add("Projection parent cleanup failed: $($_.Exception.Message)") }
    if ($stateRootCreated) {
        try { & $Lock.Module { param($Root) Remove-PshPSReadLineProjectionEmptyParent -Paths @($Root) } ([string](Get-PshUninstallProperty $Child 'StateRoot')) }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    if ($compensationErrors.Count -eq 0) {
        try {
            if ((Get-PshUninstallProjectionRestoreMode -Child $Child -Lock $Lock) -cne 'Post') { throw 'Projection state did not return to its exact post-child image.' }
        }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    $suffix = if ($compensationErrors.Count -eq 0) { 'All completed projection restore writes were compensated to exact Post.' } else { 'Restore compensation errors: ' + [string]::Join('; ', $compensationErrors.ToArray()) }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Exact projection rollback failed: {0} {1}" -f $restoreFailure.Exception.Message, $suffix)
}

function Get-PshUninstallProfileRestoreMode {
    param([Parameter(Mandatory = $true)][object] $Child)
    $observation = Get-PshUninstallProfileManifestObservation -StateRoot ([string](Get-PshUninstallProperty $Child 'StateRoot'))
    $preExists = [bool](Get-PshUninstallProperty $Child 'PreUninstallManifestExists')
    [byte[]]$preBytes = [byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes')
    [byte[]]$postBytes = [byte[]](Get-PshUninstallProperty $Child 'PostUninstallManifestBytes')
    if ([bool](Get-PshUninstallProperty $observation 'Exists') -eq $preExists) {
        if (-not $preExists -or [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $observation 'Bytes')) -ceq [Convert]::ToBase64String($preBytes)) {
            if ((Test-PshUninstallProfileTargetObservations -Expected @($Child.PreUninstallTargetObservations)) -and
                (Test-PshUninstallProfileTargetObservations -Expected @($Child.PreUninstallBackupObservations))) { return 'Pre' }
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile manifest returned to its pre-child bytes, but one or more profile targets/backups did not.'
        }
    }
    if ([bool](Get-PshUninstallProperty $observation 'Exists') -and
        $null -ne $postBytes -and
        [Convert]::ToBase64String([byte[]](Get-PshUninstallProperty $observation 'Bytes')) -ceq [Convert]::ToBase64String($postBytes)) {
        if ((Test-PshUninstallProfileTargetObservations -Expected @($Child.PostUninstallTargetObservations)) -and
            (Test-PshUninstallProfileTargetObservations -Expected @($Child.PostUninstallBackupObservations))) { return 'Post' }
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile manifest retained its post-child bytes, but one or more profile targets/backups changed.'
    }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile manifest matches neither the exact pre-child nor post-child byte image.'
}

function Set-PshUninstallProfileObservationCas {
    param(
        [Parameter(Mandatory = $true)][object] $From,
        [Parameter(Mandatory = $true)][object] $To,
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][string] $Description
    )
    $path = [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $From 'Path'))
    if (-not [string]::Equals($path, [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $To 'Path')), (Get-PshUninstallPathComparison))) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description restore contract changed paths."
    }
    if (Test-PshUninstallProfileObservationEqual -Left $From -Right $To) { return }
    $actual = Get-PshUninstallProfileTargetObservation -Path $path
    if (-not (Test-PshUninstallProfileObservationEqual -Left $actual -Right $From)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description changed before its exact CAS transition."
    }

    $fromExists = [bool](Get-PshUninstallProperty $From 'Exists')
    $toExists = [bool](Get-PshUninstallProperty $To 'Exists')
    try {
        if ($toExists) {
            [byte[]]$toBytes = [byte[]](Get-PshUninstallProperty $To 'Bytes')
            if ($fromExists) {
                [byte[]]$fromBytes = [byte[]](Get-PshUninstallProperty $From 'Bytes')
                & $Lock.Module {
                    param($TargetPath, $ExpectedBytes, $DesiredBytes)
                    Assert-PshFileUnchanged -Path $TargetPath -ExpectedToExist $true -ExpectedBytes $ExpectedBytes
                    Write-PshAtomicFileByte -Path $TargetPath -Bytes $DesiredBytes -ExpectedToExist $true -ExpectedBytes $ExpectedBytes
                    Assert-PshFileUnchanged -Path $TargetPath -ExpectedToExist $true -ExpectedBytes $DesiredBytes
                } $path $fromBytes $toBytes
            }
            else {
                Write-PshUninstallBytesAbsentCas -Path $path -Bytes $toBytes -ExpectedSha256 ([string](Get-PshUninstallProperty $To 'Sha256')) -Description $Description
            }
        }
        elseif ($fromExists) {
            Remove-PshUninstallFileCas -Path $path -ExpectedSha256 ([string](Get-PshUninstallProperty $From 'Sha256')) -Description $Description
        }
    }
    catch {
        if ($_.Exception.Data['PshExitCode'] -eq 5) { throw }
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} exact CAS transition failed: {1}" -f $Description, $_.Exception.Message)
    }

    if ([string]$env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE -ceq $Description) {
        Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_RESTORE_POST_WRITE_FAILURE -ErrorAction SilentlyContinue
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description injected a post-write observation failure."
    }

    $verified = Get-PshUninstallProfileTargetObservation -Path $path
    if (-not (Test-PshUninstallProfileObservationEqual -Left $verified -Right $To)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$Description did not retain its exact expected bytes after CAS transition."
    }
}

function Restore-PshUninstallProfileChildExact {
    param(
        [Parameter(Mandatory = $true)][object] $Child,
        [Parameter(Mandatory = $true)][object] $Lock
    )
    $mode = Get-PshUninstallProfileRestoreMode -Child $Child
    if ($mode -ceq 'Pre') { return }
    if ($mode -cne 'Post') {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile rollback requires an exact pre-child or post-child state.'
    }

    $pairs = New-Object System.Collections.Generic.List[object]
    $preBackups = @($Child.PreUninstallBackupObservations)
    $postBackups = @($Child.PostUninstallBackupObservations)
    if ($preBackups.Count -ne $postBackups.Count) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile backup restore contract has mismatched pre/post cardinality.'
    }
    for ($index = 0; $index -lt $preBackups.Count; $index++) {
        $pairs.Add([pscustomobject][ordered]@{ Pre = $preBackups[$index]; Post = $postBackups[$index]; Description = 'profile backup' })
    }

    $preTargets = @($Child.PreUninstallTargetObservations)
    $postTargets = @($Child.PostUninstallTargetObservations)
    if ($preTargets.Count -ne $postTargets.Count) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile target restore contract has mismatched pre/post cardinality.'
    }
    for ($index = 0; $index -lt $preTargets.Count; $index++) {
        $pairs.Add([pscustomobject][ordered]@{ Pre = $preTargets[$index]; Post = $postTargets[$index]; Description = 'profile target' })
    }

    $manifestPath = Join-Path ([string](Get-PshUninstallProperty $Child 'StateRoot')) 'manifest.json'
    $preManifest = [pscustomobject][ordered]@{
        Path = $manifestPath
        Exists = [bool](Get-PshUninstallProperty $Child 'PreUninstallManifestExists')
        Bytes = [byte[]](Get-PshUninstallProperty $Child 'PreUninstallManifestBytes')
        Sha256 = [string](Get-PshUninstallProperty $Child 'PreUninstallManifestSha256')
    }
    $postManifest = [pscustomobject][ordered]@{
        Path = $manifestPath
        Exists = $true
        Bytes = [byte[]](Get-PshUninstallProperty $Child 'PostUninstallManifestBytes')
        Sha256 = [string](Get-PshUninstallProperty $Child 'PostUninstallManifestSha256')
    }
    $pairs.Add([pscustomobject][ordered]@{ Pre = $preManifest; Post = $postManifest; Description = 'profile manifest' })

    $completed = New-Object System.Collections.Generic.List[object]
    $restoreFailure = $null
    $currentPair = $null
    try {
        foreach ($pair in $pairs) {
            if (Test-PshUninstallProfileObservationEqual -Left $pair.Pre -Right $pair.Post) { continue }
            $currentPair = $pair
            Set-PshUninstallProfileObservationCas -From $pair.Post -To $pair.Pre -Lock $Lock -Description ([string]$pair.Description)
            $completed.Add($pair)
            $currentPair = $null
        }
        if ((Get-PshUninstallProfileRestoreMode -Child $Child) -cne 'Pre') {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Exact profile compensation did not reach the complete pre-child state.'
        }
        return
    }
    catch { $restoreFailure = $_ }

    $compensationErrors = New-Object System.Collections.Generic.List[string]
    if ($null -ne $currentPair) {
        try {
            $current = Get-PshUninstallProfileTargetObservation -Path ([string](Get-PshUninstallProperty $currentPair.Pre 'Path'))
            if (Test-PshUninstallProfileObservationEqual -Left $current -Right $currentPair.Pre) {
                $completed.Add($currentPair)
            }
            elseif (-not (Test-PshUninstallProfileObservationEqual -Left $current -Right $currentPair.Post)) {
                $compensationErrors.Add(("{0} reached neither its exact pre-child nor post-child image after a failed transition." -f [string]$currentPair.Description))
            }
        }
        catch { $compensationErrors.Add(("{0} transition outcome could not be classified: {1}" -f [string]$currentPair.Description, $_.Exception.Message)) }
    }
    for ($index = $completed.Count - 1; $index -ge 0; $index--) {
        $pair = $completed[$index]
        try {
            Set-PshUninstallProfileObservationCas -From $pair.Pre -To $pair.Post -Lock $Lock -Description ("{0} restore compensation" -f [string]$pair.Description)
        }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    if ($compensationErrors.Count -eq 0) {
        try {
            if ((Get-PshUninstallProfileRestoreMode -Child $Child) -cne 'Post') { throw 'Profile state did not return to its exact post-child image.' }
        }
        catch { $compensationErrors.Add($_.Exception.Message) }
    }
    $suffix = if ($compensationErrors.Count -eq 0) { 'All completed restore writes were compensated back to the exact post-child state.' } else { 'Restore compensation errors: ' + [string]::Join('; ', $compensationErrors.ToArray()) }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Exact profile rollback failed: {0} {1}" -f $restoreFailure.Exception.Message, $suffix)
}

function Invoke-PshUninstallFailureInjection {
    param([Parameter(Mandatory = $true)][ValidateSet('AfterContentMove', 'BeforeOwnershipRemoval', 'BeforeQuarantineCleanup', 'BeforeTransactionMarkerRemoval')][string] $Point)
    if ([string]$env:PSH_UNINSTALL_TEST_FAILURE_POINT -ceq $Point) {
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "Injected uninstall failure at $Point."
    }
}

function Invoke-PshUninstallChildFailureInjection {
    param([Parameter(Mandatory = $true)][string] $Kind)
    if ([string]$env:PSH_UNINSTALL_TEST_CHILD_FAILURE -ceq $Kind) {
        Remove-Item Env:PSH_UNINSTALL_TEST_CHILD_FAILURE -ErrorAction SilentlyContinue
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "Injected $Kind child uninstall failure."
    }
}

function Invoke-PshUninstallPartialChildFailureInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    $kind = [string](Get-PshUninstallProperty $Child 'Kind')
    if ([string]$env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE -cne $kind) { return }
    if ($kind -ceq 'projection') {
        $observations = @($Child.PreUninstallTargetObservations)
        if ($observations.Count -eq 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Partial projection failure injection found no target.'
        }
        $targetPath = [string](Get-PshUninstallProperty $observations[0] 'TargetPath')
        $partialPath = $targetPath + '.partial-test'
        if ([IO.File]::Exists($partialPath) -or [IO.Directory]::Exists($partialPath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Partial projection failure evidence path already exists.'
        }
        [IO.Directory]::Move($targetPath, $partialPath)
    }
    else {
        $targets = @((Get-PshUninstallProperty $Child 'Targets'))
        if ($targets.Count -eq 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Partial child failure injection found no target.'
        }
        [IO.File]::WriteAllText([string]$targets[0], "partial child mutation`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    Remove-Item Env:PSH_UNINSTALL_TEST_PARTIAL_CHILD_FAILURE -ErrorAction SilentlyContinue
    Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "Injected partial $kind child uninstall failure."
}

function Invoke-PshUninstallPreLockProfileAdditionInjection {
    param([Parameter(Mandatory = $true)][System.Collections.Generic.List[object]] $ChildPlans)
    $target = [string]$env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    foreach ($child in $ChildPlans) {
        if ([string](Get-PshUninstallProperty $child 'Kind') -cne 'profile') { continue }
        $result = @(& $child.InstallPath -ProfilePath @($target) -StateRoot $child.StateRoot -Confirm:$false)
        if ($result.Count -gt 0 -and $null -ne $result[-1].PSObject.Properties['success'] -and -not [bool]$result[-1].success) {
            Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message 'Pre-lock profile addition injection returned failure.'
        }
        Remove-Item Env:PSH_UNINSTALL_TEST_PRE_LOCK_PROFILE_ADD_TARGET -ErrorAction SilentlyContinue
        return
    }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Pre-lock profile addition injection found no profile child.'
}

function Invoke-PshUninstallPreChildBackupReplacementInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    if ([string]$env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT -cne '1' -or
        [string](Get-PshUninstallProperty $Child 'Kind') -cne 'profile') { return }
    $backups = @($Child.PreUninstallBackupObservations)
    if ($backups.Count -eq 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Pre-child backup replacement injection found no backup.'
    }
    [IO.File]::WriteAllText([string]$backups[0].Path, "concurrent backup replacement`n", (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item Env:PSH_UNINSTALL_TEST_PRE_CHILD_BACKUP_REPLACEMENT -ErrorAction SilentlyContinue
}

function Invoke-PshUninstallProfileStateRootFileFailureInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    if ([string]$env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE -cne '1' -or
        [string](Get-PshUninstallProperty $Child 'Kind') -cne 'profile') { return }
    $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
    $evidence = $stateRoot + '.concurrent-evidence'
    if (-not [IO.Directory]::Exists($stateRoot) -or [IO.File]::Exists($evidence) -or [IO.Directory]::Exists($evidence)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile state-root file injection could not preserve the original state directory.'
    }
    [IO.Directory]::Move($stateRoot, $evidence)
    [IO.File]::WriteAllText($stateRoot, "concurrent profile state-root file`n", (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_STATE_ROOT_FILE_FAILURE -ErrorAction SilentlyContinue
    Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message 'Injected profile state-root file replacement.'
}

function Invoke-PshUninstallPostChildStateRootReparseInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    $kind = [string](Get-PshUninstallProperty $Child 'Kind')
    $variableName = if ($kind -ceq 'profile') {
        'PSH_UNINSTALL_TEST_POST_CHILD_PROFILE_STATE_ROOT_REPARSE_TARGET'
    }
    elseif ($kind -ceq 'projection') {
        'PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_REPARSE_TARGET'
    }
    else { return }
    $target = [string][Environment]::GetEnvironmentVariable($variableName)
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
    $evidence = $stateRoot + '.reparse-evidence'
    if (-not [IO.Directory]::Exists($target)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$kind state-root reparse injection target is missing."
    }
    if ([IO.File]::Exists($stateRoot)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$kind state-root reparse injection found a file at the state root."
    }
    if ([IO.Directory]::Exists($stateRoot)) {
        if ([IO.File]::Exists($evidence) -or [IO.Directory]::Exists($evidence)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "$kind state-root reparse evidence path already exists."
        }
        [IO.Directory]::Move($stateRoot, $evidence)
    }
    try {
        $itemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $itemType -Path $stateRoot -Target $target -ErrorAction Stop
        $attributes = [IO.File]::GetAttributes($stateRoot)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'The injected path is not a reparse point.' }
    }
    catch {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Unable to inject the {0} state-root reparse point: {1}" -f $kind, $_.Exception.Message)
    }
    finally {
        [Environment]::SetEnvironmentVariable($variableName, $null)
    }
}

function Invoke-PshUninstallQuarantineTamperInjection {
    param([Parameter(Mandatory = $true)][string] $QuarantineRoot)
    if ([string]$env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE -cne '1') { return }
    $targetName = [string]$env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME
    $candidates = @(Get-ChildItem -LiteralPath $QuarantineRoot -Recurse -Force -File | Where-Object {
        [string]::IsNullOrWhiteSpace($targetName) -or $_.Name -ceq $targetName
    } | Sort-Object FullName)
    if ($candidates.Count -eq 0) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Quarantine tamper injection could not find a target.'
    }
    [IO.File]::AppendAllText($candidates[0].FullName, "# quarantine tamper`n", (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE -ErrorAction SilentlyContinue
    Remove-Item Env:PSH_UNINSTALL_TEST_TAMPER_QUARANTINE_NAME -ErrorAction SilentlyContinue
}

function Invoke-PshUninstallProfileManifestReplacementInjection {
    param([Parameter(Mandatory = $true)][System.Collections.Generic.List[object]] $ChildPlans)
    $replaceManifest = [string]$env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT -ceq '1'
    $replaceTarget = [string]$env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT -ceq '1'
    if (-not $replaceManifest -and -not $replaceTarget) { return }
    foreach ($child in $ChildPlans) {
        if ([string](Get-PshUninstallProperty $child 'Kind') -cne 'profile') { continue }
        if ($replaceManifest) {
            $manifestPath = Join-Path ([string](Get-PshUninstallProperty $child 'StateRoot')) 'manifest.json'
            if (-not [IO.File]::Exists($manifestPath) -or [IO.Directory]::Exists($manifestPath)) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile manifest replacement injection target is missing.'
            }
            [IO.File]::WriteAllText($manifestPath, '{"schemaVersion":1,"product":"Psh","profiles":[]}' + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
        }
        if ($replaceTarget) {
            $targets = @((Get-PshUninstallProperty $child 'Targets'))
            if ($targets.Count -eq 0) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile target replacement injection found no target.'
            }
            [IO.File]::WriteAllText([string]$targets[0], "precommit concurrent target`n", (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item Env:PSH_UNINSTALL_TEST_PROFILE_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
        }
        return
    }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile precommit replacement injection found no profile child.'
}

function Invoke-PshUninstallPostChildManifestReplacementInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    if ([string](Get-PshUninstallProperty $Child 'Kind') -cne 'profile') { return }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT -ceq '1') {
        $manifestPath = Join-Path ([string](Get-PshUninstallProperty $Child 'StateRoot')) 'manifest.json'
        if (-not [IO.File]::Exists($manifestPath) -or [IO.Directory]::Exists($manifestPath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Post-child profile manifest replacement injection target is missing.'
        }
        [IO.File]::WriteAllText($manifestPath, '{"schemaVersion":1,"product":"Psh","profiles":[]}' + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT -ceq '1') {
        $targets = @((Get-PshUninstallProperty $Child 'Targets'))
        if ($targets.Count -eq 0) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Post-child profile target replacement injection found no target.'
        }
        [IO.File]::WriteAllText([string]$targets[0], "post-child concurrent target`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    }
}

function Invoke-PshUninstallPostChildProjectionReplacementInjection {
    param([Parameter(Mandatory = $true)][object] $Child)
    if ([string](Get-PshUninstallProperty $Child 'Kind') -cne 'projection') { return }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT -ceq '1') {
        $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
        if ([IO.File]::Exists($stateRoot) -or [IO.Directory]::Exists($stateRoot)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Post-child projection empty state-root injection target already exists.'
        }
        [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_EMPTY_STATE_ROOT -ErrorAction SilentlyContinue
    }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE -ceq '1') {
        $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
        if ([IO.Directory]::Exists($stateRoot)) {
            if (@(Get-ChildItem -LiteralPath $stateRoot -Force).Count -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Post-child projection state root is not empty for file replacement.' }
            [IO.Directory]::Delete($stateRoot, $false)
        }
        [IO.File]::WriteAllText($stateRoot, "projection post-child state-root file`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_STATE_ROOT_FILE -ErrorAction SilentlyContinue
    }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT -ceq '1') {
        $stateRoot = [string](Get-PshUninstallProperty $Child 'StateRoot')
        [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $stateRoot 'manifest.json'), '{"concurrent":"projection-post-child"}' + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
    }
    if ([string]$env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT -ceq '1') {
        $postTargets = @($Child.PostUninstallTargetObservations | Where-Object { -not [bool](Get-PshUninstallProperty $_ 'Exists') })
        if ($postTargets.Count -eq 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Post-child projection target replacement found no created target.' }
        $targetPath = [string](Get-PshUninstallProperty $postTargets[0] 'TargetPath')
        [IO.Directory]::CreateDirectory($targetPath) | Out-Null
        [IO.File]::WriteAllText((Join-Path $targetPath 'concurrent.bin'), "projection post-child concurrent target`n", (New-Object System.Text.UTF8Encoding($false)))
        Remove-Item Env:PSH_UNINSTALL_TEST_POST_CHILD_PROJECTION_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
    }
}

function Invoke-PshUninstallPrecommitProjectionReplacementInjection {
    param([Parameter(Mandatory = $true)][System.Collections.Generic.List[object]] $ChildPlans)
    $replaceManifest = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT -ceq '1'
    $replaceTarget = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT -ceq '1'
    $replaceStateRoot = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE -ceq '1'
    if (-not $replaceManifest -and -not $replaceTarget -and -not $replaceStateRoot) { return }
    foreach ($child in $ChildPlans) {
        if ([string](Get-PshUninstallProperty $child 'Kind') -cne 'projection') { continue }
        if ($replaceManifest) {
            $stateRoot = [string](Get-PshUninstallProperty $child 'StateRoot')
            [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
            [IO.File]::WriteAllText((Join-Path $stateRoot 'manifest.json'), '{"concurrent":"projection-precommit"}' + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_MANIFEST_REPLACEMENT -ErrorAction SilentlyContinue
        }
        if ($replaceStateRoot) {
            $stateRoot = [string](Get-PshUninstallProperty $child 'StateRoot')
            if ([IO.Directory]::Exists($stateRoot)) {
                if (@(Get-ChildItem -LiteralPath $stateRoot -Force).Count -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Precommit projection state root is not empty for file replacement.' }
                [IO.Directory]::Delete($stateRoot, $false)
            }
            [IO.File]::WriteAllText($stateRoot, "projection precommit state-root file`n", (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_STATE_ROOT_FILE -ErrorAction SilentlyContinue
        }
        if ($replaceTarget) {
            $postTargets = @($child.PostUninstallTargetObservations | Where-Object { -not [bool](Get-PshUninstallProperty $_ 'Exists') })
            if ($postTargets.Count -eq 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Precommit projection target replacement found no created target.' }
            $targetPath = [string](Get-PshUninstallProperty $postTargets[0] 'TargetPath')
            [IO.Directory]::CreateDirectory($targetPath) | Out-Null
            [IO.File]::WriteAllText((Join-Path $targetPath 'concurrent.bin'), "projection precommit concurrent target`n", (New-Object System.Text.UTF8Encoding($false)))
            Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_PRECOMMIT_TARGET_REPLACEMENT -ErrorAction SilentlyContinue
        }
        return
    }
    Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection precommit replacement injection found no projection child.'
}

function Invoke-PshUninstallProjectionLockHoldInjection {
    param([Parameter(Mandatory = $true)][object] $Lock)
    $readyPath = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_READY_PATH
    $releasePath = [string]$env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_RELEASE_PATH
    if ([string]::IsNullOrWhiteSpace($readyPath) -and [string]::IsNullOrWhiteSpace($releasePath)) { return }
    try {
        if ([string]::IsNullOrWhiteSpace($readyPath) -or [string]::IsNullOrWhiteSpace($releasePath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection lock hold injection requires both ready and release paths.'
        }
        if ($null -eq $Lock.Inner -or -not [bool]$Lock.Inner.Acquired) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection lock hold injection found no retained projection mutex.'
        }
        if ([IO.File]::Exists($readyPath) -or [IO.Directory]::Exists($readyPath) -or
            [IO.File]::Exists($releasePath) -or [IO.Directory]::Exists($releasePath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection lock hold injection marker path already exists.'
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($readyPath))) | Out-Null
        [IO.File]::WriteAllText($readyPath, "projection-lock-held`n", (New-Object System.Text.UTF8Encoding($false)))
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not [IO.File]::Exists($releasePath)) {
            if ([DateTime]::UtcNow -ge $deadline) {
                Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message 'Timed out waiting to release the projection lock hold injection.'
            }
            Start-Sleep -Milliseconds 25
        }
    }
    finally {
        Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_READY_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:PSH_UNINSTALL_TEST_PROJECTION_LOCK_RELEASE_PATH -ErrorAction SilentlyContinue
    }
}

function Invoke-PshUninstallMetadataRestoreFailureInjection {
    param([Parameter(Mandatory = $true)][string] $Root)
    if ([string]$env:PSH_UNINSTALL_TEST_METADATA_RESTORE_FAILURE -cne '1') { return }
    $currentPath = Join-Path $Root 'current.json'
    if ([IO.File]::Exists($currentPath) -or [IO.Directory]::Exists($currentPath)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Metadata restore failure injection target already exists.'
    }
    [IO.File]::WriteAllText($currentPath, '{"schemaVersion":1,"version":"metadata-restore-conflict"}' + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message 'Injected metadata restore failure.'
}

function Invoke-PshUninstallRollbackCleanupFailureInjection {
    param([Parameter(Mandatory = $true)][ValidateSet('BeforeQuarantineDelete')][string] $Point)
    if ([string]$env:PSH_UNINSTALL_TEST_ROLLBACK_CLEANUP_FAILURE -ceq $Point) {
        Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message "Injected rollback cleanup failure at $Point."
    }
}

function Invoke-PshUninstallUnknownContentInjection {
    param([Parameter(Mandatory = $true)][string] $QuarantineRoot)
    if ([string]$env:PSH_UNINSTALL_TEST_UNKNOWN_QUARANTINE -cne '1') { return }
    $path = Join-Path $QuarantineRoot 'unknown-test-content.bin'
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unknown-content injection target already exists: $path"
    }
    [IO.File]::WriteAllBytes($path, [byte[]](New-Object byte[] 16))
}

function New-PshUninstallCommittedCleanupResult {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $false)][AllowNull()][object] $QuarantinePath,
        [Parameter(Mandatory = $true)][bool] $RestartRequired
    )
    $global:LASTEXITCODE = $Code
    return [pscustomobject][ordered]@{
        success = $false
        code = $Code
        operation = 'uninstall'
        status = 'committedCleanupPending'
        metadataCommitted = $true
        restartRequired = $RestartRequired
        recoveryRequired = $true
        rollbackRestored = $false
        message = $Message
        quarantinePath = $QuarantinePath
    }
}

$lock = $null
$root = $null
$quarantineRoot = $null
$journal = $null
$journalWritten = $false
$transactionStarted = $false
$confirmed = $false
$metadataCommitted = $false
$profileStateLock = $null
$projectionStateLock = $null
$moved = New-Object System.Collections.Generic.List[object]
$metadataMoved = New-Object System.Collections.Generic.List[object]
$completedChildren = New-Object System.Collections.Generic.List[object]
try {
    $root = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Stop-PshUninstall -Code 4 -Kind 'MissingDependency' -Message 'LOCALAPPDATA is unavailable.' }
        Join-Path $env:LOCALAPPDATA 'Psh'
    } else { Resolve-PshUninstallPath -Path $InstallRoot -Description 'InstallRoot' }
    Assert-PshUninstallRootNotFilesystemRoot -Root $root
    if (-not [IO.Directory]::Exists($root)) { return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'uninstall'; status = 'notInstalled'; restartRequired = $false; recoveryRequired = $false } }
    Assert-PshUninstallDirectoryPath -Root $root -Path $root -Description 'InstallRoot' | Out-Null
    $lock = Enter-PshInstallRootLock -InstallRoot $root
    Assert-PshUninstallNoPendingTransaction -Root $root
    $ownershipSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
    if ($null -eq $ownershipSnapshot) { return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'uninstall'; status = 'notOwned'; restartRequired = $false; recoveryRequired = $false } }
    $ownership = Get-PshUninstallProperty $ownershipSnapshot 'Document'
    $ownershipBeforeSha256 = [string](Get-PshUninstallProperty $ownershipSnapshot 'Sha256')

    $versionsRoot = Join-Path $root 'versions'
    $lifecycleRoot = Join-Path $root '.lifecycle'
    $backupRoot = Join-Path $lifecycleRoot 'backups'
    $stagingRoot = Join-Path $root '.staging'
    $quarantineParent = Join-Path $root '.quarantine'
    foreach ($directoryCheck in @(
            [pscustomobject]@{ Path = $versionsRoot; Description = 'Versions root' },
            [pscustomobject]@{ Path = $lifecycleRoot; Description = 'Lifecycle root' },
            [pscustomobject]@{ Path = $backupRoot; Description = 'Lifecycle backup root' },
            [pscustomobject]@{ Path = $stagingRoot; Description = 'Staging root' },
            [pscustomobject]@{ Path = $quarantineParent; Description = 'Quarantine root' })) {
        Assert-PshUninstallDirectoryPath -Root $root -Path $directoryCheck.Path -Description $directoryCheck.Description -AllowMissing | Out-Null
    }

    $versionPlans = New-Object System.Collections.Generic.List[object]
    $filePlans = New-Object System.Collections.Generic.List[object]
    $lockedPaths = New-Object System.Collections.Generic.List[string]
    $retainedUnknown = New-Object System.Collections.Generic.List[string]
    $plannedBackupPaths = New-Object 'System.Collections.Generic.HashSet[string]' (Get-PshUninstallPathComparer)
    $ownershipVersions = Get-PshUninstallProperty $ownership 'versions'
    foreach ($entry in @($ownershipVersions)) {
        $version = [string](Get-PshUninstallProperty $entry 'version')
        $relativeRoot = [string](Get-PshUninstallProperty $entry 'relativeRoot')
        if ($version -notmatch $script:VersionPattern -or $relativeRoot -cne ('versions/' + $version)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Unsafe owned version record: $version" }
        $versionRoot = Join-Path $root ($relativeRoot.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-PshUninstallWithinRoot -Path $versionRoot -Root $versionsRoot)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned version escaped versions root: $relativeRoot" }
        Assert-PshUninstallDirectoryPath -Root $root -Path $versionRoot -Description "Owned version $version" -AllowMissing | Out-Null
        $tree = Test-PshUninstallVersionTree -VersionRoot $versionRoot -VersionEntry $entry
        if (@($tree.Locked).Count -gt 0) {
            foreach ($path in @($tree.Locked)) { $lockedPaths.Add([string]$path) }
            continue
        }
        if (-not [bool](Get-PshUninstallProperty $tree 'Exact')) {
            $reasons = [string]::Join('; ', @((Get-PshUninstallProperty $tree 'Unknown')))
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Owned version tree is not exact and cannot be safely removed ($version): $reasons"
        }
        foreach ($path in @((Get-PshUninstallProperty $tree 'OwnedFiles'))) { if (-not (Test-PshUninstallFileUnlocked -Path $path)) { $lockedPaths.Add([string]$path) } }
        $versionPlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($versionRoot); Kind = 'directory'; Label = "version $version"; Entry = $entry; Action = 'remove'; ExpectedSha256 = $null; RestoreBytes = $null })
    }

    $stableFiles = Get-PshUninstallProperty $ownership 'stableFiles'
    foreach ($stable in @($stableFiles)) {
        $relative = [string](Get-PshUninstallProperty $stable 'relativePath')
        $target = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-PshUninstallSafePath -Root $root -Path $target -Description 'Stable file target' -AllowMissing | Out-Null
        if ([IO.Directory]::Exists($target)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Stable file target is a directory: $target" }
        if ([string](Get-PshUninstallProperty $stable 'disposition') -ceq 'reused' -or -not [IO.File]::Exists($target)) { continue }
        $installedHash = [string](Get-PshUninstallProperty $stable 'installedSha256')
        try { $targetHash = Get-PshUninstallHash -Path $target }
        catch { $lockedPaths.Add($target); continue }
        if ($targetHash -cne $installedHash) { $retainedUnknown.Add("modified stable file: $relative"); continue }
        if (-not (Test-PshUninstallFileUnlocked -Path $target)) { $lockedPaths.Add($target) }
        $action = 'remove'
        $restoreBytes = $null
        if ([string](Get-PshUninstallProperty $stable 'disposition') -ceq 'replaced') {
            $backupName = [string](Get-PshUninstallProperty $stable 'backupFileName')
            $backupPath = Join-Path $backupRoot $backupName
            Assert-PshUninstallSafePath -Root $root -Path $backupPath -Description 'Stable backup' | Out-Null
            if ([IO.Directory]::Exists($backupPath) -or -not [IO.File]::Exists($backupPath) -or (Get-PshUninstallHash -Path $backupPath) -cne [string](Get-PshUninstallProperty $stable 'originalSha256') -or (Get-Item -LiteralPath $backupPath).Length -ne [long](Get-PshUninstallProperty $stable 'originalLength')) {
                $retainedUnknown.Add("invalid stable backup: $relative")
                continue
            }
            if (-not (Test-PshUninstallFileUnlocked -Path $backupPath)) { $lockedPaths.Add($backupPath) }
            $action = 'restore'
            $restoreBytes = [IO.File]::ReadAllBytes($backupPath)
            if ($plannedBackupPaths.Add([IO.Path]::GetFullPath($backupPath))) {
                $filePlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($backupPath); Kind = 'file'; Label = "backup for $relative"; Action = 'remove'; RestoreBytes = $null; ExpectedSha256 = Get-PshUninstallHash -Path $backupPath })
            }
        }
        $filePlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($target); Kind = 'file'; Label = $relative; Action = $action; RestoreBytes = $restoreBytes; ExpectedSha256 = $targetHash })
    }

    $config = Get-PshUninstallProperty $ownership 'config'
    if (-not $KeepConfig -and $null -ne $config -and [string](Get-PshUninstallProperty $config 'disposition') -cne 'reused') {
        $relative = [string](Get-PshUninstallProperty $config 'relativePath')
        $target = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-PshUninstallSafePath -Root $root -Path $target -Description 'Config target' -AllowMissing | Out-Null
        if ([IO.Directory]::Exists($target)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Config target is a directory: $target" }
        if ([IO.File]::Exists($target)) {
            $installedHash = [string](Get-PshUninstallProperty $config 'installedSha256')
            try { $configHash = Get-PshUninstallHash -Path $target } catch { $lockedPaths.Add($target); $configHash = $null }
            if ($null -ne $configHash -and $configHash -ceq $installedHash) {
                if (-not (Test-PshUninstallFileUnlocked -Path $target)) { $lockedPaths.Add($target) }
                $action = 'remove'
                $restoreBytes = $null
                if ([string](Get-PshUninstallProperty $config 'disposition') -ceq 'replaced') {
                    $backupName = [string](Get-PshUninstallProperty $config 'backupFileName')
                    $backupPath = Join-Path $backupRoot $backupName
                    Assert-PshUninstallSafePath -Root $root -Path $backupPath -Description 'Config backup' | Out-Null
                    if ([IO.Directory]::Exists($backupPath) -or -not [IO.File]::Exists($backupPath) -or (Get-PshUninstallHash -Path $backupPath) -cne [string](Get-PshUninstallProperty $config 'originalSha256') -or (Get-Item -LiteralPath $backupPath).Length -ne [long](Get-PshUninstallProperty $config 'originalLength')) {
                        $retainedUnknown.Add("invalid config backup: $relative")
                    }
                    else {
                        if (-not (Test-PshUninstallFileUnlocked -Path $backupPath)) { $lockedPaths.Add($backupPath) }
                        $action = 'restore'
                        $restoreBytes = [IO.File]::ReadAllBytes($backupPath)
                        if ($plannedBackupPaths.Add([IO.Path]::GetFullPath($backupPath))) {
                            $filePlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($backupPath); Kind = 'file'; Label = "backup for $relative"; Action = 'remove'; RestoreBytes = $null; ExpectedSha256 = Get-PshUninstallHash -Path $backupPath })
                        }
                        $filePlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($target); Kind = 'file'; Label = $relative; Action = $action; RestoreBytes = $restoreBytes; ExpectedSha256 = $configHash })
                    }
                }
                else { $filePlans.Add([pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($target); Kind = 'file'; Label = $relative; Action = $action; RestoreBytes = $restoreBytes; ExpectedSha256 = $configHash }) }
            }
            elseif ($null -ne $configHash) { $retainedUnknown.Add("modified config: $relative") }
        }
    }

    $activeVersion = [string](Get-PshUninstallProperty $ownership 'activeVersion')
    $currentPath = Join-Path $root 'current.json'
    Assert-PshUninstallSafePath -Root $root -Path $currentPath -Description 'current.json' -AllowMissing | Out-Null
    if ([IO.Directory]::Exists($currentPath)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "current.json is a directory: $currentPath" }
    $currentObservation = Get-PshUninstallCurrentObservation -Root $root
    if (-not [bool](Get-PshUninstallProperty $currentObservation 'Exists') -or [string](Get-PshUninstallProperty $currentObservation 'Version') -cne $activeVersion) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'current.json does not select ownership.activeVersion.'
    }
    if (-not (Test-PshUninstallFileUnlocked -Path $currentPath)) { $lockedPaths.Add($currentPath) }
    $currentPlan = [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($currentPath); Kind = 'file'; Label = 'current.json'; Action = 'remove'; RestoreBytes = $null; ExpectedSha256 = Get-PshUninstallCanonicalCurrentSha256 -Version $activeVersion }

    if ($lockedPaths.Count -gt 0) { return New-PshUninstallRestartResult -Message ('Locked Psh files require a restart: ' + [string]::Join(', ', $lockedPaths.ToArray())) }

    $activeRoot = Join-Path $versionsRoot $activeVersion
    Assert-PshUninstallDirectoryPath -Root $root -Path $activeRoot -Description 'Active version root' -AllowMissing | Out-Null
    $activeEntry = $null
    foreach ($candidateEntry in @($ownershipVersions)) { if ([string](Get-PshUninstallProperty $candidateEntry 'version') -ceq $activeVersion) { $activeEntry = $candidateEntry; break } }
    if ($null -eq $activeEntry) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'ownership.activeVersion has no matching version record.' }
    $profiles = @(if ($PSBoundParameters.ContainsKey('ProfilePath')) { @($ProfilePath) } else { @(Get-PshUninstallDefaultProfiles) })
    $modules = @(if ($PSBoundParameters.ContainsKey('ModuleRoot')) { @($ModuleRoot) } else { @(Get-PshUninstallDefaultModules) })
    $profileState = if ([string]::IsNullOrWhiteSpace($ProfileStateRoot)) { Join-Path $root 'profile-state' } else { Resolve-PshUninstallPath -Path $ProfileStateRoot -Description 'ProfileStateRoot' }
    $projectionState = if ([string]::IsNullOrWhiteSpace($ProjectionStateRoot)) { Join-Path $root 'psreadline-projection-state' } else { Resolve-PshUninstallPath -Path $ProjectionStateRoot -Description 'ProjectionStateRoot' }
    if (Test-PshUninstallWithinRoot -Path $profileState -Root $root) { Assert-PshUninstallDirectoryPath -Root $root -Path $profileState -Description 'Profile state root' -AllowMissing | Out-Null }
    if (Test-PshUninstallWithinRoot -Path $projectionState -Root $root) { Assert-PshUninstallDirectoryPath -Root $root -Path $projectionState -Description 'Projection state root' -AllowMissing | Out-Null }

    $childPlans = New-Object System.Collections.Generic.List[object]
    $components = Get-PshUninstallProperty $ownership 'components'
    $profileComponent = Get-PshUninstallProperty $components 'profile'
    if ([bool](Get-PshUninstallProperty $profileComponent 'installed')) {
        if ($profiles.Count -eq 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Installed profile state requires at least one profile target.' }
        $profileUninstall = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'Uninstall-PshProfile.ps1'
        $profileInstall = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'Install-PshProfile.ps1'
        $profileBlock = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'ProfileBlock.ps1'
        if ($null -eq $profileUninstall -or $null -eq $profileInstall -or $null -eq $profileBlock -or
            -not [string]::Equals([IO.Path]::GetDirectoryName($profileUninstall.Path), [IO.Path]::GetDirectoryName($profileInstall.Path), (Get-PshUninstallPathComparison)) -or
            -not [string]::Equals([IO.Path]::GetDirectoryName($profileUninstall.Path), [IO.Path]::GetDirectoryName($profileBlock.Path), (Get-PshUninstallPathComparison))) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile uninstall requires a verified paired installer, uninstaller, and profile helper.'
        }
        Assert-PshUninstallProfileTargetsCoverManifest -StateRoot $profileState -Targets $profiles -HelperPath $profileBlock.Path
        $childPlans.Add([pscustomobject][ordered]@{ Kind = 'profile'; UninstallPath = $profileUninstall.Path; UninstallSha256 = $profileUninstall.Sha256; InstallPath = $profileInstall.Path; InstallSha256 = $profileInstall.Sha256; ProfileBlockPath = $profileBlock.Path; ProfileBlockSha256 = $profileBlock.Sha256; Targets = $profiles; StateRoot = $profileState; SourcePath = $null; PreUninstallManifestExists = $false; PreUninstallManifestBytes = $null; PreUninstallManifestSha256 = $null; PreUninstallTargetObservations = $null; PreUninstallBackupObservations = $null; PostUninstallManifestBytes = $null; PostUninstallManifestSha256 = $null; PostUninstallTargetObservations = $null; PostUninstallBackupObservations = $null })
    }
    $projectionComponent = Get-PshUninstallProperty $components 'psReadLineProjection'
    if ([bool](Get-PshUninstallProperty $projectionComponent 'installed')) {
        if ($modules.Count -eq 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Installed PSReadLine projection state requires at least one module root.' }
        $projectionUninstall = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'Uninstall-PshPSReadLineProjection.ps1'
        $projectionInstall = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'Install-PshPSReadLineProjection.ps1'
        $projectionHelper = Find-PshUninstallCompanionScript -VersionRoot $activeRoot -VersionEntry $activeEntry -Name 'PSReadLineProjection.ps1'
        $projectionSource = Find-PshUninstallProjectionSource -VersionRoot $activeRoot
        if ($null -eq $projectionUninstall -or $null -eq $projectionInstall -or $null -eq $projectionHelper -or $null -eq $projectionSource -or
            -not [string]::Equals([IO.Path]::GetDirectoryName($projectionUninstall.Path), [IO.Path]::GetDirectoryName($projectionInstall.Path), (Get-PshUninstallPathComparison)) -or
            -not [string]::Equals([IO.Path]::GetDirectoryName($projectionUninstall.Path), [IO.Path]::GetDirectoryName($projectionHelper.Path), (Get-PshUninstallPathComparison))) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'PSReadLine projection uninstall requires a verified paired installer, uninstaller, helper, and source tree.'
        }
        $childPlans.Add([pscustomobject][ordered]@{ Kind = 'projection'; UninstallPath = $projectionUninstall.Path; UninstallSha256 = $projectionUninstall.Sha256; InstallPath = $projectionInstall.Path; InstallSha256 = $projectionInstall.Sha256; ProjectionHelperPath = $projectionHelper.Path; ProjectionHelperSha256 = $projectionHelper.Sha256; Targets = $modules; StateRoot = $projectionState; SourcePath = $projectionSource; PreUninstallManifestBytes = $null; PreUninstallManifestSha256 = $null; PreUninstallTargetObservations = $null; PostUninstallTargetObservations = $null; SourceTreeSha256 = $null })
    }

    foreach ($child in $childPlans) {
        try {
            if ([string]$child.Kind -ceq 'profile') { $null = @(& $child.UninstallPath -ProfilePath $child.Targets -StateRoot $child.StateRoot -WhatIf -Confirm:$false) }
            else { $null = @(& $child.UninstallPath -ModuleRoot $child.Targets -StateRoot $child.StateRoot -WhatIf -Confirm:$false) }
        }
        catch { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} uninstall preflight failed: {1}" -f [string]$child.Kind, $_.Exception.Message) }
    }

    $confirmed = $PSCmdlet.ShouldProcess($root, 'Quarantine and remove owned Psh content')
    if (-not $confirmed) {
        return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'uninstall'; status = 'noChanges'; whatIf = [bool]$WhatIfPreference; confirmed = $false; restartRequired = $false; recoveryRequired = $false; retainedUnknown = $retainedUnknown.ToArray() }
    }

    Invoke-PshUninstallPreLockProfileAdditionInjection -ChildPlans $childPlans

    $profileChildren = @($childPlans | Where-Object { [string](Get-PshUninstallProperty $_ 'Kind') -ceq 'profile' })
    $projectionChildren = @($childPlans | Where-Object { [string](Get-PshUninstallProperty $_ 'Kind') -ceq 'projection' })
    if ($profileChildren.Count -gt 1) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'More than one profile child transaction was planned.'
    }
    if ($projectionChildren.Count -gt 1) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'More than one PSReadLine projection child transaction was planned.'
    }
    if ($profileChildren.Count -eq 1) {
        $profileChild = $profileChildren[0]
        $profileBlockStatus = Get-PshUninstallScriptStatus -Path $profileChild.ProfileBlockPath -ExpectedSha256 $profileChild.ProfileBlockSha256
        if (-not [bool](Get-PshUninstallProperty $profileBlockStatus 'Trusted')) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Profile transaction helper changed before lock acquisition: {0}" -f [string](Get-PshUninstallProperty $profileBlockStatus 'Reason'))
        }
        $profileStateLock = Enter-PshUninstallProfileStateLock -StateRoot $profileChild.StateRoot -HelperPath $profileChild.ProfileBlockPath
    }
    if ($projectionChildren.Count -eq 1) {
        $projectionChild = $projectionChildren[0]
        $projectionHelperStatus = Get-PshUninstallScriptStatus -Path $projectionChild.ProjectionHelperPath -ExpectedSha256 $projectionChild.ProjectionHelperSha256
        if (-not [bool](Get-PshUninstallProperty $projectionHelperStatus 'Trusted')) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Projection transaction helper changed before lock acquisition: {0}" -f [string](Get-PshUninstallProperty $projectionHelperStatus 'Reason'))
        }
        $projectionStateLock = Enter-PshUninstallProjectionStateLock -StateRoot $projectionChild.StateRoot -HelperPath $projectionChild.ProjectionHelperPath
    }

    foreach ($child in $childPlans) {
        try {
            if ([string]$child.Kind -ceq 'profile') {
                Assert-PshUninstallProfileTargetsCoverManifest -StateRoot $child.StateRoot -Targets @($child.Targets) -HelperPath $child.ProfileBlockPath
                $null = @(& $child.UninstallPath -ProfilePath $child.Targets -StateRoot $child.StateRoot -WhatIf -Confirm:$false)
            }
            else {
                $null = @(& $child.UninstallPath -ModuleRoot $child.Targets -StateRoot $child.StateRoot -WhatIf -Confirm:$false)
            }
        }
        catch { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} locked uninstall preflight failed: {1}" -f [string]$child.Kind, $_.Exception.Message) }
    }

    foreach ($profileChild in $profileChildren) {
        $preManifest = Get-PshUninstallProfileManifestObservation -StateRoot $profileChild.StateRoot
        $profileChild.PreUninstallManifestExists = [bool]$preManifest.Exists
        $profileChild.PreUninstallManifestBytes = [byte[]]$preManifest.Bytes
        $profileChild.PreUninstallManifestSha256 = [string]$preManifest.Sha256
        $profileChild.PreUninstallTargetObservations = @(Get-PshUninstallProfileTargetObservations -Targets @($profileChild.Targets))
        $profileContract = Get-PshUninstallProfileChildStateContract -Child $profileChild -HelperPath $profileChild.ProfileBlockPath
        $profileChild.PostUninstallManifestBytes = [byte[]]$profileContract.PostManifestBytes
        $profileChild.PostUninstallManifestSha256 = [string]$profileContract.PostManifestSha256
        $profileChild.PostUninstallTargetObservations = @($profileContract.PostTargetObservations)
        $profileChild.PreUninstallBackupObservations = @($profileContract.PreBackupObservations)
        $profileChild.PostUninstallBackupObservations = @($profileContract.PostBackupObservations)
    }
    foreach ($projectionChild in $projectionChildren) {
        $projectionContract = Get-PshUninstallProjectionChildStateContract -Child $projectionChild -HelperPath $projectionChild.ProjectionHelperPath
        $projectionChild.PreUninstallManifestBytes = [byte[]]$projectionContract.PreManifestBytes
        $projectionChild.PreUninstallManifestSha256 = [string]$projectionContract.PreManifestSha256
        $projectionChild.PreUninstallTargetObservations = @($projectionContract.PreTargetObservations)
        $projectionChild.PostUninstallTargetObservations = @($projectionContract.PostTargetObservations)
        $projectionChild.SourceTreeSha256 = [string]$projectionContract.SourceTreeSha256
    }

    $journal = [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        transactionId = ([Guid]::NewGuid()).ToString('N')
        operation = 'uninstall'
        phase = 'staged'
        oldCurrent = [pscustomobject][ordered]@{ exists = $true; version = $activeVersion; sha256 = [string](Get-PshUninstallProperty $currentObservation 'Sha256') }
        targetVersion = $null
        stageRelativePath = $null
        publishedRelativePath = $null
        ownershipBeforeSha256 = $ownershipBeforeSha256
        startedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    $journalBeforeSha256 = Write-PshUninstallTransactionCas -Root $root -State $journal
    $journalWritten = $true
    $journalSnapshot = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind transaction
    if ($null -eq $journalSnapshot) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Transaction journal disappeared immediately after creation.' }
    if ([string](Get-PshUninstallProperty $journalSnapshot 'Sha256') -cne $journalBeforeSha256) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Transaction journal changed immediately after creation.' }
    $transactionStarted = $true

    $quarantineRoot = Join-Path $quarantineParent ([string]$journal.transactionId)
    Assert-PshUninstallDirectoryPath -Root $root -Path $quarantineRoot -Description 'Quarantine transaction root' -AllowMissing | Out-Null
    [IO.Directory]::CreateDirectory($quarantineRoot) | Out-Null
    Assert-PshUninstallDirectoryPath -Root $root -Path $quarantineRoot -Description 'Quarantine transaction root' | Out-Null

    $allPlans = @($versionPlans.ToArray()) + @($filePlans.ToArray())
    for ($planIndex = 0; $planIndex -lt $allPlans.Count; $planIndex++) {
        $plan = $allPlans[$planIndex]
        $destination = Join-Path $quarantineRoot ('item-{0:d4}' -f $planIndex)
        $movedEntry = Move-PshUninstallPathCas -Path ([string](Get-PshUninstallProperty $plan 'Path')) -Destination $destination -Kind ([string](Get-PshUninstallProperty $plan 'Kind')) -ExpectedSha256 ([string](Get-PshUninstallProperty $plan 'ExpectedSha256')) -Entry (Get-PshUninstallProperty $plan 'Entry') -Description ([string](Get-PshUninstallProperty $plan 'Label')) -MoveList $moved
        if ([string](Get-PshUninstallProperty $plan 'Action') -ceq 'restore') {
            $movedEntry.RestoredSha256 = Write-PshUninstallRestoredFileCas -Path ([string](Get-PshUninstallProperty $plan 'Path')) -Bytes ([byte[]](Get-PshUninstallProperty $plan 'RestoreBytes')) -Description ([string](Get-PshUninstallProperty $plan 'Label'))
            $movedEntry.Restored = $true
        }
        Assert-PshUninstallQuarantineMove -Move $movedEntry
    }
    Assert-PshUninstallQuarantineRoot -Root $quarantineRoot -ContentMoves $moved -MetadataMoves $metadataMoved
    Invoke-PshUninstallQuarantineTamperInjection -QuarantineRoot $quarantineRoot
    Invoke-PshUninstallFailureInjection -Point 'AfterContentMove'

    foreach ($child in $childPlans) {
        # Owned component scripts may have moved with their version tree.  Resolve
        # the post-quarantine path before the CAS check and invocation.
        $childUninstallPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.UninstallPath -OriginalVersionRoot $activeRoot -Moves $moved
        $status = Get-PshUninstallScriptStatus -Path $childUninstallPath -ExpectedSha256 $child.UninstallSha256
        if (-not [bool](Get-PshUninstallProperty $status 'Trusted')) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("{0} uninstaller changed after preflight: {1}" -f [string]$child.Kind, [string](Get-PshUninstallProperty $status 'Reason')) }
        if ([string]$child.Kind -ceq 'profile') {
            $profileBlockPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.ProfileBlockPath -OriginalVersionRoot $activeRoot -Moves $moved
            $profileBlockStatus = Get-PshUninstallScriptStatus -Path $profileBlockPath -ExpectedSha256 $child.ProfileBlockSha256
            if (-not [bool](Get-PshUninstallProperty $profileBlockStatus 'Trusted')) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Profile post-state helper changed after preflight: {0}" -f [string](Get-PshUninstallProperty $profileBlockStatus 'Reason'))
            }
        }
        elseif ([string]$child.Kind -ceq 'projection') {
            $projectionHelperPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.ProjectionHelperPath -OriginalVersionRoot $activeRoot -Moves $moved
            $projectionHelperStatus = Get-PshUninstallScriptStatus -Path $projectionHelperPath -ExpectedSha256 $child.ProjectionHelperSha256
            if (-not [bool](Get-PshUninstallProperty $projectionHelperStatus 'Trusted')) {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Projection post-state helper changed after preflight: {0}" -f [string](Get-PshUninstallProperty $projectionHelperStatus 'Reason'))
            }
        }
        $completedChildren.Add($child)
        Invoke-PshUninstallPreChildBackupReplacementInjection -Child $child
        Invoke-PshUninstallProfileStateRootFileFailureInjection -Child $child
        Invoke-PshUninstallPartialChildFailureInjection -Child $child
        Invoke-PshUninstallChildFailureInjection -Kind ([string]$child.Kind)
        if ([string]$child.Kind -ceq 'profile') { $childResult = @(& $childUninstallPath -ProfilePath $child.Targets -StateRoot $child.StateRoot -Confirm:$false) }
        else { $childResult = @(& $childUninstallPath -ModuleRoot $child.Targets -StateRoot $child.StateRoot -Confirm:$false) }
        Invoke-PshUninstallPostChildStateRootReparseInjection -Child $child
        Invoke-PshUninstallPostChildManifestReplacementInjection -Child $child
        Invoke-PshUninstallPostChildProjectionReplacementInjection -Child $child
        if ($childResult.Count -gt 0 -and $null -ne $childResult[-1].PSObject.Properties['success'] -and -not [bool]$childResult[-1].success) {
            Stop-PshUninstall -Code 3 -Kind 'RuntimeError' -Message ("{0} uninstaller returned failure." -f [string]$child.Kind)
        }
        if ([string]$child.Kind -ceq 'profile') {
            if ((Get-PshUninstallProfileRestoreMode -Child $child) -cne 'Post') {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile uninstaller did not leave the derived exact post-child state.'
            }
        }
        elseif ([string]$child.Kind -ceq 'projection') {
            if ($null -eq $projectionStateLock -or (Get-PshUninstallProjectionRestoreMode -Child $child -Lock $projectionStateLock) -cne 'Post') {
                Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection uninstaller did not leave the derived exact post-child state.'
            }
        }
        Assert-PshUninstallQuarantineRoot -Root $quarantineRoot -ContentMoves $moved -MetadataMoves $metadataMoved
    }

    if ((Get-PshOwnershipStateSha256 -InstallRoot $root) -cne $ownershipBeforeSha256) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'ownership.json changed during uninstall.'
    }

    if ($profileChildren.Count -eq 1 -and $null -eq $profileStateLock) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile transaction lock was not retained through precommit.'
    }
    if ($projectionChildren.Count -eq 1 -and $null -eq $projectionStateLock) {
        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection transaction lock was not retained through precommit.'
    }
    Invoke-PshUninstallProfileManifestReplacementInjection -ChildPlans $childPlans
    Invoke-PshUninstallPrecommitProjectionReplacementInjection -ChildPlans $childPlans
    foreach ($profileChild in $profileChildren) {
        if ((Get-PshUninstallProfileRestoreMode -Child $profileChild) -cne 'Post') {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile state changed after child verification and before metadata commit.'
        }
    }
    foreach ($projectionChild in $projectionChildren) {
        if ((Get-PshUninstallProjectionRestoreMode -Child $projectionChild -Lock $projectionStateLock) -cne 'Post') {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state changed after child verification and before metadata commit.'
        }
    }
    if ($projectionChildren.Count -eq 1 -and $null -ne $projectionStateLock) {
        Invoke-PshUninstallProjectionLockHoldInjection -Lock $projectionStateLock
    }
    Invoke-PshUninstallFailureInjection -Point 'BeforeOwnershipRemoval'

    $null = Move-PshUninstallPathCas -Path $currentPlan.Path -Destination (Join-Path $quarantineRoot 'metadata-current.json') -Kind file -ExpectedSha256 $currentPlan.ExpectedSha256 -Description 'current.json' -MoveList $metadataMoved
    $null = Move-PshUninstallPathCas -Path (Join-Path $root 'ownership.json') -Destination (Join-Path $quarantineRoot 'metadata-ownership.json') -Kind file -ExpectedSha256 $ownershipBeforeSha256 -Description 'ownership.json' -MoveList $metadataMoved
    $null = Move-PshUninstallPathCas -Path (Join-Path $root 'transaction.json') -Destination (Join-Path $quarantineRoot 'metadata-transaction.json') -Kind file -ExpectedSha256 $journalBeforeSha256 -Description 'transaction journal' -MoveList $metadataMoved
    Assert-PshUninstallQuarantineRoot -Root $quarantineRoot -ContentMoves $moved -MetadataMoves $metadataMoved
    foreach ($metadataPath in @($currentPlan.Path, (Join-Path $root 'ownership.json'), (Join-Path $root 'transaction.json'))) {
        if ([IO.File]::Exists($metadataPath) -or [IO.Directory]::Exists($metadataPath)) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message "Lifecycle metadata reappeared during uninstall: $metadataPath"
        }
    }
    foreach ($profileChild in $profileChildren) {
        if ((Get-PshUninstallProfileRestoreMode -Child $profileChild) -cne 'Post') {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile state changed while lifecycle metadata was committing.'
        }
    }
    foreach ($projectionChild in $projectionChildren) {
        if ((Get-PshUninstallProjectionRestoreMode -Child $projectionChild -Lock $projectionStateLock) -cne 'Post') {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection state changed while lifecycle metadata was committing.'
        }
    }
    Invoke-PshUninstallMetadataRestoreFailureInjection -Root $root
    $metadataCommitted = $true
    Invoke-PshUninstallFailureInjection -Point 'BeforeQuarantineCleanup'

    try {
        Invoke-PshUninstallUnknownContentInjection -QuarantineRoot $quarantineRoot
        Assert-PshUninstallQuarantineRoot -Root $quarantineRoot -ContentMoves $moved -MetadataMoves $metadataMoved
        $transactionPath = [IO.Path]::GetFullPath((Join-Path $root 'transaction.json'))
        $transactionMove = $null
        $metadataCleanupMoves = New-Object System.Collections.Generic.List[object]
        foreach ($move in $metadataMoved) {
            if ([string]::Equals([string](Get-PshUninstallProperty $move 'Original'), $transactionPath, (Get-PshUninstallPathComparison))) {
                if ($null -ne $transactionMove) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Duplicate transaction journal quarantine entries were recorded.' }
                $transactionMove = $move
            }
            else { $metadataCleanupMoves.Add($move) }
        }
        if ($null -eq $transactionMove) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Transaction journal quarantine entry is missing.' }

        foreach ($move in $moved) {
            Remove-PshUninstallQuarantineMoveCas -Move $move
        }
        foreach ($move in $metadataCleanupMoves) {
            Remove-PshUninstallQuarantineMoveCas -Move $move
        }
        Assert-PshUninstallQuarantineMove -Move $transactionMove
        $remaining = @(Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction Stop)
        if ($remaining.Count -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath($remaining[0].FullName), [IO.Path]::GetFullPath([string](Get-PshUninstallProperty $transactionMove 'Quarantine')), (Get-PshUninstallPathComparison))) {
            Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Unknown quarantine content remained before transaction marker finalization.'
        }
        Move-PshUninstallTransactionMarkerLast -Move $transactionMove -ExpectedSha256 $journalBeforeSha256
        if (@(Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction Stop).Count -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Unknown quarantine content appeared after transaction marker restoration.' }
        [IO.Directory]::Delete($quarantineRoot, $false)
        if ([IO.Directory]::Exists($quarantineRoot) -or [IO.File]::Exists($quarantineRoot)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Quarantine transaction root remained after cleanup.' }
        Invoke-PshUninstallFailureInjection -Point 'BeforeTransactionMarkerRemoval'
        Remove-PshUninstallFileCas -Path $transactionPath -ExpectedSha256 $journalBeforeSha256 -Description 'transaction journal after committed cleanup'
        $journalWritten = $false
    }
    catch {
        $cleanupCode = if ($_.Exception.Data['PshExitCode'] -eq 5) { 5 } else { 3 }
        $cleanupRestart = ($cleanupCode -eq 3)
        $cleanupQuarantine = if ([IO.Directory]::Exists($quarantineRoot) -or [IO.File]::Exists($quarantineRoot)) { $quarantineRoot } else { $null }
        return New-PshUninstallCommittedCleanupResult -Code $cleanupCode -Message ("Uninstall metadata committed, but quarantine cleanup failed: {0}" -f $_.Exception.Message) -QuarantinePath $cleanupQuarantine -RestartRequired $cleanupRestart
    }

    foreach ($directory in @($versionsRoot, $stagingRoot, $quarantineParent, $backupRoot, $lifecycleRoot)) {
        if ([IO.Directory]::Exists($directory) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            try { [IO.Directory]::Delete($directory, $false) } catch {}
        }
    }
    return [pscustomobject][ordered]@{ success = $true; code = 0; operation = 'uninstall'; status = 'removedOwnedContent'; restartRequired = $false; recoveryRequired = $false; retainedUnknown = $retainedUnknown.ToArray(); installRootRetained = [IO.Directory]::Exists($root) }
}
catch {
    $failure = $_
    if (-not $confirmed -or -not $transactionStarted) { throw }
    if ($metadataCommitted) {
        $cleanupCode = if ($failure.Exception.Data['PshExitCode'] -eq 5) { 5 } else { 3 }
        $cleanupQuarantine = if ([IO.Directory]::Exists($quarantineRoot) -or [IO.File]::Exists($quarantineRoot)) { $quarantineRoot } else { $null }
        return New-PshUninstallCommittedCleanupResult -Code $cleanupCode -Message ("Uninstall metadata committed; recovery cleanup is required: {0}" -f $failure.Exception.Message) -QuarantinePath $cleanupQuarantine -RestartRequired ($cleanupCode -eq 3)
    }
    $issues = New-Object System.Collections.Generic.List[string]
    $issues.Add(('Uninstall failed: {0}' -f $failure.Exception.Message))
    $integrityConflict = $false
    $restartRequired = $true
    $failureCodeValue = $failure.Exception.Data['PshExitCode']
    if ($null -ne $failureCodeValue -and [int]$failureCodeValue -eq 5) { $integrityConflict = $true; $restartRequired = $false }

    # Restore lifecycle metadata first so a partial component rollback always
    # leaves a recovery marker and never silently loses the old pointer.
    $metadataRestore = Restore-PshUninstallMoves -Moves $metadataMoved
    $metadataRestored = [bool](Get-PshUninstallProperty $metadataRestore 'Success')
    if (-not $metadataRestored) {
        $integrityConflict = $true
        $restartRequired = $true
        foreach ($restoreError in @((Get-PshUninstallProperty $metadataRestore 'Errors'))) { $issues.Add("Metadata rollback: $restoreError") }
    }
    if ($metadataRestored) {
        try {
            $restoredCurrent = Get-PshUninstallCurrentObservation -Root $root
            if (-not [bool](Get-PshUninstallProperty $restoredCurrent 'Exists') -or [string](Get-PshUninstallProperty $restoredCurrent 'Sha256') -cne $currentPlan.ExpectedSha256) { throw 'current.json was not restored to its canonical pre-uninstall bytes.' }
            $restoredOwnership = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
            if ($null -eq $restoredOwnership -or [string](Get-PshUninstallProperty $restoredOwnership 'Sha256') -cne $ownershipBeforeSha256) { throw 'ownership.json was not restored to its exact pre-uninstall bytes.' }
            $restoredJournal = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind transaction
            if ($null -eq $restoredJournal -or [string](Get-PshUninstallProperty $restoredJournal 'Sha256') -cne $journalBeforeSha256) { throw 'transaction journal was not restored to its exact pre-uninstall bytes.' }
        }
        catch {
            $metadataRestored = $false
            $integrityConflict = $true
            $restartRequired = $true
            $issues.Add("Metadata verification: $($_.Exception.Message)")
        }
    }

    $childrenRestored = $false
    $contentRestored = $false
    if ($metadataRestored) {
        $childrenRestored = $true
        for ($childIndex = $completedChildren.Count - 1; $childIndex -ge 0; $childIndex--) {
            $child = $completedChildren[$childIndex]
            if ([string]$child.Kind -ceq 'profile') {
                try {
                    $profileRestoreMode = Get-PshUninstallProfileRestoreMode -Child $child
                    if ($profileRestoreMode -ceq 'Pre') { continue }
                    $profileBlockPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.ProfileBlockPath -OriginalVersionRoot $activeRoot -Moves $moved
                    $profileBlockStatus = Get-PshUninstallScriptStatus -Path $profileBlockPath -ExpectedSha256 $child.ProfileBlockSha256
                    if (-not [bool](Get-PshUninstallProperty $profileBlockStatus 'Trusted')) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Profile rollback helper changed: {0}" -f [string](Get-PshUninstallProperty $profileBlockStatus 'Reason'))
                    }
                    if ($null -eq $profileStateLock) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Profile transaction lock was lost before exact rollback.'
                    }
                    Restore-PshUninstallProfileChildExact -Child $child -Lock $profileStateLock
                    continue
                }
                catch {
                    if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true }
                    $childrenRestored = $false
                    $restartRequired = $true
                    $issues.Add("Profile exact rollback: $($_.Exception.Message)")
                    continue
                }
            }
            if ([string]$child.Kind -ceq 'projection') {
                try {
                    if ($null -eq $projectionStateLock) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Projection transaction lock was lost before exact rollback.'
                    }
                    $projectionRestoreMode = Get-PshUninstallProjectionRestoreMode -Child $child -Lock $projectionStateLock
                    if ($projectionRestoreMode -ceq 'Pre') { continue }
                    $projectionHelperPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.ProjectionHelperPath -OriginalVersionRoot $activeRoot -Moves $moved
                    $projectionHelperStatus = Get-PshUninstallScriptStatus -Path $projectionHelperPath -ExpectedSha256 $child.ProjectionHelperSha256
                    if (-not [bool](Get-PshUninstallProperty $projectionHelperStatus 'Trusted')) {
                        Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message ("Projection rollback helper changed: {0}" -f [string](Get-PshUninstallProperty $projectionHelperStatus 'Reason'))
                    }
                    $projectionSourcePath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.SourcePath -OriginalVersionRoot $activeRoot -Moves $moved
                    Restore-PshUninstallProjectionChildExact -Child $child -Lock $projectionStateLock -SourcePath $projectionSourcePath
                    continue
                }
                catch {
                    if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true }
                    $childrenRestored = $false
                    $restartRequired = $true
                    $issues.Add("Projection exact rollback: $($_.Exception.Message)")
                    continue
                }
            }
            $installPath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.InstallPath -OriginalVersionRoot $activeRoot -Moves $moved
            $installStatus = Get-PshUninstallScriptStatus -Path $installPath -ExpectedSha256 $child.InstallSha256
            if (-not [bool](Get-PshUninstallProperty $installStatus 'Trusted')) {
                $childrenRestored = $false
                $integrityConflict = $true
                $issues.Add(("The {0} component could not be restored because its installer {1}." -f [string]$child.Kind, [string](Get-PshUninstallProperty $installStatus 'Reason')))
                continue
            }
            try {
                $sourcePath = Get-PshUninstallRestorationScriptPath -OriginalPath $child.SourcePath -OriginalVersionRoot $activeRoot -Moves $moved
                $restoreResult = @(& $installPath -SourcePath $sourcePath -ModuleRoot $child.Targets -StateRoot $child.StateRoot -Confirm:$false)
                if ($restoreResult.Count -gt 0 -and $null -ne $restoreResult[-1].PSObject.Properties['success'] -and -not [bool]$restoreResult[-1].success) {
                    throw ("{0} installer returned failure." -f [string]$child.Kind)
                }
            }
            catch {
                if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true }
                $childrenRestored = $false
                $restartRequired = $true
                $issues.Add(("The {0} component could not be restored: {1}" -f [string]$child.Kind, $_.Exception.Message))
            }
        }

        $moveRestore = Restore-PshUninstallMoves -Moves $moved
        $contentRestored = [bool](Get-PshUninstallProperty $moveRestore 'Success')
        if (-not $contentRestored) {
            $restartRequired = $true
            if ([bool](Get-PshUninstallProperty $moveRestore 'IntegrityConflict')) { $integrityConflict = $true }
            foreach ($restoreError in @((Get-PshUninstallProperty $moveRestore 'Errors'))) { $issues.Add("Content rollback: $restoreError") }
        }
    }
    else {
        $issues.Add('Lifecycle metadata rollback was not exact; component and content compensation were skipped.')
    }

    $rollbackRestored = $metadataRestored -and $contentRestored -and $childrenRestored -and -not $integrityConflict
    $quarantineForResult = $quarantineRoot
    if ($rollbackRestored) {
        try {
            $remaining = @(Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction Stop)
            if ($remaining.Count -ne 0) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Unexpected quarantine evidence remained after rollback.' }
            Invoke-PshUninstallRollbackCleanupFailureInjection -Point 'BeforeQuarantineDelete'
            [IO.Directory]::Delete($quarantineRoot, $false)
            if ([IO.Directory]::Exists($quarantineRoot) -or [IO.File]::Exists($quarantineRoot)) { Stop-PshUninstall -Code 5 -Kind 'IntegrityFailure' -Message 'Rollback quarantine root could not be removed.' }
            # The journal is the final recovery marker; remove it only after the
            # isolated quarantine directory is known to be empty and gone.
            Remove-PshUninstallFileCas -Path (Join-Path $root 'transaction.json') -ExpectedSha256 $journalBeforeSha256 -Description 'transaction journal after rollback'
            $quarantineForResult = $null
            $journalWritten = $false
        }
        catch {
            if ($_.Exception.Data['PshExitCode'] -eq 5) { $integrityConflict = $true }
            $rollbackRestored = $false
            $restartRequired = $true
            $quarantineForResult = if ([IO.Directory]::Exists($quarantineRoot) -or [IO.File]::Exists($quarantineRoot)) { $quarantineRoot } else { $null }
            $issues.Add("Rollback journal/quarantine cleanup: $($_.Exception.Message)")
        }
    }
    $code = if ($integrityConflict) { 5 } else { 3 }
    return New-PshUninstallRecoveryResult -Code $code -Message $failure.Exception.Message -QuarantinePath $quarantineForResult -RestartRequired $restartRequired -RollbackRestored $rollbackRestored -RecoveryRequired (-not $rollbackRestored) -Issues $issues.ToArray()
}
finally {
    if ($null -ne $projectionStateLock) {
        try { Exit-PshUninstallProjectionStateLock -Lock $projectionStateLock } catch {}
    }
    if ($null -ne $profileStateLock) {
        try { Exit-PshUninstallProfileStateLock -Lock $profileStateLock } catch {}
    }
    if ($null -ne $lock) { Exit-PshInstallRootLock -Lock $lock }
}
