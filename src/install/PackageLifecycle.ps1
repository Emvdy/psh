# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

<#
    Package lifecycle primitives used by the Goal 5 installer.  This file is
    deliberately side-effect free when dot-sourced: callers decide when to
    stage, publish, switch, or remove a package.  The helpers below only
    validate data, hash files, write state atomically, and take the install
    root lock.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PshLifecycleVersionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z'
$script:PshLifecycleSha256Pattern = '\A[0-9a-f]{64}\z'
$script:PshLifecycleRidPattern = '\Awin-(?:x64|arm64)\z'
$script:PshLifecycleManifestFileName = 'package.manifest.json'
$script:PshLifecycleManifestKeys = @(
    'schemaVersion', 'product', 'version', 'edition', 'architecture',
    'payloadRoot', 'files', 'treeSha256', 'entrypoints', 'testOnly', 'source',
    'bootstrapper', 'nativeToolsLockSha256'
)
$script:PshLifecycleFileKeys = @('relativePath', 'length', 'sha256', 'role')
$script:PshLifecycleEntrypointKeys = @('offlinePowerShell', 'uninstallPowerShell', 'shell', 'bootstrapper')
$script:PshLifecycleEntrypointValues = [ordered]@{
    offlinePowerShell = 'install-offline.ps1'
    uninstallPowerShell = 'uninstall.ps1'
    shell             = 'install.sh'
    bootstrapper      = 'psh-installer.exe'
}
$script:PshLifecycleRoles = @('payload', 'entrypoint', 'bootstrapper', 'license', 'notice', 'sbom', 'metadata')
$script:PshLifecycleOwnershipKeys = @(
    'schemaVersion', 'product', 'installRoot', 'activeVersion', 'rollbackOrder',
    'stableFiles', 'config', 'versions', 'components'
)
$script:PshLifecycleTransactionKeys = @(
    'schemaVersion', 'product', 'transactionId', 'operation', 'phase', 'oldCurrent',
    'targetVersion', 'stageRelativePath', 'publishedRelativePath',
    'ownershipBeforeSha256', 'startedUtc'
)

function New-PshLifecycleException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][AllowNull()][Exception] $InnerException,
        [Parameter()][string] $ErrorId = 'PshLifecycle'
    )

    if ($null -eq $InnerException) {
        $exception = New-Object System.Exception($Message)
    }
    else {
        $exception = New-Object System.Exception($Message, $InnerException)
    }
    $exception.Data['PshExitCode'] = $ExitCode
    $exception.Data['PshErrorKind'] = $Kind
    $exception.Data['PshErrorId'] = $ErrorId
    return $exception
}

function Throw-PshLifecycleError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter()][AllowNull()][Exception] $InnerException,
        [Parameter()][string] $ErrorId = 'PshLifecycle'
    )

    throw (New-PshLifecycleException -ExitCode $ExitCode -Kind $Kind -Message $Message -InnerException $InnerException -ErrorId $ErrorId)
}

function Get-PshLifecycleErrorMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $ErrorRecord
    )

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    }
    while ($null -ne $exception -and $exception -is [Exception] -and $null -ne $exception.InnerException -and
        -not $exception.Data.Contains('PshExitCode')) {
        $exception = $exception.InnerException
    }
    $exitCode = 3
    $kind = 'Io'
    $errorId = 'PshLifecycle'
    if ($null -ne $exception -and $exception -is [Exception]) {
        if ($exception.Data.Contains('PshExitCode')) { $exitCode = [int]$exception.Data['PshExitCode'] }
        if ($exception.Data.Contains('PshErrorKind')) { $kind = [string]$exception.Data['PshErrorKind'] }
        if ($exception.Data.Contains('PshErrorId')) { $errorId = [string]$exception.Data['PshErrorId'] }
    }
    return [pscustomobject][ordered]@{
        ExitCode = $exitCode
        Kind     = $kind
        ErrorId  = $errorId
        Message  = if ($null -ne $exception) { [string]$exception.Message } else { [string]$ErrorRecord }
    }
}

function Test-PshLifecycleExceptionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $ErrorRecord)

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
    return ($null -ne $exception -and $exception -is [Exception] -and $exception.Data.Contains('PshExitCode'))
}

function Test-PshLifecycleCatalogValidationStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Status)

    return ($null -ne $Status -and $Status -ceq 'Valid')
}

function Get-PshLifecyclePropertyNames {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [System.Array]) {
        return @()
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-PshLifecycleProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ceq $Name) { return (, $InputObject[$key]) }
        }
        return $null
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]$property.Name -ceq $Name) { return (, $property.Value) }
    }
    return $null
}

function Test-PshLifecycleHasProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $InputObject) { return $false }
    foreach ($propertyName in (Get-PshLifecyclePropertyNames -InputObject $InputObject)) {
        if ($propertyName -ceq $Name) { return $true }
    }
    return $false
}

function Assert-PshLifecycleObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if ($null -eq $InputObject -or $InputObject -is [string] -or
        $InputObject -is [System.Array] -or
        (-not ($InputObject -is [System.Collections.IDictionary]) -and
         @($InputObject.PSObject.Properties).Count -eq 0)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidObject' -Message "$Description must be a JSON object."
    }
}

function Assert-PshLifecycleAllowedProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Allowed,
        [Parameter(Mandatory = $true)][string] $Description
    )

    Assert-PshLifecycleObject -InputObject $InputObject -Description $Description
    $allowedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $Allowed) { [void]$allowedSet.Add($name) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in (Get-PshLifecyclePropertyNames -InputObject $InputObject)) {
        if (-not $allowedSet.Contains($name)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshUnknownField' -Message "$Description contains unsupported field '$name'."
        }
        if (-not $seen.Add($name)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshDuplicateField' -Message "$Description contains duplicate field '$name'."
        }
    }
}

function Assert-PshLifecycleRequiredProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Required,
        [Parameter(Mandatory = $true)][string] $Description
    )

    foreach ($name in $Required) {
        if (-not (Test-PshLifecycleHasProperty -InputObject $InputObject -Name $name)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshMissingField' -Message "$Description is missing required field '$name'."
        }
    }
}

function Assert-PshLifecycleInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][switch] $NonNegative,
        [Parameter()][ref] $Result
    )

    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $isInteger = $false
    foreach ($type in $integerTypes) {
        if ($Value -is $type) { $isInteger = $true; break }
    }
    if (-not $isInteger) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidInteger' -Message "$Description must be an integer."
    }
    try { $number = [int64]$Value }
    catch {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidInteger' -Message "$Description is outside the supported range." -InnerException $_.Exception
    }
    if ($NonNegative -and $number -lt 0) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshNegativeInteger' -Message "$Description must be non-negative."
    }
    if ($null -ne $Result) { $Result.Value = $number }
    return $number
}

function Assert-PshLifecycleSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][switch] $AllowNull
    )

    if ($AllowNull -and $null -eq $Value) { return $null }
    if ($null -eq $Value -or -not ($Value -is [string]) -or [string]$Value -cnotmatch $script:PshLifecycleSha256Pattern -or
        [string]$Value -ceq ('0' * 64)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidSha256' -Message "$Description must be a non-zero lowercase SHA256 hex string."
    }
    return [string]$Value
}

function Assert-PshLifecycleSemVer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Value, [Parameter(Mandatory = $true)][string] $Description)

    if ($null -eq $Value -or -not ($Value -is [string]) -or [string]$Value -cnotmatch $script:PshLifecycleVersionPattern) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidVersion' -Message "$Description is not a valid Semantic Version 2.0 value."
    }
    return [string]$Value
}

function Assert-PshLifecycleRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][AllowNull()][System.Collections.Generic.HashSet[string]] $Seen
    )

    if ($null -eq $Value -or -not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRelativePath' -Message "$Description must be a non-empty relative path."
    }
    $path = [string]$Value
    if ($path -match '\A(?:[A-Za-z]:|[/\\]|\\\\|//)') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshAbsolutePath' -Message "$Description must not be absolute: $path"
    }
    if ($path -match '[\x00-\x1F\x7F]') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshControlPath' -Message "$Description contains a control character: $path"
    }
    if ($path -match '[<>:"|?*]') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidPathCharacter' -Message "$Description contains a Windows-invalid character: $path"
    }
    if ([IO.Path]::IsPathRooted($path)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshAbsolutePath' -Message "$Description must not be absolute: $path"
    }
    if ($path -match '\\') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshBackslashPath' -Message "$Description must use forward slashes: $path"
    }
    $segments = @($path.Split('/'))
    if ($segments.Count -eq 0) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRelativePath' -Message "$Description is empty."
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTraversalPath' -Message "$Description contains an empty, '.', or '..' segment: $path"
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTrailingPathCharacter' -Message "$Description contains a segment ending in a dot or space: $path"
        }
        $base = $segment
        $dot = $base.IndexOf('.')
        if ($dot -ge 0) { $base = $base.Substring(0, $dot) }
        if ($base -match '(?i)\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]|CONIN\$|CONOUT\$)\z') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReservedPathName' -Message "$Description contains a Windows reserved name: $path"
        }
    }
    if ($null -ne $Seen -and -not $Seen.Add($path)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshDuplicatePath' -Message "$Description is duplicated case-insensitively: $path"
    }
    return $path
}

function Resolve-PshPackageRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter()][string] $Description = 'Package path',
        [Parameter()][switch] $AllowMissing
    )

    $validated = Assert-PshLifecycleRelativePath -Value $RelativePath -Description $Description
    try { $fullRoot = [IO.Path]::GetFullPath($Root) }
    catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRoot' -Message "The package root is not a valid path: $Root" -InnerException $_.Exception }
    $fullRoot = $fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([IO.File]::Exists($fullRoot) -or [IO.Directory]::Exists($fullRoot)) {
        try { $rootAttributes = [IO.File]::GetAttributes($fullRoot) }
        catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPathStatFailed' -Message "Cannot inspect package root: $fullRoot" -InnerException $_.Exception }
        if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Package root must not be a reparse point: $fullRoot"
        }
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path -Path $fullRoot -ChildPath $validated.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $comparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPathEscape' -Message "$Description escapes its root: $RelativePath"
    }

    # Walk every existing component.  A reparse point anywhere in the chain
    # would make a seemingly safe relative path resolve outside the package.
    $current = $fullRoot
    $relativeSegments = @($validated.Split('/'))
    foreach ($segment in $relativeSegments) {
        $current = Join-Path -Path $current -ChildPath $segment
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            try { $attributes = [IO.File]::GetAttributes($current) }
            catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPathStatFailed' -Message "Cannot inspect package path: $current" -InnerException $_.Exception }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Package path must not contain a reparse point: $current"
            }
        }
        elseif (-not $AllowMissing) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshMissingPath' -Message "Package path does not exist: $candidate"
        }
    }
    return $candidate
}

function Get-PshLifecycleUtf8NoBom {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Text)
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $encoding.GetBytes($Text) }
    catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidUtf8' -Message 'JSON contains invalid UTF-16 data.' -InnerException $_.Exception }
}

function Assert-PshLifecycleJsonKeysUnique {
    <# A small JSON scanner catches exact duplicate keys, which ConvertFrom-Json
       historically accepted by silently keeping the last value on PS5.1. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Text)

    $index = 0
    $length = $Text.Length
    $parseValue = $null
    $parseString = $null
    $skipWhitespace = {
        while ($script:__PshJsonIndex -lt $script:__PshJsonLength -and
            [int][char]$script:__PshJsonText[$script:__PshJsonIndex] -in @(0x20, 0x09, 0x0A, 0x0D)) {
            $script:__PshJsonIndex++
        }
    }
    $script:__PshJsonIndex = 0
    $script:__PshJsonLength = $length
    $script:__PshJsonText = $Text
    $parseString = {
        if ($script:__PshJsonIndex -ge $script:__PshJsonLength -or $script:__PshJsonText[$script:__PshJsonIndex] -cne '"') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON string was expected.'
        }
        $script:__PshJsonIndex++
        $builder = New-Object System.Text.StringBuilder
        while ($script:__PshJsonIndex -lt $script:__PshJsonLength) {
            $character = [char]$script:__PshJsonText[$script:__PshJsonIndex]
            $script:__PshJsonIndex++
            if ($character -ceq '"') { return $builder.ToString() }
            if ([int]$character -lt 0x20) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON string contains an unescaped control character.'
            }
            if ($character -cne '\\') {
                [void]$builder.Append($character)
                continue
            }
            if ($script:__PshJsonIndex -ge $script:__PshJsonLength) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON string has an incomplete escape.'
            }
            $escape = [char]$script:__PshJsonText[$script:__PshJsonIndex]
            $script:__PshJsonIndex++
            switch ($escape) {
                '"' { [void]$builder.Append('"'); continue }
                '\\' { [void]$builder.Append('\\'); continue }
                '/' { [void]$builder.Append('/'); continue }
                'b' { [void]$builder.Append([char]8); continue }
                'f' { [void]$builder.Append([char]12); continue }
                'n' { [void]$builder.Append([char]10); continue }
                'r' { [void]$builder.Append([char]13); continue }
                't' { [void]$builder.Append([char]9); continue }
                'u' {
                    if ($script:__PshJsonIndex + 4 -gt $script:__PshJsonLength) {
                        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON unicode escape is incomplete.'
                    }
                    $hex = $script:__PshJsonText.Substring($script:__PshJsonIndex, 4)
                    if ($hex -notmatch '\A[0-9A-Fa-f]{4}\z') {
                        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON unicode escape is malformed.'
                    }
                    $code = [Convert]::ToInt32($hex, 16)
                    $script:__PshJsonIndex += 4
                    if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                        if ($script:__PshJsonIndex + 6 -gt $script:__PshJsonLength -or
                            $script:__PshJsonText.Substring($script:__PshJsonIndex, 2) -cne '\\u') {
                            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON has an unpaired high surrogate.'
                        }
                        $lowHex = $script:__PshJsonText.Substring($script:__PshJsonIndex + 2, 4)
                        if ($lowHex -notmatch '\A[0-9A-Fa-f]{4}\z') {
                            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON low surrogate is malformed.'
                        }
                        $low = [Convert]::ToInt32($lowHex, 16)
                        if ($low -lt 0xDC00 -or $low -gt 0xDFFF) {
                            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON has an invalid surrogate pair.'
                        }
                        $script:__PshJsonIndex += 6
                        [void]$builder.Append([char]$code)
                        [void]$builder.Append([char]$low)
                        continue
                    }
                    if ($code -ge 0xDC00 -and $code -le 0xDFFF) {
                        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON has an unpaired low surrogate.'
                    }
                    [void]$builder.Append([char]$code)
                    continue
                }
                default {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message "JSON contains an unsupported escape '\\$escape'."
                }
            }
        }
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON string is unterminated.'
    }
    $parseValue = {
        & $skipWhitespace
        if ($script:__PshJsonIndex -ge $script:__PshJsonLength) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON value is missing.'
        }
        $character = [char]$script:__PshJsonText[$script:__PshJsonIndex]
        if ($character -ceq '"') { [void](& $parseString); return }
        if ($character -ceq '{') {
            $script:__PshJsonIndex++
            & $skipWhitespace
            $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            if ($script:__PshJsonIndex -lt $script:__PshJsonLength -and $script:__PshJsonText[$script:__PshJsonIndex] -ceq '}') { $script:__PshJsonIndex++; return }
            while ($true) {
                & $skipWhitespace
                $key = [string](& $parseString)
                if (-not $keys.Add($key)) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshDuplicateField' -Message "JSON object contains a duplicate key: $key"
                }
                & $skipWhitespace
                if ($script:__PshJsonIndex -ge $script:__PshJsonLength -or $script:__PshJsonText[$script:__PshJsonIndex] -cne ':') {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON object key is not followed by a colon.'
                }
                $script:__PshJsonIndex++
                & $parseValue
                & $skipWhitespace
                if ($script:__PshJsonIndex -ge $script:__PshJsonLength) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON object is unterminated.'
                }
                $separator = [char]$script:__PshJsonText[$script:__PshJsonIndex]
                $script:__PshJsonIndex++
                if ($separator -ceq '}') { return }
                if ($separator -cne ',') {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON object requires a comma between members.'
                }
            }
        }
        if ($character -ceq '[') {
            $script:__PshJsonIndex++
            & $skipWhitespace
            if ($script:__PshJsonIndex -lt $script:__PshJsonLength -and $script:__PshJsonText[$script:__PshJsonIndex] -ceq ']') { $script:__PshJsonIndex++; return }
            while ($true) {
                & $parseValue
                & $skipWhitespace
                if ($script:__PshJsonIndex -ge $script:__PshJsonLength) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON array is unterminated.'
                }
                $separator = [char]$script:__PshJsonText[$script:__PshJsonIndex]
                $script:__PshJsonIndex++
                if ($separator -ceq ']') { return }
                if ($separator -cne ',') {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON array requires a comma between values.'
                }
            }
        }
        foreach ($literal in @('true', 'false', 'null')) {
            if ($script:__PshJsonIndex + $literal.Length -le $script:__PshJsonLength -and
                $script:__PshJsonText.Substring($script:__PshJsonIndex, $literal.Length) -ceq $literal) {
                $script:__PshJsonIndex += $literal.Length
                return
            }
        }
        $remaining = $script:__PshJsonText.Substring($script:__PshJsonIndex)
        $numberMatch = [Text.RegularExpressions.Regex]::Match($remaining, '\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?')
        if ($numberMatch.Success) {
            $script:__PshJsonIndex += $numberMatch.Length
            return
        }
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message "JSON value is malformed near offset $($script:__PshJsonIndex)."
    }
    & $parseValue
    & $skipWhitespace
    if ($script:__PshJsonIndex -ne $script:__PshJsonLength) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message 'JSON contains trailing data.'
    }
    Remove-Variable __PshJsonIndex, __PshJsonLength, __PshJsonText -Scope Script -ErrorAction SilentlyContinue
}

function Read-PshStrictJsonDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $snapshot = Read-PshStrictJsonSnapshot -Path $Path -Description $Description
    return (, $snapshot.Document)
}

function Test-PshLifecycleMissingPathException {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.FileNotFoundException] -or $current -is [IO.DirectoryNotFoundException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-PshLifecyclePathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $attributes = $null
    try { $attributes = [IO.File]::GetAttributes($Path) }
    catch {
        if (Test-PshLifecycleMissingPathException -Exception $_.Exception) {
            # File.GetAttributes reports a dangling symbolic link as missing on
            # Unix.  Enumerating its parent still exposes the reparse entry.
            try {
                $fullPath = [IO.Path]::GetFullPath($Path)
                $parent = [IO.Path]::GetDirectoryName($fullPath)
                $leaf = [IO.Path]::GetFileName($fullPath)
                if (-not [string]::IsNullOrEmpty($parent) -and -not [string]::IsNullOrEmpty($leaf)) {
                    $directory = New-Object IO.DirectoryInfo($parent)
                    foreach ($candidate in @($directory.GetFileSystemInfos())) {
                        if ([string]::Equals([string]$candidate.Name, $leaf, (Get-PshLifecyclePathComparison))) {
                            $attributes = $candidate.Attributes
                            break
                        }
                    }
                }
            }
            catch { }
            if ($null -eq $attributes) {
                return [pscustomobject][ordered]@{
                    Path = $Path; Exists = $false; IsDirectory = $false; IsReparsePoint = $false; IsRegularFile = $false
                }
            }
        }
        else {
            Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshPathInspectFailed' -Message "Unable to inspect ${Description}: $Path" -InnerException $_.Exception
        }
    }
    $isDirectory = (($attributes -band [IO.FileAttributes]::Directory) -ne 0)
    $isReparse = (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    return [pscustomobject][ordered]@{
        Path = $Path
        Exists = $true
        IsDirectory = $isDirectory
        IsReparsePoint = $isReparse
        IsRegularFile = (-not $isDirectory -and -not $isReparse)
    }
}

function Assert-PshLifecycleNoReparseAncestors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidPath' -Message "$Description is not a valid filesystem path: $Path" -InnerException $_.Exception
    }
    $comparison = Get-PshLifecyclePathComparison
    $probe = $fullPath
    $isLeaf = $true
    while ($true) {
        $entry = Get-PshLifecyclePathEntry -Path $probe -Description "$Description component"
        if ([bool]$entry.Exists) {
            if ([bool]$entry.IsReparsePoint) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "$Description must not contain a reparse point: $probe"
            }
            if (-not $isLeaf -and -not [bool]$entry.IsDirectory) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPathAncestorNotDirectory' -Message "$Description has a non-directory ancestor: $probe"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $probe, $comparison)) { break }
        $probe = $parent
        $isLeaf = $false
    }
    return $fullPath
}

function Read-PshStrictJsonSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][switch] $AllowMissing,
        [Parameter()][switch] $RequireLf
    )

    $entry = Get-PshLifecyclePathEntry -Path $Path -Description $Description
    if (-not [bool]$entry.Exists) {
        if ($AllowMissing) { return $null }
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshMissingJson' -Message "$Description was not found: $Path"
    }
    if ([bool]$entry.IsReparsePoint) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "$Description must not be a reparse point: $Path"
    }
    if (-not [bool]$entry.IsRegularFile) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshNotRegularFile' -Message "$Description must be a regular file: $Path"
    }
    try {
        $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        try {
            $memory = New-Object IO.MemoryStream
            try {
                $stream.CopyTo($memory)
                $bytes = $memory.ToArray()
            }
            finally { $memory.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshJsonReadFailed' -Message "Unable to read ${Description}: $Path" -InnerException $_.Exception
    }
    return New-PshStrictJsonSnapshotFromBytes -Path $Path -Bytes $bytes -Description $Description -RequireLf:$RequireLf
}

function New-PshStrictJsonSnapshotFromBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][switch] $RequireLf
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshJsonBom' -Message "$Description must be UTF-8 without a BOM: $Path"
    }
    if ($RequireLf) {
        if ($Bytes.Length -eq 0 -or $Bytes[$Bytes.Length - 1] -ne 0x0A) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshJsonLineEnding' -Message "$Description must use UTF-8 LF line endings and end with LF: $Path"
        }
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            if ($Bytes[$index] -eq 0x0D) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshJsonLineEnding' -Message "$Description must use UTF-8 LF line endings and must not contain CR bytes: $Path"
            }
        }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { $text = $encoding.GetString($Bytes) }
    catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshJsonUtf8' -Message "$Description is not valid UTF-8: $Path" -InnerException $_.Exception }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshJsonEmpty' -Message "$Description is empty: $Path"
    }
    Assert-PshLifecycleJsonKeysUnique -Text $text
    try { $document = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidJson' -Message "$Description is not valid JSON: $Path" -InnerException $_.Exception }
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Bytes = $Bytes
        Length = [int64]$Bytes.Length
        Sha256 = Get-PshLifecycleSha256Bytes -Bytes $Bytes
        Document = $document
    }
}

function Get-PshLifecycleSha256Bytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PshLifecycleFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        $stream = New-Object IO.FileStream($Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read))
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { return [pscustomobject][ordered]@{ Length = $stream.Length; Sha256 = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } }
            finally { $sha.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshFileHashFailed' -Message "Unable to read and hash package file: $Path" -InnerException $_.Exception }
}

function Get-PshPackageTreeDigest {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][string] $PackageRoot,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    $entries = @()
    $manifestFilesValue = Get-PshLifecycleProperty -InputObject $Manifest -Name 'files'
    $manifestFiles = @($manifestFilesValue)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        foreach ($entry in $manifestFiles) {
            $relative = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty -InputObject $entry -Name 'relativePath') -Description 'Tree entry relativePath' -Seen $seen
            $length = [int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty -InputObject $entry -Name 'length') -Description "Tree entry '$relative' length" -NonNegative)
            $sha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty -InputObject $entry -Name 'sha256') -Description "Tree entry '$relative' SHA256"
            $entries += [pscustomobject][ordered]@{
                RelativePath = $relative
                Length       = $length
                Sha256       = $sha
            }
        }
    }
    else {
        foreach ($entry in $manifestFiles) {
            $relative = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty -InputObject $entry -Name 'relativePath') -Description 'Tree entry relativePath' -Seen $seen
            $path = Resolve-PshPackageRelativePath -Root $PackageRoot -RelativePath $relative -Description "Package file '$relative'"
            if (-not [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshMissingPackageFile' -Message "Manifest file is missing or not regular: $relative"
            }
            $actual = Get-PshLifecycleFileSha256 -Path $path
            $entries += [pscustomobject][ordered]@{
                RelativePath = $relative
                Length       = [int64]$actual.Length
                Sha256       = [string]$actual.Sha256
            }
        }
    }
    $entryByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    [string[]]$sortedPaths = @($entries | ForEach-Object { $entryByPath[[string]$_.RelativePath] = $_; [string]$_.RelativePath })
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $builder = New-Object System.Text.StringBuilder
    foreach ($path in $sortedPaths) {
        $entry = $entryByPath[$path]
        [void]$builder.Append([string]$entry.RelativePath)
        [void]$builder.Append("`t")
        [void]$builder.Append(([int64]$entry.Length).ToString([Globalization.CultureInfo]::InvariantCulture))
        [void]$builder.Append("`t")
        [void]$builder.Append(([string]$entry.Sha256).ToLowerInvariant())
        [void]$builder.Append("`n")
    }
    return Get-PshLifecycleSha256Bytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($builder.ToString()))
}

function Read-PshPackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][AllowNull()][object] $Snapshot
    )

    if ([IO.Path]::GetFileName($Path) -cne $script:PshLifecycleManifestFileName) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestFileName' -Message "Package manifest file name must be exactly '$($script:PshLifecycleManifestFileName)'."
    }
    if ($null -eq $Snapshot) {
        $document = Read-PshStrictJsonDocument -Path $Path -Description 'Package manifest'
    }
    else {
        $snapshotPath = [string](Get-PshLifecycleProperty -InputObject $Snapshot -Name 'Path')
        if ([string]::IsNullOrWhiteSpace($snapshotPath) -or
            -not [string]::Equals([IO.Path]::GetFullPath($snapshotPath), [IO.Path]::GetFullPath($Path), (Get-PshLifecyclePathComparison))) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSnapshot' -Message 'Package manifest snapshot path does not match the requested path.'
        }
        $document = Get-PshLifecycleProperty -InputObject $Snapshot -Name 'Document'
        if ($null -eq $document) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSnapshot' -Message 'Package manifest snapshot has no parsed document.'
        }
    }
    Assert-PshLifecycleAllowedProperties -InputObject $document -Allowed $script:PshLifecycleManifestKeys -Description 'Package manifest'
    Assert-PshLifecycleRequiredProperties -InputObject $document -Required $script:PshLifecycleManifestKeys -Description 'Package manifest'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $document 'schemaVersion') -Description 'schemaVersion' -NonNegative) -ne 1) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSchema' -Message 'Package manifest schemaVersion must be 1.'
    }
    if ([string](Get-PshLifecycleProperty $document 'product') -cne 'Psh') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestProduct' -Message 'Package manifest product must be Psh.'
    }
    $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $document 'version') -Description 'Package manifest version'
    $edition = Get-PshLifecycleProperty $document 'edition'
    if ($edition -isnot [string] -or [string]$edition -cnotin @('Core', 'Full')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestEdition' -Message 'Package manifest edition must be Core or Full.'
    }
    $architecture = Get-PshLifecycleProperty $document 'architecture'
    if ($architecture -isnot [string] -or ($edition -ceq 'Core' -and [string]$architecture -cne 'any') -or
        ($edition -ceq 'Full' -and [string]$architecture -cnotmatch $script:PshLifecycleRidPattern)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestArchitecture' -Message 'Package manifest architecture is invalid for its edition.'
    }
    $payloadRoot = Get-PshLifecycleProperty $document 'payloadRoot'
    if ($payloadRoot -isnot [string] -or [string]$payloadRoot -cne 'payload') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestPayloadRoot' -Message "Package manifest payloadRoot must be exactly 'payload'."
    }
    $treeSha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $document 'treeSha256') -Description 'Package manifest treeSha256'
    if ((Get-PshLifecycleProperty $document 'testOnly') -isnot [bool]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestTestOnly' -Message 'Package manifest testOnly must be boolean.'
    }

    $filesValue = Get-PshLifecycleProperty $document 'files'
    if ($null -eq $filesValue -or -not ($filesValue -is [System.Array])) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestFiles' -Message 'Package manifest files must be an array.'
    }
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $normalizedFiles = New-Object System.Collections.Generic.List[object]
    foreach ($file in @($filesValue)) {
        Assert-PshLifecycleAllowedProperties -InputObject $file -Allowed $script:PshLifecycleFileKeys -Description 'Package manifest file entry'
        Assert-PshLifecycleRequiredProperties -InputObject $file -Required $script:PshLifecycleFileKeys -Description 'Package manifest file entry'
        $relative = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $file 'relativePath') -Description 'Package manifest file relativePath' -Seen $seenPaths
        if ([string]::Equals($relative, $script:PshLifecycleManifestFileName, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSelfListed' -Message 'Package manifest must not list itself in files.'
        }
        $length = [int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $file 'length') -Description "Length for '$relative'" -NonNegative)
        $sha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $file 'sha256') -Description "SHA256 for '$relative'"
        $role = Get-PshLifecycleProperty $file 'role'
        if ($role -isnot [string] -or @($script:PshLifecycleRoles | Where-Object { $_ -ceq [string]$role }).Count -ne 1) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestRole' -Message "Role for '$relative' is invalid."
        }
        [void]$normalizedFiles.Add([pscustomobject][ordered]@{ relativePath = $relative; length = $length; sha256 = $sha; role = [string]$role })
    }
    if ($normalizedFiles.Count -eq 0) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestFilesEmpty' -Message 'Package manifest files must not be empty.'
    }
    $declaredDigest = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = @($normalizedFiles.ToArray()) })
    if ($declaredDigest -cne $treeSha) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestTreeMismatch' -Message 'Package manifest treeSha256 does not match its files array.'
    }

    $entrypoints = Get-PshLifecycleProperty $document 'entrypoints'
    Assert-PshLifecycleAllowedProperties -InputObject $entrypoints -Allowed $script:PshLifecycleEntrypointKeys -Description 'Package manifest entrypoints'
    Assert-PshLifecycleRequiredProperties -InputObject $entrypoints -Required $script:PshLifecycleEntrypointKeys -Description 'Package manifest entrypoints'
    foreach ($key in $script:PshLifecycleEntrypointKeys) {
        $entrypointPath = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $entrypoints $key) -Description "Entrypoint '$key'"
        if ([string]$entrypointPath -cne [string]$script:PshLifecycleEntrypointValues[$key]) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestEntrypoint' -Message "Entrypoint '$key' must be '$($script:PshLifecycleEntrypointValues[$key])'."
        }
        $entryFile = @($normalizedFiles | Where-Object { [string]$_.relativePath -ceq $entrypointPath })
        if ($entryFile.Count -ne 1 -or (($key -ceq 'bootstrapper' -and [string]$entryFile[0].role -cne 'bootstrapper') -or
            ($key -cne 'bootstrapper' -and [string]$entryFile[0].role -cne 'entrypoint'))) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestEntrypointFile' -Message "Entrypoint '$key' is not represented by the required file role."
        }
    }

    $source = Get-PshLifecycleProperty $document 'source'
    Assert-PshLifecycleAllowedProperties -InputObject $source -Allowed @('repository', 'commit') -Description 'Package manifest source'
    Assert-PshLifecycleRequiredProperties -InputObject $source -Required @('repository', 'commit') -Description 'Package manifest source'
    $repository = Get-PshLifecycleProperty $source 'repository'
    if ($repository -isnot [string] -or [string]$repository -notmatch '\Ahttps://[^\s]+\z') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSource' -Message 'Package manifest source.repository must be an HTTPS URL.'
    }
    $commit = Get-PshLifecycleProperty $source 'commit'
    if ($commit -isnot [string] -or [string]$commit -cnotmatch '\A[0-9a-f]{40}\z') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestSource' -Message 'Package manifest source.commit must be a lowercase 40-character commit id.'
    }

    $bootstrapper = Get-PshLifecycleProperty $document 'bootstrapper'
    Assert-PshLifecycleAllowedProperties -InputObject $bootstrapper -Allowed @('relativePath', 'sha256', 'anyCpu') -Description 'Package manifest bootstrapper'
    Assert-PshLifecycleRequiredProperties -InputObject $bootstrapper -Required @('relativePath', 'sha256', 'anyCpu') -Description 'Package manifest bootstrapper'
    $bootstrapPath = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $bootstrapper 'relativePath') -Description 'Bootstrapper relativePath'
    if ($bootstrapPath -cne 'psh-installer.exe' -or [string](Get-PshLifecycleProperty $entrypoints 'bootstrapper') -cne $bootstrapPath) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestBootstrapper' -Message 'Bootstrapper path must match the bootstrapper entrypoint.'
    }
    if ((Get-PshLifecycleProperty $bootstrapper 'anyCpu') -isnot [bool] -or -not [bool](Get-PshLifecycleProperty $bootstrapper 'anyCpu')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestBootstrapper' -Message 'Package bootstrapper must declare anyCpu=true.'
    }
    $bootstrapSha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $bootstrapper 'sha256') -Description 'Bootstrapper SHA256'
    $bootstrapFile = @($normalizedFiles | Where-Object { [string]$_.relativePath -ceq $bootstrapPath })
    if ($bootstrapFile.Count -ne 1 -or [string]$bootstrapFile[0].sha256 -cne $bootstrapSha) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestBootstrapper' -Message 'Bootstrapper SHA256 does not match files.'
    }

    $nativeLockSha = Get-PshLifecycleProperty $document 'nativeToolsLockSha256'
    if ($edition -ceq 'Core') {
        if ($null -ne $nativeLockSha) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestNativeLock' -Message 'Core package nativeToolsLockSha256 must be null.'
        }
    }
    else {
        $nativeLockSha = Assert-PshLifecycleSha256 -Value $nativeLockSha -Description 'nativeToolsLockSha256'
        $lockMatches = @($normalizedFiles | Where-Object { [string]$_.relativePath -match '(?i)(?:^|/)native-tools\.lock\.json\z' })
        if ($lockMatches.Count -ne 1 -or [string]$lockMatches[0].sha256 -cne $nativeLockSha) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestNativeLock' -Message 'nativeToolsLockSha256 does not match the native-tools lock file.'
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion          = 1
        product                = 'Psh'
        version                = $version
        edition                = [string]$edition
        architecture           = [string]$architecture
        payloadRoot            = 'payload'
        files                  = @($normalizedFiles.ToArray())
        treeSha256             = $treeSha
        entrypoints            = [pscustomobject][ordered]@{
            offlinePowerShell = [string](Get-PshLifecycleProperty $entrypoints 'offlinePowerShell')
            uninstallPowerShell = [string](Get-PshLifecycleProperty $entrypoints 'uninstallPowerShell')
            shell             = [string](Get-PshLifecycleProperty $entrypoints 'shell')
            bootstrapper      = [string](Get-PshLifecycleProperty $entrypoints 'bootstrapper')
        }
        testOnly               = [bool](Get-PshLifecycleProperty $document 'testOnly')
        source                 = [pscustomobject][ordered]@{ repository = [string]$repository; commit = [string]$commit }
        bootstrapper           = [pscustomobject][ordered]@{ relativePath = $bootstrapPath; sha256 = $bootstrapSha; anyCpu = $true }
        nativeToolsLockSha256  = $nativeLockSha
    }
}

function Get-PshPackageTreeEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $PackageRoot)

    if (-not [IO.Directory]::Exists($PackageRoot)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshMissingPackageRoot' -Message "Package root was not found: $PackageRoot"
    }
    try {
        $rootAttributes = [IO.File]::GetAttributes($PackageRoot)
        if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Package root must not be a reparse point: $PackageRoot"
        }
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshPackageRootStatFailed' -Message "Unable to inspect package root: $PackageRoot" -InnerException $_.Exception
    }
    $stack = New-Object System.Collections.Stack
    $stack.Push([pscustomobject]@{ FullPath = [IO.Path]::GetFullPath($PackageRoot); RelativePath = '' })
    $result = New-Object System.Collections.Generic.List[object]
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        try { $children = [IO.Directory]::GetFileSystemEntries([string]$node.FullPath) }
        catch { Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshPackageEnumerateFailed' -Message "Unable to enumerate package directory: $($node.FullPath)" -InnerException $_.Exception }
        foreach ($child in $children) {
            $name = [IO.Path]::GetFileName($child)
            $relative = if ([string]::IsNullOrEmpty([string]$node.RelativePath)) { $name } else { "$($node.RelativePath)/$name" }
            try { $attributes = [IO.File]::GetAttributes($child) }
            catch { Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshPackageStatFailed' -Message "Unable to inspect package entry: $child" -InnerException $_.Exception }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Package entry must not be a reparse point: $relative"
            }
            if ([string]::Equals($relative, $script:PshLifecycleManifestFileName, [StringComparison]::OrdinalIgnoreCase)) {
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshManifestNotFile' -Message 'package.manifest.json must be a regular file.'
                }
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push([pscustomobject]@{ FullPath = $child; RelativePath = $relative })
                continue
            }
            $relative = Assert-PshLifecycleRelativePath -Value $relative -Description 'Package file path'
            $hash = Get-PshLifecycleFileSha256 -Path $child
            [void]$result.Add([pscustomobject][ordered]@{ RelativePath = $relative; Length = [int64]$hash.Length; Sha256 = [string]$hash.Sha256; FullPath = $child })
        }
    }
    return @($result.ToArray())
}

function Test-PshPackageTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    $expected = @((Get-PshLifecycleProperty -InputObject $Manifest -Name 'files'))
    $actual = @(Get-PshPackageTreeEntries -PackageRoot $PackageRoot)
    if ($actual.Count -ne $expected.Count) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPackageFileSet' -Message "Package file count does not match its manifest (actual=$($actual.Count), expected=$($expected.Count))."
    }
    $expectedByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $expected) {
        $path = [string](Get-PshLifecycleProperty $entry 'relativePath')
        if ($expectedByPath.ContainsKey($path)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshDuplicatePath' -Message "Manifest contains duplicate path: $path"
        }
        $expectedByPath[$path] = $entry
    }
    foreach ($entry in $actual) {
        $path = [string]$entry.RelativePath
        if (-not $expectedByPath.ContainsKey($path)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshUnexpectedPackageFile' -Message "Package contains an unlisted file: $path"
        }
        $declared = $expectedByPath[$path]
        if ([string]$declared.relativePath -cne $path -or [int64](Get-PshLifecycleProperty $declared 'length') -ne [int64]$entry.Length -or
            [string](Get-PshLifecycleProperty $declared 'sha256') -cne [string]$entry.Sha256) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPackageFileMismatch' -Message "Package file integrity does not match its manifest: $path"
        }
    }
    $digest = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = @($actual | ForEach-Object { [pscustomobject]@{ relativePath = $_.RelativePath; length = $_.Length; sha256 = $_.Sha256 } }) })
    $declaredTree = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $Manifest 'treeSha256') -Description 'Package manifest treeSha256'
    if ($digest -cne $declaredTree) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshPackageTreeMismatch' -Message "Package tree SHA256 does not match its manifest."
    }
    return [pscustomobject][ordered]@{
        Verified   = $true
        FileCount  = $actual.Count
        TotalLength = [int64](($actual | Measure-Object -Property Length -Sum).Sum)
        TreeSha256 = $digest
        Files      = $actual
    }
}

function ConvertTo-PshCanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)

    $builder = New-Object System.Text.StringBuilder
    $writeValue = $null
    $writeString = {
        if ($null -eq $args[0]) { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonType' -Message 'JSON string cannot be null.' }
        $value = [string]$args[0]
        [void]$builder.Append('"')
        for ($i = 0; $i -lt $value.Length; $i++) {
            $code = [int][char]$value[$i]
            if ($code -eq 0x08) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x62)
            }
            elseif ($code -eq 0x09) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x74)
            }
            elseif ($code -eq 0x0A) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x6E)
            }
            elseif ($code -eq 0x0C) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x66)
            }
            elseif ($code -eq 0x0D) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x72)
            }
            elseif ($code -eq 0x22) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x22)
            }
            elseif ($code -eq 0x5C) {
                [void]$builder.Append([char]0x5C); [void]$builder.Append([char]0x5C)
            }
            elseif ($code -lt 0x20) {
                [void]$builder.Append([char]0x5C)
                [void]$builder.Append([char]0x75)
                [void]$builder.Append(('{0:x4}' -f $code))
            }
            elseif ($code -ge 0xD800 -and $code -le 0xDBFF) {
                if ($i + 1 -ge $value.Length -or [int][char]$value[$i + 1] -lt 0xDC00 -or [int][char]$value[$i + 1] -gt 0xDFFF) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonType' -Message 'JSON string contains an unpaired high surrogate.'
                }
                [void]$builder.Append($value[$i]); $i++; [void]$builder.Append($value[$i])
            }
            elseif ($code -ge 0xDC00 -and $code -le 0xDFFF) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonType' -Message 'JSON string contains an unpaired low surrogate.'
            }
            else {
                [void]$builder.Append([char]$code)
            }
        }
        [void]$builder.Append('"')
    }
    $writeValue = {
        param($value, [int]$depth)
        if ($depth -gt 64) { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonDepth' -Message 'JSON nesting exceeds the supported depth.' }
        if ($null -eq $value) { [void]$builder.Append('null'); return }
        if ($value -is [string] -or $value -is [char]) { & $writeString ([string]$value); return }
        if ($value -is [bool]) { [void]$builder.Append($(if ($value) { 'true' } else { 'false' })); return }
        if ($value -is [byte] -or $value -is [sbyte] -or $value -is [int16] -or $value -is [uint16] -or
            $value -is [int32] -or $value -is [uint32] -or $value -is [int64] -or $value -is [uint64] -or
            $value -is [decimal] -or $value -is [System.Numerics.BigInteger]) {
            [void]$builder.Append(([string]$value.ToString([Globalization.CultureInfo]::InvariantCulture))); return
        }
        if ($value -is [single] -or $value -is [double]) {
            if ([double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value)) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonNumber' -Message 'JSON cannot encode NaN or infinity.'
            }
            [void]$builder.Append(([double]$value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)); return
        }
        if ($value -is [DateTimeOffset]) {
            & $writeString $value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [Globalization.CultureInfo]::InvariantCulture)
            return
        }
        if ($value -is [DateTime]) {
            & $writeString $value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [Globalization.CultureInfo]::InvariantCulture)
            return
        }
        if ($value -is [System.Collections.IDictionary]) {
            $names = @($value.Keys | ForEach-Object {
                if ($_ -isnot [string]) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonKey' -Message 'JSON object keys must be strings.'
                }
                [string]$_
            })
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in $names) { if (-not $seen.Add($name)) { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonDuplicate' -Message "JSON object contains duplicate key '$name'." } }
            [Array]::Sort($names, [StringComparer]::Ordinal)
            [void]$builder.Append('{')
            for ($i = 0; $i -lt $names.Count; $i++) { if ($i -gt 0) { [void]$builder.Append(',') }; & $writeString $names[$i]; [void]$builder.Append(':'); & $writeValue $value[$names[$i]] ($depth + 1) }
            [void]$builder.Append('}'); return
        }
        if ($value -is [System.Array] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
            [void]$builder.Append('['); $index = 0
            foreach ($item in $value) { if ($index -gt 0) { [void]$builder.Append(',') }; & $writeValue $item ($depth + 1); $index++ }
            [void]$builder.Append(']'); return
        }
        if ($value -is [pscustomobject]) {
            $names = @($value.PSObject.Properties | ForEach-Object { [string]$_.Name })
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in $names) { if (-not $seen.Add($name)) { Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonDuplicate' -Message "JSON object contains duplicate key '$name'." } }
            [Array]::Sort($names, [StringComparer]::Ordinal)
            [void]$builder.Append('{')
            for ($i = 0; $i -lt $names.Count; $i++) { if ($i -gt 0) { [void]$builder.Append(',') }; & $writeString $names[$i]; [void]$builder.Append(':'); & $writeValue (Get-PshLifecycleProperty -InputObject $value -Name $names[$i]) ($depth + 1) }
            [void]$builder.Append('}'); return
        }
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCanonicalJsonType' -Message "Unsupported JSON value type: $($value.GetType().FullName)"
    }
    & $writeValue $InputObject 0
    return $builder.ToString()
}

function Get-PshCanonicalJsonSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $InputObject)
    return Get-PshLifecycleSha256Bytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-PshCanonicalJson -InputObject $InputObject)))
}

function Write-PshCanonicalJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowNull()][object] $InputObject
    )

    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshAtomicPath' -Message "Invalid atomic JSON path: $Path" -InnerException $_.Exception }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrEmpty($parent)) { Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshAtomicPath' -Message "Atomic JSON path has no parent directory: $Path" }
    if (-not [IO.Directory]::Exists($parent)) {
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshAtomicParent' -Message "Atomic JSON parent directory does not exist: $parent"
    }
    $parentEntry = Get-PshLifecyclePathEntry -Path $parent -Description 'atomic JSON parent directory'
    if (-not [bool]$parentEntry.Exists -or -not [bool]$parentEntry.IsDirectory) {
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshAtomicParent' -Message "Atomic JSON parent directory does not exist: $parent"
    }
    if ([bool]$parentEntry.IsReparsePoint) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Atomic JSON parent must not be a reparse point: $parent"
    }
    $destinationEntry = Get-PshLifecyclePathEntry -Path $fullPath -Description 'atomic JSON destination'
    if ([bool]$destinationEntry.Exists) {
        if ([bool]$destinationEntry.IsReparsePoint) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Atomic JSON destination must not be a reparse point: $fullPath"
        }
        if (-not [bool]$destinationEntry.IsRegularFile) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshNotRegularFile' -Message "Atomic JSON destination must be a regular file: $fullPath"
        }
    }
    $json = (ConvertTo-PshCanonicalJson -InputObject $InputObject) + "`n"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $operationId = ([Guid]::NewGuid()).ToString('N')
    $temporaryPath = Join-Path $parent ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($fullPath)), $operationId)
    $backupPath = Join-Path $parent ('.{0}.{1}.bak' -f ([IO.Path]::GetFileName($fullPath)), $operationId)
    $temporaryOwned = $true
    $expectedTemporarySha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes
    $expectedBackupSha256 = $null
    if ([IO.File]::Exists($fullPath)) { $expectedBackupSha256 = (Get-PshLifecycleFileSha256 -Path $fullPath).Sha256 }
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
            if (-not [IO.File]::Exists($backupPath) -or (Get-PshLifecycleFileSha256 -Path $backupPath).Sha256 -cne $expectedBackupSha256) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshAtomicBackupMismatch' -Message "Atomic JSON backup did not match the pre-write bytes: $fullPath"
            }
        }
        else { [IO.File]::Move($temporaryPath, $fullPath) }
        if (-not [IO.File]::Exists($fullPath) -or (Get-PshLifecycleFileSha256 -Path $fullPath).Sha256 -cne $expectedTemporarySha256) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshAtomicTargetMismatch' -Message "Atomic JSON destination did not retain the transaction bytes: $fullPath"
        }
        $temporaryOwned = $false
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshAtomicWriteFailed' -Message "Unable to atomically write JSON: $fullPath" -InnerException $_.Exception
    }
    finally {
        if ($temporaryOwned -and [IO.File]::Exists($temporaryPath)) {
            try { if ((Get-PshLifecycleFileSha256 -Path $temporaryPath).Sha256 -ceq $expectedTemporarySha256) { [IO.File]::Delete($temporaryPath) } } catch {}
        }
        if ([IO.File]::Exists($backupPath)) {
            try { if (-not [string]::IsNullOrWhiteSpace($expectedBackupSha256) -and (Get-PshLifecycleFileSha256 -Path $backupPath).Sha256 -ceq $expectedBackupSha256) { [IO.File]::Delete($backupPath) } } catch {}
        }
    }
    return [pscustomobject][ordered]@{ Path = $fullPath; Length = [int64]$bytes.Length; Sha256 = Get-PshLifecycleSha256Bytes -Bytes $bytes }
}

function Get-PshInstallRootMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    try {
        $normalized = Get-PshLifecycleNormalizedRoot -Path $InstallRoot
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $normalized = $normalized.ToUpperInvariant() }
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshLockPath' -Message "Invalid install root for locking: $InstallRoot" -InnerException $_.Exception
    }
    return 'Psh.InstallRoot.' + (Get-PshLifecycleSha256Bytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($normalized)))
}

function Enter-PshInstallRootLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter()][ValidateRange(1, 300000)][int] $TimeoutMilliseconds = 30000
    )
    $name = Get-PshInstallRootMutexName -InstallRoot $InstallRoot
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { Throw-PshLifecycleError -ExitCode 3 -Kind 'Lock' -ErrorId 'PshLockTimeout' -Message "Timed out waiting for the Psh install root lock: $InstallRoot" }
        return [pscustomobject][ordered]@{ Mutex = $mutex; Acquired = $true; Name = $name; InstallRoot = Get-PshLifecycleNormalizedRoot -Path $InstallRoot }
    }
    catch {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Lock' -ErrorId 'PshLockFailed' -Message "Unable to acquire the Psh install root lock: $InstallRoot" -InnerException $_.Exception
    }
}

function Exit-PshInstallRootLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject] $Lock)
    try {
        if ([bool]$Lock.Acquired) { $Lock.Mutex.ReleaseMutex(); $Lock.Acquired = $false }
    }
    catch { Throw-PshLifecycleError -ExitCode 3 -Kind 'Lock' -ErrorId 'PshLockReleaseFailed' -Message 'Unable to release the Psh install root lock.' -InnerException $_.Exception }
    finally { try { $Lock.Mutex.Dispose() } catch {} }
}

function Get-PshLifecycleStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][ValidateSet('ownership', 'transaction')][string] $Kind)
    return Join-Path (Get-PshLifecycleNormalizedRoot -Path $InstallRoot) $(if ($Kind -ceq 'ownership') { 'ownership.json' } else { 'transaction.json' })
}

function Get-PshLifecycleNormalizedRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        if (-not (Test-PshLifecycleAbsoluteRootedPath -Path $Path)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRoot' -Message "Lifecycle root must be an absolute rooted path: $Path"
        }
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRoot' -Message "Lifecycle root has no filesystem root: $Path"
        }

        # Check every existing component. A missing leaf is valid, but no
        # existing directory in the target chain may be a symlink/reparse.
        $probe = $full
        $comparison = Get-PshLifecyclePathComparison
        while ($true) {
            $entry = Get-PshLifecyclePathEntry -Path $probe -Description 'lifecycle root component'
            if ([bool]$entry.Exists) {
                if ([bool]$entry.IsReparsePoint) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Lifecycle root component must not be a reparse point: $probe"
                }
                if (-not [bool]$entry.IsDirectory) {
                    Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRoot' -Message "Lifecycle root component must be a directory: $probe"
                }
            }
            $parent = [IO.Path]::GetDirectoryName($probe)
            if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $probe, $comparison)) { break }
            $probe = $parent
        }
        if ($full.Length -gt $root.Length) {
            $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        }
        return $full
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshInvalidRoot' -Message "Invalid lifecycle root: $Path" -InnerException $_.Exception
    }
}

function Test-PshLifecycleAbsoluteRootedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Path)

    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Path)) { return $false }
    try {
        if (-not [IO.Path]::IsPathRooted([string]$Path)) { return $false }
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            return ([string]$Path -cmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))')
        }
        return ([string]$Path).StartsWith([string][IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
    }
    catch { return $false }
}

function Get-PshLifecyclePathComparison {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Assert-PshLifecycleNoPathOverlap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]] $Paths)

    $comparison = Get-PshLifecyclePathComparison
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Paths)) {
        if ($null -eq $item) { continue }
        $path = [string](Get-PshLifecycleProperty $item 'Path')
        $category = [string](Get-PshLifecycleProperty $item 'Category')
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($category)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipPathOverlap' -Message 'Ownership path metadata is incomplete.'
        }
        $normalizedPath = $path.TrimEnd('/')
        [void]$normalized.Add([pscustomobject]@{ Path = $normalizedPath; Category = $category })
    }
    for ($i = 0; $i -lt $normalized.Count; $i++) {
        for ($j = $i + 1; $j -lt $normalized.Count; $j++) {
            $left = [string]$normalized[$i].Path
            $right = [string]$normalized[$j].Path
            $leftPrefix = $left + '/'
            $rightPrefix = $right + '/'
            if ([string]::Equals($left, $right, $comparison) -or
                $left.StartsWith($rightPrefix, $comparison) -or $right.StartsWith($leftPrefix, $comparison)) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipPathOverlap' -Message "Ownership paths overlap: '$left' and '$right'."
            }
        }
    }
}

function Assert-PshStableFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $State,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter()][AllowNull()][System.Collections.Generic.HashSet[string]] $Seen
    )

    $keys = @(
        'relativePath', 'disposition', 'originalExisted', 'originalLength',
        'originalSha256', 'backupFileName', 'installedLength', 'installedSha256'
    )
    Assert-PshLifecycleAllowedProperties -InputObject $State -Allowed $keys -Description $Description
    Assert-PshLifecycleRequiredProperties -InputObject $State -Required $keys -Description $Description
    $relativePath = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $State 'relativePath') -Description "$Description relativePath" -Seen $Seen
    $disposition = Get-PshLifecycleProperty $State 'disposition'
    if ($disposition -isnot [string] -or [string]$disposition -cnotin @('created', 'reused', 'replaced')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipDisposition' -Message "$Description disposition is invalid."
    }
    $originalExisted = Get-PshLifecycleProperty $State 'originalExisted'
    if ($originalExisted -isnot [bool]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipOriginal' -Message "$Description originalExisted must be boolean."
    }
    $originalLength = Get-PshLifecycleProperty $State 'originalLength'
    $originalSha = Get-PshLifecycleProperty $State 'originalSha256'
    $backupName = Get-PshLifecycleProperty $State 'backupFileName'
    if ([bool]$originalExisted) {
        $originalLength = [int64](Assert-PshLifecycleInteger -Value $originalLength -Description "$Description originalLength" -NonNegative)
        $originalSha = Assert-PshLifecycleSha256 -Value $originalSha -Description "$Description originalSha256"
        if ([string]$disposition -ceq 'created') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipOriginal' -Message "$Description cannot be created when originalExisted=true."
        }
    }
    else {
        if ($null -ne $originalLength -or $null -ne $originalSha) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipOriginal' -Message "$Description original length and SHA256 must be null when originalExisted=false."
        }
        if ([string]$disposition -cne 'created') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipOriginal' -Message "$Description must be created when originalExisted=false."
        }
    }
    if ($null -ne $backupName) {
        $backupName = Assert-PshLifecycleRelativePath -Value $backupName -Description "$Description backupFileName"
        if ($backupName.Contains('/')) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipBackup' -Message "$Description backupFileName must be a file name, not a path."
        }
    }
    if ([string]$disposition -ceq 'replaced' -and [bool]$originalExisted -and $null -eq $backupName) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipBackup' -Message "$Description replaced content requires a backupFileName."
    }
    if ([string]$disposition -cne 'replaced' -and $null -ne $backupName) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipBackup' -Message "$Description backupFileName is only valid for replaced content."
    }
    [void](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $State 'installedLength') -Description "$Description installedLength" -NonNegative)
    [void](Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $State 'installedSha256') -Description "$Description installedSha256")
    return $relativePath
}

function Assert-PshOwnershipVersionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $SeenVersions,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]] $SeenRoots
    )

    $keys = @(
        'version', 'edition', 'architecture', 'relativeRoot', 'archiveSha256',
        'packageManifestSha256', 'treeSha256', 'files'
    )
    Assert-PshLifecycleAllowedProperties -InputObject $State -Allowed $keys -Description 'ownership version record'
    Assert-PshLifecycleRequiredProperties -InputObject $State -Required $keys -Description 'ownership version record'
    $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $State 'version') -Description 'ownership version'
    if (-not $SeenVersions.Add($version)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipDuplicateVersion' -Message "ownership contains duplicate version '$version'."
    }
    $edition = Get-PshLifecycleProperty $State 'edition'
    $architecture = Get-PshLifecycleProperty $State 'architecture'
    if ($edition -isnot [string] -or [string]$edition -cnotin @('Core', 'Full')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipEdition' -Message "ownership version '$version' has an invalid edition."
    }
    if ($architecture -isnot [string] -or
        ([string]$edition -ceq 'Core' -and [string]$architecture -cne 'any') -or
        ([string]$edition -ceq 'Full' -and [string]$architecture -cnotmatch $script:PshLifecycleRidPattern)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipArchitecture' -Message "ownership version '$version' has an invalid architecture."
    }
    $relativeRoot = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $State 'relativeRoot') -Description "ownership version '$version' relativeRoot" -Seen $SeenRoots
    if ($relativeRoot -cne ('versions/' + $version)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipVersionRoot' -Message "ownership version '$version' relativeRoot must be exactly 'versions/$version'."
    }
    [void](Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $State 'archiveSha256') -Description "ownership version '$version' archiveSha256" -AllowNull)
    [void](Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $State 'packageManifestSha256') -Description "ownership version '$version' packageManifestSha256")
    $treeSha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $State 'treeSha256') -Description "ownership version '$version' treeSha256"
    $files = Get-PshLifecycleProperty $State 'files'
    if ($files -isnot [System.Array] -or @($files).Count -eq 0) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipFiles' -Message "ownership version '$version' files must be a non-empty array."
    }
    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $digestFiles = New-Object System.Collections.Generic.List[object]
    foreach ($file in @($files)) {
        Assert-PshLifecycleAllowedProperties -InputObject $file -Allowed @('relativePath', 'length', 'sha256') -Description "ownership version '$version' file"
        Assert-PshLifecycleRequiredProperties -InputObject $file -Required @('relativePath', 'length', 'sha256') -Description "ownership version '$version' file"
        $relative = Assert-PshLifecycleRelativePath -Value (Get-PshLifecycleProperty $file 'relativePath') -Description "ownership version '$version' file relativePath" -Seen $seenFiles
        $length = [int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $file 'length') -Description "ownership version '$version' file length" -NonNegative)
        $sha = Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $file 'sha256') -Description "ownership version '$version' file SHA256"
        [void]$digestFiles.Add([pscustomobject]@{ relativePath = $relative; length = $length; sha256 = $sha })
    }
    $calculatedTree = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = @($digestFiles.ToArray()) })
    if ($calculatedTree -cne $treeSha) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipTree' -Message "ownership version '$version' treeSha256 does not match its files."
    }
    return [pscustomobject]@{ Version = $version; RelativeRoot = $relativeRoot }
}

function Assert-PshOwnershipDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $State,
        [Parameter(Mandatory = $true)][string] $InstallRoot
    )

    Assert-PshLifecycleAllowedProperties -InputObject $State -Allowed $script:PshLifecycleOwnershipKeys -Description 'ownership state'
    Assert-PshLifecycleRequiredProperties -InputObject $State -Required $script:PshLifecycleOwnershipKeys -Description 'ownership state'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $State 'schemaVersion') -Description 'ownership schemaVersion' -NonNegative) -ne 1 -or
        [string](Get-PshLifecycleProperty $State 'product') -cne 'Psh') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipSchema' -Message 'ownership state schema is unsupported.'
    }
    $root = Get-PshLifecycleNormalizedRoot -Path $InstallRoot
    $stateRoot = Get-PshLifecycleProperty $State 'installRoot'
    if (-not (Test-PshLifecycleAbsoluteRootedPath -Path $stateRoot)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipRoot' -Message 'ownership installRoot must be an absolute rooted path.'
    }
    $comparison = Get-PshLifecyclePathComparison
    try { $normalizedStateRoot = if ($stateRoot -is [string]) { Get-PshLifecycleNormalizedRoot -Path ([string]$stateRoot) } else { $null } }
    catch { $normalizedStateRoot = $null }
    if ($null -eq $normalizedStateRoot -or -not [string]::Equals($normalizedStateRoot, $root, $comparison)) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipRoot' -Message 'ownership installRoot does not match the requested root.'
    }
    if ($State -is [System.Collections.IDictionary]) { $State['installRoot'] = $root }
    else { $State.PSObject.Properties['installRoot'].Value = $root }

    $stableFiles = Get-PshLifecycleProperty $State 'stableFiles'
    if ($stableFiles -isnot [System.Array]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipStableFiles' -Message 'ownership stableFiles must be an array.'
    }
    $ownershipPaths = New-Object System.Collections.Generic.List[object]
    $seenStable = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($stable in @($stableFiles)) {
        $stablePath = Assert-PshStableFileState -State $stable -Description 'ownership stable file' -Seen $seenStable
        if ($stablePath -cnotin @('bootstrap.ps1', 'uninstall.ps1', 'psh-installer.exe')) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipStablePath' -Message "Unsupported stable-file ownership path: $stablePath"
        }
        [void]$ownershipPaths.Add([pscustomobject]@{ Path = $stablePath; Category = 'stable' })
    }
    $config = Get-PshLifecycleProperty $State 'config'
    $configPath = Assert-PshStableFileState -State $config -Description 'ownership config'
    if ($configPath -cne 'config.psd1') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipConfigPath' -Message "ownership config relativePath must be exactly 'config.psd1'."
    }
    [void]$ownershipPaths.Add([pscustomobject]@{ Path = $configPath; Category = 'config' })

    $versions = Get-PshLifecycleProperty $State 'versions'
    if ($versions -isnot [System.Array]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipVersions' -Message 'ownership versions must be an array.'
    }
    $seenVersions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($versionState in @($versions)) {
        $validatedVersion = Assert-PshOwnershipVersionState -State $versionState -SeenVersions $seenVersions -SeenRoots $seenRoots
        [void]$ownershipPaths.Add([pscustomobject]@{ Path = [string]$validatedVersion.RelativeRoot; Category = 'version' })
    }
    $active = Get-PshLifecycleProperty $State 'activeVersion'
    if ($null -ne $active) {
        $active = Assert-PshLifecycleSemVer -Value $active -Description 'ownership activeVersion'
        if (-not $seenVersions.Contains($active)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipActiveVersion' -Message 'ownership activeVersion is not present in versions.'
        }
    }

    $rollback = Get-PshLifecycleProperty $State 'rollbackOrder'
    if ($rollback -isnot [System.Array]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipRollback' -Message 'ownership rollbackOrder must be an array.'
    }
    $seenRollback = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($rollbackVersion in @($rollback)) {
        $rollbackVersion = Assert-PshLifecycleSemVer -Value $rollbackVersion -Description 'ownership rollback version'
        if (-not $seenRollback.Add($rollbackVersion) -or -not $seenVersions.Contains($rollbackVersion)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipRollback' -Message "ownership rollbackOrder contains an invalid or duplicate version '$rollbackVersion'."
        }
    }

    $components = Get-PshLifecycleProperty $State 'components'
    Assert-PshLifecycleAllowedProperties -InputObject $components -Allowed @('profile', 'psReadLineProjection') -Description 'ownership components'
    Assert-PshLifecycleRequiredProperties -InputObject $components -Required @('profile', 'psReadLineProjection') -Description 'ownership components'
    foreach ($componentName in @('profile', 'psReadLineProjection')) {
        $component = Get-PshLifecycleProperty $components $componentName
        Assert-PshLifecycleAllowedProperties -InputObject $component -Allowed @('stateRelativePath', 'installed') -Description "ownership component '$componentName'"
        Assert-PshLifecycleRequiredProperties -InputObject $component -Required @('stateRelativePath', 'installed') -Description "ownership component '$componentName'"
        $expectedPath = if ($componentName -ceq 'profile') { 'profile-state' } else { 'psreadline-projection-state' }
        if ([string](Get-PshLifecycleProperty $component 'stateRelativePath') -cne $expectedPath -or
            (Get-PshLifecycleProperty $component 'installed') -isnot [bool]) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipComponent' -Message "ownership component '$componentName' is invalid."
        }
        [void]$ownershipPaths.Add([pscustomobject]@{ Path = $expectedPath; Category = 'component' })
    }
    foreach ($metadataPath in @('current.json', 'ownership.json', 'transaction.json', '.lifecycle', '.staging', '.quarantine')) {
        [void]$ownershipPaths.Add([pscustomobject]@{ Path = $metadataPath; Category = 'metadata' })
    }
    Assert-PshLifecycleNoPathOverlap -Paths $ownershipPaths.ToArray()
    return $State
}

function Read-PshOwnershipState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $snapshot = Read-PshLifecycleStateSnapshot -InstallRoot $InstallRoot -Kind ownership
    if ($null -eq $snapshot) { return $null }
    return (, $snapshot.Document)
}

function Write-PshOwnershipState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][AllowNull()][object] $State)
    $path = Get-PshLifecycleStatePath -InstallRoot $InstallRoot -Kind ownership
    if ($null -eq $State) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshOwnershipNull' -Message 'Write-PshOwnershipState requires a non-null state. Use Remove-PshOwnershipState to remove it.'
    }
    $validated = Assert-PshOwnershipDocument -State $State -InstallRoot $InstallRoot
    return Write-PshCanonicalJsonAtomic -Path $path -InputObject $validated
}

function Read-PshLifecycleStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ownership', 'transaction')][string] $Kind
    )

    $path = Get-PshLifecycleStatePath -InstallRoot $InstallRoot -Kind $Kind
    $description = if ($Kind -ceq 'ownership') { 'ownership state' } else { 'transaction state' }
    $snapshot = Read-PshStrictJsonSnapshot -Path $path -Description $description -AllowMissing
    if ($null -eq $snapshot) { return $null }
    $validated = if ($Kind -ceq 'ownership') {
        Assert-PshOwnershipDocument -State $snapshot.Document -InstallRoot $InstallRoot
    }
    else {
        Assert-PshTransactionDocument -State $snapshot.Document
    }
    return [pscustomobject][ordered]@{
        Path = $snapshot.Path
        Bytes = $snapshot.Bytes
        Length = $snapshot.Length
        Sha256 = $snapshot.Sha256
        ActiveVersion = if ($Kind -ceq 'ownership') { Get-PshLifecycleProperty $validated 'activeVersion' } else { $null }
        Document = $validated
    }
}

function Remove-PshLifecycleStateFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ownership', 'transaction')][string] $Kind
    )
    $Path = Get-PshLifecycleStatePath -InstallRoot $InstallRoot -Kind $Kind
    $entry = Get-PshLifecyclePathEntry -Path $Path -Description 'lifecycle state'
    if (-not [bool]$entry.Exists) {
        return [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Removed = $false }
    }
    if ([bool]$entry.IsReparsePoint) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshReparsePoint' -Message "Lifecycle state must not be a reparse point: $Path"
    }
    if (-not [bool]$entry.IsRegularFile) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshNotRegularFile' -Message "Lifecycle state must be a regular file: $Path"
    }
    try {
        [IO.File]::Delete($Path)
    }
    catch {
        if (Test-PshLifecycleExceptionMetadata $_) { throw }
        Throw-PshLifecycleError -ExitCode 3 -Kind 'Io' -ErrorId 'PshStateDeleteFailed' -Message "Unable to remove lifecycle state: $Path" -InnerException $_.Exception
    }
    return [pscustomobject][ordered]@{ Path = [IO.Path]::GetFullPath($Path); Removed = $true }
}

function Get-PshLifecycleStateSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet('ownership', 'transaction')][string] $Kind
    )
    $snapshot = Read-PshLifecycleStateSnapshot -InstallRoot $InstallRoot -Kind $Kind
    if ($null -eq $snapshot) { return $null }
    return [string]$snapshot.Sha256
}

function Get-PshOwnershipStateSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return Get-PshLifecycleStateSha256 -InstallRoot $InstallRoot -Kind ownership
}

function Get-PshTransactionStateSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return Get-PshLifecycleStateSha256 -InstallRoot $InstallRoot -Kind transaction
}

function Remove-PshOwnershipState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return Remove-PshLifecycleStateFile -InstallRoot $InstallRoot -Kind ownership
}

function Read-PshTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    $snapshot = Read-PshLifecycleStateSnapshot -InstallRoot $InstallRoot -Kind transaction
    if ($null -eq $snapshot) { return $null }
    return (, $snapshot.Document)
}

function Assert-PshTransactionDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $State)

    Assert-PshLifecycleAllowedProperties -InputObject $State -Allowed $script:PshLifecycleTransactionKeys -Description 'transaction state'
    Assert-PshLifecycleRequiredProperties -InputObject $State -Required $script:PshLifecycleTransactionKeys -Description 'transaction state'
    if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $State 'schemaVersion') -Description 'transaction schemaVersion' -NonNegative) -ne 1 -or
        [string](Get-PshLifecycleProperty $State 'product') -cne 'Psh') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionSchema' -Message 'transaction state schema is unsupported.'
    }
    $id = Get-PshLifecycleProperty $State 'transactionId'
    if ($id -isnot [string] -or [string]$id -cnotmatch '\A[0-9a-f]{32}\z') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionId' -Message 'transactionId must be a lowercase 32-hex GUID in N form.'
    }
    $operation = [string](Get-PshLifecycleProperty $State 'operation')
    if ($operation -cnotin @('install', 'upgrade', 'rollback', 'uninstall')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOperation' -Message 'transaction operation is invalid.'
    }
    $phase = Get-PshLifecycleProperty $State 'phase'
    if ($phase -isnot [string] -or [string]$phase -cnotin @('staged', 'published', 'switched')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionPhase' -Message 'transaction phase must be staged, published, or switched.'
    }
    $old = Get-PshLifecycleProperty $State 'oldCurrent'
    Assert-PshLifecycleAllowedProperties -InputObject $old -Allowed @('exists', 'version', 'sha256') -Description 'transaction oldCurrent'
    Assert-PshLifecycleRequiredProperties -InputObject $old -Required @('exists', 'version', 'sha256') -Description 'transaction oldCurrent'
    $oldExists = Get-PshLifecycleProperty $old 'exists'
    if ($oldExists -isnot [bool]) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOldCurrent' -Message 'oldCurrent.exists must be boolean.'
    }
    if ([bool]$oldExists) {
        [void](Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $old 'version') -Description 'oldCurrent.version')
        [void](Assert-PshLifecycleSha256 -Value (Get-PshLifecycleProperty $old 'sha256') -Description 'oldCurrent.sha256')
    }
    elseif ($null -ne (Get-PshLifecycleProperty $old 'version') -or $null -ne (Get-PshLifecycleProperty $old 'sha256')) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOldCurrent' -Message 'oldCurrent version and sha256 must be null when exists=false.'
    }
    $target = Get-PshLifecycleProperty $State 'targetVersion'
    if ($null -ne $target) { $target = Assert-PshLifecycleSemVer -Value $target -Description 'transaction targetVersion' }
    $stagePath = Get-PshLifecycleProperty $State 'stageRelativePath'
    $publishedPath = Get-PshLifecycleProperty $State 'publishedRelativePath'
    if ($null -ne $stagePath) { $stagePath = Assert-PshLifecycleRelativePath -Value $stagePath -Description 'transaction stageRelativePath' }
    if ($null -ne $publishedPath) { $publishedPath = Assert-PshLifecycleRelativePath -Value $publishedPath -Description 'transaction publishedRelativePath' }
    $beforeOwnership = Get-PshLifecycleProperty $State 'ownershipBeforeSha256'
    if ($null -ne $beforeOwnership) { $beforeOwnership = Assert-PshLifecycleSha256 -Value $beforeOwnership -Description 'transaction ownershipBeforeSha256' }

    if ($operation -in @('install', 'upgrade')) {
        if ($null -eq $target) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionTarget' -Message "$operation transactions require targetVersion."
        }
        if ($null -eq $stagePath -or [string]$stagePath -cne ('.staging/' + [string]$id)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionStagePath' -Message "$operation transactions require stageRelativePath .staging/<transactionId>."
        }
        if ($phase -in @('published', 'switched') -and ($null -eq $publishedPath -or $publishedPath -cne ('versions/' + [string]$target))) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionPublishedPath' -Message "$operation $phase transactions require publishedRelativePath versions/$target."
        }
        if ($phase -eq 'staged' -and $null -ne $publishedPath -and $publishedPath -cne ('versions/' + [string]$target)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionPublishedPath' -Message "$operation staged publishedRelativePath must be versions/$target when present."
        }
        if ($operation -ceq 'upgrade') {
            if (-not [bool]$oldExists -or [string](Get-PshLifecycleProperty $old 'version') -ceq [string]$target) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOldCurrent' -Message 'upgrade transactions require an existing different oldCurrent version.'
            }
            if ($null -eq $beforeOwnership) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOwnershipBefore' -Message 'upgrade transactions require ownershipBeforeSha256.'
            }
        }
        elseif ([bool]$oldExists -and [string](Get-PshLifecycleProperty $old 'version') -cne [string]$target) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOperation' -Message 'install transactions cannot replace a different current version; use upgrade.'
        }
    }
    elseif ($operation -ceq 'rollback') {
        if ($null -eq $target) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionTarget' -Message 'rollback transactions require targetVersion.'
        }
        if ([bool]$oldExists -eq $false -or [string](Get-PshLifecycleProperty $old 'version') -ceq [string]$target) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOldCurrent' -Message 'rollback transactions require an existing different oldCurrent version.'
        }
        if ($null -ne $stagePath -or $publishedPath -cne ('versions/' + [string]$target)) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionRollbackPaths' -Message 'rollback transactions require null stageRelativePath and publishedRelativePath versions/<target>.'
        }
        if ($phase -ceq 'published') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionPhase' -Message 'rollback transactions do not have a published phase.'
        }
        if ($null -eq $beforeOwnership) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionOwnershipBefore' -Message 'rollback transactions require ownershipBeforeSha256.'
        }
    }
    else {
        if ($null -ne $target -or $null -ne $stagePath -or $null -ne $publishedPath -or $null -eq $beforeOwnership) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionUninstallShape' -Message 'uninstall transactions require null target/path fields and ownershipBeforeSha256.'
        }
        if ($phase -cne 'staged') {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionPhase' -Message 'uninstall transactions only support the staged phase.'
        }
    }
    $startedValue = Get-PshLifecycleProperty $State 'startedUtc'
    if ($startedValue -is [DateTimeOffset]) {
        $started = $startedValue.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($startedValue -is [DateTime]) {
        $started = $startedValue.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        $started = [string]$startedValue
    }
    if ([string]::IsNullOrEmpty($started) -or $started -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?Z\z') {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionTimestamp' -Message 'transaction startedUtc must be an exact UTC ISO-8601 timestamp.'
    }
    try {
        [void][DateTimeOffset]::Parse([string]$started, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    }
    catch {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionTimestamp' -Message 'transaction startedUtc is not a valid timestamp.' -InnerException $_.Exception
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        product = 'Psh'
        transactionId = [string]$id
        operation = $operation
        phase = [string]$phase
        oldCurrent = [pscustomobject][ordered]@{
            exists = [bool]$oldExists
            version = if ([bool]$oldExists) { [string](Get-PshLifecycleProperty $old 'version') } else { $null }
            sha256 = if ([bool]$oldExists) { [string](Get-PshLifecycleProperty $old 'sha256') } else { $null }
        }
        targetVersion = if ($null -ne $target) { [string]$target } else { $null }
        stageRelativePath = if ($null -ne $stagePath) { [string]$stagePath } else { $null }
        publishedRelativePath = if ($null -ne $publishedPath) { [string]$publishedPath } else { $null }
        ownershipBeforeSha256 = if ($null -ne $beforeOwnership) { [string]$beforeOwnership } else { $null }
        startedUtc = $started
    }
}

function Write-PshTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot, [Parameter(Mandatory = $true)][AllowNull()][object] $State)
    $path = Get-PshLifecycleStatePath -InstallRoot $InstallRoot -Kind transaction
    if ($null -eq $State) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshTransactionNull' -Message 'Write-PshTransactionState requires a non-null state. Use Remove-PshTransactionState to remove it.'
    }
    $validated = Assert-PshTransactionDocument -State $State
    return Write-PshCanonicalJsonAtomic -Path $path -InputObject $validated
}

function Remove-PshTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)
    return Remove-PshLifecycleStateFile -InstallRoot $InstallRoot -Kind transaction
}

function Get-PshRecoveryCurrentObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)

    $root = Get-PshLifecycleNormalizedRoot -Path $InstallRoot
    if (-not [IO.Directory]::Exists($root)) {
        return [pscustomobject][ordered]@{ Available = $false; Exists = $false; Version = $null; Sha256 = $null; Reason = 'Install root is missing.' }
    }
    $path = Join-Path $root 'current.json'
    try {
        $snapshot = Read-PshStrictJsonSnapshot -Path $path -Description 'current state' -AllowMissing -RequireLf
        if ($null -eq $snapshot) {
            return [pscustomobject][ordered]@{ Available = $true; Exists = $false; Version = $null; Sha256 = $null; Reason = 'current.json is absent.' }
        }
        $document = $snapshot.Document
        Assert-PshLifecycleAllowedProperties -InputObject $document -Allowed @('schemaVersion', 'version') -Description 'current state'
        Assert-PshLifecycleRequiredProperties -InputObject $document -Required @('schemaVersion', 'version') -Description 'current state'
        if ([int64](Assert-PshLifecycleInteger -Value (Get-PshLifecycleProperty $document 'schemaVersion') -Description 'current schemaVersion' -NonNegative) -ne 1) {
            Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshCurrentSchema' -Message 'current schemaVersion must be 1.'
        }
        $version = Assert-PshLifecycleSemVer -Value (Get-PshLifecycleProperty $document 'version') -Description 'current version'
        return [pscustomobject][ordered]@{ Available = $true; Exists = $true; Version = $version; Sha256 = [string]$snapshot.Sha256; Reason = 'current.json verified.' }
    }
    catch {
        return [pscustomobject][ordered]@{ Available = $false; Exists = $true; Version = $null; Sha256 = $null; Reason = 'current.json could not be verified.' }
    }
}

function Get-PshLifecycleCanonicalCurrentSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Version)

    $bytes = Get-PshLifecycleCanonicalCurrentBytes -Version $Version
    return Get-PshLifecycleSha256Bytes -Bytes $bytes
}

function Get-PshLifecycleCanonicalCurrentBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Version)

    $validated = Assert-PshLifecycleSemVer -Value $Version -Description 'target current version'
    $document = [ordered]@{ schemaVersion = 1; version = $validated }
    $json = (ConvertTo-PshCanonicalJson -InputObject $document) + "`n"
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    return (,$bytes)
}

function Get-PshRecoveryOwnershipObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $InstallRoot)

    $root = Get-PshLifecycleNormalizedRoot -Path $InstallRoot
    if (-not [IO.Directory]::Exists($root)) {
        return [pscustomobject][ordered]@{ Available = $false; Exists = $false; Sha256 = $null; ActiveVersion = $null; Reason = 'Install root is missing.' }
    }
    try {
        $snapshot = Read-PshLifecycleStateSnapshot -InstallRoot $root -Kind ownership
        if ($null -eq $snapshot) {
            return [pscustomobject][ordered]@{ Available = $true; Exists = $false; Sha256 = $null; ActiveVersion = $null; Reason = 'ownership.json is absent.' }
        }
        return [pscustomobject][ordered]@{
            Available = $true
            Exists = $true
            Sha256 = [string]$snapshot.Sha256
            ActiveVersion = if ($null -ne $snapshot.ActiveVersion) { [string]$snapshot.ActiveVersion } else { $null }
            Reason = 'ownership.json verified.'
        }
    }
    catch {
        return [pscustomobject][ordered]@{ Available = $false; Exists = $true; Sha256 = $null; ActiveVersion = $null; Reason = 'ownership.json could not be verified.' }
    }
}

function New-PshRecoveryResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('None', 'DiscardStage', 'RemovePublished', 'CompleteCommit', 'Inspect')][string] $Action,
        [Parameter(Mandatory = $true)][bool] $Safe,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter()][AllowNull()][string] $TargetVersion,
        [Parameter()][AllowNull()][string] $ActualCurrentVersion,
        [Parameter()][AllowNull()][string] $ActualOwnershipSha256
    )
    return [pscustomobject][ordered]@{
        Action = $Action
        Safe = $Safe
        Reason = $Reason
        TargetVersion = $TargetVersion
        ActualCurrentVersion = $ActualCurrentVersion
        ActualOwnershipSha256 = $ActualOwnershipSha256
    }
}

function Get-PshRecoveryDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter()][AllowNull()][object] $Transaction,
        [Parameter()][AllowNull()][string] $CurrentVersion,
        [Parameter()][AllowNull()][string] $CurrentSha256,
        [Parameter()][AllowNull()][string] $OwnershipSha256
    )
    if ($null -eq $Transaction) { $Transaction = Read-PshTransactionState -InstallRoot $InstallRoot }
    if ($null -eq $Transaction) { return [pscustomobject][ordered]@{ Action = 'None'; Safe = $true; Reason = 'No in-flight transaction.' } }
    $Transaction = Assert-PshTransactionDocument -State $Transaction
    $currentVersionSpecified = $PSBoundParameters.ContainsKey('CurrentVersion')
    $currentShaSpecified = $PSBoundParameters.ContainsKey('CurrentSha256')
    $ownershipShaSpecified = $PSBoundParameters.ContainsKey('OwnershipSha256')
    if ($currentShaSpecified -and -not $currentVersionSpecified) {
        Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshRecoveryCurrent' -Message 'CurrentSha256 requires CurrentVersion.'
    }
    if ($currentVersionSpecified) {
        if ([string]::IsNullOrEmpty($CurrentVersion)) {
            if ($currentShaSpecified -and -not [string]::IsNullOrEmpty($CurrentSha256)) {
                Throw-PshLifecycleError -ExitCode 5 -Kind 'Integrity' -ErrorId 'PshRecoveryCurrent' -Message 'CurrentSha256 must be null when CurrentVersion is absent.'
            }
            $current = [pscustomobject][ordered]@{ Available = $true; Exists = $false; Version = $null; Sha256 = $null; Reason = 'Caller reports no current version.' }
        }
        else {
            $currentVersionValue = Assert-PshLifecycleSemVer -Value $CurrentVersion -Description 'CurrentVersion'
            $currentHashValue = if ($currentShaSpecified -and -not [string]::IsNullOrEmpty($CurrentSha256)) { Assert-PshLifecycleSha256 -Value $CurrentSha256 -Description 'CurrentSha256' } else { $null }
            $current = [pscustomobject][ordered]@{ Available = $true; Exists = $true; Version = $currentVersionValue; Sha256 = $currentHashValue; Reason = 'Caller reports current version.' }
        }
    }
    else {
        $current = Get-PshRecoveryCurrentObservation -InstallRoot $InstallRoot
    }
    $ownershipObservation = Get-PshRecoveryOwnershipObservation -InstallRoot $InstallRoot
    if ($ownershipShaSpecified) {
        $ownershipHashValue = if ([string]::IsNullOrEmpty($OwnershipSha256)) { $null } else { Assert-PshLifecycleSha256 -Value $OwnershipSha256 -Description 'OwnershipSha256' }
        $ownership = [pscustomobject][ordered]@{
            Available = [bool]$ownershipObservation.Available
            Exists = ($null -ne $ownershipHashValue)
            Sha256 = $ownershipHashValue
            ActiveVersion = $ownershipObservation.ActiveVersion
            Reason = if ([bool]$ownershipObservation.Available) { 'Caller reports ownership hash; activeVersion was verified from ownership.json.' } else { [string]$ownershipObservation.Reason }
        }
    }
    else {
        $ownership = $ownershipObservation
    }

    $phase = [string](Get-PshLifecycleProperty $Transaction 'phase')
    $operation = [string](Get-PshLifecycleProperty $Transaction 'operation')
    $old = Get-PshLifecycleProperty $Transaction 'oldCurrent'
    $targetValue = Get-PshLifecycleProperty $Transaction 'targetVersion'
    $target = if ($null -ne $targetValue) { [string]$targetValue } else { $null }
    $beforeHash = Get-PshLifecycleProperty $Transaction 'ownershipBeforeSha256'
    $oldExists = [bool](Get-PshLifecycleProperty $old 'exists')
    $oldVersion = if ($oldExists) { [string](Get-PshLifecycleProperty $old 'version') } else { $null }
    $oldHash = if ($oldExists) { [string](Get-PshLifecycleProperty $old 'sha256') } else { $null }
    $oldMatches = $current.Available -and ($current.Exists -eq $oldExists)
    if ($oldMatches -and $oldExists) { $oldMatches = [string]$current.Version -ceq $oldVersion -and [string]$current.Sha256 -ceq $oldHash }
    if ($oldMatches -and -not $oldExists) { $oldMatches = $null -eq $current.Version -and $null -eq $current.Sha256 }
    $targetCanonicalSha = if ($null -ne $target) { Get-PshLifecycleCanonicalCurrentSha256 -Version $target } else { $null }
    $targetMatches = $current.Available -and $null -ne $target -and $current.Exists -and [string]$current.Version -ceq $target -and [string]$current.Sha256 -ceq $targetCanonicalSha
    $ownershipMatches = $false
    if ($ownership.Available) {
        $ownershipMatches = if ($null -eq $beforeHash) { -not $ownership.Exists } else { $ownership.Exists -and [string]$ownership.Sha256 -ceq [string]$beforeHash }
    }
    $ownershipTransitioned = $false
    if ($ownership.Available) {
        $ownershipTransitioned = if ($null -eq $beforeHash) { $ownership.Exists } else { $ownership.Exists -and [string]$ownership.Sha256 -cne [string]$beforeHash }
    }
    $ownershipActiveVersion = if ($ownership.Exists -and $null -ne $ownership.ActiveVersion) { [string]$ownership.ActiveVersion } else { $null }
    $ownershipTargetMatches = $ownership.Available -and $ownership.Exists -and $null -ne $target -and $null -ne $ownershipActiveVersion -and $ownershipActiveVersion -ceq $target
    $actualCurrentVersion = if ($current.Exists) { [string]$current.Version } else { $null }
    $actualOwnershipSha = if ($ownership.Exists) { [string]$ownership.Sha256 } else { $null }
    if (-not $current.Available -or -not $ownership.Available) {
        return New-PshRecoveryResult -Action Inspect -Safe $false -Reason 'Necessary current.json or ownership.json state could not be verified.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
    }
    if ($operation -ceq 'uninstall') {
        return New-PshRecoveryResult -Action Inspect -Safe $false -Reason 'Uninstall recovery requires inspection; the journal does not retain enough restoration data.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
    }
    if ($operation -ceq 'rollback') {
        if ($targetMatches -and $ownershipTransitioned -and $ownershipTargetMatches) {
            return New-PshRecoveryResult -Action CompleteCommit -Safe $true -Reason 'Rollback selected the target and ownership changed; clear the journal.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
        }
        return New-PshRecoveryResult -Action Inspect -Safe $false -Reason 'Rollback current or ownership state does not prove completion.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
    }
    if ($phase -ceq 'staged') {
        if ($oldMatches -and $ownershipMatches) {
            return New-PshRecoveryResult -Action DiscardStage -Safe $true -Reason 'Staging-only transaction still matches its recorded old state.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
        }
        if ($targetMatches -and $ownershipTransitioned -and $ownershipTargetMatches) {
            return New-PshRecoveryResult -Action CompleteCommit -Safe $true -Reason 'Target current and changed ownership prove commit completion.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
        }
    }
    elseif ($phase -ceq 'published') {
        if ($targetMatches -and $ownershipTransitioned -and $ownershipTargetMatches) {
            return New-PshRecoveryResult -Action CompleteCommit -Safe $true -Reason 'Published transaction already selected the target and committed ownership.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
        }
        if ($oldMatches -and $ownershipMatches) {
            return New-PshRecoveryResult -Action RemovePublished -Safe $true -Reason 'Published transaction still matches its recorded old state.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
        }
    }
    elseif ($phase -ceq 'switched' -and $targetMatches -and $ownershipTransitioned -and $ownershipTargetMatches) {
        return New-PshRecoveryResult -Action CompleteCommit -Safe $true -Reason 'Switched transaction matches target current and changed ownership.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
    }
    return New-PshRecoveryResult -Action Inspect -Safe $false -Reason 'Actual current and ownership state do not prove a safe automatic recovery.' -TargetVersion $target -ActualCurrentVersion $actualCurrentVersion -ActualOwnershipSha256 $actualOwnershipSha
}
