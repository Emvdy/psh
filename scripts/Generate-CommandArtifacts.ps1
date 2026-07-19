# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [switch]$Check,
    [string]$SpecificationPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SpecificationPath)) {
    $SpecificationPath = Join-Path $repositoryRoot 'src/Psh/Specification/commands.psd1'
}
$SpecificationPath = [System.IO.Path]::GetFullPath($SpecificationPath)

function Assert-PshCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Command specification validation failed: $Message"
    }
}

function Test-PshProperty {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Assert-PshFlags {
    param(
        [object]$Command,
        [string[]]$RequiredFlags
    )

    $actualFlags = @($Command.Flags)
    foreach ($requiredFlag in $RequiredFlags) {
        Assert-PshCondition ($actualFlags -contains $requiredFlag) "command '$($Command.Name)' is missing required flag '$requiredFlag'."
    }
}

function ConvertTo-PshMarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function ConvertTo-PshSingleQuotedString {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-PshStringArrayLiteral {
    param([object[]]$Values)

    $quoted = @(
        foreach ($value in @($Values)) {
            ConvertTo-PshSingleQuotedString ([string]$value)
        }
    )
    return '@(' + ($quoted -join ', ') + ')'
}

function New-PshJsonObject {
    param(
        [string[]]$PropertyNames,
        [object]$Source
    )

    $result = New-Object PSObject
    foreach ($propertyName in $PropertyNames) {
        $value = $Source[$propertyName]
        Add-Member -InputObject $result -MemberType NoteProperty -Name $propertyName -Value $value
    }
    return $result
}

function New-PshCommandsJson {
    param([hashtable]$Specification)

    $commandTiers = @(
        foreach ($commandTier in @($Specification.CommandTiers)) {
            $item = New-Object PSObject
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Tier' -Value ([int]$commandTier.Tier)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Name' -Value ([string]$commandTier.Name)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Description' -Value ([string]$commandTier.Description)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Validation' -Value ([string]$commandTier.Validation)
            $item
        }
    )
    $nameCollisionPolicy = New-Object PSObject
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'ResolutionOrder' -Value @($Specification.NameCollisionPolicy.ResolutionOrder)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'DisableConfigKey' -Value ([string]$Specification.NameCollisionPolicy.DisableConfigKey)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'DefaultDisabledCommands' -Value @($Specification.NameCollisionPolicy.DefaultDisabledCommands)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'ConfigSyntax' -Value @($Specification.NameCollisionPolicy.ConfigSyntax)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'ConfigPath' -Value ([string]$Specification.NameCollisionPolicy.ConfigPath)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'InstalledConfigFallback' -Value ([string]$Specification.NameCollisionPolicy.InstalledConfigFallback)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'ConfigSummary' -Value ([string]$Specification.NameCollisionPolicy.ConfigSummary)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'Activation' -Value ([string]$Specification.NameCollisionPolicy.Activation)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'DisableCommandExample' -Value ([string]$Specification.NameCollisionPolicy.DisableCommandExample)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'ResetCommandExample' -Value ([string]$Specification.NameCollisionPolicy.ResetCommandExample)
    Add-Member -InputObject $nameCollisionPolicy -MemberType NoteProperty -Name 'Summary' -Value ([string]$Specification.NameCollisionPolicy.Summary)
    $exitCodes = @(
        foreach ($exitCode in @($Specification.ExitCodes)) {
            New-PshJsonObject @('Code', 'Name', 'Description') $exitCode
        }
    )
    $editions = @(
        foreach ($edition in @($Specification.Editions)) {
            $item = New-Object PSObject
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Name' -Value ([string]$edition.Name)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Summary' -Value ([string]$edition.Summary)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'NativeTools' -Value @($edition.NativeTools)
            $item
        }
    )
    $objectApis = @(
        foreach ($objectApi in @($Specification.ObjectApis)) {
            $item = New-Object PSObject
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Name' -Value ([string]$objectApi.Name)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Commands' -Value @($objectApi.Commands)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Summary' -Value ([string]$objectApi.Summary)
            $item
        }
    )
    $managementCommands = @(
        foreach ($managementCommand in @($Specification.ManagementCommands)) {
            $item = New-Object PSObject
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Name' -Value ([string]$managementCommand.Name)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Summary' -Value ([string]$managementCommand.Summary)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'SupportsJson' -Value ([bool]$managementCommand.SupportsJson)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Flags' -Value @($managementCommand.Flags)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'ExitCodes' -Value @($managementCommand.ExitCodes)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Examples' -Value @($managementCommand.Examples)
            $item
        }
    )
    $commands = @(
        foreach ($command in @($Specification.Commands)) {
            $item = New-Object PSObject
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Name' -Value ([string]$command.Name)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Tier' -Value ([int]$command.Tier)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'PlatformShaped' -Value ([bool]$command.PlatformShaped)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'EditionNotes' -Value ([string]$command.EditionNotes)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'CollisionTargets' -Value @($command.CollisionTargets)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'CollisionNotes' -Value ([string]$command.CollisionNotes)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Category' -Value ([string]$command.Category)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Summary' -Value ([string]$command.Summary)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Flags' -Value @($command.Flags)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'ExitCodes' -Value @($command.ExitCodes)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'CoreBackend' -Value ([string]$command.CoreBackend)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'FullBackend' -Value ([string]$command.FullBackend)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'ObjectApi' -Value ([string]$command.ObjectApi)
            Add-Member -InputObject $item -MemberType NoteProperty -Name 'Examples' -Value @($command.Examples)
            $item
        }
    )

    $root = New-Object PSObject
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'SchemaVersion' -Value ([string]$Specification.SchemaVersion)
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'PshVersion' -Value ([string]$Specification.PshVersion)
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'CommandTiers' -Value $commandTiers
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'NameCollisionPolicy' -Value $nameCollisionPolicy
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'ExitCodes' -Value $exitCodes
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'Editions' -Value $editions
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'ObjectApis' -Value $objectApis
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'ManagementCommands' -Value $managementCommands
    Add-Member -InputObject $root -MemberType NoteProperty -Name 'Commands' -Value $commands

    return ($root | ConvertTo-Json -Depth 12 -Compress) + "`n"
}

function New-PshCompatibilityMarkdown {
    param([hashtable]$Specification)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('<!-- SPDX-License-Identifier: GPL-3.0-or-later -->')
    [void]$lines.Add('<!-- Generated by scripts/Generate-CommandArtifacts.ps1 from src/Psh/Specification/commands.psd1. Do not edit. -->')
    [void]$lines.Add('')
    [void]$lines.Add('# Psh command compatibility')
    [void]$lines.Add('')
    [void]$lines.Add("Specification schema: ``$($Specification.SchemaVersion)``. Psh version: ``$($Specification.PshVersion)``.")
    [void]$lines.Add('')
    [void]$lines.Add('Core uses PowerShell implementations and contains no third-party utility executables. Full delegates `rg`, `fd`, `jq`, and `bat` to pinned native tools; all other commands keep the PowerShell backend.')
    [void]$lines.Add('')
    [void]$lines.Add('For the four delegated commands, the flags listed below are common completion hints; Full accepts each pinned native tool''s complete argument set.')
    [void]$lines.Add('')
    [void]$lines.Add('## Command tiers')
    [void]$lines.Add('')
    [void]$lines.Add('All 64 commands ship in both editions. Tier 2 uses documented PowerShell subsets in Core and for PowerShell-backed Full commands; unsupported syntax in those subsets is rejected with exit code `2` (`UsageError`). Full native `rg`, `fd`, `jq`, and `bat` instead accept their pinned tools'' complete argument sets.')
    [void]$lines.Add('')
    [void]$lines.Add('| Tier | Fidelity target | Validation |')
    [void]$lines.Add('| ---: | --- | --- |')
    foreach ($commandTier in @($Specification.CommandTiers)) {
        $fidelity = '{0}: {1}' -f $commandTier.Name, $commandTier.Description
        [void]$lines.Add(('| {0} | {1} | {2} |' -f $commandTier.Tier, (ConvertTo-PshMarkdownCell $fidelity), (ConvertTo-PshMarkdownCell $commandTier.Validation)))
    }
    [void]$lines.Add('')
    [void]$lines.Add('Commands marked platform-shaped are verified with structural assertions instead of GNU golden bytes. Other Tier 1 text commands use GNU output normalized for path separators, line endings, and `LC_ALL=C` collation.')
    [void]$lines.Add('')
    [void]$lines.Add('## Editions')
    [void]$lines.Add('')
    [void]$lines.Add('| Edition | Native tools | Description |')
    [void]$lines.Add('| --- | --- | --- |')
    foreach ($edition in @($Specification.Editions)) {
        $nativeTools = if (@($edition.NativeTools).Count -eq 0) { '-' } else { @($edition.NativeTools) -join ', ' }
        [void]$lines.Add(('| {0} | {1} | {2} |' -f (ConvertTo-PshMarkdownCell $edition.Name), (ConvertTo-PshMarkdownCell $nativeTools), (ConvertTo-PshMarkdownCell $edition.Summary)))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Name collision policy')
    [void]$lines.Add('')
    $resolutionOrder = @($Specification.NameCollisionPolicy.ResolutionOrder | ForEach-Object { '`' + $_ + '`' }) -join ' > '
    [void]$lines.Add("Resolution order: $resolutionOrder.")
    [void]$lines.Add('')
    [void]$lines.Add([string]$Specification.NameCollisionPolicy.Summary)
    [void]$lines.Add('')
    [void]$lines.Add(('All commands are enabled by default (`{0} = @()`). Disable individual Psh functions with `{1}`; restore the default with `{2}`. A disabled name falls through to the built-in alias, then to the native executable.' -f (ConvertTo-PshMarkdownCell $Specification.NameCollisionPolicy.DisableConfigKey), (ConvertTo-PshMarkdownCell $Specification.NameCollisionPolicy.DisableCommandExample), (ConvertTo-PshMarkdownCell $Specification.NameCollisionPolicy.ResetCommandExample)))
    [void]$lines.Add('')
    [void]$lines.Add('### Disabled command configuration')
    [void]$lines.Add('')
    [void]$lines.Add([string]$Specification.NameCollisionPolicy.ConfigSummary)
    [void]$lines.Add('')
    [void]$lines.Add('Public syntax:')
    [void]$lines.Add('')
    foreach ($configSyntax in @($Specification.NameCollisionPolicy.ConfigSyntax)) {
        [void]$lines.Add(('- `{0}`' -f (ConvertTo-PshMarkdownCell $configSyntax)))
    }
    [void]$lines.Add('')
    $fallbackText = (ConvertTo-PshMarkdownCell $Specification.NameCollisionPolicy.InstalledConfigFallback).Replace('<', '&lt;').Replace('>', '&gt;')
    [void]$lines.Add(('The current-user file is `{0}`. {1}' -f (ConvertTo-PshMarkdownCell $Specification.NameCollisionPolicy.ConfigPath), $fallbackText))
    [void]$lines.Add('')
    $activationText = ([string]$Specification.NameCollisionPolicy.Activation).Replace('Remove-Module Psh; Import-Module Psh', '`Remove-Module Psh; Import-Module Psh`')
    [void]$lines.Add($activationText)
    [void]$lines.Add('')
    [void]$lines.Add('## Exit codes')
    [void]$lines.Add('')
    [void]$lines.Add('| Code | Name | Meaning |')
    [void]$lines.Add('| ---: | --- | --- |')
    foreach ($exitCode in @($Specification.ExitCodes)) {
        [void]$lines.Add(('| {0} | {1} | {2} |' -f $exitCode.Code, (ConvertTo-PshMarkdownCell $exitCode.Name), (ConvertTo-PshMarkdownCell $exitCode.Description)))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Object APIs')
    [void]$lines.Add('')
    [void]$lines.Add('| API | Commands | Description |')
    [void]$lines.Add('| --- | --- | --- |')
    foreach ($objectApi in @($Specification.ObjectApis)) {
        [void]$lines.Add(('| `{0}` | {1} | {2} |' -f (ConvertTo-PshMarkdownCell $objectApi.Name), (ConvertTo-PshMarkdownCell (@($objectApi.Commands) -join ', ')), (ConvertTo-PshMarkdownCell $objectApi.Summary)))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Management commands')
    [void]$lines.Add('')
    [void]$lines.Add('| Action | JSON | Flags | Description | Example |')
    [void]$lines.Add('| --- | :---: | --- | --- | --- |')
    foreach ($managementCommand in @($Specification.ManagementCommands)) {
        $jsonSupport = if ($managementCommand.SupportsJson) { 'yes' } else { 'no' }
        $flags = @($managementCommand.Flags | ForEach-Object { '`' + $_ + '`' }) -join ' '
        $example = @($managementCommand.Examples)[0]
        [void]$lines.Add(('| `psh {0}` | {1} | {2} | {3} | `{4}` |' -f (ConvertTo-PshMarkdownCell $managementCommand.Name), $jsonSupport, (ConvertTo-PshMarkdownCell $flags), (ConvertTo-PshMarkdownCell $managementCommand.Summary), (ConvertTo-PshMarkdownCell $example)))
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Bash-style commands')
    [void]$lines.Add('')
    [void]$lines.Add('| Command | Tier | Platform-shaped | Category | Core | Full | Edition notes | Collision targets | Collision notes | Object API | Flags | Example |')
    [void]$lines.Add('| --- | ---: | :---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($command in @($Specification.Commands)) {
        $objectApi = if ([string]::IsNullOrEmpty([string]$command.ObjectApi)) { '-' } else { '`' + $command.ObjectApi + '`' }
        $platformShaped = if ([bool]$command.PlatformShaped) { 'yes' } else { 'no' }
        $collisionTargets = if (@($command.CollisionTargets).Count -eq 0) { '-' } else { @($command.CollisionTargets | ForEach-Object { '`' + $_ + '`' }) -join ' ' }
        $flags = @($command.Flags | ForEach-Object { '`' + $_ + '`' }) -join ' '
        $example = @($command.Examples)[0]
        [void]$lines.Add(('| `{0}` | {1} | {2} | {3} | `{4}` | `{5}` | {6} | {7} | {8} | {9} | {10} | `{11}` |' -f (ConvertTo-PshMarkdownCell $command.Name), $command.Tier, $platformShaped, (ConvertTo-PshMarkdownCell $command.Category), (ConvertTo-PshMarkdownCell $command.CoreBackend), (ConvertTo-PshMarkdownCell $command.FullBackend), (ConvertTo-PshMarkdownCell $command.EditionNotes), (ConvertTo-PshMarkdownCell $collisionTargets), (ConvertTo-PshMarkdownCell $command.CollisionNotes), (ConvertTo-PshMarkdownCell $objectApi), (ConvertTo-PshMarkdownCell $flags), (ConvertTo-PshMarkdownCell $example)))
    }

    return ($lines -join "`n") + "`n"
}

function New-PshInstallLayoutMarkdown {
    param(
        [hashtable]$Specification,
        [hashtable]$DefaultConfig
    )

    $disableConfigKey = [string]$Specification.NameCollisionPolicy.DisableConfigKey
    $activationText = ([string]$Specification.NameCollisionPolicy.Activation).Replace('Remove-Module Psh; Import-Module Psh', '`Remove-Module Psh; Import-Module Psh`')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('<!-- SPDX-License-Identifier: GPL-3.0-or-later -->')
    [void]$lines.Add('<!-- Generated by scripts/Generate-CommandArtifacts.ps1 from src/Psh/Specification/commands.psd1 and src/install/config.psd1. Do not edit. -->')
    [void]$lines.Add('')
    [void]$lines.Add('# Current-User Installation Layout')
    [void]$lines.Add('')
    [void]$lines.Add('Psh uses a versioned, current-user installation rooted at')
    [void]$lines.Add('`%LOCALAPPDATA%\Psh`. The layout contract is:')
    [void]$lines.Add('')
    [void]$lines.Add('```text')
    [void]$lines.Add('%LOCALAPPDATA%\Psh\')
    [void]$lines.Add('|-- bootstrap.ps1')
    [void]$lines.Add('|-- config.psd1')
    [void]$lines.Add('|-- current.json')
    [void]$lines.Add('`-- versions\')
    [void]$lines.Add('    `-- <version>\')
    [void]$lines.Add('        `-- Psh\')
    [void]$lines.Add('            |-- Psh.psd1')
    [void]$lines.Add('            `-- ...')
    [void]$lines.Add('```')
    [void]$lines.Add('')
    [void]$lines.Add('`<version>` is a semantic version such as `0.1.0`, without the release tag''s')
    [void]$lines.Add('leading `v`. A version is eligible to become current only when')
    [void]$lines.Add('`versions\<version>\Psh\Psh.psd1` exists.')
    [void]$lines.Add('')
    [void]$lines.Add('## Stable Files')
    [void]$lines.Add('')
    [void]$lines.Add('`bootstrap.ps1` is the stable entry point for a shell session. It reads only')
    [void]$lines.Add('the adjacent local `current.json`, validates its schema and version, verifies')
    [void]$lines.Add('the selected module manifest, and imports that manifest into the session. It')
    [void]$lines.Add('does not download content, request elevation, change an execution policy,')
    [void]$lines.Add('change `PATH`, or edit a PowerShell profile.')
    [void]$lines.Add('')
    [void]$lines.Add('`config.psd1` is current-user configuration shared by installed versions. Its')
    [void]$lines.Add('initial contents select the Core edition and enable all Psh commands:')
    [void]$lines.Add('')
    [void]$lines.Add('```powershell')
    [void]$lines.Add('@{')
    [void]$lines.Add(('    {0,-17}= {1}' -f 'SchemaVersion', [int]$DefaultConfig.SchemaVersion))
    [void]$lines.Add(('    {0,-17}= {1}' -f 'Edition', (ConvertTo-PshSingleQuotedString ([string]$DefaultConfig.Edition))))
    [void]$lines.Add(('    {0,-17}= {1}' -f $disableConfigKey, (ConvertTo-PshStringArrayLiteral @($DefaultConfig[$disableConfigKey]))))
    [void]$lines.Add('}')
    [void]$lines.Add('```')
    [void]$lines.Add('')
    [void]$lines.Add([string]$Specification.NameCollisionPolicy.ConfigSummary)
    [void]$lines.Add('')
    [void]$lines.Add($activationText)
    [void]$lines.Add('')
    [void]$lines.Add('Version packages are immutable after their integrity has been verified. An')
    [void]$lines.Add('upgrade installs a new version directory rather than overwriting the selected')
    [void]$lines.Add('one.')
    [void]$lines.Add('')
    [void]$lines.Add('## Version Pointer')
    [void]$lines.Add('')
    [void]$lines.Add('`current.json` is local machine-readable state with this schema:')
    [void]$lines.Add('')
    [void]$lines.Add('```json')
    [void]$lines.Add('{"schemaVersion":1,"version":"0.1.0"}')
    [void]$lines.Add('```')
    [void]$lines.Add('')
    [void]$lines.Add('`Set-PshCurrentVersion.ps1` is the only primitive in this contract that writes')
    [void]$lines.Add('the pointer. Before writing, it validates the semantic version and the target')
    [void]$lines.Add('module manifest. It encodes a uniquely named temporary file as UTF-8 without a')
    [void]$lines.Add('BOM in the same directory as `current.json`, then performs one same-volume')
    [void]$lines.Add('filesystem operation:')
    [void]$lines.Add('')
    [void]$lines.Add('- `File.Replace` with a unique same-directory backup when `current.json`')
    [void]$lines.Add('  already exists, followed by best-effort cleanup of that Psh-owned backup;')
    [void]$lines.Add('- `File.Move` when no pointer exists yet.')
    [void]$lines.Add('')
    [void]$lines.Add('If validation or replacement fails, the previous `current.json` is left in')
    [void]$lines.Add('place and the script removes only the temporary and backup files it created.')
    [void]$lines.Add('The optional `-InstallRoot` parameter exists for installer staging and')
    [void]$lines.Add('isolated tests; the installed default remains `%LOCALAPPDATA%\Psh`.')
    [void]$lines.Add('')
    [void]$lines.Add('## Lifecycle Status')
    [void]$lines.Add('')
    [void]$lines.Add('These files define the Goal 1 layout and switching contract. They are not an')
    [void]$lines.Add('online or offline installer, do not modify PowerShell profiles, and do not')
    [void]$lines.Add('claim that a Psh release has been published. Staged installation, package')
    [void]$lines.Add('verification, profile backup and restoration, rollback retention, and')
    [void]$lines.Add('uninstallation belong to the Goal 5 installer lifecycle.')

    return ($lines -join "`n") + "`n"
}

function New-PshArgumentCompleters {
    param([hashtable]$Specification)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('# Copyright (C) 2026 Emvdy')
    [void]$lines.Add('# SPDX-License-Identifier: GPL-3.0-or-later')
    [void]$lines.Add('# Generated by scripts/Generate-CommandArtifacts.ps1 from src/Psh/Specification/commands.psd1. Do not edit.')
    [void]$lines.Add('')
    [void]$lines.Add('$script:PshCommandFlags = @{')
    foreach ($command in @($Specification.Commands)) {
        [void]$lines.Add(('    {0} = {1}' -f (ConvertTo-PshSingleQuotedString $command.Name), (ConvertTo-PshStringArrayLiteral @($command.Flags))))
    }
    [void]$lines.Add('}')
    [void]$lines.Add('')
    $commandNames = @($Specification.Commands | ForEach-Object { [string]$_.Name })
    [void]$lines.Add(('$script:PshCommandNames = {0}' -f (ConvertTo-PshStringArrayLiteral $commandNames)))
    [void]$lines.Add(('$script:PshDisableConfigKey = {0}' -f (ConvertTo-PshSingleQuotedString ([string]$Specification.NameCollisionPolicy.DisableConfigKey))))
    [void]$lines.Add('')
    [void]$lines.Add('$script:PshManagementFlags = @{')
    foreach ($managementCommand in @($Specification.ManagementCommands)) {
        [void]$lines.Add(('    {0} = {1}' -f (ConvertTo-PshSingleQuotedString $managementCommand.Name), (ConvertTo-PshStringArrayLiteral @($managementCommand.Flags))))
    }
    [void]$lines.Add('}')
    [void]$lines.Add('')
    [void]$lines.Add('$script:PshManagementSummaries = @{')
    foreach ($managementCommand in @($Specification.ManagementCommands)) {
        [void]$lines.Add(('    {0} = {1}' -f (ConvertTo-PshSingleQuotedString $managementCommand.Name), (ConvertTo-PshSingleQuotedString $managementCommand.Summary)))
    }
    [void]$lines.Add('}')
    [void]$lines.Add('')

    $body = @'
function Register-PshArgumentCompleters {
    [CmdletBinding()]
    param()

    Register-ArgumentCompleter -CommandName 'psh' -ParameterName 'Arguments' -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $elements = @($commandAst.CommandElements)
        $action = ''
        if ($elements.Count -gt 1) {
            $action = $elements[1].Extent.Text.Trim("'`"")
        }

        if ($action -eq 'config') {
            $configAction = ''
            if ($elements.Count -gt 2) {
                $configAction = $elements[2].Extent.Text.Trim("'`"")
            }

            if ($configAction -in @('get', 'set', 'reset')) {
                $configKey = ''
                if ($elements.Count -gt 3) {
                    $configKey = $elements[3].Extent.Text.Trim("'`"")
                }

                if (-not [string]::Equals($configKey, $script:PshDisableConfigKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($script:PshDisableConfigKey -like "$wordToComplete*") {
                        New-Object System.Management.Automation.CompletionResult -ArgumentList @(
                            $script:PshDisableConfigKey,
                            $script:PshDisableConfigKey,
                            [System.Management.Automation.CompletionResultType]::ParameterName,
                            'Disable selected Psh command functions.'
                        )
                    }
                    return
                }

                if ($configAction -eq 'set') {
                    foreach ($candidate in @($script:PshCommandNames)) {
                        if ($candidate -like "$wordToComplete*") {
                            New-Object System.Management.Automation.CompletionResult -ArgumentList @(
                                $candidate,
                                $candidate,
                                [System.Management.Automation.CompletionResultType]::ParameterValue,
                                "Disable the $candidate Psh command."
                            )
                        }
                    }
                }
                return
            }
        }

        if ($elements.Count -le 2 -and $wordToComplete -notlike '-*') {
            foreach ($candidate in @($script:PshManagementFlags.Keys | Sort-Object)) {
                if ($candidate -like "$wordToComplete*") {
                    New-Object System.Management.Automation.CompletionResult -ArgumentList @(
                        $candidate,
                        $candidate,
                        [System.Management.Automation.CompletionResultType]::ParameterValue,
                        $script:PshManagementSummaries[$candidate]
                    )
                }
            }
            return
        }

        if ($script:PshManagementFlags.ContainsKey($action)) {
            foreach ($candidate in @($script:PshManagementFlags[$action])) {
                if ($candidate -like "$wordToComplete*") {
                    New-Object System.Management.Automation.CompletionResult -ArgumentList @(
                        $candidate,
                        $candidate,
                        [System.Management.Automation.CompletionResultType]::ParameterName,
                        "$action option $candidate"
                    )
                }
            }
        }
    }

    foreach ($registeredCommandName in @($script:PshCommandFlags.Keys)) {
        Register-ArgumentCompleter -CommandName $registeredCommandName -ParameterName 'Arguments' -ScriptBlock {
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            foreach ($candidate in @($script:PshCommandFlags[$commandName])) {
                if ($candidate -like "$wordToComplete*") {
                    New-Object System.Management.Automation.CompletionResult -ArgumentList @(
                        $candidate,
                        $candidate,
                        [System.Management.Automation.CompletionResultType]::ParameterName,
                        "$commandName option $candidate"
                    )
                }
            }
        }
    }
}
'@
    foreach ($bodyLine in @($body -split "`r?`n")) {
        [void]$lines.Add($bodyLine)
    }

    return ($lines -join "`n").TrimEnd([char[]]"`r`n") + "`n"
}

function Write-PshUtf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

Assert-PshCondition (Test-Path -LiteralPath $SpecificationPath -PathType Leaf) "specification file not found: $SpecificationPath"
$specification = Import-PowerShellDataFile -LiteralPath $SpecificationPath

$requiredTopLevel = @('SchemaVersion', 'PshVersion', 'CommandTiers', 'NameCollisionPolicy', 'ExitCodes', 'Editions', 'ObjectApis', 'ManagementCommands', 'Commands')
$actualTopLevel = @($specification.Keys | Sort-Object)
$sortedRequiredTopLevel = @($requiredTopLevel | Sort-Object)
Assert-PshCondition (($actualTopLevel -join '|') -eq ($sortedRequiredTopLevel -join '|')) 'top-level fields must be exactly SchemaVersion, PshVersion, CommandTiers, NameCollisionPolicy, ExitCodes, Editions, ObjectApis, ManagementCommands, and Commands.'
Assert-PshCondition ([string]$specification.SchemaVersion -eq '1.1') "SchemaVersion must be '1.1'."
Assert-PshCondition ([string]$specification.PshVersion -eq '0.1.0') "PshVersion must be '0.1.0'."

$commandTiers = @($specification.CommandTiers)
Assert-PshCondition ($commandTiers.Count -eq 3) 'CommandTiers must define exactly three tiers.'
$expectedTierNames = @('Full common semantics', 'Documented subset', 'Thin wrapper')
for ($tierIndex = 0; $tierIndex -lt $commandTiers.Count; $tierIndex++) {
    $commandTier = $commandTiers[$tierIndex]
    foreach ($property in @('Tier', 'Name', 'Description', 'Validation')) {
        Assert-PshCondition (Test-PshProperty $commandTier $property) "command tier '$($tierIndex + 1)' is missing '$property'."
    }
    Assert-PshCondition ([int]$commandTier.Tier -eq ($tierIndex + 1)) 'CommandTiers must be numbered 1, 2, and 3 in order.'
    Assert-PshCondition ([string]$commandTier.Name -eq $expectedTierNames[$tierIndex]) "command tier '$($tierIndex + 1)' has the wrong fidelity name."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$commandTier.Description)) "command tier '$($tierIndex + 1)' has an empty Description."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$commandTier.Validation)) "command tier '$($tierIndex + 1)' has an empty Validation rule."
}
Assert-PshCondition ([string]$commandTiers[1].Description -match 'Core implements the documented subset') 'Tier 2 must document the Core subset boundary.'
Assert-PshCondition ([string]$commandTiers[1].Description -match 'Full native rg, fd, jq, and bat accept') 'Tier 2 must document the Full native complete-argument exception.'
Assert-PshCondition ([string]$commandTiers[1].Validation -match 'exit code 2') 'Tier 2 validation must require usage exit code 2 for unsupported PowerShell-subset syntax.'
Assert-PshCondition ([string]$commandTiers[1].Validation -match 'Full native commands follow their pinned tools') 'Tier 2 validation must preserve pinned native argument contracts in Full.'

$nameCollisionPolicy = $specification.NameCollisionPolicy
$requiredCollisionPolicyFields = @('ResolutionOrder', 'DisableConfigKey', 'DefaultDisabledCommands', 'ConfigSyntax', 'ConfigPath', 'InstalledConfigFallback', 'ConfigSummary', 'Activation', 'DisableCommandExample', 'ResetCommandExample', 'Summary')
$actualCollisionPolicyFields = @($nameCollisionPolicy.Keys | Sort-Object)
Assert-PshCondition (($actualCollisionPolicyFields -join '|') -eq ((@($requiredCollisionPolicyFields | Sort-Object)) -join '|')) 'NameCollisionPolicy contains missing or unsupported fields.'
$expectedResolutionOrder = @('Psh function', 'built-in alias', 'native executable')
Assert-PshCondition ((@($nameCollisionPolicy.ResolutionOrder) -join '|') -eq ($expectedResolutionOrder -join '|')) 'NameCollisionPolicy resolution order must be Psh function, built-in alias, then native executable.'
Assert-PshCondition ([string]$nameCollisionPolicy.DisableConfigKey -eq 'DisabledCommands') "NameCollisionPolicy DisableConfigKey must be 'DisabledCommands'."
foreach ($property in @('ConfigPath', 'InstalledConfigFallback', 'ConfigSummary', 'Activation', 'DisableCommandExample', 'ResetCommandExample', 'Summary')) {
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$nameCollisionPolicy[$property])) "NameCollisionPolicy '$property' must not be empty."
}
Assert-PshCondition (@($nameCollisionPolicy.DefaultDisabledCommands).Count -eq 0) 'NameCollisionPolicy DefaultDisabledCommands must be an empty array.'
$expectedConfigSyntax = @(
    'psh config get [DisabledCommands]'
    'psh config set DisabledCommands <command> [<command>...]'
    'psh config reset DisabledCommands'
    'psh config --help'
)
Assert-PshCondition ((@($nameCollisionPolicy.ConfigSyntax) -join '|') -eq ($expectedConfigSyntax -join '|')) 'NameCollisionPolicy ConfigSyntax must document the exact v0.1.0 public syntax.'
Assert-PshCondition ([string]$nameCollisionPolicy.ConfigPath -eq '%LOCALAPPDATA%\Psh\config.psd1') 'NameCollisionPolicy ConfigPath must be the canonical current-user path.'
Assert-PshCondition ([string]$nameCollisionPolicy.InstalledConfigFallback -match '<installRoot>\\versions\\<version>\\Psh') 'NameCollisionPolicy must document the exact versioned-install fallback layout.'
Assert-PshCondition ([string]$nameCollisionPolicy.InstalledConfigFallback -match 'never scanned') 'NameCollisionPolicy must reject arbitrary ancestor config scanning.'
Assert-PshCondition ([string]$nameCollisionPolicy.ConfigSummary -match 'only mutable key') 'NameCollisionPolicy must limit v0.1.0 mutation to DisabledCommands.'
Assert-PshCondition ([string]$nameCollisionPolicy.ConfigSummary -match 'atomic write') 'NameCollisionPolicy must document atomic configuration persistence.'
Assert-PshCondition ([string]$nameCollisionPolicy.Activation -match 'new shell') 'NameCollisionPolicy must document next-shell activation.'
Assert-PshCondition ([string]$nameCollisionPolicy.Activation -match 'Remove-Module Psh; Import-Module Psh') 'NameCollisionPolicy must document explicit module re-import activation.'
Assert-PshCondition ([string]$nameCollisionPolicy.DisableCommandExample -eq 'psh config set DisabledCommands curl wget') 'NameCollisionPolicy DisableCommandExample must document disabling individual command names.'
Assert-PshCondition ([string]$nameCollisionPolicy.ResetCommandExample -eq 'psh config reset DisabledCommands') 'NameCollisionPolicy ResetCommandExample must document restoring the default command set.'

$defaultConfigPath = Join-Path $repositoryRoot 'src/install/config.psd1'
Assert-PshCondition (Test-Path -LiteralPath $defaultConfigPath -PathType Leaf) 'default config.psd1 is missing.'
$defaultConfig = Import-PowerShellDataFile -LiteralPath $defaultConfigPath
$expectedDefaultConfigKeys = @('DisabledCommands', 'Edition', 'SchemaVersion')
$actualDefaultConfigKeys = @($defaultConfig.Keys | Sort-Object)
Assert-PshCondition (($actualDefaultConfigKeys -join '|') -eq ($expectedDefaultConfigKeys -join '|')) 'default config.psd1 fields must be exactly SchemaVersion, Edition, and DisabledCommands.'
Assert-PshCondition ($defaultConfig.SchemaVersion -is [int] -and [int]$defaultConfig.SchemaVersion -eq 1) 'default config.psd1 SchemaVersion must be the integer 1.'
Assert-PshCondition ([string]$defaultConfig.Edition -eq 'Core') 'default config.psd1 Edition must be Core.'
$disableConfigKey = [string]$nameCollisionPolicy.DisableConfigKey
Assert-PshCondition (Test-PshProperty $defaultConfig $disableConfigKey) "default config.psd1 is missing '$disableConfigKey'."
Assert-PshCondition (@($defaultConfig[$disableConfigKey]).Count -eq 0) "default config.psd1 must set '$disableConfigKey' to an empty array."
Assert-PshCondition ((@($defaultConfig[$disableConfigKey]) -join '|') -eq (@($nameCollisionPolicy.DefaultDisabledCommands) -join '|')) "default config.psd1 must match NameCollisionPolicy DefaultDisabledCommands."

$expectedExitCodes = @(0, 1, 2, 3, 4, 5)
$actualExitCodes = @($specification.ExitCodes | ForEach-Object { [int]$_.Code })
Assert-PshCondition (($actualExitCodes -join ',') -eq ($expectedExitCodes -join ',')) 'ExitCodes must define codes 0 through 5 exactly once and in ascending order.'
foreach ($exitCode in @($specification.ExitCodes)) {
    foreach ($property in @('Code', 'Name', 'Description')) {
        Assert-PshCondition (Test-PshProperty $exitCode $property) "exit code '$($exitCode.Code)' is missing '$property'."
    }
}

$editionNames = @($specification.Editions | ForEach-Object { [string]$_.Name })
Assert-PshCondition (($editionNames -join '|') -eq 'Core|Full') 'Editions must define Core and Full in that order.'

$expectedManagementNames = @('version', 'doctor', 'capabilities', 'commands', 'config', 'update', 'rollback', 'self-test', 'uninstall')
$actualManagementNames = @($specification.ManagementCommands | ForEach-Object { [string]$_.Name })
Assert-PshCondition (($actualManagementNames -join '|') -eq ($expectedManagementNames -join '|')) 'ManagementCommands must define every public psh action in PLAN order.'
$jsonManagementNames = @($specification.ManagementCommands | Where-Object { $_.SupportsJson } | ForEach-Object { [string]$_.Name } | Sort-Object)
Assert-PshCondition (($jsonManagementNames -join '|') -eq 'capabilities|doctor') 'Only doctor and capabilities must declare JSON support for v0.1.0.'
foreach ($managementCommand in @($specification.ManagementCommands)) {
    foreach ($property in @('Name', 'Summary', 'SupportsJson', 'Flags', 'ExitCodes', 'Examples')) {
        Assert-PshCondition (Test-PshProperty $managementCommand $property) "management command '$($managementCommand.Name)' is missing '$property'."
    }
    Assert-PshCondition (@($managementCommand.Flags) -contains '--help') "management command '$($managementCommand.Name)' is missing '--help'."
    if ($managementCommand.SupportsJson) {
        Assert-PshCondition (@($managementCommand.Flags) -contains '--json') "management command '$($managementCommand.Name)' declares JSON support without '--json'."
    }
}
$configManagementCommand = @($specification.ManagementCommands | Where-Object { [string]$_.Name -eq 'config' })[0]
Assert-PshCondition (@($configManagementCommand.Examples) -contains [string]$nameCollisionPolicy.DisableCommandExample) 'psh config examples must include the DisabledCommands disable command.'
Assert-PshCondition (@($configManagementCommand.Examples) -contains [string]$nameCollisionPolicy.ResetCommandExample) 'psh config examples must include the DisabledCommands reset command.'
Assert-PshCondition (@($configManagementCommand.Examples) -contains 'psh config get DisabledCommands') 'psh config examples must include keyed retrieval.'

$objectApiNames = @($specification.ObjectApis | ForEach-Object { [string]$_.Name })
Assert-PshCondition ($objectApiNames.Count -eq 8) 'ObjectApis must define the eight PLAN object APIs.'
Assert-PshCondition (@($objectApiNames | Select-Object -Unique).Count -eq $objectApiNames.Count) 'ObjectApis contains duplicate names.'

$expectedCommandNames = @('pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname stat file tree find fd du df mktemp cat bat head tail grep rg sed awk jq cut tr sort uniq wc tee xargs printf echo base64 which env printenv export test ps kill pgrep pkill timeout sleep curl wget tar zip unzip gzip gunzip sha256sum md5sum date whoami hostname clear'.Split(' '))
$commands = @($specification.Commands)
$actualCommandNames = @($commands | ForEach-Object { [string]$_.Name })
Assert-PshCondition ($commands.Count -eq 64) "Commands must contain exactly 64 entries; found $($commands.Count)."
Assert-PshCondition (@($actualCommandNames | Select-Object -Unique).Count -eq 64) 'Commands contains duplicate names.'
Assert-PshCondition (($actualCommandNames -join '|') -eq ($expectedCommandNames -join '|')) 'Commands must match the 64 names and PLAN order exactly.'

$expectedTierPartitions = @{
    1 = @('pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname mktemp cat head tail cut tr sort uniq wc tee printf echo base64 which env printenv test sleep sha256sum md5sum'.Split(' '))
    2 = @('stat file tree find fd du df bat grep rg sed awk jq xargs export ps kill pgrep pkill timeout curl wget tar zip unzip gzip gunzip'.Split(' '))
    3 = @('date whoami hostname clear'.Split(' '))
}
foreach ($tierNumber in @(1, 2, 3)) {
    $actualTierCommands = @($commands | Where-Object { [int]$_.Tier -eq $tierNumber } | ForEach-Object { [string]$_.Name })
    Assert-PshCondition (($actualTierCommands -join '|') -eq ($expectedTierPartitions[$tierNumber] -join '|')) "Tier $tierNumber command partition does not exactly match PLAN.md."
}

$expectedPlatformShapedCommands = @('ls', 'stat', 'file', 'tree', 'du', 'df', 'which', 'ps', 'pgrep', 'pkill', 'date', 'whoami', 'hostname', 'clear')
$actualPlatformShapedCommands = @($commands | Where-Object { [bool]$_.PlatformShaped } | ForEach-Object { [string]$_.Name })
Assert-PshCondition (($actualPlatformShapedCommands -join '|') -eq ($expectedPlatformShapedCommands -join '|')) 'Platform-shaped command markers do not match the documented structural-assertion set.'

$expectedCollisionTargets = @{
    'pwd' = @('alias:pwd')
    'cd' = @('alias:cd')
    'ls' = @('alias:ls')
    'rmdir' = @('alias:rmdir')
    'cp' = @('alias:cp')
    'mv' = @('alias:mv')
    'rm' = @('alias:rm')
    'tree' = @('native:tree.com')
    'find' = @('native:find.exe')
    'fd' = @('native:fd.exe')
    'cat' = @('alias:cat')
    'bat' = @('native:bat.exe')
    'rg' = @('native:rg.exe')
    'jq' = @('native:jq.exe')
    'sort' = @('alias:sort', 'native:sort.exe')
    'tee' = @('alias:tee')
    'echo' = @('alias:echo')
    'ps' = @('alias:ps')
    'kill' = @('alias:kill')
    'timeout' = @('native:timeout.exe')
    'sleep' = @('alias:sleep')
    'curl' = @('alias:curl', 'native:curl.exe')
    'wget' = @('alias:wget')
    'tar' = @('native:tar.exe')
    'whoami' = @('native:whoami.exe')
    'hostname' = @('native:hostname.exe')
    'clear' = @('alias:clear')
}

$requiredCommandProperties = @('Name', 'Tier', 'PlatformShaped', 'EditionNotes', 'CollisionTargets', 'CollisionNotes', 'Category', 'Summary', 'Flags', 'ExitCodes', 'CoreBackend', 'FullBackend', 'ObjectApi', 'Examples')
$nativeCommands = @('rg', 'fd', 'jq', 'bat')
foreach ($command in $commands) {
    foreach ($property in $requiredCommandProperties) {
        Assert-PshCondition (Test-PshProperty $command $property) "command '$($command.Name)' is missing '$property'."
    }
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Name)) 'a command has an empty Name.'
    Assert-PshCondition ([int]$command.Tier -in @(1, 2, 3)) "command '$($command.Name)' has invalid Tier '$($command.Tier)'."
    Assert-PshCondition ($command.PlatformShaped -is [bool]) "command '$($command.Name)' PlatformShaped must be Boolean."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.EditionNotes)) "command '$($command.Name)' has empty EditionNotes."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.CollisionNotes)) "command '$($command.Name)' has empty CollisionNotes."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Category)) "command '$($command.Name)' has an empty Category."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Summary)) "command '$($command.Name)' has an empty Summary."
    Assert-PshCondition (@($command.Flags).Count -gt 0) "command '$($command.Name)' has no Flags."
    Assert-PshCondition (@($command.Flags) -contains '--help') "command '$($command.Name)' is missing '--help'."
    Assert-PshCondition (@($command.Examples).Count -gt 0) "command '$($command.Name)' has no Examples."
    Assert-PshCondition ([string]$command.CoreBackend -eq 'powershell') "command '$($command.Name)' must use the PowerShell Core backend."

    if ([int]$command.Tier -eq 1) {
        Assert-PshCondition ([string]$command.EditionNotes -match 'full common semantics') "Tier 1 command '$($command.Name)' must document full common semantics."
    }
    elseif ([int]$command.Tier -eq 2) {
        Assert-PshCondition (@($command.ExitCodes) -contains 2) "Tier 2 command '$($command.Name)' must declare usage exit code 2."
        Assert-PshCondition ([string]$command.EditionNotes -match 'unsupported syntax exits 2') "Tier 2 command '$($command.Name)' must document unsupported syntax exit code 2."
    }
    else {
        Assert-PshCondition ([string]$command.EditionNotes -match 'thin PowerShell wrapper') "Tier 3 command '$($command.Name)' must document its thin wrapper contract."
    }

    $actualCollisionTargets = @($command.CollisionTargets)
    Assert-PshCondition (@($actualCollisionTargets | Select-Object -Unique).Count -eq $actualCollisionTargets.Count) "command '$($command.Name)' has duplicate CollisionTargets."
    foreach ($collisionTarget in $actualCollisionTargets) {
        Assert-PshCondition ([string]$collisionTarget -match '^(alias|native):[^:]+$') "command '$($command.Name)' has invalid collision target '$collisionTarget'."
    }
    $expectedCommandCollisionTargets = @()
    if ($expectedCollisionTargets.ContainsKey([string]$command.Name)) {
        $expectedCommandCollisionTargets = @($expectedCollisionTargets[[string]$command.Name])
    }
    Assert-PshCondition (($actualCollisionTargets -join '|') -eq ($expectedCommandCollisionTargets -join '|')) "command '$($command.Name)' CollisionTargets do not match the v0.1.0 collision inventory."
    if ($actualCollisionTargets.Count -eq 0) {
        Assert-PshCondition ([string]$command.CollisionNotes -match '^No default PowerShell alias or Windows executable collision') "command '$($command.Name)' must explicitly document that no default collision is known."
    }
    else {
        Assert-PshCondition ([string]$command.CollisionNotes -match 'disabling') "command '$($command.Name)' collision notes must explain the disable behavior."
    }

    $expectedFullBackend = 'powershell'
    if ($nativeCommands -contains [string]$command.Name) {
        $expectedFullBackend = 'native:' + [string]$command.Name
        Assert-PshCondition ([string]$command.EditionNotes -match ("Full delegates to pinned native {0}" -f [regex]::Escape([string]$command.Name))) "command '$($command.Name)' must document its Full native delegation."
        Assert-PshCondition ([string]$command.EditionNotes -match 'accepts its complete argument set') "command '$($command.Name)' must document Full native argument compatibility."
    }
    else {
        Assert-PshCondition ([string]$command.EditionNotes -match 'Core and Full') "command '$($command.Name)' must document the shared Core and Full behavior."
    }
    Assert-PshCondition ([string]$command.FullBackend -eq $expectedFullBackend) "command '$($command.Name)' must use Full backend '$expectedFullBackend'."

    if (-not [string]::IsNullOrEmpty([string]$command.ObjectApi)) {
        Assert-PshCondition ($objectApiNames -contains [string]$command.ObjectApi) "command '$($command.Name)' references unknown ObjectApi '$($command.ObjectApi)'."
    }

    foreach ($commandExitCode in @($command.ExitCodes)) {
        Assert-PshCondition ($expectedExitCodes -contains [int]$commandExitCode) "command '$($command.Name)' references invalid exit code '$commandExitCode'."
    }
}

$commandByName = @{}
foreach ($command in $commands) {
    $commandByName[[string]$command.Name] = $command
}
Assert-PshFlags $commandByName['ls'] @('-a', '-l', '-h', '-R')
Assert-PshFlags $commandByName['mkdir'] @('-p', '-v')
Assert-PshFlags $commandByName['cp'] @('-R', '-r', '-f', '-n', '-u', '-v')
Assert-PshFlags $commandByName['mv'] @('-f', '-n', '-u', '-v')
Assert-PshFlags $commandByName['rm'] @('-R', '-r', '-f', '-v')
foreach ($searchCommandName in @('grep', 'rg')) {
    Assert-PshFlags $commandByName[$searchCommandName] @('-i', '-v', '-n', '-r', '-l', '-c', '-m', '-A', '-B', '-C', '-E', '-F', '-q', '--include', '--exclude', '--hidden', '--glob')
}
Assert-PshFlags $commandByName['find'] @('-name', '-type', '-mindepth', '-maxdepth', '-size', '-mtime', '--hidden', '--exclude', '-print0')
Assert-PshFlags $commandByName['fd'] @('-e', '--glob', '--type', '--max-depth', '--size', '--changed-before', '--hidden', '--exclude', '--print0')
Assert-PshFlags $commandByName['xargs'] @('-0', '-n', '-I', '-P')
Assert-PshFlags $commandByName['sed'] @('-e', '-n', '-i', '-E')
Assert-PshFlags $commandByName['awk'] @('-F', '-v')
Assert-PshFlags $commandByName['jq'] @('-r', '-c', '-e')

$commandsJsonPath = Join-Path $repositoryRoot 'generated/commands.json'
$compatibilityPath = Join-Path $repositoryRoot 'docs/compatibility.md'
$installLayoutPath = Join-Path $repositoryRoot 'docs/install-layout.md'
$completersPath = Join-Path $repositoryRoot 'src/Psh/Generated/ArgumentCompleters.ps1'
$artifactPaths = @($commandsJsonPath, $compatibilityPath, $installLayoutPath, $completersPath)
$artifactContent = @{}
$artifactContent[$commandsJsonPath] = New-PshCommandsJson $specification
$artifactContent[$compatibilityPath] = New-PshCompatibilityMarkdown $specification
$artifactContent[$installLayoutPath] = New-PshInstallLayoutMarkdown $specification $defaultConfig
$artifactContent[$completersPath] = New-PshArgumentCompleters $specification

$driftedPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($artifactPath in $artifactPaths) {
    $expectedContent = [string]$artifactContent[$artifactPath]
    $matches = $false
    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        $actualContent = [System.IO.File]::ReadAllText($artifactPath)
        $matches = $actualContent -ceq $expectedContent
    }

    if ($Check) {
        if (-not $matches) {
            $trimCharacters = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            [void]$driftedPaths.Add($artifactPath.Substring($repositoryRoot.Length).TrimStart($trimCharacters))
        }
    }
    elseif (-not $matches) {
        Write-PshUtf8NoBom -Path $artifactPath -Content $expectedContent
        Write-Output "generated $artifactPath"
    }
}

if ($Check -and $driftedPaths.Count -gt 0) {
    throw 'Generated command artifacts are missing or out of date: ' + ($driftedPaths -join ', ')
}

if ($Check) {
    Write-Output 'Generated command artifacts are up to date.'
}
