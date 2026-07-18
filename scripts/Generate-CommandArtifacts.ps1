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
    [void]$lines.Add('## Editions')
    [void]$lines.Add('')
    [void]$lines.Add('| Edition | Native tools | Description |')
    [void]$lines.Add('| --- | --- | --- |')
    foreach ($edition in @($Specification.Editions)) {
        $nativeTools = if (@($edition.NativeTools).Count -eq 0) { '-' } else { @($edition.NativeTools) -join ', ' }
        [void]$lines.Add(('| {0} | {1} | {2} |' -f (ConvertTo-PshMarkdownCell $edition.Name), (ConvertTo-PshMarkdownCell $nativeTools), (ConvertTo-PshMarkdownCell $edition.Summary)))
    }
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
    [void]$lines.Add('| Command | Category | Core | Full | Object API | Flags | Example |')
    [void]$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
    foreach ($command in @($Specification.Commands)) {
        $objectApi = if ([string]::IsNullOrEmpty([string]$command.ObjectApi)) { '-' } else { '`' + $command.ObjectApi + '`' }
        $flags = @($command.Flags | ForEach-Object { '`' + $_ + '`' }) -join ' '
        $example = @($command.Examples)[0]
        [void]$lines.Add(('| `{0}` | {1} | `{2}` | `{3}` | {4} | {5} | `{6}` |' -f (ConvertTo-PshMarkdownCell $command.Name), (ConvertTo-PshMarkdownCell $command.Category), (ConvertTo-PshMarkdownCell $command.CoreBackend), (ConvertTo-PshMarkdownCell $command.FullBackend), (ConvertTo-PshMarkdownCell $objectApi), (ConvertTo-PshMarkdownCell $flags), (ConvertTo-PshMarkdownCell $example)))
    }

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

$requiredTopLevel = @('SchemaVersion', 'PshVersion', 'ExitCodes', 'Editions', 'ObjectApis', 'ManagementCommands', 'Commands')
$actualTopLevel = @($specification.Keys | Sort-Object)
$sortedRequiredTopLevel = @($requiredTopLevel | Sort-Object)
Assert-PshCondition (($actualTopLevel -join '|') -eq ($sortedRequiredTopLevel -join '|')) 'top-level fields must be exactly SchemaVersion, PshVersion, ExitCodes, Editions, ObjectApis, ManagementCommands, and Commands.'
Assert-PshCondition ([string]$specification.SchemaVersion -eq '1.0') "SchemaVersion must be '1.0'."
Assert-PshCondition ([string]$specification.PshVersion -eq '0.1.0') "PshVersion must be '0.1.0'."

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

$objectApiNames = @($specification.ObjectApis | ForEach-Object { [string]$_.Name })
Assert-PshCondition ($objectApiNames.Count -eq 8) 'ObjectApis must define the eight PLAN object APIs.'
Assert-PshCondition (@($objectApiNames | Select-Object -Unique).Count -eq $objectApiNames.Count) 'ObjectApis contains duplicate names.'

$expectedCommandNames = @('pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname stat file tree find fd du df mktemp cat bat head tail grep rg sed awk jq cut tr sort uniq wc tee xargs printf echo base64 which env printenv export test ps kill pgrep pkill timeout sleep curl wget tar zip unzip gzip gunzip sha256sum md5sum date whoami hostname clear'.Split(' '))
$commands = @($specification.Commands)
$actualCommandNames = @($commands | ForEach-Object { [string]$_.Name })
Assert-PshCondition ($commands.Count -eq 64) "Commands must contain exactly 64 entries; found $($commands.Count)."
Assert-PshCondition (@($actualCommandNames | Select-Object -Unique).Count -eq 64) 'Commands contains duplicate names.'
Assert-PshCondition (($actualCommandNames -join '|') -eq ($expectedCommandNames -join '|')) 'Commands must match the 64 names and PLAN order exactly.'

$requiredCommandProperties = @('Name', 'Category', 'Summary', 'Flags', 'ExitCodes', 'CoreBackend', 'FullBackend', 'ObjectApi', 'Examples')
$nativeCommands = @('rg', 'fd', 'jq', 'bat')
foreach ($command in $commands) {
    foreach ($property in $requiredCommandProperties) {
        Assert-PshCondition (Test-PshProperty $command $property) "command '$($command.Name)' is missing '$property'."
    }
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Name)) 'a command has an empty Name.'
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Category)) "command '$($command.Name)' has an empty Category."
    Assert-PshCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Summary)) "command '$($command.Name)' has an empty Summary."
    Assert-PshCondition (@($command.Flags).Count -gt 0) "command '$($command.Name)' has no Flags."
    Assert-PshCondition (@($command.Flags) -contains '--help') "command '$($command.Name)' is missing '--help'."
    Assert-PshCondition (@($command.Examples).Count -gt 0) "command '$($command.Name)' has no Examples."
    Assert-PshCondition ([string]$command.CoreBackend -eq 'powershell') "command '$($command.Name)' must use the PowerShell Core backend."

    $expectedFullBackend = 'powershell'
    if ($nativeCommands -contains [string]$command.Name) {
        $expectedFullBackend = 'native:' + [string]$command.Name
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
Assert-PshFlags $commandByName['fd'] @('--glob', '--type', '--max-depth', '--size', '--changed-before', '--hidden', '--exclude', '--print0')
Assert-PshFlags $commandByName['xargs'] @('-0', '-n', '-I', '-P')
Assert-PshFlags $commandByName['sed'] @('-e', '-n', '-i', '-E')
Assert-PshFlags $commandByName['awk'] @('-F', '-v')
Assert-PshFlags $commandByName['jq'] @('-r', '-c', '-e')

$commandsJsonPath = Join-Path $repositoryRoot 'generated/commands.json'
$compatibilityPath = Join-Path $repositoryRoot 'docs/compatibility.md'
$completersPath = Join-Path $repositoryRoot 'src/Psh/Generated/ArgumentCompleters.ps1'
$artifactPaths = @($commandsJsonPath, $compatibilityPath, $completersPath)
$artifactContent = @{}
$artifactContent[$commandsJsonPath] = New-PshCommandsJson $specification
$artifactContent[$compatibilityPath] = New-PshCompatibilityMarkdown $specification
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
