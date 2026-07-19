# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# Psh's public module surface is intentionally small.  The command catalog is
# data-driven; no executable utility is launched while the module is loaded.

$script:PshCallerFileCommandProjection = $null
$script:PshDisabledCommands = @{}
$script:PshConfigSnapshotPath = $null
$script:PshConfigLoadError = $null
$script:PshConfigEdition = 'Core'
$pshProjectionHandoff = Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $pshProjectionHandoff) {
    $script:PshCallerFileCommandProjection = $pshProjectionHandoff.Value
    if ($null -ne $pshProjectionHandoff.Value.DisabledCommands) {
        $script:PshDisabledCommands = $pshProjectionHandoff.Value.DisabledCommands
    }
    $script:PshConfigSnapshotPath = $pshProjectionHandoff.Value.ConfigPath
    $script:PshConfigLoadError = $pshProjectionHandoff.Value.ConfigLoadError
    if ([string]::Equals([string]$pshProjectionHandoff.Value.Edition, 'Full', [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:PshConfigEdition = 'Full'
    }
    Remove-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -Force -ErrorAction Stop
}
Remove-Variable -Name pshProjectionHandoff -ErrorAction SilentlyContinue

function Restore-PshCallerFileCommandProjection {
    param(
        [AllowNull()]
        [object]$State
    )

    if ($null -eq $State -or $null -eq $State.Aliases -or $null -eq $State.Restore) { return }
    & $State.Restore $State.Aliases
}

$ExecutionContext.SessionState.Module.OnRemove = {
    Restore-PshCallerFileCommandProjection -State $script:PshCallerFileCommandProjection
    $script:PshCallerFileCommandProjection = $null
}

try {
$script:PshCompleterLoadError = $null
$script:PshInteractiveLoadError = $null

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

function Get-PshCanonicalConfigPath {
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', [EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }

    if ([string]::IsNullOrWhiteSpace([string]$localAppData)) {
        return $null
    }

    return (Join-Path -Path (Join-Path -Path $localAppData -ChildPath 'Psh') -ChildPath 'config.psd1')
}

function Get-PshInstalledConfigPath {
    $versionRoot = Split-Path -Path $PSScriptRoot -Parent
    $versionsRoot = Split-Path -Path $versionRoot -Parent
    $installRoot = Split-Path -Path $versionsRoot -Parent
    $versionName = Split-Path -Path $versionRoot -Leaf
    $versionsName = Split-Path -Path $versionsRoot -Leaf
    $versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'

    if (-not [string]::Equals($versionsName, 'versions', [System.StringComparison]::OrdinalIgnoreCase) -or
        $versionName -notmatch $versionPattern -or
        [string]::IsNullOrWhiteSpace([string]$installRoot)) {
        return $null
    }

    return (Join-Path -Path $installRoot -ChildPath 'config.psd1')
}

function Get-PshConfigPaths {
    $paths = @()
    $canonicalPath = Get-PshCanonicalConfigPath
    $installedPath = Get-PshInstalledConfigPath

    if (-not [string]::IsNullOrWhiteSpace([string]$canonicalPath)) {
        $paths += $canonicalPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$installedPath) -and $paths -notcontains $installedPath) {
        $paths += $installedPath
    }

    return $paths
}

function Resolve-PshConfigPath {
    $paths = @(Get-PshConfigPaths)
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    if ($paths.Count -gt 0) {
        return [string]$paths[0]
    }

    throw 'LOCALAPPDATA is not available and Psh is not running from a versioned installation layout.'
}

function Import-PshConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$KnownCommands
    )

    if (-not [IO.File]::Exists($Path)) {
        if (Test-Path -LiteralPath $Path) {
            throw ('Psh configuration path is not a regular file: {0}' -f $Path)
        }

        return [PSCustomObject]@{
            Path = $Path
            SchemaVersion = 1
            Edition = 'Core'
            DisabledCommands = @()
            Exists = $false
        }
    }

    try {
        $raw = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw ('Psh configuration could not be loaded from {0}: {1}' -f $Path, $_.Exception.Message)
    }

    if ($raw -isnot [System.Collections.IDictionary]) {
        throw ('Psh configuration is invalid: the top level of {0} must be a data hashtable.' -f $Path)
    }

    $allowedKeys = @('SchemaVersion', 'Edition', 'DisabledCommands')
    foreach ($key in @($raw.Keys)) {
        if ($allowedKeys -notcontains [string]$key) {
            throw ('Psh configuration is invalid: unsupported top-level key "{0}".' -f [string]$key)
        }
    }
    foreach ($requiredKey in $allowedKeys) {
        if (-not (Test-PshProperty -InputObject $raw -Name $requiredKey)) {
            throw ('Psh configuration is invalid: required key "{0}" is missing.' -f $requiredKey)
        }
    }

    $schemaVersion = Get-PshPropertyValue -InputObject $raw -Name 'SchemaVersion'
    if ($schemaVersion -isnot [int] -or [int]$schemaVersion -ne 1) {
        throw 'Psh configuration is invalid: SchemaVersion must be the integer 1.'
    }

    $editionValue = Get-PshPropertyValue -InputObject $raw -Name 'Edition'
    if ($editionValue -isnot [string] -or
        ([string]$editionValue -notin @('Core', 'Full'))) {
        throw 'Psh configuration is invalid: Edition must be Core or Full.'
    }
    $edition = if ([string]::Equals([string]$editionValue, 'Full', [System.StringComparison]::OrdinalIgnoreCase)) { 'Full' } else { 'Core' }

    $disabledValue = $null
    foreach ($rawKey in @($raw.Keys)) {
        if ([string]::Equals([string]$rawKey, 'DisabledCommands', [System.StringComparison]::OrdinalIgnoreCase)) {
            $disabledValue = $raw[$rawKey]
            break
        }
    }
    if ($disabledValue -is [string] -or
        $disabledValue -isnot [System.Collections.IEnumerable] -or
        $disabledValue -is [System.Collections.IDictionary]) {
        throw 'Psh configuration is invalid: DisabledCommands must be a string array.'
    }

    $knownByName = @{}
    foreach ($knownCommand in @($KnownCommands)) {
        $knownByName[$knownCommand.ToLowerInvariant()] = $knownCommand.ToLowerInvariant()
    }

    $requested = @{}
    foreach ($disabledCommand in @($disabledValue)) {
        if ($disabledCommand -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$disabledCommand)) {
            throw 'Psh configuration is invalid: DisabledCommands must contain non-empty strings.'
        }
        $key = ([string]$disabledCommand).Trim().ToLowerInvariant()
        if (-not $knownByName.ContainsKey($key)) {
            throw ('Psh configuration is invalid: unknown command "{0}".' -f [string]$disabledCommand)
        }
        $requested[$key] = $true
    }

    $disabled = @()
    foreach ($knownCommand in @($KnownCommands)) {
        $key = $knownCommand.ToLowerInvariant()
        if ($requested.ContainsKey($key)) {
            $disabled += $key
        }
    }

    return [PSCustomObject]@{
        Path = $Path
        SchemaVersion = 1
        Edition = $edition
        DisabledCommands = @($disabled)
        Exists = $true
    }
}

function ConvertTo-PshConfigurationText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('# Copyright (C) 2026 Emvdy')
    [void]$lines.Add('# SPDX-License-Identifier: GPL-3.0-or-later')
    [void]$lines.Add('')
    [void]$lines.Add('@{')
    [void]$lines.Add('    SchemaVersion    = 1')
    [void]$lines.Add(("    Edition          = '{0}'" -f ([string]$Configuration.Edition).Replace("'", "''")))

    $disabled = @($Configuration.DisabledCommands)
    if ($disabled.Count -eq 0) {
        [void]$lines.Add('    DisabledCommands = @()')
    }
    else {
        [void]$lines.Add('    DisabledCommands = @(')
        foreach ($commandName in $disabled) {
            [void]$lines.Add(("        '{0}'" -f ([string]$commandName).Replace("'", "''")))
        }
        [void]$lines.Add('    )')
    }

    [void]$lines.Add('}')
    return (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-PshConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [Parameter(Mandatory = $true)]
        [string[]]$KnownCommands
    )

    $path = [string]$Configuration.Path
    $directory = Split-Path -Path $path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw ('Psh configuration path has no parent directory: {0}' -f $path)
    }
    if ([IO.Directory]::Exists($path)) {
        throw ('Psh configuration path is a directory: {0}' -f $path)
    }

    [void][IO.Directory]::CreateDirectory($directory)
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path -Path $directory -ChildPath ('.config.{0}.tmp' -f $operationId)
    $backupPath = Join-Path -Path $directory -ChildPath ('.config.{0}.bak' -f $operationId)

    try {
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, (ConvertTo-PshConfigurationText -Configuration $Configuration), $utf8WithoutBom)
        $null = Import-PshConfiguration -Path $temporaryPath -KnownCommands $KnownCommands

        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temporaryPath, $path, $backupPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $path)
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
                # A stale Psh-owned backup does not invalidate an atomic write.
            }
        }
    }
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

    return $script:PshConfigEdition
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

function Write-PshConfigUsage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Output ('psh: usage error: {0}' -f $Message)
    }
    Write-Output 'Usage: psh config get [DisabledCommands]'
    Write-Output '       psh config set DisabledCommands <command> [<command>...]'
    Write-Output '       psh config reset DisabledCommands'
}

function Format-PshDisabledCommands {
    param(
        [AllowEmptyCollection()]
        [string[]]$CommandNames
    )

    $names = @($CommandNames)
    if ($names.Count -eq 0) {
        return 'DisabledCommands = @()'
    }

    $quoted = @($names | ForEach-Object { "'{0}'" -f ([string]$_).Replace("'", "''") })
    return ('DisabledCommands = @({0})' -f ($quoted -join ', '))
}

function Invoke-PshConfigCommand {
    param(
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [object]$Specification
    )

    $items = @($Arguments)
    if ($items.Count -eq 0) {
        Write-PshConfigUsage -Message 'a config action is required.'
        return 2
    }

    $subaction = ([string]$items[0]).Trim().ToLowerInvariant()
    if ($subaction -eq '--help') {
        if ($items.Count -ne 1) {
            Write-PshConfigUsage -Message '--help does not accept additional arguments.'
            return 2
        }
        Write-PshConfigUsage -Message $null
        return 0
    }

    if ($subaction -notin @('get', 'set', 'reset')) {
        Write-PshConfigUsage -Message ('unknown config action "{0}".' -f [string]$items[0])
        return 2
    }

    $knownCommands = @()
    foreach ($entry in @(Get-PshCommandEntries -Specification $Specification)) {
        $knownCommands += (Get-PshCommandName -Entry $entry).ToLowerInvariant()
    }
    $knownByName = @{}
    foreach ($knownCommand in $knownCommands) {
        $knownByName[$knownCommand] = $true
    }

    if ($subaction -eq 'get') {
        if ($items.Count -gt 2) {
            Write-PshConfigUsage -Message 'config get accepts at most one key.'
            return 2
        }
        if ($items.Count -eq 2 -and
            -not [string]::Equals(([string]$items[1]).Trim(), 'DisabledCommands', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-PshConfigUsage -Message ('unknown config key "{0}".' -f [string]$items[1])
            return 2
        }

        $path = Resolve-PshConfigPath
        $configuration = Import-PshConfiguration -Path $path -KnownCommands $knownCommands
        Write-Output (Format-PshDisabledCommands -CommandNames @($configuration.DisabledCommands))
        return 0
    }

    if ($items.Count -lt 2 -or
        -not [string]::Equals(([string]$items[1]).Trim(), 'DisabledCommands', [System.StringComparison]::OrdinalIgnoreCase)) {
        $key = if ($items.Count -gt 1) { [string]$items[1] } else { '' }
        Write-PshConfigUsage -Message ('unknown or missing config key "{0}".' -f $key)
        return 2
    }

    if ($subaction -eq 'reset') {
        if ($items.Count -ne 2) {
            Write-PshConfigUsage -Message 'config reset accepts only the DisabledCommands key.'
            return 2
        }

        $path = Resolve-PshConfigPath
        $configuration = Import-PshConfiguration -Path $path -KnownCommands $knownCommands
        $configuration.DisabledCommands = @()
        Write-PshConfiguration -Configuration $configuration -KnownCommands $knownCommands
        Write-Output (Format-PshDisabledCommands -CommandNames @())
        Write-Output 'The change takes effect in a new shell or after re-importing Psh.'
        return 0
    }

    if ($items.Count -lt 3) {
        Write-PshConfigUsage -Message 'config set requires at least one command name; use reset for the empty set.'
        return 2
    }

    $requested = @{}
    for ($index = 2; $index -lt $items.Count; $index++) {
        $rawName = [string]$items[$index]
        $commandName = $rawName.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($commandName) -or -not $knownByName.ContainsKey($commandName)) {
            Write-PshConfigUsage -Message ('unknown Psh command "{0}".' -f $rawName)
            return 2
        }
        $requested[$commandName] = $true
    }

    $disabled = @()
    foreach ($knownCommand in $knownCommands) {
        if ($requested.ContainsKey($knownCommand)) {
            $disabled += $knownCommand
        }
    }

    $path = Resolve-PshConfigPath
    $configuration = Import-PshConfiguration -Path $path -KnownCommands $knownCommands
    $configuration.DisabledCommands = @($disabled)
    Write-PshConfiguration -Configuration $configuration -KnownCommands $knownCommands
    Write-Output (Format-PshDisabledCommands -CommandNames $disabled)
    Write-Output 'The change takes effect in a new shell or after re-importing Psh.'
    return 0
}

function Write-PshUsage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Output ('psh: usage error: {0}' -f $Message)
    }
    Write-Output 'Usage: psh version|capabilities|commands [--json] | config get|set|reset'
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

    if ($action -eq 'config') {
        $configArguments = @()
        for ($index = 1; $index -lt $items.Count; $index++) {
            $configArguments += [string]$items[$index]
        }

        try {
            $specification = Import-PshSpecification
            $configResult = @(Invoke-PshConfigCommand -Arguments $configArguments -Specification $specification)
            if ($configResult.Count -eq 0 -or $configResult[$configResult.Count - 1] -isnot [int]) {
                throw 'Psh config command did not return an exit code.'
            }
            $configExitCode = [int]$configResult[$configResult.Count - 1]
            for ($index = 0; $index -lt ($configResult.Count - 1); $index++) {
                Write-Output $configResult[$index]
            }
            Set-PshLastExitCode -Code $configExitCode
        }
        catch {
            Write-PshRuntimeError -ErrorValue $_
            Set-PshLastExitCode -Code 3
        }
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

    # Remaining management names stay in the machine-readable specification for
    # later goals, while an actually unknown action is a usage error.
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

$fileCommandsPath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Commands') -ChildPath 'FileCommands.ps1'
if (-not (Test-Path -LiteralPath $fileCommandsPath -PathType Leaf)) {
    throw ('Psh file-command source is missing: {0}' -f $fileCommandsPath)
}
. $fileCommandsPath

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

$interactivePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Interactive') -ChildPath 'Initialize-PshInteractive.ps1'
if (-not (Test-Path -LiteralPath $interactivePath -PathType Leaf)) {
    $script:PshInteractiveLoadError = 'Interactive initialization source is missing.'
}
else {
    try {
        # Dot-source at module scope so the exported initializer survives import.
        . $interactivePath
    }
    catch {
        $script:PshInteractiveLoadError = [string]$_.Exception.Message
    }
}

Initialize-PshArgumentCompleters

$exportedFunctions = @(
    'psh'
    'Get-PshCapabilities'
    'Get-PshCommandSpecification'
    'Initialize-PshInteractive'
    'Find-PshItem'
    'Set-PshFileTime'
)
$exportedFunctions += @(Get-PshEnabledFileCommandNames)

Export-ModuleMember -Function $exportedFunctions
}
catch {
    $pshModuleInitializationError = $_
    try {
        Restore-PshCallerFileCommandProjection -State $script:PshCallerFileCommandProjection
    }
    finally {
        $script:PshCallerFileCommandProjection = $null
    }
    throw $pshModuleInitializationError
}
