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
    [string] $InstallRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
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
if (-not $PSCmdlet.ShouldProcess($currentPath, "Select Psh version $Version")) {
    return
}

$currentDocument = [ordered]@{
    schemaVersion = 1
    version       = $Version
}
$currentJson = ($currentDocument | ConvertTo-Json -Compress) + [Environment]::NewLine
$operationId = ([Guid]::NewGuid()).ToString('N')
$temporaryName = '.current.{0}.tmp' -f $operationId
$temporaryPath = Join-Path -Path $InstallRoot -ChildPath $temporaryName
$backupPath = Join-Path -Path $InstallRoot -ChildPath ('.current.{0}.bak' -f $operationId)

try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $currentJson, $utf8WithoutBom)

    if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
        [IO.File]::Replace($temporaryPath, $currentPath, $backupPath)
    }
    else {
        [IO.File]::Move($temporaryPath, $currentPath)
    }

    $temporaryPath = $null
}
finally {
    if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
        [IO.File]::Delete($temporaryPath)
    }

    if ([IO.File]::Exists($backupPath)) {
        try {
            [IO.File]::Delete($backupPath)
        }
        catch {
            # A stale Psh-owned backup does not invalidate an atomic switch.
        }
    }
}
