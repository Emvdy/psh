# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$assertionCount = 0
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-config-{0}' -f [Guid]::NewGuid().ToString('N'))
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$sourceConfigTemplate = Join-Path -Path $RepositoryRoot -ChildPath 'src/install/config.psd1'
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$sourceTemplateBytes = [IO.File]::ReadAllBytes($sourceConfigTemplate)
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)

function Assert-PshConfig {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:assertionCount++
    if (-not $Condition) {
        throw $Message
    }
}

function Test-PshConfigBytesEqual {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Left,

        [Parameter(Mandatory = $true)]
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Assert-PshConfigNoAtomicDebris {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $debris = @()
    if ([IO.Directory]::Exists($Directory)) {
        $debris = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Directory -Force -File | Where-Object { $_.Name -match '^\.config\.[0-9a-f]{32}\.(tmp|bak)$' })
    }
    Assert-PshConfig ($debris.Count -eq 0) ('Config atomic write left debris: {0}' -f (@($debris.Name) -join ', '))
}

function Import-PshConfigModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manifest
    )

    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    Import-Module -Name $Manifest -Force -ErrorAction Stop
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $env:PSH_EDITION = $null
    $isolatedLocalAppData = Join-Path -Path $testRoot -ChildPath 'local-app-data'
    $configDirectory = Join-Path -Path $isolatedLocalAppData -ChildPath 'Psh'
    $configPath = Join-Path -Path $configDirectory -ChildPath 'config.psd1'
    $env:LOCALAPPDATA = $isolatedLocalAppData

    Import-PshConfigModule -Manifest $moduleManifest

    $getDefault = @(& psh config get)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'psh config get failed for a missing configuration.'
    Assert-PshConfig (($getDefault -join "`n") -eq 'DisabledCommands = @()') 'psh config get did not report the effective empty default.'
    Assert-PshConfig (-not [IO.File]::Exists($configPath)) 'psh config get created a configuration file.'

    $configHelp = @(& psh config --help)
    Assert-PshConfig ($LASTEXITCODE -eq 0 -and ($configHelp -join "`n").Contains('psh config set DisabledCommands')) 'psh config --help did not report the public syntax.'

    $null = @(& psh config set DisabledCommands)
    Assert-PshConfig ($LASTEXITCODE -eq 2) 'A zero-value config set did not exit 2.'
    $null = @(& psh config set Edition Full)
    Assert-PshConfig ($LASTEXITCODE -eq 2) 'An unsupported config key did not exit 2.'
    $null = @(& psh config --json)
    Assert-PshConfig ($LASTEXITCODE -eq 2) 'psh config --json did not exit 2.'
    Assert-PshConfig (-not [IO.File]::Exists($configPath)) 'An invalid config command created a configuration file.'

    $setOutput = @(& psh config set disabledcommands FIND PWD pwd)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'psh config set failed for valid command names.'
    Assert-PshConfig ($setOutput[0] -eq "DisabledCommands = @('pwd', 'find')") 'Config set did not canonicalize case, duplicates, and specification order.'
    Assert-PshConfig (($setOutput -join "`n").Contains('new shell')) 'Config set did not state when the change takes effect.'
    Assert-PshConfig ([IO.File]::Exists($configPath)) 'Config set did not create the current-user configuration.'
    $getKey = @(& psh config get DisabledCommands)
    Assert-PshConfig ($LASTEXITCODE -eq 0 -and $getKey[0] -eq "DisabledCommands = @('pwd', 'find')") 'Config get by key did not report the persisted value.'

    $config = Import-PowerShellDataFile -LiteralPath $configPath
    Assert-PshConfig ([int]$config.SchemaVersion -eq 1 -and [string]$config.Edition -eq 'Core') 'Config set changed the fixed schema or default edition.'
    Assert-PshConfig ((@($config.DisabledCommands) -join '|') -ceq 'pwd|find') 'Config set persisted the wrong disabled command list.'
    $configBytes = [IO.File]::ReadAllBytes($configPath)
    $hasBom = $configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF
    Assert-PshConfig (-not $hasBom) 'Config set did not use UTF-8 without BOM.'
    Assert-PshConfigNoAtomicDebris -Directory $configDirectory
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $sourceTemplateBytes -Right ([IO.File]::ReadAllBytes($sourceConfigTemplate))) 'Config set modified the source config template.'

    foreach ($commandName in @('pwd', 'find')) {
        $currentCommand = Get-Command -Name ("Psh\{0}" -f $commandName) -ErrorAction SilentlyContinue
        Assert-PshConfig ($null -ne $currentCommand) ('Config set changed the active session projection for {0}.' -f $commandName)
    }

    $bytesBeforeReject = [IO.File]::ReadAllBytes($configPath)
    $null = @(& psh config reset DisabledCommands extra)
    Assert-PshConfig ($LASTEXITCODE -eq 2) 'Config reset accepted an extra argument.'
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $bytesBeforeReject -Right ([IO.File]::ReadAllBytes($configPath))) 'A rejected config reset changed the configuration bytes.'
    $quoteLikeName = "curl'; throw 'not-code"
    $null = @(& psh config set DisabledCommands $quoteLikeName)
    Assert-PshConfig ($LASTEXITCODE -eq 2) 'An unknown quote-like command name did not exit 2.'
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $bytesBeforeReject -Right ([IO.File]::ReadAllBytes($configPath))) 'A rejected config set changed the configuration bytes.'

    Import-PshConfigModule -Manifest $moduleManifest
    $disabledPwd = Get-Command -Name pwd -ErrorAction Stop
    Assert-PshConfig ($disabledPwd.CommandType -eq 'Alias' -and $disabledPwd.Definition -eq 'Get-Location') 'Disabled pwd did not restore the built-in alias fallback after re-import.'
    Assert-PshConfig ($null -eq (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'Disabled pwd remained exported after re-import.'
    $disabledFind = Get-Command -Name find -ErrorAction Stop
    Assert-PshConfig ($disabledFind.Source -ne 'Psh') 'Disabled find did not expose native command resolution after re-import.'
    $module = Get-Module -Name Psh -ErrorAction Stop
    $snapshot = @(& $module { @($script:PshDisabledCommands.Keys | Sort-Object) })
    Assert-PshConfig (($snapshot -join '|') -eq 'find|pwd') 'Root module did not consume the ScriptsToProcess disabled-command snapshot.'
    $snapshotPath = & $module { $script:PshConfigSnapshotPath }
    Assert-PshConfig ([IO.Path]::GetFullPath([string]$snapshotPath) -eq [IO.Path]::GetFullPath($configPath)) 'Root module consumed the wrong configuration path snapshot.'

    $versionEditionBeforeChange = & $module { (Get-PshVersionData -Specification (Import-PshSpecification)).edition }
    Assert-PshConfig ([string]$versionEditionBeforeChange -eq 'Core') 'Version data did not use the imported Core snapshot.'

    [IO.File]::WriteAllText($configPath, "@{ SchemaVersion = 1; Edition = 'Full'; DisabledCommands = @('pwd', 'find') }`n", $utf8WithoutBom)
    $versionEditionAfterChange = & $module { (Get-PshVersionData -Specification (Import-PshSpecification)).edition }
    Assert-PshConfig ([string]$versionEditionAfterChange -eq 'Core') 'Version data re-read Edition after module import.'
    $capabilitiesAfterChange = @(& psh capabilities --json) -join "`n" | ConvertFrom-Json
    Assert-PshConfig ([string]$capabilitiesAfterChange.edition -eq 'Core') 'Capabilities re-read Edition after module import.'
    $fdAfterChange = @(& 'Psh\fd' --help)
    Assert-PshConfig ($LASTEXITCODE -eq 0 -and ($fdAfterChange -join "`n").StartsWith('Usage: fd [-gH0]')) 'fd changed from the imported Core backend before re-import.'
    $null = @(& psh config set DisabledCommands find PWD)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'Config set could not replace a valid Full-edition configuration.'
    $fullConfig = Import-PowerShellDataFile -LiteralPath $configPath
    Assert-PshConfig ([string]$fullConfig.Edition -eq 'Full') 'Config set did not preserve Edition=Full.'

    $validFullBytes = [IO.File]::ReadAllBytes($configPath)
    [IO.File]::WriteAllText($configPath, "@{ SchemaVersion = 2; Edition = 'Full'; DisabledCommands = @('pwd') }`n", $utf8WithoutBom)
    $invalidSchemaBytes = [IO.File]::ReadAllBytes($configPath)
    $null = @(& psh config reset DisabledCommands)
    Assert-PshConfig ($LASTEXITCODE -eq 3) 'Reset of an unsupported config schema did not exit 3.'
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $invalidSchemaBytes -Right ([IO.File]::ReadAllBytes($configPath))) 'Reset overwrote an unsupported config schema.'
    [IO.File]::WriteAllBytes($configPath, $validFullBytes)

    $resetOutput = @(& psh config reset DisabledCommands)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'psh config reset failed.'
    Assert-PshConfig ($resetOutput[0] -eq 'DisabledCommands = @()') 'Config reset reported the wrong value.'
    $resetConfig = Import-PowerShellDataFile -LiteralPath $configPath
    Assert-PshConfig ([string]$resetConfig.Edition -eq 'Full' -and @($resetConfig.DisabledCommands).Count -eq 0) 'Config reset did not preserve Edition while clearing DisabledCommands.'
    Assert-PshConfig ($null -eq (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'Config reset changed the current session before re-import.'
    Assert-PshConfigNoAtomicDebris -Directory $configDirectory

    Import-PshConfigModule -Manifest $moduleManifest
    Assert-PshConfig ($null -ne (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'Config reset did not restore pwd after re-import.'

    $specification = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Specification/commands.psd1')
    $allCommandNames = @($specification.Commands | ForEach-Object { [string]$_.Name })
    $disableAllArguments = @('config', 'set', 'DisabledCommands') + $allCommandNames
    $null = @(& psh @disableAllArguments)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'Config set could not disable all 64 commands.'
    $allDisabledConfig = Import-PowerShellDataFile -LiteralPath $configPath
    Assert-PshConfig (@($allDisabledConfig.DisabledCommands).Count -eq 64) 'Config set did not persist all 64 disabled commands.'
    Import-PshConfigModule -Manifest $moduleManifest
    Assert-PshConfig ($null -ne (Get-Command -Name psh -CommandType Function -ErrorAction SilentlyContinue)) 'Disabling all commands removed the psh management command.'
    Assert-PshConfig ($null -ne (Get-Command -Name Find-PshItem -CommandType Function -ErrorAction SilentlyContinue)) 'Disabling all commands removed an object API.'
    foreach ($fileCommandName in @('pwd', 'cd', 'ls', 'mkdir', 'rmdir', 'cp', 'mv', 'rm', 'touch', 'ln', 'realpath', 'basename', 'dirname', 'stat', 'file', 'tree', 'find', 'fd', 'du', 'df', 'mktemp')) {
        Assert-PshConfig ($null -eq (Get-Command -Name ("Psh\{0}" -f $fileCommandName) -ErrorAction SilentlyContinue)) ('All-disabled import still exported {0}.' -f $fileCommandName)
    }
    $null = @(& psh config reset DisabledCommands)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'The management command could not reset an all-disabled configuration.'

    $invalidLocalAppData = Join-Path -Path $testRoot -ChildPath 'invalid-local-app-data'
    $invalidConfigDirectory = Join-Path -Path $invalidLocalAppData -ChildPath 'Psh'
    [void][IO.Directory]::CreateDirectory($invalidConfigDirectory)
    [IO.File]::WriteAllText((Join-Path -Path $invalidConfigDirectory -ChildPath 'config.psd1'), "@{ SchemaVersion = 1; Edition = 'Full'; DisabledCommands = @('pwd', 'not-a-psh-command') }`n", $utf8WithoutBom)
    $env:LOCALAPPDATA = $invalidLocalAppData
    Import-PshConfigModule -Manifest $moduleManifest
    Assert-PshConfig ($null -ne (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'An invalid unknown command was partially applied during projection.'
    $invalidModule = Get-Module -Name Psh -ErrorAction Stop
    $invalidSnapshot = & $invalidModule {
        [PSCustomObject]@{
            Edition = $script:PshConfigEdition
            DisabledCount = $script:PshDisabledCommands.Count
            Error = $script:PshConfigLoadError
        }
    }
    Assert-PshConfig ([string]$invalidSnapshot.Edition -eq 'Core' -and [int]$invalidSnapshot.DisabledCount -eq 0) 'An invalid config did not fail open as one Core/empty snapshot.'
    Assert-PshConfig (-not [string]::IsNullOrWhiteSpace([string]$invalidSnapshot.Error) -and [string]$invalidSnapshot.Error -match 'unknown command') 'An invalid config did not retain a load diagnostic.'

    $stageRoot = Join-Path -Path $testRoot -ChildPath 'stage-install'
    $stageVersionRoot = Join-Path -Path $stageRoot -ChildPath 'versions/0.1.0'
    $stageModuleRoot = Join-Path -Path $stageVersionRoot -ChildPath 'Psh'
    [void][IO.Directory]::CreateDirectory($stageVersionRoot)
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh') -Destination $stageModuleRoot -Recurse -Force
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $sourceConfigTemplate -Destination (Join-Path -Path $stageRoot -ChildPath 'config.psd1') -Force
    $stageLocalAppData = Join-Path -Path $testRoot -ChildPath 'stage-local-app-data'
    $env:LOCALAPPDATA = $stageLocalAppData
    Import-PshConfigModule -Manifest (Join-Path -Path $stageModuleRoot -ChildPath 'Psh.psd1')
    $null = @(& psh config set DisabledCommands pwd)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'Config set failed in an exact staged installation layout.'
    $stageConfig = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $stageRoot -ChildPath 'config.psd1')
    Assert-PshConfig ((@($stageConfig.DisabledCommands) -join '|') -eq 'pwd') 'Config set did not update the staged sibling configuration.'
    Assert-PshConfig (-not [IO.File]::Exists((Join-Path -Path $stageLocalAppData -ChildPath 'Psh/config.psd1'))) 'Staged config set created a canonical file instead of using the existing sibling.'

    $looseRoot = Join-Path -Path $testRoot -ChildPath 'loose-parent'
    $looseModuleRoot = Join-Path -Path $looseRoot -ChildPath 'nested/Psh'
    [void][IO.Directory]::CreateDirectory((Split-Path -Path $looseModuleRoot -Parent))
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh') -Destination $looseModuleRoot -Recurse -Force
    $unrelatedConfigPath = Join-Path -Path $looseRoot -ChildPath 'config.psd1'
    [IO.File]::WriteAllText($unrelatedConfigPath, "@{ SchemaVersion = 1; Edition = 'Core'; DisabledCommands = @('pwd') }`n", $utf8WithoutBom)
    $unrelatedBytes = [IO.File]::ReadAllBytes($unrelatedConfigPath)
    $looseLocalAppData = Join-Path -Path $testRoot -ChildPath 'loose-local-app-data'
    $env:LOCALAPPDATA = $looseLocalAppData
    Import-PshConfigModule -Manifest (Join-Path -Path $looseModuleRoot -ChildPath 'Psh.psd1')
    Assert-PshConfig ($null -ne (Get-Command -Name 'Psh\pwd' -ErrorAction SilentlyContinue)) 'A loose module import read an arbitrary ancestor config.psd1.'
    $null = @(& psh config set DisabledCommands find)
    Assert-PshConfig ($LASTEXITCODE -eq 0) 'Loose module config set failed at the canonical path.'
    Assert-PshConfig ([IO.File]::Exists((Join-Path -Path $looseLocalAppData -ChildPath 'Psh/config.psd1'))) 'Loose module config set did not create the canonical current-user configuration.'
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $unrelatedBytes -Right ([IO.File]::ReadAllBytes($unrelatedConfigPath))) 'Loose module config set overwrote an arbitrary ancestor config.psd1.'
    Assert-PshConfig (Test-PshConfigBytesEqual -Left $sourceTemplateBytes -Right ([IO.File]::ReadAllBytes($sourceConfigTemplate))) 'Config acceptance modified the source config template.'

    Write-Output ('Goal 3 Batch 1 config acceptance passed: {0} assertions.' -f $assertionCount)
}
finally {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    if ([IO.Directory]::Exists($testRoot)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
