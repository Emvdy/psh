# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string] $SourceCommit,
    [Parameter(Mandatory = $true)][string] $OnlineInstallerPath,
    [Parameter(Mandatory = $true)][string] $OfflineInstallerPath,
    [Parameter(Mandatory = $true)][string] $ShellInstallerPath,
    [Parameter(Mandatory = $true)][string] $UninstallerPath,
    [Parameter(Mandatory = $true)][string] $BootstrapperPath,
    [Parameter(Mandatory = $true)][string] $ReleaseNotesPath,
    [Parameter(Mandatory = $true)][string] $ReleaseNotesZhCnPath,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $IncludeTestFixtures,
    [switch] $Finalize,
    [AllowNull()][string] $PackageCatalogRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$lifecyclePath = Join-Path $RepositoryRoot 'src/install/PackageLifecycle.ps1'
if (-not [IO.File]::Exists($lifecyclePath)) { throw "Package lifecycle helpers were not found: $lifecyclePath" }
. $lifecyclePath

function Throw-PshPackageBuildError {
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $ErrorId,
        [Parameter(Mandatory = $true)][string] $Message,
        [AllowNull()][Exception] $InnerException
    )

    $exception = if ($null -eq $InnerException) { New-Object System.Exception($Message) } else { New-Object System.Exception($Message, $InnerException) }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorId'] = $ErrorId
    throw $exception
}

function Get-PshBuildHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [string](Get-PshLifecycleFileSha256 -Path $Path).Sha256
}

function Resolve-PshBuildInputFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsRegularFile -or [bool]$entry.IsReparsePoint) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildInputMissing' -Message "$Description must be an existing regular non-reparse file: $full"
    }
    return $full
}

function Resolve-PshBuildInputDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    try { $full = Assert-PshLifecycleNoReparseAncestors -Path $Path -Description $Description }
    catch { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildInputPath' -Message "$Description path is unsafe: $Path" -InnerException $_.Exception }
    $entry = Get-PshLifecyclePathEntry -Path $full -Description $Description
    if (-not [bool]$entry.Exists -or -not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildInputMissing' -Message "$Description must be an existing non-reparse directory: $full"
    }
    return $full
}

function New-PshBuildDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)

    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildOutputExists' -Message "$Description already exists and will not be overwritten: $Path"
    }
    try { [void][IO.Directory]::CreateDirectory($Path) }
    catch { Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildCreateDirectory' -Message "Unable to create ${Description}: $Path" -InnerException $_.Exception }
}

function Copy-PshBuildFile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $Source = Resolve-PshBuildInputFile -Path $Source -Description $Description
    if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDestinationExists' -Message "$Description destination already exists: $Destination"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    try { [IO.File]::Copy($Source, $Destination, $false) }
    catch { Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildCopy' -Message "Unable to copy ${Description}: $Source" -InnerException $_.Exception }
}

function Get-PshBuildRelativePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Path)

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($prefix, (Get-PshLifecyclePathComparison))) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildContainment' -Message "Path escapes its expected root: $pathFull"
    }
    return $pathFull.Substring($prefix.Length).Replace('\', '/')
}

function Copy-PshBuildTree {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [string[]] $ExcludedPrefixes = @()
    )

    $Source = Resolve-PshBuildInputDirectory -Path $Source -Description 'source tree'
    if (-not [IO.Directory]::Exists($Destination)) { [void][IO.Directory]::CreateDirectory($Destination) }
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Recurse -Force | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildReparse' -Message "Source tree contains a reparse point: $($item.FullName)"
        }
        $relative = Get-PshBuildRelativePath -Root $Source -Path $item.FullName
        $excluded = $false
        foreach ($prefix in $ExcludedPrefixes) {
            if ([string]::Equals($relative, $prefix, [StringComparison]::OrdinalIgnoreCase) -or
                $relative.StartsWith($prefix + '/', [StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        $target = Join-Path $Destination $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ($item.PSIsContainer) {
            if (-not [IO.Directory]::Exists($target)) { [void][IO.Directory]::CreateDirectory($target) }
        }
        else { Copy-PshBuildFile -Source $item.FullName -Destination $target -Description "source file '$relative'" }
    }
}

function Write-PshBuildText {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDestinationExists' -Message "Build output already exists: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Read-PshBuildUtf8TextSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $Path = Resolve-PshBuildInputFile -Path $Path -Description $Description
    try { $bytes = [IO.File]::ReadAllBytes($Path) }
    catch { Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildTextRead' -Message "Unable to read ${Description}: $Path" -InnerException $_.Exception }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildTextBom' -Message "$Description must be UTF-8 without a BOM: $Path"
    }
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildTextEncoding' -Message "$Description is not valid UTF-8: $Path" -InnerException $_.Exception }
    return [pscustomobject][ordered]@{
        Path = $Path
        Bytes = $bytes
        Text = $text
        Length = [int64]$bytes.Length
        Sha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes
    }
}

function Assert-PshBuildNoDynamicExecution {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $forbiddenCommands = @($Ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                $name = [string]$node.GetCommandName()
                if ($name -ieq 'Invoke-Expression' -or $name -ieq 'iex') { return $true }
                if ($name -ieq 'Add-Type') {
                    return [string]$node.Extent.Text -notmatch '(?i)\A\s*Add-Type\s+-AssemblyName\s+System\.IO\.Compression(?:\.FileSystem)?(?:\s|$)'
                }
                return $false
            }, $true))
    if ($forbiddenCommands.Count -ne 0 -or $Text -match '(?i)\[\s*scriptblock\s*\]\s*::\s*create\s*\(' -or
        $Text -match '(?i)\bAdd-Type\s+(?:-TypeDefinition|-MemberDefinition|-Path)\b') {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDynamicExecution' -Message "$Description contains a forbidden dynamic execution surface."
    }
}

function Assert-PshBuildHelperLibrary {
    param(
        [Parameter(Mandatory = $true)][object] $Snapshot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Snapshot.Text, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) {
        $message = (@($parseErrors | ForEach-Object { $_.Message }) -join '; ')
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperParse' -Message "Embedded helper '$RelativePath' has parser errors: $message"
    }
    if ($null -ne $ast.ParamBlock) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperParam' -Message "Embedded helper '$RelativePath' must be a library without a top-level param block."
    }
    if (@($ast.UsingStatements).Count -ne 0) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperUsing' -Message "Embedded helper '$RelativePath' must not contain top-level using statements because it is embedded after the installer param block."
    }
    Assert-PshBuildNoDynamicExecution -Ast $ast -Text ([string]$Snapshot.Text) -Description "embedded helper '$RelativePath'"

    $functionCount = 0
    foreach ($statement in @($ast.EndBlock.Statements)) {
        if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $functionCount++
            continue
        }
        if ($statement -is [System.Management.Automation.Language.PipelineAst]) {
            $commands = @($statement.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            if ($commands.Count -eq 1 -and [string]$commands[0].GetCommandName() -ceq 'Set-StrictMode' -and
                [string]$statement.Extent.Text -cmatch '\ASet-StrictMode\s+-Version\s+2\.0\z') { continue }
        }
        elseif ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $left = $statement.Left
            $variableName = if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { [string]$left.VariablePath.UserPath } else { '' }
            $commands = @($statement.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            $memberCalls = @($statement.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
            if (($variableName -ceq 'ErrorActionPreference' -or $variableName -cmatch '\Ascript:Psh[A-Za-z0-9]+\z') -and
                $commands.Count -eq 0 -and $memberCalls.Count -eq 0) { continue }
        }
        elseif ($statement -is [System.Management.Automation.Language.IfStatementAst]) {
            $commands = @($statement.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            $unsafeCommand = @($commands | Where-Object {
                    $name = [string]$_.GetCommandName()
                    if ($_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
                        return $_.CommandElements.Count -ne 1 -or $_.CommandElements[0] -isnot [System.Management.Automation.Language.VariableExpressionAst]
                    }
                    if ($name -cin @('Get-Command', 'Get-Variable', 'Join-Path')) { return $false }
                    if ($name -ceq 'New-Object') {
                        return [string]$_.Extent.Text -cnotmatch "\ANew-Object (?:object|'System\.Runtime\.CompilerServices\.ConditionalWeakTable\[object,object\]')\z"
                    }
                    return $true
                })
            $memberCalls = @($statement.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
            $unsafeMember = @($memberCalls | Where-Object { $_.Extent.Text -cnotmatch '\A\[IO\.File\]::Exists\(\$[A-Za-z][A-Za-z0-9]*\)\z' })
            $hasGuard = @($commands | Where-Object { [string]$_.GetCommandName() -cin @('Get-Command', 'Get-Variable') }).Count -eq 1
            if ($hasGuard -and $unsafeCommand.Count -eq 0 -and $unsafeMember.Count -eq 0) { continue }
        }
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperSideEffect' -Message "Embedded helper '$RelativePath' contains a non-library top-level statement: $($statement.Extent.Text)"
    }
    if ($functionCount -eq 0) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperFunctions' -Message "Embedded helper '$RelativePath' contains no functions."
    }
}

function New-PshBuildEmbeddedInstaller {
    param(
        [Parameter(Mandatory = $true)][string] $TemplatePath,
        [Parameter(Mandatory = $true)][string] $Repository
    )

    $template = Read-PshBuildUtf8TextSnapshot -Path $TemplatePath -Description 'online installer template'
    $beginMarker = '# PSH_EMBED_HELPERS_BEGIN'
    $endMarker = '# PSH_EMBED_HELPERS_END'
    $beginMatches = @([regex]::Matches([string]$template.Text, '(?m)^# PSH_EMBED_HELPERS_BEGIN\r?$'))
    $endMatches = @([regex]::Matches([string]$template.Text, '(?m)^# PSH_EMBED_HELPERS_END\r?$'))
    if ($beginMatches.Count -ne 1 -or $endMatches.Count -ne 1 -or $beginMatches[0].Index -ge $endMatches[0].Index) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperMarkers' -Message "Online installer must contain exactly one ordered '$beginMarker' / '$endMarker' marker pair."
    }
    $contentStart = $beginMatches[0].Index + $beginMatches[0].Length
    if ($contentStart -ge ([string]$template.Text).Length -or ([string]$template.Text)[$contentStart] -cne "`n") {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperMarkers' -Message "The '$beginMarker' line must end before embedded helper content."
    }
    $contentStart++
    $contentEnd = $endMatches[0].Index
    if ($contentEnd -lt $contentStart) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperMarkers' -Message 'Online installer helper markers overlap.'
    }

    $helperRecords = New-Object System.Collections.Generic.List[object]
    $embeddedText = New-Object Text.StringBuilder
    foreach ($relativePath in @(
            'src/install/PackageLifecycle.ps1',
            'src/install/ReleaseTrust.ps1',
            'src/install/PackageAcquisition.ps1'
        )) {
        $snapshot = Read-PshBuildUtf8TextSnapshot -Path (Join-Path $Repository $relativePath) -Description "embedded helper '$relativePath'"
        Assert-PshBuildHelperLibrary -Snapshot $snapshot -RelativePath $relativePath
        if (-not ([string]$snapshot.Text).EndsWith("`n", [StringComparison]::Ordinal)) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperNewline' -Message "Embedded helper '$relativePath' must end with LF so adjacent original sources cannot merge."
        }
        [void]$embeddedText.Append([string]$snapshot.Text)
        $helperRecords.Add([pscustomobject][ordered]@{
                relativePath = $relativePath
                length = [int64]$snapshot.Length
                sha256 = [string]$snapshot.Sha256
            })
    }
    $templateText = [string]$template.Text
    $finalText = $templateText.Substring(0, $contentStart) + $embeddedText.ToString() + $templateText.Substring($contentEnd)
    $tokens = $null
    $parseErrors = $null
    $finalAst = [System.Management.Automation.Language.Parser]::ParseInput($finalText, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) {
        $message = (@($parseErrors | ForEach-Object { $_.Message }) -join '; ')
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildInstallerParse' -Message "Embedded online installer has parser errors: $message"
    }
    if (@([regex]::Matches($finalText, '(?m)^# PSH_EMBED_HELPERS_BEGIN\r?$')).Count -ne 1 -or
        @([regex]::Matches($finalText, '(?m)^# PSH_EMBED_HELPERS_END\r?$')).Count -ne 1) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildHelperMarkers' -Message 'Embedded online installer did not preserve exactly one marker pair.'
    }
    Assert-PshBuildNoDynamicExecution -Ast $finalAst -Text $finalText -Description 'embedded online installer'
    $finalBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($finalText)
    return [pscustomobject][ordered]@{
        Text = $finalText
        Sha256 = Get-PshLifecycleSha256Bytes -Bytes $finalBytes
        Length = [int64]$finalBytes.Length
        TemplateSha256 = [string]$template.Sha256
        TemplateLength = [int64]$template.Length
        HelperSources = $helperRecords.ToArray()
    }
}

function Get-PshBuildPeMachine {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
    try {
        if ($stream.Length -lt 0x40) { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildPe' -Message "Native tool is too short to be a PE file: $Path" }
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildPe' -Message "Native tool has no MZ header: $Path" }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            if ($peOffset -lt 0 -or [int64]$peOffset + 6 -gt $stream.Length) { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildPe' -Message "Native tool has an invalid PE header offset: $Path" }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildPe' -Message "Native tool has no PE signature: $Path" }
            return ('0x{0:X4}' -f $reader.ReadUInt16())
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Read-PshBuildNativeLock {
    param([Parameter(Mandatory = $true)][string] $Path)

    $Path = Resolve-PshBuildInputFile -Path $Path -Description 'native tools lock'
    $snapshot = Read-PshStrictJsonSnapshot -Path $Path -Description 'native tools lock'
    $lock = $snapshot.Document
    $topKeys = @('schemaVersion', 'manifest', 'toolRoot', 'tools')
    Assert-PshLifecycleAllowedProperties -InputObject $lock -Allowed $topKeys -Description 'native tools lock'
    Assert-PshLifecycleRequiredProperties -InputObject $lock -Required $topKeys -Description 'native tools lock'
    if ([int64](Assert-PshLifecycleInteger -Value $lock.schemaVersion -Description 'native tools lock schemaVersion' -NonNegative) -ne 1 -or
        [string]$lock.toolRoot -cne 'tools') {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message 'Native tools lock must use schemaVersion 1 and toolRoot tools.'
    }
    Assert-PshLifecycleAllowedProperties -InputObject $lock.manifest -Allowed @('created', 'namespaceSeed') -Description 'native tools lock manifest'
    Assert-PshLifecycleRequiredProperties -InputObject $lock.manifest -Required @('created', 'namespaceSeed') -Description 'native tools lock manifest'
    $created = if ($lock.manifest.created -is [DateTimeOffset]) {
        ([DateTimeOffset]$lock.manifest.created).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($lock.manifest.created -is [DateTime]) {
        ([DateTime]$lock.manifest.created).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    else { [string]$lock.manifest.created }
    if ($created -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z' -or
        [string]::IsNullOrWhiteSpace([string]$lock.manifest.namespaceSeed)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message 'Native tools lock manifest metadata is invalid.'
    }
    if ($lock.tools -isnot [System.Array]) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message 'Native tools lock tools value must be an array.'
    }
    $toolNames = @($lock.tools | ForEach-Object { [string]$_.name })
    if (($toolNames -join '|') -cne 'bat|fd|jq|rg') {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message 'Native tools lock must contain exactly bat, fd, jq, rg in ordinal order.'
    }
    $toolKeys = @('name', 'upstreamName', 'version', 'source', 'license', 'licenseNotes', 'versionProbe', 'artifacts')
    $requiredToolKeys = @('name', 'upstreamName', 'version', 'source', 'license', 'versionProbe', 'artifacts')
    $artifactKeys = @(
        'state', 'architecture', 'targetTriple', 'assetId', 'apiUrl', 'browserUrl', 'assetName',
        'archiveType', 'archiveSha256', 'executableArchivePath', 'installedPath', 'installedSha256', 'peMachine'
    )
    foreach ($tool in @($lock.tools)) {
        $name = [string]$tool.name
        Assert-PshLifecycleAllowedProperties -InputObject $tool -Allowed $toolKeys -Description "native tool '$name'"
        Assert-PshLifecycleRequiredProperties -InputObject $tool -Required $requiredToolKeys -Description "native tool '$name'"
        Assert-PshLifecycleAllowedProperties -InputObject $tool.artifacts -Allowed @('win-x64', 'win-arm64') -Description "native tool '$name' artifacts"
        Assert-PshLifecycleRequiredProperties -InputObject $tool.artifacts -Required @('win-x64', 'win-arm64') -Description "native tool '$name' artifacts"
        foreach ($rid in @('win-x64', 'win-arm64')) {
            $artifact = $tool.artifacts.$rid
            Assert-PshLifecycleAllowedProperties -InputObject $artifact -Allowed $artifactKeys -Description "native tool '$name/$rid' artifact"
            Assert-PshLifecycleRequiredProperties -InputObject $artifact -Required $artifactKeys -Description "native tool '$name/$rid' artifact"
            $expectedArchitecture = if ($rid -ceq 'win-x64') { 'x86_64' } else { 'aarch64' }
            $expectedMachine = if ($rid -ceq 'win-x64') { '0x8664' } else { '0xAA64' }
            $expectedPath = "$rid/$name/$name.exe"
            if ([string]$artifact.state -cne 'pinned' -or [string]$artifact.architecture -cne $expectedArchitecture -or
                [string]$artifact.peMachine -cne $expectedMachine -or [string]$artifact.installedPath -cne $expectedPath) {
                Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message "Native tool '$name/$rid' does not match its fixed architecture slot."
            }
            [void](Assert-PshLifecycleSha256 -Value $artifact.archiveSha256 -Description "native tool '$name/$rid' archive SHA256")
            [void](Assert-PshLifecycleSha256 -Value $artifact.installedSha256 -Description "native tool '$name/$rid' installed SHA256")
            if ([int64](Assert-PshLifecycleInteger -Value $artifact.assetId -Description "native tool '$name/$rid' assetId" -NonNegative) -le 0) {
                Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message "Native tool '$name/$rid' has an invalid assetId."
            }
        }
    }
    return $lock
}

function Add-PshBuildNativeTools {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter(Mandatory = $true)][string] $Repository
    )

    $lockSource = Resolve-PshBuildInputFile -Path (Join-Path $Repository 'tools/native-tools.lock.json') -Description 'native tools lock'
    $lock = Read-PshBuildNativeLock -Path $lockSource
    $toolsRoot = Join-Path $PackageRoot 'payload/Psh/Tools'
    [void][IO.Directory]::CreateDirectory($toolsRoot)
    $lockTarget = Join-Path $toolsRoot 'native-tools.lock.json'
    Copy-PshBuildFile -Source $lockSource -Destination $lockTarget -Description 'native tools lock'
    foreach ($tool in @($lock.tools)) {
        $artifact = $tool.artifacts.$Architecture
        if ($null -eq $artifact -or [string]$artifact.state -cne 'pinned') {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeLock' -Message "Native tool '$($tool.name)' has no pinned $Architecture artifact."
        }
        $relative = [string]$artifact.installedPath
        if (-not $relative.StartsWith($Architecture + '/', [StringComparison]::Ordinal) -or $relative -match '(^|/)\.\.(/|$)') {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativePath' -Message "Native tool '$($tool.name)' has an unsafe or wrong-architecture installedPath."
        }
        $source = Resolve-PshBuildInputFile -Path (Join-Path (Join-Path $Repository 'tools') $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Description "native tool '$($tool.name)'"
        if ((Get-PshBuildHash -Path $source) -cne [string]$artifact.installedSha256) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeHash' -Message "Native tool '$($tool.name)' SHA256 does not match its lock."
        }
        $expectedMachine = if ($Architecture -ceq 'win-x64') { '0x8664' } else { '0xAA64' }
        if ([string]$artifact.peMachine -cne $expectedMachine -or (Get-PshBuildPeMachine -Path $source) -cne $expectedMachine) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildNativeArchitecture' -Message "Native tool '$($tool.name)' PE machine does not match $Architecture."
        }
        Copy-PshBuildFile -Source $source -Destination (Join-Path $toolsRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Description "native tool '$($tool.name)'"
    }
    return Get-PshBuildHash -Path $lockTarget
}

function Get-PshBuildFileRole {
    param([Parameter(Mandatory = $true)][string] $RelativePath)

    if ($RelativePath -ceq 'psh-installer.exe') { return 'bootstrapper' }
    if ($RelativePath -in @('install.ps1', 'install-offline.ps1', 'install.sh', 'uninstall.ps1')) { return 'entrypoint' }
    if ($RelativePath -ceq 'LICENSE' -or $RelativePath.StartsWith('licenses/', [StringComparison]::Ordinal)) { return 'license' }
    if ($RelativePath -ceq 'THIRD_PARTY_NOTICES.md') { return 'notice' }
    if ($RelativePath -ceq 'sbom.spdx.json') { return 'sbom' }
    if ($RelativePath.StartsWith('payload/', [StringComparison]::Ordinal)) { return 'payload' }
    return 'metadata'
}

function New-PshBuildManifest {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $PackageVersion,
        [Parameter(Mandatory = $true)][string] $Edition,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter(Mandatory = $true)][bool] $TestOnly,
        [Parameter(Mandatory = $true)][string] $Commit,
        [AllowNull()][string] $NativeToolsLockSha256
    )

    $fileByRelativePath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $seenRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File)) {
        $relative = Get-PshBuildRelativePath -Root $PackageRoot -Path $file.FullName
        if ($relative -ceq 'package.manifest.json' -or $relative -ceq 'package.manifest.cat') { continue }
        if (-not $seenRelativePaths.Add($relative)) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDuplicatePath' -Message "Package contains a case-insensitive duplicate path: $relative"
        }
        $fileByRelativePath[$relative] = $file
    }
    [string[]]$relativePaths = @($fileByRelativePath.Keys)
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $relativePaths) {
        $file = $fileByRelativePath[$relative]
        $files.Add([pscustomobject][ordered]@{
                relativePath = $relative
                length = [int64]$file.Length
                sha256 = Get-PshBuildHash -Path $file.FullName
                role = Get-PshBuildFileRole -RelativePath $relative
            })
    }
    $treeSha256 = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $files.ToArray() })
    $bootstrapperSha256 = Get-PshBuildHash -Path (Join-Path $PackageRoot 'psh-installer.exe')
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        version = $PackageVersion
        edition = $Edition
        architecture = $Architecture
        payloadRoot = 'payload'
        files = $files.ToArray()
        treeSha256 = $treeSha256
        entrypoints = [pscustomobject][ordered]@{
            offlinePowerShell = 'install-offline.ps1'
            uninstallPowerShell = 'uninstall.ps1'
            shell = 'install.sh'
            bootstrapper = 'psh-installer.exe'
        }
        testOnly = $TestOnly
        source = [pscustomobject][ordered]@{ repository = 'https://github.com/Emvdy/psh'; commit = $Commit }
        bootstrapper = [pscustomobject][ordered]@{ relativePath = 'psh-installer.exe'; sha256 = $bootstrapperSha256; anyCpu = $true }
        nativeToolsLockSha256 = if ([string]::IsNullOrWhiteSpace($NativeToolsLockSha256)) { $null } else { $NativeToolsLockSha256 }
    }
}

function New-PshBuildZip {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ([IO.File]::Exists($Destination) -or [IO.Directory]::Exists($Destination)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildArchiveExists' -Message "Package archive already exists: $Destination"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination))
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $stream = New-Object IO.FileStream($Destination, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None))
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true, (New-Object Text.UTF8Encoding($false)))
        try {
            $entries = New-Object System.Collections.Generic.List[object]
            $seenEntries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($file in @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File)) {
                $name = Get-PshBuildRelativePath -Root $PackageRoot -Path $file.FullName
                if (-not $seenEntries.Add($name)) {
                    Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDuplicatePath' -Message "Package archive contains a case-insensitive duplicate path: $name"
                }
                $entries.Add([pscustomobject]@{ Name = $name; Path = $file.FullName })
            }
            if (-not $seenEntries.Add('package.manifest.cat')) {
                Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildDuplicatePath' -Message 'Package staging unexpectedly contains package.manifest.cat.'
            }
            $entries.Add([pscustomobject]@{ Name = 'package.manifest.cat'; Path = $CatalogPath })
            $entryByName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
            foreach ($item in @($entries.ToArray())) { $entryByName[[string]$item.Name] = $item }
            [string[]]$entryNames = @($entryByName.Keys)
            [Array]::Sort($entryNames, [StringComparer]::Ordinal)
            foreach ($entryName in $entryNames) {
                $item = $entryByName[$entryName]
                $entry = $archive.CreateEntry([string]$item.Name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = New-Object DateTimeOffset(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entry.ExternalAttributes = 0
                $entryStream = $entry.Open()
                $sourceStream = New-Object IO.FileStream([string]$item.Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
                try { $sourceStream.CopyTo($entryStream) }
                finally { $sourceStream.Dispose(); $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    catch {
        if ([IO.File]::Exists($Destination)) { try { [IO.File]::Delete($Destination) } catch { } }
        Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildArchive' -Message "Unable to create package archive: $Destination" -InnerException $_.Exception
    }
    finally { $stream.Dispose() }
}

function Invoke-PshBuildCatalogVerificationCleanup {
    param([Parameter(Mandatory = $true)][string] $Path)

    $entry = Get-PshLifecyclePathEntry -Path $Path -Description 'package catalog verification root'
    if (-not [bool]$entry.Exists) { return }
    if (-not [bool]$entry.IsDirectory -or [bool]$entry.IsReparsePoint) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogCleanupUnsafe' -Message "Package catalog verification root changed to an unsafe entry: $Path"
    }
    try { $children = @(Get-ChildItem -LiteralPath $Path -Force) }
    catch { Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildCatalogCleanupInspect' -Message "Unable to inspect package catalog verification root: $Path" -InnerException $_.Exception }
    foreach ($child in $children) {
        if ($child.PSIsContainer -or (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or [string]$child.Name -cne 'package.manifest.json') {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogCleanupUnsafe' -Message "Package catalog verification root contains an unexpected entry: $($child.FullName)"
        }
    }
    try {
        $manifestCopy = Join-Path $Path 'package.manifest.json'
        if ([IO.File]::Exists($manifestCopy)) { [IO.File]::Delete($manifestCopy) }
        [IO.Directory]::Delete($Path, $false)
    }
    catch { Throw-PshPackageBuildError -ExitCode 3 -ErrorId 'PshPackageBuildCatalogCleanup' -Message "Unable to remove package catalog verification root: $Path" -InnerException $_.Exception }
}

function Confirm-PshBuildPackageCatalogMembership {
    param(
        [Parameter(Mandatory = $true)][object] $CatalogCommand,
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $PackageName
    )

    $CatalogPath = Resolve-PshBuildInputFile -Path $CatalogPath -Description "package catalog '$PackageName'"
    if (([IO.FileInfo]$CatalogPath).Length -le 0) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogEmpty' -Message "Package catalog is empty: $CatalogPath"
    }
    $ManifestPath = Resolve-PshBuildInputFile -Path $ManifestPath -Description "package manifest '$PackageName'"
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-package-catalog-' + [Guid]::NewGuid().ToString('N'))
    $temporaryRoot = Assert-PshLifecycleNoReparseAncestors -Path $temporaryRoot -Description 'package catalog verification root'
    if ([IO.File]::Exists($temporaryRoot) -or [IO.Directory]::Exists($temporaryRoot)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogVerificationRoot' -Message "Package catalog verification root already exists: $temporaryRoot"
    }
    try {
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $rootEntry = Get-PshLifecyclePathEntry -Path $temporaryRoot -Description 'package catalog verification root'
        if (-not [bool]$rootEntry.IsDirectory -or [bool]$rootEntry.IsReparsePoint) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogVerificationRoot' -Message "Package catalog verification root is unsafe: $temporaryRoot"
        }
        $manifestCopy = Join-Path $temporaryRoot 'package.manifest.json'
        [IO.File]::Copy($ManifestPath, $manifestCopy, $false)
        try { $validationResults = @(& $CatalogCommand -CatalogFilePath $CatalogPath -Path $temporaryRoot -Detailed -ErrorAction Stop) }
        catch { Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogMembership' -Message "Package catalog membership verification failed for '$PackageName'." -InnerException $_.Exception }
        $statusResults = @($validationResults | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Status'] })
        if ($statusResults.Count -eq 1) { $validation = $statusResults[0] }
        elseif ($validationResults.Count -eq 1) { $validation = $validationResults[0] }
        else {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogMembership' -Message "Package catalog membership verification returned an ambiguous result set for '$PackageName' (raw=$($validationResults.Count), status=$($statusResults.Count))."
        }
        $status = if ($null -ne $validation -and $null -ne $validation.PSObject.Properties['Status']) { [string]$validation.Status } else { [string]$validation }
        if ($status -cne 'ValidationPassed') {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCatalogMembership' -Message "Package catalog does not cover exactly package.manifest.json for '$PackageName': $status"
        }
    }
    finally { Invoke-PshBuildCatalogVerificationCleanup -Path $temporaryRoot }
    return $CatalogPath
}

$RepositoryRoot = Resolve-PshBuildInputDirectory -Path $RepositoryRoot -Description 'repository root'
$Version = Assert-PshLifecycleSemVer -Value $Version -Description 'package version'
if ($Version -ceq '0.0.1-test') {
    Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildPublicVersion' -Message 'The public package version must not be the synthetic 0.0.1-test version.'
}
$resolvedInputs = [ordered]@{
    OnlineInstaller = Resolve-PshBuildInputFile -Path $OnlineInstallerPath -Description 'online installer'
    OfflineInstaller = Resolve-PshBuildInputFile -Path $OfflineInstallerPath -Description 'offline installer'
    ShellInstaller = Resolve-PshBuildInputFile -Path $ShellInstallerPath -Description 'shell installer'
    Uninstaller = Resolve-PshBuildInputFile -Path $UninstallerPath -Description 'uninstaller'
    Bootstrapper = Resolve-PshBuildInputFile -Path $BootstrapperPath -Description 'AnyCPU bootstrapper'
    ReleaseNotes = Resolve-PshBuildInputFile -Path $ReleaseNotesPath -Description 'English release notes'
    ReleaseNotesZhCn = Resolve-PshBuildInputFile -Path $ReleaseNotesZhCnPath -Description 'Simplified Chinese release notes'
}
$packageCatalogRootResolved = $null
$fileCatalogCommand = $null
if ($Finalize) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildCatalogVerificationUnavailable' -Message 'Final package ZIP creation requires Windows Test-FileCatalog membership verification.'
    }
    $fileCatalogCommand = Get-Command -Name Test-FileCatalog -CommandType Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $fileCatalogCommand) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildCatalogVerificationUnavailable' -Message 'Test-FileCatalog is unavailable on this Windows runtime.'
    }
    if ([string]::IsNullOrWhiteSpace($PackageCatalogRoot)) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildCatalogRequired' -Message 'Final package ZIP creation requires PackageCatalogRoot with package manifest catalogs.'
    }
    $packageCatalogRootResolved = Resolve-PshBuildInputDirectory -Path $PackageCatalogRoot -Description 'package catalog root'
}
$embeddedInstaller = New-PshBuildEmbeddedInstaller -TemplatePath $resolvedInputs.OnlineInstaller -Repository $RepositoryRoot
$requiredRepositoryInputs = @(
    'src/Psh', 'src/install', 'src/profile', 'licenses', 'LICENSE',
    'THIRD_PARTY_NOTICES.md', 'sbom.spdx.json', 'tools/native-tools.lock.json'
)
foreach ($relative in $requiredRepositoryInputs) {
    $candidate = Join-Path $RepositoryRoot $relative
    if (-not [IO.File]::Exists($candidate) -and -not [IO.Directory]::Exists($candidate)) {
        Throw-PshPackageBuildError -ExitCode 4 -ErrorId 'PshPackageBuildRepositoryInput' -Message "Required repository input is missing: $relative"
    }
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
[void](Assert-PshLifecycleNoReparseAncestors -Path $OutputRoot -Description 'package build output root')
foreach ($relativeSourceRoot in @('src/Psh', 'src/install', 'src/profile', 'licenses', 'tools')) {
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativeSourceRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $outputNormalized = $OutputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = Get-PshLifecyclePathComparison
    if ([string]::Equals($sourceRoot, $outputNormalized, $comparison) -or
        $sourceRoot.StartsWith($outputNormalized + [IO.Path]::DirectorySeparatorChar, $comparison) -or
        $outputNormalized.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildOutputOverlap' -Message "Package build output overlaps source tree '$relativeSourceRoot': $OutputRoot"
    }
}
New-PshBuildDirectory -Path $OutputRoot -Description 'package build output root'
$preSignRoot = Join-Path $OutputRoot 'pre-sign'
$packagesRoot = Join-Path $OutputRoot 'packages'
[void][IO.Directory]::CreateDirectory($preSignRoot)
[void][IO.Directory]::CreateDirectory($packagesRoot)

$slots = New-Object System.Collections.Generic.List[object]
foreach ($slot in @(
        [pscustomobject]@{ Version = $Version; Edition = 'Core'; Architecture = 'any'; TestOnly = $false },
        [pscustomobject]@{ Version = $Version; Edition = 'Full'; Architecture = 'win-x64'; TestOnly = $false },
        [pscustomobject]@{ Version = $Version; Edition = 'Full'; Architecture = 'win-arm64'; TestOnly = $false }
    )) { $slots.Add($slot) }
if ($IncludeTestFixtures) {
    foreach ($slot in @(
            [pscustomobject]@{ Version = '0.0.1-test'; Edition = 'Core'; Architecture = 'any'; TestOnly = $true },
            [pscustomobject]@{ Version = '0.0.1-test'; Edition = 'Full'; Architecture = 'win-x64'; TestOnly = $true },
            [pscustomobject]@{ Version = '0.0.1-test'; Edition = 'Full'; Architecture = 'win-arm64'; TestOnly = $true }
        )) { $slots.Add($slot) }
}

$bootstrapperSha256 = Get-PshBuildHash -Path $resolvedInputs.Bootstrapper
$records = New-Object System.Collections.Generic.List[object]
foreach ($slot in @($slots.ToArray())) {
    $suffix = if ([string]$slot.Edition -ceq 'Core') { 'core' } else { 'full-' + [string]$slot.Architecture }
    $baseName = 'psh-{0}-{1}' -f [string]$slot.Version, $suffix
    $packageRoot = Join-Path $preSignRoot $baseName
    New-PshBuildDirectory -Path $packageRoot -Description "pre-sign package '$baseName'"

    Write-PshBuildText -Path (Join-Path $packageRoot 'install.ps1') -Text ([string]$embeddedInstaller.Text)
    Copy-PshBuildFile -Source $resolvedInputs.OfflineInstaller -Destination (Join-Path $packageRoot 'install-offline.ps1') -Description 'offline installer'
    Copy-PshBuildFile -Source $resolvedInputs.ShellInstaller -Destination (Join-Path $packageRoot 'install.sh') -Description 'shell installer'
    Copy-PshBuildFile -Source $resolvedInputs.Uninstaller -Destination (Join-Path $packageRoot 'uninstall.ps1') -Description 'uninstaller'
    Copy-PshBuildFile -Source $resolvedInputs.Bootstrapper -Destination (Join-Path $packageRoot 'psh-installer.exe') -Description 'AnyCPU bootstrapper'
    Copy-PshBuildFile -Source (Join-Path $RepositoryRoot 'LICENSE') -Destination (Join-Path $packageRoot 'LICENSE') -Description 'Psh license'
    Copy-PshBuildFile -Source (Join-Path $RepositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.md') -Description 'third-party notices'
    Copy-PshBuildFile -Source (Join-Path $RepositoryRoot 'sbom.spdx.json') -Destination (Join-Path $packageRoot 'sbom.spdx.json') -Description 'SPDX SBOM'
    Copy-PshBuildTree -Source (Join-Path $RepositoryRoot 'licenses') -Destination (Join-Path $packageRoot 'licenses')
    Copy-PshBuildTree -Source (Join-Path $RepositoryRoot 'src/Psh') -Destination (Join-Path $packageRoot 'payload/Psh') -ExcludedPrefixes @('Tools')
    Copy-PshBuildTree -Source (Join-Path $RepositoryRoot 'src/install') -Destination (Join-Path $packageRoot 'payload/install') -ExcludedPrefixes @('config.psd1')
    Copy-PshBuildTree -Source (Join-Path $RepositoryRoot 'src/profile') -Destination (Join-Path $packageRoot 'payload/profile')
    $configText = "@{`n    SchemaVersion = 1`n    Edition = '$($slot.Edition)'`n    DisabledCommands = @()`n}`n"
    Write-PshBuildText -Path (Join-Path $packageRoot 'payload/install/config.psd1') -Text $configText

    $nativeLockSha256 = $null
    if ([string]$slot.Edition -ceq 'Full') {
        $nativeLockSha256 = Add-PshBuildNativeTools -PackageRoot $packageRoot -Architecture ([string]$slot.Architecture) -Repository $RepositoryRoot
    }
    else {
        $coreToolsEntries = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'payload/Psh') -Recurse -Force | Where-Object {
                $relative = Get-PshBuildRelativePath -Root (Join-Path $packageRoot 'payload/Psh') -Path $_.FullName
                [string]::Equals($relative, 'Tools', [StringComparison]::OrdinalIgnoreCase) -or
                $relative.StartsWith('Tools/', [StringComparison]::OrdinalIgnoreCase)
            })
        if ($coreToolsEntries.Count -ne 0) {
            Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildCoreTools' -Message 'Core package unexpectedly contains a case-insensitive Tools path.'
        }
    }

    $manifest = New-PshBuildManifest -PackageRoot $packageRoot -PackageVersion ([string]$slot.Version) -Edition ([string]$slot.Edition) -Architecture ([string]$slot.Architecture) -TestOnly ([bool]$slot.TestOnly) -Commit $SourceCommit -NativeToolsLockSha256 $nativeLockSha256
    $manifestPath = Join-Path $packageRoot 'package.manifest.json'
    Write-PshBuildText -Path $manifestPath -Text ((ConvertTo-PshCanonicalJson -InputObject $manifest) + "`n")
    $snapshot = Read-PshStrictJsonSnapshot -Path $manifestPath -Description 'built package manifest'
    $validatedManifest = Read-PshPackageManifest -Path $manifestPath -Snapshot $snapshot
    [void](Test-PshPackageTree -PackageRoot $packageRoot -Manifest $validatedManifest)
    if ((Get-PshBuildHash -Path (Join-Path $packageRoot 'psh-installer.exe')) -cne $bootstrapperSha256) {
        Throw-PshPackageBuildError -ExitCode 5 -ErrorId 'PshPackageBuildBootstrapperBytes' -Message 'Package bootstrapper bytes differ from the common AnyCPU input.'
    }

    $zipPath = $null
    $zipSha256 = $null
    $catalogSha256 = $null
    if ($Finalize) {
        $catalogPath = Confirm-PshBuildPackageCatalogMembership -CatalogCommand $fileCatalogCommand -CatalogPath (Join-Path $packageCatalogRootResolved ($baseName + '.manifest.cat')) -ManifestPath $manifestPath -PackageName $baseName
        $catalogSha256 = Get-PshBuildHash -Path $catalogPath
        $zipPath = Join-Path $packagesRoot ($baseName + '.zip')
        New-PshBuildZip -PackageRoot $packageRoot -CatalogPath $catalogPath -Destination $zipPath
        $zipSha256 = Get-PshBuildHash -Path $zipPath
    }
    $records.Add([pscustomobject][ordered]@{
            name = $baseName
            version = [string]$slot.Version
            edition = [string]$slot.Edition
            architecture = [string]$slot.Architecture
            testOnly = [bool]$slot.TestOnly
            stagingRelativePath = 'pre-sign/' + $baseName
            manifestSha256 = [string]$snapshot.Sha256
            treeSha256 = [string]$validatedManifest.treeSha256
            catalogSha256 = $catalogSha256
            archiveRelativePath = if ($null -eq $zipPath) { $null } else { 'packages/' + [IO.Path]::GetFileName($zipPath) }
            archiveSha256 = $zipSha256
        })
}

if ($Finalize) {
    $releaseAssetsRoot = Join-Path $OutputRoot 'release-assets'
    New-PshBuildDirectory -Path $releaseAssetsRoot -Description 'public release assets root'
    foreach ($record in @($records.ToArray() | Where-Object { -not [bool]$_.testOnly })) {
        Copy-PshBuildFile -Source (Join-Path $OutputRoot ([string]$record.archiveRelativePath)) -Destination (Join-Path $releaseAssetsRoot ([IO.Path]::GetFileName([string]$record.archiveRelativePath))) -Description "public package '$($record.name)'"
    }
    Write-PshBuildText -Path (Join-Path $releaseAssetsRoot 'install.ps1') -Text ([string]$embeddedInstaller.Text)
    Copy-PshBuildFile -Source $resolvedInputs.ShellInstaller -Destination (Join-Path $releaseAssetsRoot 'install.sh') -Description 'public shell installer'
    Copy-PshBuildFile -Source $resolvedInputs.Bootstrapper -Destination (Join-Path $releaseAssetsRoot 'psh-installer.exe') -Description 'public AnyCPU bootstrapper'
    Copy-PshBuildFile -Source (Join-Path $RepositoryRoot 'sbom.spdx.json') -Destination (Join-Path $releaseAssetsRoot 'sbom.spdx.json') -Description 'public SPDX SBOM'
    Copy-PshBuildFile -Source (Join-Path $RepositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $releaseAssetsRoot 'THIRD_PARTY_NOTICES.md') -Description 'public third-party notices'
    Copy-PshBuildFile -Source $resolvedInputs.ReleaseNotes -Destination (Join-Path $releaseAssetsRoot 'RELEASE_NOTES.md') -Description 'public English release notes'
    Copy-PshBuildFile -Source $resolvedInputs.ReleaseNotesZhCn -Destination (Join-Path $releaseAssetsRoot 'RELEASE_NOTES.zh-CN.md') -Description 'public Simplified Chinese release notes'
}

$buildState = [pscustomobject][ordered]@{
    schemaVersion = 1
    product = 'Psh'
    version = $Version
    sourceCommit = $SourceCommit
    phase = if ($Finalize) { 'finalized-with-verified-catalog-membership' } else { 'pre-sign' }
    code = if ($Finalize) { 0 } else { 4 }
    reproducibilityScope = 'pre-sign-staging-file-manifests'
    postCatalogByteReproducible = $false
    catalogMembershipVerified = [bool]$Finalize
    commonBootstrapperSha256 = $bootstrapperSha256
    onlineInstaller = [pscustomobject][ordered]@{
        templateSha256 = [string]$embeddedInstaller.TemplateSha256
        templateLength = [int64]$embeddedInstaller.TemplateLength
        embeddedSha256 = [string]$embeddedInstaller.Sha256
        embeddedLength = [int64]$embeddedInstaller.Length
        helperSources = $embeddedInstaller.HelperSources
    }
    packages = $records.ToArray()
}
$buildStatePath = Join-Path $OutputRoot 'pre-sign-build.json'
Write-PshBuildText -Path $buildStatePath -Text ((ConvertTo-PshCanonicalJson -InputObject $buildState) + "`n")
Write-Output $buildState
