# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$currentPath = Join-Path -Path $PSScriptRoot -ChildPath 'current.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
    throw "Psh version pointer was not found: $currentPath"
}

try {
    $currentDocument = Get-Content -LiteralPath $currentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Psh version pointer is not valid JSON: $($_.Exception.Message)"
}

if ($null -eq $currentDocument -or $currentDocument -is [System.Array]) {
    throw 'Psh version pointer must be a JSON object.'
}

$schemaProperty = $currentDocument.PSObject.Properties['schemaVersion']
if ($null -eq $schemaProperty -or
    (-not ($schemaProperty.Value -is [int]) -and -not ($schemaProperty.Value -is [long])) -or
    $schemaProperty.Value -ne 1) {
    throw 'Psh version pointer has an unsupported schemaVersion.'
}

$versionProperty = $currentDocument.PSObject.Properties['version']
$versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
if ($null -eq $versionProperty -or -not ($versionProperty.Value -is [string]) -or
    $versionProperty.Value -notmatch $versionPattern) {
    throw 'Psh version pointer contains an invalid version.'
}

$versionRoot = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'versions') -ChildPath $versionProperty.Value
$moduleManifestPath = Join-Path -Path (Join-Path -Path $versionRoot -ChildPath 'Psh') -ChildPath 'Psh.psd1'
if (-not (Test-Path -LiteralPath $moduleManifestPath -PathType Leaf)) {
    throw "Psh module manifest was not found for version $($versionProperty.Value): $moduleManifestPath"
}

Import-Module -Name $moduleManifestPath -Global -Force -ErrorAction Stop
