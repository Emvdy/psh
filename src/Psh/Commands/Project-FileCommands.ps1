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
            cat = @('Get-Content')
            sort = @('Sort-Object')
            tee = @('Tee-Object')
            echo = @('Write-Output')
        }
        State = [ordered]@{
            ProjectedAliases = [ordered]@{}
            ScopeMarkerName = '__PshFileCommandProjectionScope_baf0d32a'
            ScopeStates = @()
            ScopeStateByToken = @{}
            GlobalScopeToken = $null
            RestoreProjectedName = {
                $args[0]['RuntimeRollbackName'] = [string]$args[1]
                $args[0]['RuntimeRollbackScopes'] = @()
                $args[0]['RuntimeScopeNumber'] = 0
                $args[0]['RuntimeBoundaryFound'] = $false
                while (-not $args[0].RuntimeBoundaryFound) {
                    try {
                        Get-Variable -Name null -Scope $args[0].RuntimeScopeNumber -ErrorAction Stop | Out-Null
                    }
                    catch {
                        throw 'Psh could not find its global projection marker while rolling back one alias.'
                    }
                    $args[0]['RuntimeMarker'] = Get-Variable -Name $args[0].ScopeMarkerName -Scope $args[0].RuntimeScopeNumber -ErrorAction SilentlyContinue
                    if ($null -ne $args[0].RuntimeMarker) {
                        $args[0]['RuntimeToken'] = [string]$args[0].RuntimeMarker.Value.Token
                        if ($args[0].ScopeStateByToken.ContainsKey($args[0].RuntimeToken)) {
                            $args[0]['RuntimeScopeState'] = $args[0].ScopeStateByToken[$args[0].RuntimeToken]
                            if ([string]$args[0].RuntimeMarker.Description -ceq [string]$args[0].RuntimeScopeState.MarkerDescription -and
                                $args[0].RuntimeMarker.Options -eq [System.Management.Automation.ScopedItemOptions]::None) {
                                $args[0].RuntimeRollbackScopes += [PSCustomObject]@{
                                    Number = [int]$args[0].RuntimeScopeNumber
                                    State = $args[0].RuntimeScopeState
                                }
                                if ($args[0].RuntimeScopeState.IsGlobal -and
                                    [string]$args[0].RuntimeToken -ceq [string]$args[0].GlobalScopeToken) {
                                    $args[0]['RuntimeBoundaryFound'] = $true
                                }
                            }
                        }
                    }
                    if (-not $args[0].RuntimeBoundaryFound) {
                        $args[0]['RuntimeScopeNumber'] = [int]$args[0].RuntimeScopeNumber + 1
                    }
                }

                $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeRollbackScopes.Count - 1
                while ($args[0].RuntimeRestoreIndex -ge 0) {
                    $args[0]['RuntimeCurrentScope'] = $args[0].RuntimeRollbackScopes[$args[0].RuntimeRestoreIndex]
                    if ($args[0].RuntimeCurrentScope.State.Aliases.Contains($args[0].RuntimeRollbackName)) {
                        $args[0]['RuntimeOriginal'] = $args[0].RuntimeCurrentScope.State.Aliases[$args[0].RuntimeRollbackName]
                        $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimeRollbackName -Scope $args[0].RuntimeCurrentScope.Number -ErrorAction SilentlyContinue
                        if ($null -eq $args[0].RuntimeAlias) {
                            Set-Alias -Name $args[0].RuntimeRollbackName `
                                -Value ([string]$args[0].RuntimeOriginal.Definition) `
                                -Description ([string]$args[0].RuntimeOriginal.Description) `
                                -Option ([System.Management.Automation.ScopedItemOptions]$args[0].RuntimeOriginal.Options) `
                                -Scope $args[0].RuntimeCurrentScope.Number `
                                -Force
                            $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimeRollbackName -Scope $args[0].RuntimeCurrentScope.Number -ErrorAction Stop
                            $args[0].RuntimeAlias.Visibility = [System.Management.Automation.SessionStateEntryVisibility]$args[0].RuntimeOriginal.Visibility
                        }
                    }
                    $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeRestoreIndex - 1
                }
            }
            Peel = {
                $args[0]['RuntimePeelName'] = [string]$args[1]
                $args[0]['RuntimeKnownDefinitions'] = @($args[0].ProjectedAliases[$args[0].RuntimePeelName].KnownDefinitions)
                $args[0]['RuntimePeeledCount'] = 0
                while ($null -ne (Get-Alias -Name $args[0].RuntimePeelName -ErrorAction SilentlyContinue)) {
                    $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimePeelName -ErrorAction Stop
                    $args[0]['RuntimeKnown'] = $false
                    $args[0]['RuntimeIndex'] = 0
                    while ($args[0].RuntimeIndex -lt $args[0].RuntimeKnownDefinitions.Count) {
                        if ([string]::Equals([string]$args[0].RuntimeAlias.Definition, [string]$args[0].RuntimeKnownDefinitions[$args[0].RuntimeIndex], [StringComparison]::OrdinalIgnoreCase)) {
                            $args[0]['RuntimeKnown'] = $true
                        }
                        $args[0]['RuntimeIndex'] = [int]$args[0].RuntimeIndex + 1
                    }
                    if (-not $args[0].RuntimeKnown -or
                        ($args[0].RuntimeAlias.Options -band [System.Management.Automation.ScopedItemOptions]::Private) -ne 0 -or
                        $args[0].RuntimeAlias.Visibility -ne [System.Management.Automation.SessionStateEntryVisibility]::Public) {
                        . ($args[0].RestoreProjectedName) $args[0] $args[0].RuntimePeelName
                        [void]$args[0].ProjectedAliases.Remove($args[0].RuntimePeelName)
                        break
                    }
                    Remove-Item -LiteralPath ('Alias:{0}' -f $args[0].RuntimePeelName) -Force -ErrorAction Stop
                    $args[0]['RuntimePeeledCount'] = [int]$args[0].RuntimePeeledCount + 1
                }
            }
            DisabledCommands = $null
            ConfigPath = $null
            ConfigLoadError = $null
            Edition = 'Core'
            Restore = {
                $args[0]['RuntimeScopes'] = @()
                $args[0]['RuntimeScopeNumber'] = 0
                $args[0]['RuntimeGlobalScope'] = $null
                $args[0]['RuntimeBoundaryFound'] = $false
                while (-not $args[0].RuntimeBoundaryFound) {
                    try {
                        Get-Variable -Name null -Scope $args[0].RuntimeScopeNumber -ErrorAction Stop | Out-Null
                    }
                    catch {
                        throw 'Psh could not find its global projection marker before the caller scope chain ended; no alias state was restored.'
                    }
                    $args[0]['RuntimeMarker'] = Get-Variable -Name $args[0].ScopeMarkerName -Scope $args[0].RuntimeScopeNumber -ErrorAction SilentlyContinue
                    if ($null -ne $args[0].RuntimeMarker) {
                        $args[0]['RuntimeToken'] = [string]$args[0].RuntimeMarker.Value.Token
                        if ($args[0].ScopeStateByToken.ContainsKey($args[0].RuntimeToken)) {
                            $args[0]['RuntimeScopeState'] = $args[0].ScopeStateByToken[$args[0].RuntimeToken]
                            if ([string]$args[0].RuntimeMarker.Description -ceq [string]$args[0].RuntimeScopeState.MarkerDescription -and
                                $args[0].RuntimeMarker.Options -eq [System.Management.Automation.ScopedItemOptions]::None) {
                                $args[0].RuntimeScopes += [PSCustomObject]@{
                                    Number = [int]$args[0].RuntimeScopeNumber
                                    State = $args[0].RuntimeScopeState
                                }
                                if ($args[0].RuntimeScopeState.IsGlobal -and
                                    [string]$args[0].RuntimeToken -ceq [string]$args[0].GlobalScopeToken) {
                                    $args[0]['RuntimeGlobalScope'] = [int]$args[0].RuntimeScopeNumber
                                    $args[0]['RuntimeBoundaryFound'] = $true
                                }
                            }
                        }
                    }
                    if (-not $args[0].RuntimeBoundaryFound) {
                        $args[0]['RuntimeScopeNumber'] = [int]$args[0].RuntimeScopeNumber + 1
                    }
                }

                $args[0]['RuntimeNames'] = @($args[0].ProjectedAliases.Keys)
                $args[0]['RuntimeNameIndex'] = 0
                while ($args[0].RuntimeNameIndex -lt $args[0].RuntimeNames.Count) {
                    $args[0]['RuntimeName'] = [string]$args[0].RuntimeNames[$args[0].RuntimeNameIndex]
                    $args[0]['RuntimeLateScope'] = $null
                    $args[0]['RuntimeScopeNumber'] = 0
                    while ($null -ne $args[0].RuntimeGlobalScope -and
                        $args[0].RuntimeScopeNumber -le $args[0].RuntimeGlobalScope -and
                        $null -eq $args[0].RuntimeLateScope) {
                        $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimeName -Scope $args[0].RuntimeScopeNumber -ErrorAction SilentlyContinue
                        if ($null -ne $args[0].RuntimeAlias) {
                            $args[0]['RuntimeOwnedOriginal'] = $false
                            $args[0]['RuntimeMatchIndex'] = 0
                            while ($args[0].RuntimeMatchIndex -lt $args[0].RuntimeScopes.Count) {
                                $args[0]['RuntimeCurrentScope'] = $args[0].RuntimeScopes[$args[0].RuntimeMatchIndex]
                                if ($args[0].RuntimeCurrentScope.Number -eq $args[0].RuntimeScopeNumber -and
                                    $args[0].RuntimeCurrentScope.State.Aliases.Contains($args[0].RuntimeName)) {
                                    $args[0]['RuntimeOriginal'] = $args[0].RuntimeCurrentScope.State.Aliases[$args[0].RuntimeName]
                                    if ([string]$args[0].RuntimeAlias.Definition -ceq [string]$args[0].RuntimeOriginal.Definition -and
                                        [string]$args[0].RuntimeAlias.Description -ceq [string]$args[0].RuntimeOriginal.Description -and
                                        $args[0].RuntimeAlias.Options -eq $args[0].RuntimeOriginal.Options -and
                                        $args[0].RuntimeAlias.Visibility -eq $args[0].RuntimeOriginal.Visibility) {
                                        $args[0]['RuntimeOwnedOriginal'] = $true
                                    }
                                }
                                $args[0]['RuntimeMatchIndex'] = [int]$args[0].RuntimeMatchIndex + 1
                            }
                            if (-not $args[0].RuntimeOwnedOriginal) {
                                $args[0]['RuntimeLateScope'] = [int]$args[0].RuntimeScopeNumber
                            }
                        }
                        $args[0]['RuntimeScopeNumber'] = [int]$args[0].RuntimeScopeNumber + 1
                    }

                    $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeScopes.Count - 1
                    while ($args[0].RuntimeRestoreIndex -ge 0) {
                        $args[0]['RuntimeCurrentScope'] = $args[0].RuntimeScopes[$args[0].RuntimeRestoreIndex]
                        if ($args[0].RuntimeCurrentScope.State.Aliases.Contains($args[0].RuntimeName)) {
                            $args[0]['RuntimeOriginal'] = $args[0].RuntimeCurrentScope.State.Aliases[$args[0].RuntimeName]
                            $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimeName -Scope $args[0].RuntimeCurrentScope.Number -ErrorAction SilentlyContinue
                            if ($null -eq $args[0].RuntimeAlias -and
                                ($null -eq $args[0].RuntimeLateScope -or $args[0].RuntimeCurrentScope.Number -gt $args[0].RuntimeLateScope)) {
                                Set-Alias -Name $args[0].RuntimeName `
                                    -Value ([string]$args[0].RuntimeOriginal.Definition) `
                                    -Description ([string]$args[0].RuntimeOriginal.Description) `
                                    -Option ([System.Management.Automation.ScopedItemOptions]$args[0].RuntimeOriginal.Options) `
                                    -Scope $args[0].RuntimeCurrentScope.Number `
                                    -Force
                                $args[0]['RuntimeAlias'] = Get-Alias -Name $args[0].RuntimeName -Scope $args[0].RuntimeCurrentScope.Number -ErrorAction Stop
                                $args[0].RuntimeAlias.Visibility = [System.Management.Automation.SessionStateEntryVisibility]$args[0].RuntimeOriginal.Visibility
                            }
                        }
                        $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeRestoreIndex - 1
                    }
                    $args[0]['RuntimeNameIndex'] = [int]$args[0].RuntimeNameIndex + 1
                }

                $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeScopes.Count - 1
                while ($args[0].RuntimeRestoreIndex -ge 0) {
                    $args[0]['RuntimeCurrentScope'] = $args[0].RuntimeScopes[$args[0].RuntimeRestoreIndex]
                    $args[0]['RuntimeMarker'] = Get-Variable -Name $args[0].ScopeMarkerName -Scope $args[0].RuntimeCurrentScope.Number -ErrorAction SilentlyContinue
                    if ($null -ne $args[0].RuntimeMarker -and
                        [string]$args[0].RuntimeMarker.Value.Token -ceq [string]$args[0].RuntimeCurrentScope.State.Token -and
                        [string]$args[0].RuntimeMarker.Description -ceq [string]$args[0].RuntimeCurrentScope.State.MarkerDescription -and
                        $args[0].RuntimeMarker.Options -eq [System.Management.Automation.ScopedItemOptions]::None) {
                        Remove-Variable -Name $args[0].ScopeMarkerName -Scope $args[0].RuntimeCurrentScope.Number -Force -ErrorAction Stop
                    }
                    $args[0]['RuntimeRestoreIndex'] = [int]$args[0].RuntimeRestoreIndex - 1
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
                    if (($__PshProjection_baf0d32a_Context.VisibleAlias.Options -band [System.Management.Automation.ScopedItemOptions]::Private) -eq 0 -and
                        $__PshProjection_baf0d32a_Context.VisibleAlias.Visibility -eq [System.Management.Automation.SessionStateEntryVisibility]::Public) {
                        $__PshProjection_baf0d32a_Context.State.ProjectedAliases[$__PshProjection_baf0d32a_Context.CurrentName] = [PSCustomObject]@{
                            KnownDefinitions = @($__PshProjection_baf0d32a_Context.KnownAliases[$__PshProjection_baf0d32a_Context.CurrentName])
                        }
                    }
                }
            }
        }
    }

    if ($__PshProjection_baf0d32a_Context.State.ProjectedAliases.Count -gt 0) {
        $__PshProjection_baf0d32a_Context.ActiveScopes = @()
        $__PshProjection_baf0d32a_Context.ScopeNumber = 1
        while ($true) {
            try {
                Get-Variable -Name null -Scope $__PshProjection_baf0d32a_Context.ScopeNumber -ErrorAction Stop | Out-Null
            }
            catch {
                break
            }
            $__PshProjection_baf0d32a_Context.ActiveScopes += [PSCustomObject]@{
                Number = [int]$__PshProjection_baf0d32a_Context.ScopeNumber
                IsImporting = ($__PshProjection_baf0d32a_Context.ScopeNumber -eq 1)
                IsGlobal = $false
                Token = $null
                Aliases = [ordered]@{}
            }
            $__PshProjection_baf0d32a_Context.ScopeNumber++
        }
        if ($__PshProjection_baf0d32a_Context.ActiveScopes.Count -eq 0) {
            throw 'Psh cannot locate the caller scope for file-command projection.'
        }
        $__PshProjection_baf0d32a_Context.ActiveScopes[$__PshProjection_baf0d32a_Context.ActiveScopes.Count - 1].IsGlobal = $true

        @($__PshProjection_baf0d32a_Context.ActiveScopes) | ForEach-Object {
            if ($null -ne (Get-Variable -Name $__PshProjection_baf0d32a_Context.State.ScopeMarkerName -Scope $_.Number -ErrorAction SilentlyContinue)) {
                throw ('Psh cannot project file commands because caller scope {0} already contains variable ${1}.' -f $_.Number, $__PshProjection_baf0d32a_Context.State.ScopeMarkerName)
            }
        }

        @($__PshProjection_baf0d32a_Context.State.ProjectedAliases.Keys) | ForEach-Object {
            $__PshProjection_baf0d32a_Context.CurrentName = [string]$_
            $__PshProjection_baf0d32a_Context.Valid = $true
            @($__PshProjection_baf0d32a_Context.ActiveScopes) | ForEach-Object {
                $__PshProjection_baf0d32a_Context.ScopeAlias = Get-Alias -Name $__PshProjection_baf0d32a_Context.CurrentName -Scope $_.Number -ErrorAction SilentlyContinue
                if ($null -ne $__PshProjection_baf0d32a_Context.ScopeAlias) {
                    if (($__PshProjection_baf0d32a_Context.ScopeAlias.Options -band [System.Management.Automation.ScopedItemOptions]::Private) -ne 0 -or
                        $__PshProjection_baf0d32a_Context.ScopeAlias.Visibility -ne [System.Management.Automation.SessionStateEntryVisibility]::Public) {
                        $__PshProjection_baf0d32a_Context.Valid = $false
                    }
                    $__PshProjection_baf0d32a_Context.Known = $false
                    @($__PshProjection_baf0d32a_Context.State.ProjectedAliases[$__PshProjection_baf0d32a_Context.CurrentName].KnownDefinitions) | ForEach-Object {
                        if ([string]::Equals([string]$__PshProjection_baf0d32a_Context.ScopeAlias.Definition, [string]$_, [StringComparison]::OrdinalIgnoreCase)) {
                            $__PshProjection_baf0d32a_Context.Known = $true
                        }
                    }
                    if (-not $__PshProjection_baf0d32a_Context.Known) {
                        $__PshProjection_baf0d32a_Context.Valid = $false
                    }
                }
            }
            if (-not $__PshProjection_baf0d32a_Context.Valid) {
                $__PshProjection_baf0d32a_Context.State.ProjectedAliases.Remove($__PshProjection_baf0d32a_Context.CurrentName)
            }
        }

        @($__PshProjection_baf0d32a_Context.State.ProjectedAliases.Keys) | ForEach-Object {
            $__PshProjection_baf0d32a_Context.CurrentName = [string]$_
            @($__PshProjection_baf0d32a_Context.ActiveScopes) | ForEach-Object {
                $__PshProjection_baf0d32a_Context.ScopeAlias = Get-Alias -Name $__PshProjection_baf0d32a_Context.CurrentName -Scope $_.Number -ErrorAction SilentlyContinue
                if ($null -ne $__PshProjection_baf0d32a_Context.ScopeAlias -and
                    ($__PshProjection_baf0d32a_Context.ScopeAlias.Options -band [System.Management.Automation.ScopedItemOptions]::Private) -eq 0 -and
                    $__PshProjection_baf0d32a_Context.ScopeAlias.Visibility -eq [System.Management.Automation.SessionStateEntryVisibility]::Public) {
                    $_.Aliases[$__PshProjection_baf0d32a_Context.CurrentName] = [PSCustomObject]@{
                        Definition = [string]$__PshProjection_baf0d32a_Context.ScopeAlias.Definition
                        Description = [string]$__PshProjection_baf0d32a_Context.ScopeAlias.Description
                        Options = [System.Management.Automation.ScopedItemOptions]$__PshProjection_baf0d32a_Context.ScopeAlias.Options
                        Visibility = [System.Management.Automation.SessionStateEntryVisibility]$__PshProjection_baf0d32a_Context.ScopeAlias.Visibility
                    }
                }
            }
        }

        @($__PshProjection_baf0d32a_Context.ActiveScopes) | ForEach-Object {
            $_.Token = [Guid]::NewGuid().ToString('N')
            $__PshProjection_baf0d32a_Context.ScopeState = [PSCustomObject]@{
                Token = [string]$_.Token
                MarkerDescription = ('Psh file-command projection scope {0}' -f [string]$_.Token)
                IsImporting = [bool]$_.IsImporting
                IsGlobal = [bool]$_.IsGlobal
                Aliases = $_.Aliases
            }
            $__PshProjection_baf0d32a_Context.State.ScopeStates += $__PshProjection_baf0d32a_Context.ScopeState
            $__PshProjection_baf0d32a_Context.State.ScopeStateByToken[[string]$_.Token] = $__PshProjection_baf0d32a_Context.ScopeState
            if ($_.IsGlobal) {
                $__PshProjection_baf0d32a_Context.State.GlobalScopeToken = [string]$_.Token
            }
        }
    }

    try {
        if ($__PshProjection_baf0d32a_Context.State.ScopeStates.Count -gt 0) {
            @($__PshProjection_baf0d32a_Context.ActiveScopes) | ForEach-Object {
                $__PshProjection_baf0d32a_Context.ScopeState = $__PshProjection_baf0d32a_Context.State.ScopeStateByToken[[string]$_.Token]
                Set-Variable -Name $__PshProjection_baf0d32a_Context.State.ScopeMarkerName `
                    -Value ([PSCustomObject]@{ Token = [string]$_.Token }) `
                    -Description ([string]$__PshProjection_baf0d32a_Context.ScopeState.MarkerDescription) `
                    -Option None `
                    -Scope $_.Number `
                    -Force `
                    -ErrorAction Stop
            }
        }
        Set-Variable -Name $__PshProjection_baf0d32a_Context.HandoffName -Value $__PshProjection_baf0d32a_Context.State -Scope Global -Force -ErrorAction Stop
    }
    catch {
        if ($__PshProjection_baf0d32a_Context.State.ScopeStates.Count -gt 0) {
            . $__PshProjection_baf0d32a_Context.State.Restore $__PshProjection_baf0d32a_Context.State
        }
        Remove-Variable -Name $__PshProjection_baf0d32a_Context.HandoffName -Scope Global -Force -ErrorAction SilentlyContinue
        throw
    }
}

try {
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('pwd')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'pwd' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('cd')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'cd' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('ls')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'ls' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('rmdir')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'rmdir' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('cp')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'cp' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('mv')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'mv' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('rm')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'rm' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('cat')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'cat' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('sort')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'sort' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('tee')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'tee' }
    if ((Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.ProjectedAliases.Contains('echo')) { . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Peel (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value 'echo' }
}
catch {
    . (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value.Restore (Get-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -ErrorAction Stop).Value
    Remove-Variable -Name '__PshFileCommandProjection_baf0d32a' -Scope Global -Force -ErrorAction SilentlyContinue
    throw
}
