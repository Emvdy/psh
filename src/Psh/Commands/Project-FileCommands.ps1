# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

# ScriptsToProcess runs in the importing session. Use one collision-checked
# child-scope context object; all other iteration state lives on that object or
# in PowerShell automatic variables. The caller scope therefore retains every
# pre-existing variable exactly, including AllScope variables.

if ($null -ne (Get-Variable -Name '__PshProjection_baf0d32a_Context' -ErrorAction SilentlyContinue) -and
    (((Get-Variable -Name '__PshProjection_baf0d32a_Context' -ErrorAction Stop).Options -band [System.Management.Automation.ScopedItemOptions]::AllScope) -ne 0)) {
    throw 'Psh cannot project file commands because the caller has an AllScope projection-context variable.'
}

& {
    $__PshProjection_baf0d32a_Context = [ordered]@{
        HandoffName = '__PshFileCommandProjection_baf0d32a'
        Disabled = @{}
        LocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', [EnvironmentVariableTarget]::Process)
        ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
        CanonicalConfigPath = $null
        InstalledConfigPath = $null
        ConfigPath = $null
        ConfigLoadError = $null
        Edition = 'Core'
        KnownCommands = @{}
        KnownAliases = [ordered]@{
            pwd = @('Get-Location')
            cd = @('Set-Location')
            ls = @('Get-ChildItem')
            rmdir = @('Remove-Item')
            cp = @('Copy-Item')
            mv = @('Move-Item')
            rm = @('Remove-Item')
        }
        State = [ordered]@{
            Aliases = [ordered]@{}
            DisabledCommands = $null
            ConfigPath = $null
            ConfigLoadError = $null
            Edition = 'Core'
            Restore = {
                foreach ($__PshProjection_baf0d32a_Context in @($args[0].Keys)) {
                    if ($null -eq (Get-Alias -Name $__PshProjection_baf0d32a_Context -Scope Global -ErrorAction SilentlyContinue)) {
                        Set-Alias -Name ([string]$__PshProjection_baf0d32a_Context) `
                            -Value ([string]$args[0][$__PshProjection_baf0d32a_Context].Definition) `
                            -Description ([string]$args[0][$__PshProjection_baf0d32a_Context].Description) `
                            -Option ([System.Management.Automation.ScopedItemOptions]$args[0][$__PshProjection_baf0d32a_Context].Options) `
                            -Scope Global `
                            -Force
                    }
                }
            }
        }
    }

    if ($null -ne (Get-Variable -Name $__PshProjection_baf0d32a_Context.HandoffName -Scope Global -ErrorAction SilentlyContinue)) {
        throw ('Psh cannot project file commands because the caller variable ${0} already exists.' -f $__PshProjection_baf0d32a_Context.HandoffName)
    }

    if (-not [string]::IsNullOrWhiteSpace($__PshProjection_baf0d32a_Context.LocalAppData)) {
        $__PshProjection_baf0d32a_Context.CanonicalConfigPath = Join-Path -Path (Join-Path -Path $__PshProjection_baf0d32a_Context.LocalAppData -ChildPath 'Psh') -ChildPath 'config.psd1'
    }

    $__PshProjection_baf0d32a_Context.VersionRoot = Split-Path -Path $__PshProjection_baf0d32a_Context.ModuleRoot -Parent
    $__PshProjection_baf0d32a_Context.VersionsRoot = Split-Path -Path $__PshProjection_baf0d32a_Context.VersionRoot -Parent
    $__PshProjection_baf0d32a_Context.InstallRoot = Split-Path -Path $__PshProjection_baf0d32a_Context.VersionsRoot -Parent
    $__PshProjection_baf0d32a_Context.VersionName = Split-Path -Path $__PshProjection_baf0d32a_Context.VersionRoot -Leaf
    $__PshProjection_baf0d32a_Context.VersionsName = Split-Path -Path $__PshProjection_baf0d32a_Context.VersionsRoot -Leaf
    if ([string]::Equals($__PshProjection_baf0d32a_Context.VersionsName, 'versions', [StringComparison]::OrdinalIgnoreCase) -and
        $__PshProjection_baf0d32a_Context.VersionName -match '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z') {
        $__PshProjection_baf0d32a_Context.InstalledConfigPath = Join-Path -Path $__PshProjection_baf0d32a_Context.InstallRoot -ChildPath 'config.psd1'
    }

    if (-not [string]::IsNullOrWhiteSpace($__PshProjection_baf0d32a_Context.CanonicalConfigPath) -and
        (Test-Path -LiteralPath $__PshProjection_baf0d32a_Context.CanonicalConfigPath)) {
        $__PshProjection_baf0d32a_Context.ConfigPath = $__PshProjection_baf0d32a_Context.CanonicalConfigPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($__PshProjection_baf0d32a_Context.InstalledConfigPath) -and
        (Test-Path -LiteralPath $__PshProjection_baf0d32a_Context.InstalledConfigPath)) {
        $__PshProjection_baf0d32a_Context.ConfigPath = $__PshProjection_baf0d32a_Context.InstalledConfigPath
    }

    if (-not [string]::IsNullOrWhiteSpace($__PshProjection_baf0d32a_Context.ConfigPath)) {
        try {
            $__PshProjection_baf0d32a_Context.Config = Import-PowerShellDataFile -LiteralPath $__PshProjection_baf0d32a_Context.ConfigPath -ErrorAction Stop
            if ($__PshProjection_baf0d32a_Context.Config -isnot [System.Collections.IDictionary]) {
                throw 'the top level must be a data hashtable'
            }

            @($__PshProjection_baf0d32a_Context.Config.Keys) | ForEach-Object {
                if ([string]$_ -notin @('SchemaVersion', 'Edition', 'DisabledCommands')) {
                    throw ('unsupported top-level key "{0}"' -f [string]$_)
                }
            }
            if ($__PshProjection_baf0d32a_Context.Config.SchemaVersion -isnot [int] -or
                [int]$__PshProjection_baf0d32a_Context.Config.SchemaVersion -ne 1) {
                throw 'SchemaVersion must be 1'
            }
            if ([string]$__PshProjection_baf0d32a_Context.Config.Edition -notin @('Core', 'Full')) {
                throw 'Edition must be Core or Full'
            }
            $__PshProjection_baf0d32a_Context.Edition = if ([string]::Equals([string]$__PshProjection_baf0d32a_Context.Config.Edition, 'Full', [StringComparison]::OrdinalIgnoreCase)) { 'Full' } else { 'Core' }

            $__PshProjection_baf0d32a_Context.SpecificationPath = Join-Path -Path (Join-Path -Path $__PshProjection_baf0d32a_Context.ModuleRoot -ChildPath 'Specification') -ChildPath 'commands.psd1'
            $__PshProjection_baf0d32a_Context.Specification = Import-PowerShellDataFile -LiteralPath $__PshProjection_baf0d32a_Context.SpecificationPath -ErrorAction Stop
            @($__PshProjection_baf0d32a_Context.Specification.Commands) | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace([string]$_.Name)) {
                    throw 'the command specification contains an empty name'
                }
                $__PshProjection_baf0d32a_Context.KnownCommands[([string]$_.Name).Trim().ToLowerInvariant()] = $true
            }
            if ($__PshProjection_baf0d32a_Context.KnownCommands.Count -ne 64) {
                throw 'the command specification must contain 64 unique command names'
            }

            $__PshProjection_baf0d32a_Context.Value = $__PshProjection_baf0d32a_Context.Config.DisabledCommands
            if ($__PshProjection_baf0d32a_Context.Value -is [string] -or
                $__PshProjection_baf0d32a_Context.Value -isnot [System.Collections.IEnumerable] -or
                $__PshProjection_baf0d32a_Context.Value -is [System.Collections.IDictionary]) {
                throw 'DisabledCommands must be a string array'
            }
            @($__PshProjection_baf0d32a_Context.Value) | ForEach-Object {
                if ($_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_)) {
                    throw 'DisabledCommands must contain non-empty strings'
                }
                $__PshProjection_baf0d32a_Context.DisabledName = ([string]$_).Trim().ToLowerInvariant()
                if (-not $__PshProjection_baf0d32a_Context.KnownCommands.ContainsKey($__PshProjection_baf0d32a_Context.DisabledName)) {
                    throw ('DisabledCommands contains unknown command "{0}"' -f [string]$_)
                }
                $__PshProjection_baf0d32a_Context.Disabled[$__PshProjection_baf0d32a_Context.DisabledName] = $true
            }
        }
        catch {
            $__PshProjection_baf0d32a_Context.Disabled.Clear()
            $__PshProjection_baf0d32a_Context.Edition = 'Core'
            $__PshProjection_baf0d32a_Context.ConfigLoadError = [string]$_.Exception.Message
        }
    }

    $__PshProjection_baf0d32a_Context.State.DisabledCommands = $__PshProjection_baf0d32a_Context.Disabled
    $__PshProjection_baf0d32a_Context.State.ConfigPath = $__PshProjection_baf0d32a_Context.ConfigPath
    $__PshProjection_baf0d32a_Context.State.ConfigLoadError = $__PshProjection_baf0d32a_Context.ConfigLoadError
    $__PshProjection_baf0d32a_Context.State.Edition = $__PshProjection_baf0d32a_Context.Edition

    $__PshProjection_baf0d32a_Context.KnownAliases.Keys | ForEach-Object {
        $__PshProjection_baf0d32a_Context.CurrentName = [string]$_
        if (-not $__PshProjection_baf0d32a_Context.Disabled.ContainsKey($__PshProjection_baf0d32a_Context.CurrentName)) {
            $__PshProjection_baf0d32a_Context.VisibleAlias = Get-Alias -Name $__PshProjection_baf0d32a_Context.CurrentName -ErrorAction SilentlyContinue
            if ($null -ne $__PshProjection_baf0d32a_Context.VisibleAlias) {
                $__PshProjection_baf0d32a_Context.Known = $false
                @($__PshProjection_baf0d32a_Context.KnownAliases[$__PshProjection_baf0d32a_Context.CurrentName]) | ForEach-Object {
                    if ([string]::Equals([string]$__PshProjection_baf0d32a_Context.VisibleAlias.Definition, [string]$_, [StringComparison]::OrdinalIgnoreCase)) {
                        $__PshProjection_baf0d32a_Context.Known = $true
                    }
                }
                if ($__PshProjection_baf0d32a_Context.Known) {
                    $__PshProjection_baf0d32a_Context.State.Aliases[$__PshProjection_baf0d32a_Context.CurrentName] = [PSCustomObject]@{
                        Definition = [string]$__PshProjection_baf0d32a_Context.VisibleAlias.Definition
                        Description = [string]$__PshProjection_baf0d32a_Context.VisibleAlias.Description
                        Options = [System.Management.Automation.ScopedItemOptions]$__PshProjection_baf0d32a_Context.VisibleAlias.Options
                        Scope = 'Global'
                    }
                }
            }
        }
    }

    Set-Variable -Name $__PshProjection_baf0d32a_Context.HandoffName -Value $__PshProjection_baf0d32a_Context.State -Scope Global -Force -ErrorAction Stop
}

try {
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('pwd')) { Remove-Item -LiteralPath Alias:pwd -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('cd')) { Remove-Item -LiteralPath Alias:cd -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('ls')) { Remove-Item -LiteralPath Alias:ls -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('rmdir')) { Remove-Item -LiteralPath Alias:rmdir -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('cp')) { Remove-Item -LiteralPath Alias:cp -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('mv')) { Remove-Item -LiteralPath Alias:mv -Force -ErrorAction Stop }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases.Contains('rm')) { Remove-Item -LiteralPath Alias:rm -Force -ErrorAction Stop }
}
catch {
    & (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Restore (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Aliases
    Remove-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -Force -ErrorAction SilentlyContinue
    throw
}
