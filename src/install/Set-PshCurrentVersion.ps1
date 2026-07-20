# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
.SYNOPSIS
Atomically selects an installed Psh version for the current user.

.DESCRIPTION
Validates the version and its module manifest before replacing current.json.
The temporary file is written beside current.json so the final filesystem
operation stays on the same volume.

.PARAMETER Version
The installed semantic version to select, without a leading "v".

.PARAMETER InstallRoot
The Psh installation root. Defaults to %LOCALAPPDATA%\Psh. This override is
intended for installer staging and isolated tests.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Version,

    [Parameter()]
    [string] $InstallRoot,

    [Parameter()]
    [AllowNull()]
    [string] $ExpectedCurrentSha256
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'

function Stop-PshCurrentSwitch {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [int] $Code = 5,
        [string] $Kind = 'IntegrityFailure'
    )
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['PshExitCode'] = $Code
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = if ($Code -eq 5) { 'PshLifecycle.CurrentCasConflict' } else { 'PshLifecycle.CurrentSwitch' }
    throw $exception
}

function Get-PshCurrentSwitchHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PshCurrentSwitchBytesHash {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
if ($Version -notmatch $versionPattern) {
    throw "Psh version must be a semantic version without a leading 'v': $Version"
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not available; the current-user Psh root cannot be determined.'
    }

    $InstallRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh'
}

$versionRoot = Join-Path -Path (Join-Path -Path $InstallRoot -ChildPath 'versions') -ChildPath $Version
$moduleManifestPath = Join-Path -Path (Join-Path -Path $versionRoot -ChildPath 'Psh') -ChildPath 'Psh.psd1'
if (-not (Test-Path -LiteralPath $moduleManifestPath -PathType Leaf)) {
    throw "Psh module manifest was not found for version ${Version}: $moduleManifestPath"
}

$currentPath = Join-Path -Path $InstallRoot -ChildPath 'current.json'
$expectedWasSpecified = $PSBoundParameters.ContainsKey('ExpectedCurrentSha256')
if ($expectedWasSpecified -and -not [string]::IsNullOrEmpty($ExpectedCurrentSha256) -and $ExpectedCurrentSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
    Stop-PshCurrentSwitch -Message 'ExpectedCurrentSha256 must be empty for an absent pointer or a lowercase SHA256 value.'
}
$currentExistsBefore = [IO.File]::Exists($currentPath)
if ([IO.Directory]::Exists($currentPath)) { Stop-PshCurrentSwitch -Message "current.json is a directory: $currentPath" }
$preSwitchSha256 = if ($currentExistsBefore) { Get-PshCurrentSwitchHash -Path $currentPath } else { $null }
if ($expectedWasSpecified) {
    if ([string]::IsNullOrEmpty($ExpectedCurrentSha256)) {
        if ($currentExistsBefore) { Stop-PshCurrentSwitch -Message 'current.json appeared before the expected-absent switch.' }
    }
    elseif (-not $currentExistsBefore -or (Get-PshCurrentSwitchHash -Path $currentPath) -cne $ExpectedCurrentSha256) {
        Stop-PshCurrentSwitch -Message 'current.json changed before the expected-hash switch.'
    }
}
if (-not $PSCmdlet.ShouldProcess($currentPath, "Select Psh version $Version")) {
    return
}

$currentDocument = [ordered]@{
    schemaVersion = 1
    version       = $Version
}
$currentJson = ($currentDocument | ConvertTo-Json -Compress) + [Environment]::NewLine
$currentBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($currentJson)
$targetSha256 = Get-PshCurrentSwitchBytesHash -Bytes $currentBytes
$operationId = ([Guid]::NewGuid()).ToString('N')
$temporaryName = '.current.{0}.tmp' -f $operationId
$temporaryPath = Join-Path -Path $InstallRoot -ChildPath $temporaryName
$backupPath = Join-Path -Path $InstallRoot -ChildPath ('.current.{0}.bak' -f $operationId)
$recoveryPath = Join-Path -Path $InstallRoot -ChildPath ('.current.{0}.recovery' -f $operationId)
$backupOwned = $false
$recoveryOwned = $false
$expectedBackupHash = $null
$expectedRecoveryHash = $targetSha256

try {
    [IO.File]::WriteAllBytes($temporaryPath, $currentBytes)

    if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
        try { [IO.File]::Replace($temporaryPath, $currentPath, $backupPath) }
        catch {
            $nowExists = [IO.File]::Exists($currentPath)
            $nowMatches = $false
            if ($nowExists) { try { $nowMatches = (Get-PshCurrentSwitchHash -Path $currentPath) -ceq (if ($expectedWasSpecified) { $ExpectedCurrentSha256 } else { $preSwitchSha256 }) } catch {} }
            if (-not $nowExists -or -not $nowMatches) {
                Stop-PshCurrentSwitch -Message 'current.json changed at the atomic switch point.' -Code 5 -Kind 'IntegrityFailure'
            }
            Stop-PshCurrentSwitch -Message ("current.json could not be replaced: {0}" -f $_.Exception.Message) -Code 3 -Kind 'RuntimeError'
        }
        $expectedBackupHash = if ($expectedWasSpecified -and -not [string]::IsNullOrEmpty($ExpectedCurrentSha256)) { $ExpectedCurrentSha256 } else { $preSwitchSha256 }
        $backupMatches = $false
        if ([IO.File]::Exists($backupPath) -and -not [string]::IsNullOrEmpty($expectedBackupHash)) {
            try { $backupMatches = (Get-PshCurrentSwitchHash -Path $backupPath) -ceq $expectedBackupHash } catch {}
        }
        if (-not $backupMatches) {
            # The backup may be the exact file created by a concurrent actor.
            # Restore it to current.json only while the live pointer is still
            # the transaction image. Unknown backup/recovery bytes are never
            # deleted in the failure path.
            if ([IO.File]::Exists($backupPath) -and [IO.File]::Exists($currentPath) -and (Get-PshCurrentSwitchHash -Path $currentPath) -ceq $targetSha256) {
                try {
                    [IO.File]::Replace($backupPath, $currentPath, $recoveryPath)
                    if ([IO.File]::Exists($recoveryPath) -and (Get-PshCurrentSwitchHash -Path $recoveryPath) -ceq $expectedRecoveryHash) {
                        $recoveryOwned = $true
                    }
                }
                catch { }
            }
            Stop-PshCurrentSwitch -Message 'current.json changed at the atomic switch point; recovery evidence was retained.' -Code 5 -Kind 'IntegrityFailure'
        }
        $backupOwned = $true
    }
    else {
        if ($expectedWasSpecified -and -not [string]::IsNullOrEmpty($ExpectedCurrentSha256)) {
            Stop-PshCurrentSwitch -Message 'current.json disappeared before the expected-hash switch.'
        }
        try { [IO.File]::Move($temporaryPath, $currentPath) }
        catch {
            if ([IO.File]::Exists($currentPath) -or [IO.Directory]::Exists($currentPath)) {
                if ($expectedWasSpecified -and [string]::IsNullOrEmpty($ExpectedCurrentSha256)) { Stop-PshCurrentSwitch -Message 'current.json appeared at the atomic switch point.' -Code 5 -Kind 'IntegrityFailure' }
                Stop-PshCurrentSwitch -Message 'current.json appeared at the atomic switch point.' -Code 5 -Kind 'IntegrityFailure'
            }
            Stop-PshCurrentSwitch -Message ("current.json could not be created: {0}" -f $_.Exception.Message) -Code 3 -Kind 'RuntimeError'
        }
    }

    $temporaryPath = $null
    if (-not [IO.File]::Exists($currentPath) -or (Get-PshCurrentSwitchHash -Path $currentPath) -cne $targetSha256) {
        $backupOwned = $false
        Stop-PshCurrentSwitch -Message 'current.json did not retain the expected target bytes after the switch.'
    }
}
finally {
    if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
        try {
            if ((Get-PshCurrentSwitchHash -Path $temporaryPath) -ceq $targetSha256) { [IO.File]::Delete($temporaryPath) }
        } catch {}
    }

    if ($backupOwned -and [IO.File]::Exists($backupPath)) {
        try {
            if (-not [string]::IsNullOrEmpty($expectedBackupHash) -and (Get-PshCurrentSwitchHash -Path $backupPath) -ceq $expectedBackupHash) {
                [IO.File]::Delete($backupPath)
            }
        } catch { }
    }
    if ($recoveryOwned -and [IO.File]::Exists($recoveryPath)) {
        try {
            if ((Get-PshCurrentSwitchHash -Path $recoveryPath) -ceq $expectedRecoveryHash) { [IO.File]::Delete($recoveryPath) }
        } catch {}
    }
}
