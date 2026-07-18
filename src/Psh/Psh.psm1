# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Psh's public module surface is intentionally small.  The command catalog is
# data-driven; no executable utility is launched while the module is loaded.

$script:PshCompleterLoadError = $null

function Set-PshLastExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    # LASTEXITCODE is a session-level value in both Windows PowerShell and pwsh.
    # Assigning it explicitly keeps a function invocation as predictable as a
    # native command invocation without terminating the caller's session.
    $global:LASTEXITCODE = $Code
}

function Test-PshProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }

        return $false
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-PshPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }

        return $null
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-PshBoolean {
    param(
        [AllowNull()]
        [object]$Value,

        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::Equals($text, 'true', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ([string]::Equals($text, 'false', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $Default
}

function ConvertTo-PshSpecificationEntry {
    param(
        [AllowNull()]
        [object]$Entry,

        [AllowNull()]
        [string]$FallbackName
    )

    $copy = [ordered]@{}

    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($key in $Entry.Keys) {
            $copy[[string]$key] = $Entry[$key]
        }
    }
    elseif ($Entry -is [string]) {
        $copy['Name'] = [string]$Entry
    }
    elseif ($null -ne $Entry) {
        foreach ($property in $Entry.PSObject.Properties) {
            $copy[[string]$property.Name] = $property.Value
        }
    }

    $name = Get-PshPropertyValue -InputObject $copy -Name 'Name'
    if ($null -eq $name -or [string]::IsNullOrWhiteSpace([string]$name)) {
        $name = Get-PshPropertyValue -InputObject $copy -Name 'Command'
    }
    if ($null -eq $name -or [string]::IsNullOrWhiteSpace([string]$name)) {
        $name = $FallbackName
    }
    if ($null -eq $name -or [string]::IsNullOrWhiteSpace([string]$name)) {
        throw 'Psh specification contains an entry without a command name.'
    }

    if (-not (Test-PshProperty -InputObject $copy -Name 'Name')) {
        $copy['Name'] = ([string]$name).Trim()
    }

    return [PSCustomObject]$copy
}

function Get-PshCommandEntries {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $rawCommands = Get-PshPropertyValue -InputObject $Specification -Name 'Commands'
    $entries = @()

    if ($rawCommands -is [System.Collections.IDictionary]) {
        foreach ($key in $rawCommands.Keys) {
            $entries += ConvertTo-PshSpecificationEntry -Entry $rawCommands[$key] -FallbackName ([string]$key)
        }
    }
    elseif ($rawCommands -is [System.Collections.IEnumerable] -and $rawCommands -isnot [string]) {
        foreach ($entry in $rawCommands) {
            $entries += ConvertTo-PshSpecificationEntry -Entry $entry -FallbackName $null
        }
    }
    elseif ($null -ne $rawCommands) {
        $entries += ConvertTo-PshSpecificationEntry -Entry $rawCommands -FallbackName $null
    }

    return $entries
}

function Get-PshManagementEntries {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $rawCommands = Get-PshPropertyValue -InputObject $Specification -Name 'ManagementCommands'
    $entries = @()

    if ($rawCommands -is [System.Collections.IDictionary]) {
        foreach ($key in $rawCommands.Keys) {
            $entries += ConvertTo-PshSpecificationEntry -Entry $rawCommands[$key] -FallbackName ([string]$key)
        }
    }
    elseif ($rawCommands -is [System.Collections.IEnumerable] -and $rawCommands -isnot [string]) {
        foreach ($entry in $rawCommands) {
            $entries += ConvertTo-PshSpecificationEntry -Entry $entry -FallbackName $null
        }
    }
    elseif ($null -ne $rawCommands) {
        $entries += ConvertTo-PshSpecificationEntry -Entry $rawCommands -FallbackName $null
    }

    return $entries
}

function Get-PshSpecificationPath {
    $specificationDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'Specification'
    return (Join-Path -Path $specificationDirectory -ChildPath 'commands.psd1')
}

function Import-PshSpecification {
    $path = Get-PshSpecificationPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('Psh specification is missing: {0}' -f $path)
    }

    try {
        $specification = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop
    }
    catch {
        throw ('Psh specification could not be loaded from {0}: {1}' -f $path, $_.Exception.Message)
    }

    if ($null -eq $specification -or $specification -isnot [System.Collections.IDictionary]) {
        throw ('Psh specification is invalid: the top level of {0} must be a data hashtable.' -f $path)
    }

    $requiredFields = @(
        'SchemaVersion'
        'PshVersion'
        'ExitCodes'
        'Editions'
        'ObjectApis'
        'ManagementCommands'
        'Commands'
    )

    foreach ($field in $requiredFields) {
        if (-not (Test-PshProperty -InputObject $specification -Name $field)) {
            throw ('Psh specification is invalid: required top-level field "{0}" is missing.' -f $field)
        }

        if ($null -eq (Get-PshPropertyValue -InputObject $specification -Name $field)) {
            throw ('Psh specification is invalid: required top-level field "{0}" is null.' -f $field)
        }
    }

    $schemaVersion = Get-PshPropertyValue -InputObject $specification -Name 'SchemaVersion'
    $pshVersion = Get-PshPropertyValue -InputObject $specification -Name 'PshVersion'
    if ([string]::IsNullOrWhiteSpace([string]$schemaVersion)) {
        throw 'Psh specification is invalid: SchemaVersion is empty.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$pshVersion)) {
        throw 'Psh specification is invalid: PshVersion is empty.'
    }

    $entries = @(Get-PshCommandEntries -Specification $specification)
    if ($entries.Count -ne 64) {
        throw ('Psh specification is invalid: Commands must contain exactly 64 entries; found {0}.' -f $entries.Count)
    }

    $seenNames = @{}
    foreach ($entry in $entries) {
        $name = ([string](Get-PshPropertyValue -InputObject $entry -Name 'Name')).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Psh specification is invalid: a command name is empty.'
        }
        $nameKey = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($nameKey)) {
            throw ('Psh specification is invalid: command "{0}" is duplicated.' -f $name)
        }
        $seenNames[$nameKey] = $true
    }

    return $specification
}

function Get-PshConfigPaths {
    $paths = @()
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', [EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$localAppData)) {
        $paths += Join-Path -Path (Join-Path -Path $localAppData -ChildPath 'Psh') -ChildPath 'config.psd1'
    }

    # Installed modules live at <LOCALAPPDATA>\Psh\versions\<version>\Psh.
    # Walking upward also makes a copied/versioned module honor its sibling
    # configuration when LOCALAPPDATA is not set in a test host.
    $cursor = $PSScriptRoot
    for ($index = 0; $index -lt 5; $index++) {
        if ([string]::IsNullOrWhiteSpace([string]$cursor)) {
            break
        }

        $candidate = Join-Path -Path $cursor -ChildPath 'config.psd1'
        if (-not ($paths -contains $candidate)) {
            $paths += $candidate
        }

        $parent = Split-Path -Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace([string]$parent) -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }

    return $paths
}

function Resolve-PshEdition {
    $environmentEdition = [Environment]::GetEnvironmentVariable('PSH_EDITION', [EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace([string]$environmentEdition)) {
        $environmentEdition = $env:PSH_EDITION
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$environmentEdition)) {
        if ([string]::Equals(([string]$environmentEdition).Trim(), 'Full', [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'Full'
        }

        return 'Core'
    }

    foreach ($configPath in @(Get-PshConfigPaths)) {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            continue
        }

        try {
            $config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
            $configuredEdition = Get-PshPropertyValue -InputObject $config -Name 'Edition'
            if ($null -eq $configuredEdition) {
                $configuredEdition = Get-PshPropertyValue -InputObject $config -Name 'PshEdition'
            }
            if ($configuredEdition -is [System.Collections.IDictionary]) {
                $configuredEdition = Get-PshPropertyValue -InputObject $configuredEdition -Name 'Name'
            }

            if ([string]::Equals(([string]$configuredEdition).Trim(), 'Full', [System.StringComparison]::OrdinalIgnoreCase)) {
                return 'Full'
            }
        }
        catch {
            # A broken optional config must never make Core unusable.  Core is
            # the safe default and does not require native tools.
        }

        break
    }

    return 'Core'
}

function Get-PshCommandName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $value = Get-PshPropertyValue -InputObject $Entry -Name 'Name'
    if ($null -eq $value) {
        $value = Get-PshPropertyValue -InputObject $Entry -Name 'Command'
    }
    if ($null -eq $value) {
        return ''
    }

    return ([string]$value).Trim()
}

function Get-PshCommandBackend {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Core', 'Full')]
        [string]$Edition
    )

    if ([string]::Equals($Edition, 'Full', [System.StringComparison]::OrdinalIgnoreCase)) {
        $name = (Get-PshCommandName -Entry $Entry).ToLowerInvariant()
        if ($name -eq 'rg' -or $name -eq 'fd' -or $name -eq 'jq' -or $name -eq 'bat') {
            $declared = Get-PshPropertyValue -InputObject $Entry -Name 'FullBackend'
            if ($null -ne $declared -and ([string]$declared).ToLowerInvariant().StartsWith('native:')) {
                return ([string]$declared)
            }

            return ('native:{0}' -f $name)
        }
    }

    return 'powershell'
}

function Get-PshSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $summary = Get-PshPropertyValue -InputObject $Entry -Name 'Summary'
    if ($null -eq $summary) {
        $summary = Get-PshPropertyValue -InputObject $Entry -Name 'Description'
    }
    if ($null -eq $summary) {
        $summary = Get-PshPropertyValue -InputObject $Entry -Name 'Help'
    }

    if ($null -eq $summary) {
        return ''
    }

    return ([string]$summary).Trim()
}

function ConvertTo-PshCapabilityEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Core', 'Full')]
        [string]$Edition
    )

    $name = Get-PshCommandName -Entry $Entry
    $capability = [ordered]@{
        name = $name
    }

    $fieldMappings = @(
        @('category', 'Category')
        @('summary', 'Summary')
        @('flags', 'Flags')
        @('examples', 'Examples')
        @('exitCodes', 'ExitCodes')
        @('objectApi', 'ObjectApi')
        @('coreBackend', 'CoreBackend')
        @('fullBackend', 'FullBackend')
    )

    foreach ($mapping in $fieldMappings) {
        $value = Get-PshPropertyValue -InputObject $Entry -Name ([string]$mapping[1])
        if ($null -ne $value) {
            $capability[[string]$mapping[0]] = $value
        }
    }

    $capability['activeBackend'] = Get-PshCommandBackend -Entry $Entry -Edition $Edition
    return [PSCustomObject]$capability
}

function ConvertTo-PshManagementCapability {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $result = [ordered]@{
        name = Get-PshCommandName -Entry $Entry
    }
    $summary = Get-PshSummary -Entry $Entry
    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        $result['summary'] = $summary
    }

    $supportsJson = Get-PshPropertyValue -InputObject $Entry -Name 'SupportsJson'
    if ($null -ne $supportsJson) {
        $result['supportsJson'] = ConvertTo-PshBoolean -Value $supportsJson
    }

    foreach ($field in @('Flags', 'Examples', 'ExitCodes')) {
        $value = Get-PshPropertyValue -InputObject $Entry -Name $field
        if ($null -ne $value) {
            $key = $field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)
            $result[$key] = $value
        }
    }

    return [PSCustomObject]$result
}

function Get-PshManagementEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($entry in $Entries) {
        if ([string]::Equals((Get-PshCommandName -Entry $entry), $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }

    return $null
}

function Get-PshVersionData {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $result = [ordered]@{
        name = 'psh'
        pshVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'PshVersion')
        schemaVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'SchemaVersion')
        edition = Resolve-PshEdition
    }

    return [PSCustomObject]$result
}

function Get-PshCapabilitiesData {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $edition = Resolve-PshEdition
    $entries = @(Get-PshCommandEntries -Specification $Specification)
    if ($entries.Count -ne 64) {
        throw ('Psh specification is invalid: capabilities require exactly 64 commands; found {0}.' -f $entries.Count)
    }

    $capabilities = @()
    foreach ($entry in $entries) {
        $capabilities += ConvertTo-PshCapabilityEntry -Entry $entry -Edition $edition
    }

    $result = [ordered]@{
        name = 'capabilities'
        pshVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'PshVersion')
        schemaVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'SchemaVersion')
        edition = $edition
        commands = @($capabilities)
    }

    return [PSCustomObject]$result
}

function Get-PshCommandsData {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $edition = Resolve-PshEdition
    $entries = @(Get-PshCommandEntries -Specification $Specification)
    $managementEntries = @(Get-PshManagementEntries -Specification $Specification)
    $commands = @()
    foreach ($entry in $entries) {
        $commands += ConvertTo-PshCapabilityEntry -Entry $entry -Edition $edition
    }

    $management = @()
    foreach ($entry in $managementEntries) {
        $management += ConvertTo-PshManagementCapability -Entry $entry
    }

    $result = [ordered]@{
        name = 'commands'
        pshVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'PshVersion')
        schemaVersion = [string](Get-PshPropertyValue -InputObject $Specification -Name 'SchemaVersion')
        edition = $edition
        managementCommands = @($management)
        commands = @($commands)
    }

    return [PSCustomObject]$result
}

function ConvertTo-PshNormalizedSpecification {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $commands = @(Get-PshCommandEntries -Specification $Specification)
    $management = @(Get-PshManagementEntries -Specification $Specification)
    $result = [ordered]@{
        SchemaVersion = Get-PshPropertyValue -InputObject $Specification -Name 'SchemaVersion'
        PshVersion = Get-PshPropertyValue -InputObject $Specification -Name 'PshVersion'
        ExitCodes = Get-PshPropertyValue -InputObject $Specification -Name 'ExitCodes'
        Editions = Get-PshPropertyValue -InputObject $Specification -Name 'Editions'
        ObjectApis = Get-PshPropertyValue -InputObject $Specification -Name 'ObjectApis'
        ManagementCommands = @($management)
        Commands = @($commands)
    }

    return [PSCustomObject]$result
}

function ConvertTo-PshJsonText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    # Depth is deliberately explicit: the specification contains nested flag,
    # example, and exit-code arrays, and the same value is valid in PS5.1/PS7.
    return ($InputObject | ConvertTo-Json -Depth 20 -Compress)
}

function Write-PshUsage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Output ('psh: usage error: {0}' -f $Message)
    }
    Write-Output 'Usage: psh version|capabilities|commands [--json]'
}

function Write-PshRuntimeError {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ErrorValue
    )

    $message = [string]$ErrorValue
    if ($ErrorValue -is [System.Management.Automation.ErrorRecord]) {
        $message = [string]$ErrorValue.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'unknown runtime failure'
    }
    $message = ($message -replace '[\r\n]+', ' ').Trim()
    Write-Output ('psh: runtime error: {0}' -f $message)
}

function Get-PshJsonSupport {
    param(
        [AllowNull()]
        [object]$ManagementEntry,

        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if ($null -ne $ManagementEntry) {
        $declared = Get-PshPropertyValue -InputObject $ManagementEntry -Name 'SupportsJson'
        if ($null -ne $declared) {
            return (ConvertTo-PshBoolean -Value $declared)
        }
    }

    # A missing declaration is treated conservatively.  The two discovery
    # commands are JSON-capable by contract; version follows its declaration.
    return ($Action -eq 'capabilities' -or $Action -eq 'commands')
}

function psh {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    Set-PshLastExitCode -Code 0
    $items = @()
    if ($null -ne $Arguments) {
        $items = @($Arguments)
    }
    if ($items.Count -eq 0) {
        Write-PshUsage -Message 'an action is required.'
        Set-PshLastExitCode -Code 2
        return
    }

    $action = ([string]$items[0]).Trim().ToLowerInvariant()
    if ($action -eq '--help' -or $action -eq '-h' -or $action -eq 'help') {
        Write-PshUsage -Message $null
        Set-PshLastExitCode -Code 0
        return
    }

    $json = $false
    if ($items.Count -gt 1) {
        for ($index = 1; $index -lt $items.Count; $index++) {
            $argument = [string]$items[$index]
            if ($argument -eq '--json' -and -not $json) {
                $json = $true
                continue
            }

            Write-PshUsage -Message ('unsupported argument "{0}".' -f $argument)
            Set-PshLastExitCode -Code 2
            return
        }
    }

    # Goal 1 deliberately exposes only discovery/version actions.  Other
    # management names remain in the machine-readable specification for later
    # goals, while an actually unknown action is a usage error.
    $implementedActions = @('version', 'capabilities', 'commands')
    if ($implementedActions -notcontains $action) {
        Write-PshUsage -Message ('unknown action "{0}".' -f $action)
        Set-PshLastExitCode -Code 2
        return
    }

    try {
        $specification = Import-PshSpecification
        $managementEntries = @(Get-PshManagementEntries -Specification $specification)
        $managementEntry = Get-PshManagementEntry -Entries $managementEntries -Name $action
        if ($json -and -not (Get-PshJsonSupport -ManagementEntry $managementEntry -Action $action)) {
            Write-PshUsage -Message ('action "{0}" does not support --json.' -f $action)
            Set-PshLastExitCode -Code 2
            return
        }

        switch ($action) {
            'version' {
                $data = Get-PshVersionData -Specification $specification
                if ($json) {
                    Write-Output (ConvertTo-PshJsonText -InputObject $data)
                }
                else {
                    Write-Output ('psh {0}' -f [string]$data.pshVersion)
                }
            }
            'capabilities' {
                $data = Get-PshCapabilitiesData -Specification $specification
                if ($json) {
                    Write-Output (ConvertTo-PshJsonText -InputObject $data)
                }
                else {
                    Write-Output ('edition: {0}' -f [string]$data.edition)
                    foreach ($command in @($data.commands)) {
                        Write-Output ("{0}`t{1}" -f [string]$command.name, [string]$command.activeBackend)
                    }
                }
            }
            'commands' {
                $data = Get-PshCommandsData -Specification $specification
                if ($json) {
                    Write-Output (ConvertTo-PshJsonText -InputObject $data)
                }
                else {
                    foreach ($command in @($data.commands)) {
                        Write-Output ([string]$command.name)
                    }
                }
            }
        }

        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshRuntimeError -ErrorValue $_
        Set-PshLastExitCode -Code 3
    }
}

function Get-PshCapabilities {
    [CmdletBinding()]
    param(
        [Alias('AsJson')]
        [switch]$Json
    )

    $specification = Import-PshSpecification
    $data = Get-PshCapabilitiesData -Specification $specification
    if ($Json) {
        return (ConvertTo-PshJsonText -InputObject $data)
    }

    return $data
}

function Get-PshCommandSpecification {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Command', 'CommandName')]
        [AllowNull()]
        [string]$Name,

        [switch]$IncludeManagement,

        [switch]$Json
    )

    $specification = Import-PshSpecification
    $commands = @(Get-PshCommandEntries -Specification $specification)
    $managementEntries = @(Get-PshManagementEntries -Specification $specification)

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        foreach ($entry in $commands) {
            if ([string]::Equals((Get-PshCommandName -Entry $entry), $Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($Json) {
                    return (ConvertTo-PshJsonText -InputObject $entry)
                }
                return $entry
            }
        }

        if ($IncludeManagement) {
            foreach ($entry in $managementEntries) {
                if ([string]::Equals((Get-PshCommandName -Entry $entry), $Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($Json) {
                        return (ConvertTo-PshJsonText -InputObject $entry)
                    }
                    return $entry
                }
            }
        }

        return $null
    }

    $normalized = ConvertTo-PshNormalizedSpecification -Specification $specification
    if ($Json) {
        return (ConvertTo-PshJsonText -InputObject $normalized)
    }

    return $normalized
}

function Initialize-PshArgumentCompleters {
    $completerPath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Generated') -ChildPath 'ArgumentCompleters.ps1'
    if (-not (Test-Path -LiteralPath $completerPath -PathType Leaf)) {
        return
    }

    try {
        . $completerPath

        # Generated files may register directly when dot-sourced, or expose a
        # small registrar so this module controls when registration occurs.
        $registrar = Get-Command -Name 'Register-PshArgumentCompleters' -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $registrar) {
            & $registrar
        }
    }
    catch {
        # Completion is optional at import time.  Keep the import quiet and
        # retain the diagnostic for a future doctor/self-test implementation.
        $script:PshCompleterLoadError = $_.Exception.Message
    }
}

Initialize-PshArgumentCompleters

Export-ModuleMember -Function @(
    'psh'
    'Get-PshCapabilities'
    'Get-PshCommandSpecification'
)
