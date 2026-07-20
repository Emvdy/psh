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
$expectedTierPartitions = @{
    1 = @('pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname mktemp cat head tail cut tr sort uniq wc tee printf echo base64 which env printenv test sleep sha256sum md5sum'.Split(' '))
    2 = @('stat file tree find fd du df bat grep rg sed awk jq xargs export ps kill pgrep pkill timeout curl wget tar zip unzip gzip gunzip'.Split(' '))
    3 = @('date whoami hostname clear'.Split(' '))
}
$expectedPlatformShapedCommands = @(
    'ls', 'stat', 'file', 'tree', 'du', 'df', 'which', 'ps', 'pgrep', 'pkill',
    'date', 'whoami', 'hostname', 'clear'
)

$specificationPath = Join-Path $RepositoryRoot 'src/Psh/Specification/commands.psd1'
$manifestPath = Join-Path $RepositoryRoot 'src/Psh/Psh.psd1'
$generatorPath = Join-Path $RepositoryRoot 'scripts/Generate-CommandArtifacts.ps1'

Assert-PshCondition (Test-Path -LiteralPath $specificationPath -PathType Leaf) 'The command specification is missing.'
Assert-PshCondition (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The module manifest is missing.'
Assert-PshCondition (Test-Path -LiteralPath $generatorPath -PathType Leaf) 'The artifact generator is missing.'

$specification = Import-PowerShellDataFile -LiteralPath $specificationPath
Assert-PshCondition ([string]$specification.SchemaVersion -eq '1.1') 'Unexpected specification schema version.'
Assert-PshCondition ($specification.PshVersion -eq '0.1.0') 'Unexpected Psh version in the specification.'
Assert-PshCondition ((@($specification.CommandTiers.Tier) -join ',') -eq '1,2,3') 'The specification does not define command tiers 1 through 3.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Description -match 'Core implements the documented subset') 'Tier 2 does not document the Core subset boundary.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Description -match 'Full native rg, fd, jq, and bat accept') 'Tier 2 does not document the Full native complete-argument exception.'
Assert-PshCondition ([string]$specification.CommandTiers[1].Validation -match 'exit code 2') 'Tier 2 does not document usage exit code 2 for unsupported PowerShell-subset syntax.'
Assert-PshCondition ((@($specification.NameCollisionPolicy.ResolutionOrder) -join '|') -eq 'Psh function|built-in alias|native executable') 'The name-collision resolution order drifted from PLAN.md.'
Assert-PshCondition ([string]$specification.NameCollisionPolicy.DisableConfigKey -eq 'DisabledCommands') 'The name-collision disable key is not DisabledCommands.'

$actualNames = @($specification.Commands | ForEach-Object { $_.Name })
Assert-PshCondition ($actualNames.Count -eq 64) 'The specification must contain exactly 64 commands.'
Assert-PshCondition (@($actualNames | Group-Object | Where-Object { $_.Count -ne 1 }).Count -eq 0) 'Command names must be unique.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) ($actualNames | Sort-Object)).Count -eq 0) 'The 64 command names do not match PLAN.md.'

foreach ($tierNumber in @(1, 2, 3)) {
    $actualTierCommands = @($specification.Commands | Where-Object { [int]$_.Tier -eq $tierNumber } | ForEach-Object { [string]$_.Name })
    Assert-PshCondition (($actualTierCommands -join '|') -eq ($expectedTierPartitions[$tierNumber] -join '|')) "Tier $tierNumber does not exactly match PLAN.md."
}
$actualPlatformShapedCommands = @($specification.Commands | Where-Object { [bool]$_.PlatformShaped } | ForEach-Object { [string]$_.Name })
Assert-PshCondition (($actualPlatformShapedCommands -join '|') -eq ($expectedPlatformShapedCommands -join '|')) 'Platform-shaped command metadata drifted.'

$actualManagement = @($specification.ManagementCommands | ForEach-Object { $_.Name })
Assert-PshCondition (@(Compare-Object ($expectedManagementCommands | Sort-Object) ($actualManagement | Sort-Object)).Count -eq 0) 'Management commands do not match PLAN.md.'
Assert-PshCondition (((@($specification.ExitCodes | ForEach-Object { [int]$_.Code }) | Sort-Object) -join ',') -eq '0,1,2,3,4,5') 'The exit-code contract must define 0 through 5.'

foreach ($command in $specification.Commands) {
    Assert-PshCondition ([int]$command.Tier -in @(1, 2, 3)) "$($command.Name) has invalid tier metadata."
    Assert-PshCondition ($command.PlatformShaped -is [bool]) "$($command.Name) has non-Boolean PlatformShaped metadata."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.EditionNotes)) "$($command.Name) has no Core/Full compatibility notes."
    Assert-PshCondition ($null -ne $command.CollisionTargets) "$($command.Name) has no collision target data."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.CollisionNotes)) "$($command.Name) has no collision notes."
    foreach ($collisionTarget in @($command.CollisionTargets)) {
        Assert-PshCondition ([string]$collisionTarget -match '^(alias|native):[^:]+$') "$($command.Name) uses an unsupported collision category: $collisionTarget"
    }
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Summary)) "$($command.Name) has no help summary."
    Assert-PshCondition ($null -ne $command.Flags) "$($command.Name) has no completion flag data."
    Assert-PshCondition (@($command.ExitCodes).Count -gt 0) "$($command.Name) has no exit-code data."
    Assert-PshCondition (@($command.Examples).Count -gt 0) "$($command.Name) has no examples."
    Assert-PshCondition ($command.CoreBackend -eq 'powershell') "$($command.Name) Core backend is not PowerShell."

    if ([int]$command.Tier -eq 2) {
        Assert-PshCondition (@($command.ExitCodes) -contains 2) "$($command.Name) Tier 2 contract does not expose usage exit code 2."
        Assert-PshCondition ([string]$command.EditionNotes -match 'unsupported syntax exits 2') "$($command.Name) Tier 2 notes do not document unsupported syntax exit code 2."
    }

    if ($nativeFullCommands -contains $command.Name) {
        Assert-PshCondition ($command.FullBackend -eq ("native:{0}" -f $command.Name)) "$($command.Name) Full backend is not its pinned native tool."
    }
    else {
        Assert-PshCondition ($command.FullBackend -eq 'powershell') "$($command.Name) unexpectedly uses a native Full backend."
    }
}

& $generatorPath -Check

$specificationText = [IO.File]::ReadAllText($specificationPath)
$generatorValidationRoot = Join-Path ([IO.Path]::GetTempPath()) ("psh-goal1-generator-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($generatorValidationRoot) | Out-Null
    $generatorMutationCases = @(
        @{
            Name = 'tier-partition'
            Find = "            Name = 'pwd'`n            Tier = 1"
            Replace = "            Name = 'pwd'`n            Tier = 2"
            ExpectedError = 'Tier 1 command partition does not exactly match PLAN.md.'
        }
        @{
            Name = 'collision-order'
            Find = "ResolutionOrder = @('Psh function', 'built-in alias', 'native executable')"
            Replace = "ResolutionOrder = @('built-in alias', 'Psh function', 'native executable')"
            ExpectedError = 'NameCollisionPolicy resolution order must be Psh function, built-in alias, then native executable.'
        }
        @{
            Name = 'required-command-metadata'
            Find = "            CollisionNotes = 'Shadows the built-in pwd alias; disabling this Psh command restores alias resolution.'"
            Replace = "            CollisionDetail = 'Shadows the built-in pwd alias; disabling this Psh command restores alias resolution.'"
            ExpectedError = "command 'pwd' is missing 'CollisionNotes'."
        }
    )

    foreach ($mutationCase in $generatorMutationCases) {
        Assert-PshCondition ($specificationText.Contains([string]$mutationCase.Find)) "Generator validation fixture '$($mutationCase.Name)' did not match the canonical specification."
        $mutatedSpecification = $specificationText.Replace([string]$mutationCase.Find, [string]$mutationCase.Replace)
        $mutatedSpecificationPath = Join-Path $generatorValidationRoot ("{0}.psd1" -f $mutationCase.Name)
        [IO.File]::WriteAllText($mutatedSpecificationPath, $mutatedSpecification, (New-Object System.Text.UTF8Encoding($false)))

        $validationError = $null
        try {
            & $generatorPath -Check -SpecificationPath $mutatedSpecificationPath | Out-Null
        }
        catch {
            $validationError = $_.Exception.Message
        }
        Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$validationError)) "Generator accepted invalid '$($mutationCase.Name)' metadata."
        Assert-PshCondition ([string]$validationError -like ("*{0}*" -f $mutationCase.ExpectedError)) "Generator rejected '$($mutationCase.Name)' for the wrong reason: $validationError"
    }
}
finally {
    if (Test-Path -LiteralPath $generatorValidationRoot) {
        Remove-Item -LiteralPath $generatorValidationRoot -Recurse -Force
    }
}

$generatedFiles = @(
    (Join-Path $RepositoryRoot 'generated/commands.json'),
    (Join-Path $RepositoryRoot 'docs/compatibility.md'),
    (Join-Path $RepositoryRoot 'docs/install-layout.md'),
    (Join-Path $RepositoryRoot 'src/Psh/Generated/ArgumentCompleters.ps1')
)
foreach ($generatedFile in $generatedFiles) {
    Assert-PshCondition (Test-Path -LiteralPath $generatedFile -PathType Leaf) "Missing generated artifact: $generatedFile"
    $bytes = [IO.File]::ReadAllBytes($generatedFile)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-PshCondition (-not $hasBom) "Generated artifact has a UTF-8 BOM: $generatedFile"
}

$generatedSpecification = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'generated/commands.json') -Raw | ConvertFrom-Json
Assert-PshCondition ([string]$generatedSpecification.SchemaVersion -eq '1.1') 'Generated commands.json has the wrong schema version.'
Assert-PshCondition ((@($generatedSpecification.NameCollisionPolicy.ResolutionOrder) -join '|') -eq 'Psh function|built-in alias|native executable') 'Generated commands.json has the wrong collision resolution order.'
Assert-PshCondition ([string]$generatedSpecification.NameCollisionPolicy.DisableConfigKey -eq 'DisabledCommands') 'Generated commands.json has the wrong disable config key.'
Assert-PshCondition (@($generatedSpecification.CommandTiers).Count -eq @($specification.CommandTiers).Count) 'Generated commands.json has the wrong command-tier count.'
for ($tierIndex = 0; $tierIndex -lt @($specification.CommandTiers).Count; $tierIndex++) {
    $sourceTier = @($specification.CommandTiers)[$tierIndex]
    $generatedTier = @($generatedSpecification.CommandTiers)[$tierIndex]
    foreach ($tierProperty in @('Tier', 'Name', 'Description', 'Validation')) {
        Assert-PshCondition ([string]$generatedTier.$tierProperty -ceq [string]$sourceTier[$tierProperty]) "Generated command tier $($tierIndex + 1) '$tierProperty' drifted from the source specification."
    }
}
Assert-PshCondition (@($generatedSpecification.Commands).Count -eq 64) 'Generated commands.json does not contain 64 commands.'
Assert-PshCondition (@(Compare-Object ($expectedCommands | Sort-Object) (@($generatedSpecification.Commands.Name) | Sort-Object)).Count -eq 0) 'Generated commands.json command names drifted from PLAN.md.'
Assert-PshCondition ((@($generatedSpecification.Commands.Name) -join '|') -eq ($actualNames -join '|')) 'Generated commands.json command order drifted from the source specification.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 1 }).Count -eq 33) 'Generated commands.json has the wrong Tier 1 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 2 }).Count -eq 27) 'Generated commands.json has the wrong Tier 2 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [int]$_.Tier -eq 3 }).Count -eq 4) 'Generated commands.json has the wrong Tier 3 count.'
Assert-PshCondition (@($generatedSpecification.Commands | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.CollisionNotes) }).Count -eq 0) 'Generated commands.json omitted per-command collision notes.'

$sourceCommandByName = @{}
foreach ($sourceCommand in @($specification.Commands)) {
    $sourceCommandByName[[string]$sourceCommand.Name] = $sourceCommand
}
foreach ($generatedCommand in @($generatedSpecification.Commands)) {
    $sourceCommand = $sourceCommandByName[[string]$generatedCommand.Name]
    Assert-PshCondition ($null -ne $sourceCommand) "Generated commands.json contains unknown command '$($generatedCommand.Name)'."
    foreach ($metadataProperty in @('Tier', 'PlatformShaped', 'EditionNotes', 'CollisionTargets', 'CollisionNotes')) {
        Assert-PshCondition ($null -ne $generatedCommand.PSObject.Properties[$metadataProperty]) "$($generatedCommand.Name) generated metadata is missing '$metadataProperty'."
    }
    Assert-PshCondition ([int]$generatedCommand.Tier -eq [int]$sourceCommand.Tier) "$($generatedCommand.Name) generated Tier drifted from the source specification."
    Assert-PshCondition ([bool]$generatedCommand.PlatformShaped -eq [bool]$sourceCommand.PlatformShaped) "$($generatedCommand.Name) generated PlatformShaped drifted from the source specification."
    Assert-PshCondition ([string]$generatedCommand.EditionNotes -ceq [string]$sourceCommand.EditionNotes) "$($generatedCommand.Name) generated EditionNotes drifted from the source specification."
    Assert-PshCondition ((@($generatedCommand.CollisionTargets) -join '|') -ceq (@($sourceCommand.CollisionTargets) -join '|')) "$($generatedCommand.Name) generated CollisionTargets drifted from the source specification."
    Assert-PshCondition ([string]$generatedCommand.CollisionNotes -ceq [string]$sourceCommand.CollisionNotes) "$($generatedCommand.Name) generated CollisionNotes drifted from the source specification."
}

$compatibilityText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'docs/compatibility.md'))
foreach ($requiredDocumentation in @(
    'Tier 2 uses documented PowerShell subsets in Core',
    'unsupported syntax in those subsets is rejected with exit code `2`',
    'Full native `rg`, `fd`, `jq`, and `bat` instead accept their pinned tools'' complete argument sets',
    'Psh function` > `built-in alias` > `native executable',
    'psh config set DisabledCommands curl wget',
    'Full delegates `rg`, `fd`, `jq`, and `bat`'
)) {
    Assert-PshCondition ($compatibilityText.Contains($requiredDocumentation)) "Compatibility documentation is missing: $requiredDocumentation"
}

$defaultConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $RepositoryRoot 'src/install/config.psd1')
Assert-PshCondition ($defaultConfig.Contains('DisabledCommands')) 'Default config.psd1 is missing DisabledCommands.'
Assert-PshCondition (@($defaultConfig.DisabledCommands).Count -eq 0) 'Default config.psd1 must enable all commands with an empty DisabledCommands array.'

$installLayoutText = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'docs/install-layout.md'))
Assert-PshCondition ($installLayoutText.Contains('DisabledCommands = @()')) 'Generated install layout omits the required DisabledCommands default.'
Assert-PshCondition ($installLayoutText.Contains('Changes are persisted only and take effect in a new shell or after `Remove-Module Psh; Import-Module Psh`.')) 'Generated install layout omits config activation semantics.'

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
    'Start-Process[^\r\n]+-Verb\s+RunAs'
)
foreach ($pattern in $unsafePatterns) {
    $matches = @(
        $sourceFiles | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern $pattern
        }
    )
    Assert-PshCondition ($matches.Count -eq 0) "Goal 1 source contains a forbidden startup, elevation, or policy pattern: $pattern"
}

# Goal 5 must be able to print a read-only execution-policy remediation hint.
# Permit exactly that diagnostic constant while keeping the policy mutation
# spelling forbidden everywhere else.  The PowerShell AST check below catches
# an actual command invocation independently of comments and string literals.
$policyDiagnosticPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'src/bootstrapper/Program.cs'))
$policyDiagnosticLine = 'private const string PolicyRemediation = "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned";'
$policyLiteralMatches = @(
    $sourceFiles | ForEach-Object {
        Select-String -LiteralPath $_.FullName -SimpleMatch 'Set-ExecutionPolicy'
    }
)
$unexpectedPolicyLiteralMatches = @(
    $policyLiteralMatches | Where-Object {
        $matchPath = [IO.Path]::GetFullPath([string]$_.Path)
        -not ([string]::Equals($matchPath, $policyDiagnosticPath, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals(([string]$_.Line).Trim(), $policyDiagnosticLine, [StringComparison]::Ordinal))
    }
)
Assert-PshCondition ($policyLiteralMatches.Count -eq 1 -and $unexpectedPolicyLiteralMatches.Count -eq 0) 'Goal 1 source contains an execution-policy mutation or an unapproved policy diagnostic.'

$policyCommandFindings = New-Object System.Collections.Generic.List[string]
foreach ($powerShellSource in @($sourceFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($powerShellSource.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-PshCondition (@($parseErrors).Count -eq 0) "PowerShell source could not be parsed for policy-command validation: $($powerShellSource.FullName)"
    foreach ($command in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    [string]$node.GetCommandName() -ieq 'Set-ExecutionPolicy'
            }, $true))) {
        $policyCommandFindings.Add(('{0}:{1}' -f $powerShellSource.FullName, $command.Extent.StartLineNumber))
    }
}
Assert-PshCondition ($policyCommandFindings.Count -eq 0) ('Goal 1 source executes Set-ExecutionPolicy: {0}' -f ([string]::Join(', ', $policyCommandFindings.ToArray())))

$originalEdition = $env:PSH_EDITION
try {
    Remove-Module Psh -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force -ErrorAction Stop

    $module = Get-Module -Name Psh
    $completerLoadError = & $module { $script:PshCompleterLoadError }
    Assert-PshCondition ([string]::IsNullOrWhiteSpace([string]$completerLoadError)) "Generated argument completers failed to load: $completerLoadError"
    $completion = TabExpansion2 -InputScript 'psh cap' -CursorColumn 7
    Assert-PshCondition (@($completion.CompletionMatches.CompletionText) -contains 'capabilities') 'Generated management completion did not offer capabilities.'

    $configKeyInput = 'psh config set Dis'
    $configKeyCompletion = TabExpansion2 -InputScript $configKeyInput -CursorColumn $configKeyInput.Length
    Assert-PshCondition (@($configKeyCompletion.CompletionMatches.CompletionText) -contains 'DisabledCommands') 'Generated config completion did not offer DisabledCommands.'

    $fdGeneratedFlags = @(& $module { @($script:PshCommandFlags['fd']) })
    Assert-PshCondition ($fdGeneratedFlags -contains '-e') 'Generated fd completion metadata omitted the documented -e extension filter.'

    foreach ($expectedCommand in $expectedCommands) {
        $disabledCommandInput = "psh config set DisabledCommands $expectedCommand"
        $disabledCommandCompletion = TabExpansion2 -InputScript $disabledCommandInput -CursorColumn $disabledCommandInput.Length
        Assert-PshCondition (@($disabledCommandCompletion.CompletionMatches.CompletionText) -contains $expectedCommand) "Generated config completion did not offer '$expectedCommand' for DisabledCommands."
    }

    foreach ($edition in @('Core', 'Full')) {
        $env:PSH_EDITION = $edition
        $jsonOutput = @(& psh capabilities --json)
        Assert-PshCondition ($LASTEXITCODE -eq 0) "psh capabilities --json failed for $edition."
        $capabilities = Convert-PshOutputFromJson -Output $jsonOutput
        Assert-PshCondition ($capabilities.edition -eq $edition) "Capabilities reported the wrong edition for $edition."
        Assert-PshCondition (@($capabilities.commands).Count -eq 64) "Capabilities did not report 64 commands for $edition."

        foreach ($capability in $capabilities.commands) {
            if ($edition -eq 'Full' -and $nativeFullCommands -contains $capability.name) {
                $nativeState = [string]$capability.nativeState
                Assert-PshCondition ($nativeState -in @('pinned', 'unavailable', 'missing', 'invalid', 'tampered', 'wrong-architecture')) "$($capability.name) reported an unexpected Full native state: $nativeState."
                if ($nativeState -eq 'pinned') {
                    Assert-PshCondition ($capability.activeBackend -eq ("native:{0}" -f $capability.name)) "$($capability.name) reported the wrong Full backend for a healthy pinned tool."
                }
                else {
                    Assert-PshCondition ($capability.activeBackend -eq 'unavailable') "$($capability.name) exposed a usable Full backend while its pinned tool was $nativeState."
                }
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
