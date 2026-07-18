# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Assert-PshCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Goal 1 acceptance failed: $Message"
    }
}

function Convert-PshOutputFromJson {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Output
    )

    $text = ($Output -join [Environment]::NewLine)
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace($text)) 'JSON output was empty.'
    return ($text | ConvertFrom-Json)
}

$expectedCommands = @(
    'pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln',
    'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd',
    'du', 'df', 'mktemp', 'cat', 'bat', 'head', 'tail', 'grep', 'rg', 'sed',
    'awk', 'jq', 'cut', 'tr', 'sort', 'uniq', 'wc', 'tee', 'xargs', 'printf',
    'echo', 'base64', 'which', 'env', 'printenv', 'export', 'test', 'ps',
    'kill', 'pgrep', 'pkill', 'timeout', 'sleep', 'curl', 'wget', 'tar', 'zip',
    'unzip', 'gzip', 'gunzip', 'sha256sum', 'md5sum', 'date', 'whoami',
    'hostname', 'clear'
)
$expectedManagementCommands = @(
    'version', 'doctor', 'capabilities', 'commands', 'config', 'update',
    'rollback', 'self-test', 'uninstall'
)
$nativeFullCommands = @('bat', 'fd', 'jq', 'rg')

$specificationPath = Join-Path $RepositoryRoot 'src/Psh/Specification/commands.psd1'
$manifestPath = Join-Path $RepositoryRoot 'src/Psh/Psh.psd1'
$generatorPath = Join-Path $RepositoryRoot 'scripts/Generate-CommandArtifacts.ps1'

Assert-PshCondition (Test-Path -LiteralPath $specificationPath -PathType Leaf) 'The command specification is missing.'
Assert-PshCondition (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The module manifest is missing.'
Assert-PshCondition (Test-Path -LiteralPath $generatorPath -PathType Leaf) 'The artifact generator is missing.'

$specification = Import-PowerShellDataFile -LiteralPath $specificationPath
Assert-PshCondition ([string]$specification.SchemaVersion -eq '1.0') 'Unexpected specification schema version.'
Assert-PshCondition ($specification.PshVersion -eq '0.1.0') 'Unexpected Psh version in the specification.'

$actualNames = @($specification.Commands | ForEach-Object { $_.Name })
Assert-PshCondition ($actualNames.Count -eq 64) 'The specification must contain exactly 64 commands.'
Assert-PshCondition (@($actualNames | Group-Object | Where-Object { $_.Count -ne 1 }).Count -eq 0) 'Command names must be unique.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) ($actualNames | Sort-Object)).Count -eq 0) 'The 64 command names do not match PLAN.md.'

$actualManagement = @($specification.ManagementCommands | ForEach-Object { $_.Name })
Assert-PshCondition (@(Compare-Object ($expectedManagementCommands | Sort-Object) ($actualManagement | Sort-Object)).Count -eq 0) 'Management commands do not match PLAN.md.'
Assert-PshCondition (((@($specification.ExitCodes | ForEach-Object { [int]$_.Code }) | Sort-Object) -join ',') -eq '0,1,2,3,4,5') 'The exit-code contract must define 0 through 5.'

foreach ($command in $specification.Commands) {
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Summary)) "$($command.Name) has no help summary."
    Assert-PshCondition ($null -ne $command.Flags) "$($command.Name) has no completion flag data."
    Assert-PshCondition (@($command.ExitCodes).Count -gt 0) "$($command.Name) has no exit-code data."
    Assert-PshCondition (@($command.Examples).Count -gt 0) "$($command.Name) has no examples."
    Assert-PshCondition ($command.CoreBackend -eq 'powershell') "$($command.Name) Core backend is not PowerShell."

    if ($nativeFullCommands -contains $command.Name) {
        Assert-PshCondition ($command.FullBackend -eq ("native:{0}" -f $command.Name)) "$($command.Name) Full backend is not its pinned native tool."
    }
    else {
        Assert-PshCondition ($command.FullBackend -eq 'powershell') "$($command.Name) unexpectedly uses a native Full backend."
    }
}

& $generatorPath -Check

$generatedFiles = @(
    (Join-Path $RepositoryRoot 'generated/commands.json'),
    (Join-Path $RepositoryRoot 'docs/compatibility.md'),
    (Join-Path $RepositoryRoot 'src/Psh/Generated/ArgumentCompleters.ps1')
)
foreach ($generatedFile in $generatedFiles) {
    Assert-PshCondition (Test-Path -LiteralPath $generatedFile -PathType Leaf) "Missing generated artifact: $generatedFile"
    $bytes = [IO.File]::ReadAllBytes($generatedFile)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-PshCondition (-not $hasBom) "Generated artifact has a UTF-8 BOM: $generatedFile"
}

$generatedSpecification = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'generated/commands.json') -Raw | ConvertFrom-Json
Assert-PshCondition (@($generatedSpecification.Commands).Count -eq 64) 'Generated commands.json does not contain 64 commands.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) (@($generatedSpecification.Commands.Name) | Sort-Object)).Count -eq 0) 'Generated commands.json command names drifted from PLAN.md.'

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'src') -Recurse -File)
$allowedManagedDependencyRoot = [IO.Path]::GetFullPath(
    (Join-Path $RepositoryRoot 'src/Psh/Dependencies/PSReadLine/2.4.5')
).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$allowedManagedDependencyPrefix = $allowedManagedDependencyRoot + [IO.Path]::DirectorySeparatorChar
$pathComparison = [StringComparison]::Ordinal
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $pathComparison = [StringComparison]::OrdinalIgnoreCase
}
$unexpectedBinaries = @(
    $sourceFiles |
        Where-Object {
            if ($_.Extension -in @('.exe', '.com', '.msi')) {
                return $true
            }
            if ($_.Extension -ne '.dll') {
                return $false
            }
            return -not $_.FullName.StartsWith($allowedManagedDependencyPrefix, $pathComparison)
        }
)
Assert-PshCondition ($unexpectedBinaries.Count -eq 0) 'Core source contains an executable binary outside the fixed managed dependency directory.'

$unsafePatterns = @(
    'Invoke-WebRequest',
    'Start-BitsTransfer',
    'Download(File|String|Data)',
    '#requires\s+-RunAsAdministrator',
    'Start-Process[^\r\n]+-Verb\s+RunAs',
    'Set-ExecutionPolicy'
)
foreach ($pattern in $unsafePatterns) {
    $matches = @(
        $sourceFiles | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern $pattern
        }
    )
    Assert-PshCondition ($matches.Count -eq 0) "Goal 1 source contains a forbidden startup, elevation, or policy pattern: $pattern"
}

$originalEdition = $env:PSH_EDITION
try {
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force -ErrorAction Stop

    $module = Get-Module -Name Psh
    $completerLoadError = & $module { $script:PshCompleterLoadError }
    Assert-PshCondition ([string]::IsNullOrWhiteSpace([string]$completerLoadError)) "Generated argument completers failed to load: $completerLoadError"
    $completion = TabExpansion2 -InputScript 'psh cap' -CursorColumn 7
    Assert-PshCondition (@($completion.CompletionMatches.CompletionText) -contains 'capabilities') 'Generated management completion did not offer capabilities.'

    foreach ($edition in @('Core', 'Full')) {
        $env:PSH_EDITION = $edition
        $jsonOutput = @(& psh capabilities --json)
        Assert-PshCondition ($LASTEXITCODE -eq 0) "psh capabilities --json failed for $edition."
        $capabilities = Convert-PshOutputFromJson -Output $jsonOutput
        Assert-PshCondition ($capabilities.edition -eq $edition) "Capabilities reported the wrong edition for $edition."
        Assert-PshCondition (@($capabilities.commands).Count -eq 64) "Capabilities did not report 64 commands for $edition."

        foreach ($capability in $capabilities.commands) {
            if ($edition -eq 'Full' -and $nativeFullCommands -contains $capability.name) {
                Assert-PshCondition ($capability.activeBackend -eq ("native:{0}" -f $capability.name)) "$($capability.name) reported the wrong Full backend."
            }
            else {
                Assert-PshCondition ($capability.activeBackend -eq 'powershell') "$($capability.name) reported the wrong active backend for $edition."
            }
        }
    }

    $usageOutput = @(& psh not-a-command)
    Assert-PshCondition ($LASTEXITCODE -eq 2) 'An unknown management action did not set usage exit code 2.'
    Assert-PshCondition ($usageOutput.Count -gt 0) 'An unknown management action did not emit a plain-text usage error.'
}
finally {
    $env:PSH_EDITION = $originalEdition
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
}

$installRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal1-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $versionRoot = Join-Path $installRoot 'versions/0.1.0'
    $installedModuleRoot = Join-Path $versionRoot 'Psh'
    [IO.Directory]::CreateDirectory($versionRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh') -Destination $installedModuleRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/bootstrap.ps1') -Destination (Join-Path $installRoot 'bootstrap.ps1')
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'src/install/config.psd1') -Destination (Join-Path $installRoot 'config.psd1')

    $switchScript = Join-Path $RepositoryRoot 'src/install/Set-PshCurrentVersion.ps1'
    & $switchScript -InstallRoot $installRoot -Version '0.1.0'
    & $switchScript -InstallRoot $installRoot -Version '0.1.0'

    $currentPath = Join-Path $installRoot 'current.json'
    Assert-PshCondition (Test-Path -LiteralPath $currentPath -PathType Leaf) 'Atomic version switching did not create current.json.'
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    Assert-PshCondition ($current.version -eq '0.1.0') 'current.json points to the wrong version.'
    Assert-PshCondition (@(Get-ChildItem -LiteralPath $installRoot -Filter '.current.*.tmp' -File).Count -eq 0) 'Atomic version switching left temporary files behind.'
    Assert-PshCondition (@(Get-ChildItem -LiteralPath $installRoot -Filter '.current.*.bak' -File).Count -eq 0) 'Atomic version switching left backup files behind.'

    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    . (Join-Path $installRoot 'bootstrap.ps1')
    Assert-PshCondition ($null -ne (Get-Module Psh)) 'The stable bootstrap did not import Psh.'
    $installedCapabilities = Convert-PshOutputFromJson -Output @(& psh capabilities --json)
    Assert-PshCondition ($installedCapabilities.edition -eq 'Core') 'The installed default config did not select Core.'
    Assert-PshCondition (@($installedCapabilities.commands).Count -eq 64) 'The bootstrapped module did not report 64 commands.'
}
finally {
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
}

Write-Output 'Goal 1 acceptance passed: specification, generated artifacts, module capabilities, safety constraints, and install layout.'
