# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0

$script:PshProfileStartMarker = '# >>> Psh managed profile >>>'
$script:PshProfileEndMarker = '# <<< Psh managed profile <<<'
$script:PshProfileManifestName = 'manifest.json'
$script:PshProfileBackupDirectoryName = 'backups'

function Get-PshCanonicalProfileBlockLine {
    [CmdletBinding()]
    param()

    return @(
        $script:PshProfileStartMarker
        '$null = & {'
        '    try {'
        '        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {'
        '            return'
        '        }'
        '        $pshBootstrap = Join-Path -Path $env:LOCALAPPDATA -ChildPath ''Psh\bootstrap.ps1'''
        '        if (-not (Test-Path -LiteralPath $pshBootstrap -PathType Leaf)) {'
        '            return'
        '        }'
        '        . $pshBootstrap'
        '        if ($null -ne (Get-Command -Name Initialize-PshInteractive -CommandType Function -ErrorAction Ignore)) {'
        '            $pshInteractive = Initialize-PshInteractive -EnablePrompt'
        '            if ($null -eq $pshInteractive -or -not [bool]$pshInteractive.success) {'
        '                $pshInteractiveError = @($pshInteractive.errors) -join ''; '''
        '                if ([string]::IsNullOrWhiteSpace($pshInteractiveError)) {'
        '                    $pshInteractiveError = ''unknown failure'''
        '                }'
        '                Write-Warning (''Psh interactive initialization reported a failure: {0}'' -f $pshInteractiveError) -WarningAction Continue'
        '            }'
        '        }'
        '        else {'
        '            Write-Warning ''Psh bootstrap loaded, but Initialize-PshInteractive is unavailable.'' -WarningAction Continue'
        '        }'
        '    }'
        '    catch {'
        '        Write-Warning (''Psh interactive initialization failed: {0}'' -f $_.Exception.Message) -WarningAction Continue'
        '    }'
        '}'
        $script:PshProfileEndMarker
    )
}

function Get-PshCanonicalProfileBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("`r`n", "`n", "`r")]
        [string] $NewLine
    )

    return [string]::Join($NewLine, (Get-PshCanonicalProfileBlockLine))
}

function Get-PshDefaultProfilePath {
    [CmdletBinding()]
    param()

    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) {
        throw 'The current user Documents directory is unavailable; CurrentUserAllHosts profiles cannot be resolved safely.'
    }

    return @(
        (Join-Path -Path (Join-Path -Path $documents -ChildPath 'WindowsPowerShell') -ChildPath 'profile.ps1')
        (Join-Path -Path (Join-Path -Path $documents -ChildPath 'PowerShell') -ChildPath 'profile.ps1')
    )
}

function Resolve-PshFullPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description cannot be empty or whitespace."
    }

    try {
        $provider = $null
        $drive = $null
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path,
            [ref] $provider,
            [ref] $drive
        )
    }
    catch {
        throw "${Description} is not a valid filesystem path: $Path. $($_.Exception.Message)"
    }

    if ($null -eq $provider -or $provider.Name -cne 'FileSystem') {
        throw "$Description must use the FileSystem provider: $Path"
    }

    if (-not [IO.Path]::IsPathRooted($fullPath)) {
        throw "$Description did not resolve to an absolute filesystem path: $Path"
    }

    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        if ($fullPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or
            $fullPath.StartsWith('\\.\', [StringComparison]::Ordinal)) {
            throw "$Description must not use a Windows device-path prefix: $Path"
        }
        $pathRoot = [IO.Path]::GetPathRoot($fullPath)
        if ($fullPath.Substring($pathRoot.Length).IndexOf(':') -ge 0) {
            throw "$Description must not name an NTFS alternate data stream: $Path"
        }
    }

    return $fullPath
}

function Test-PshPathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $fullPath = Resolve-PshFullPath -Path $Path -Description 'Candidate path'
    $fullRoot = Resolve-PshFullPath -Path $Root -Description 'Root path'
    $separators = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $fullRoot.TrimEnd($separators) + [IO.Path]::DirectorySeparatorChar

    return [string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PshNotReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
        return
    }

    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a symbolic link, junction, or other reparse point: $Path"
    }
}

function Resolve-PshProfileTarget {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]] $ProfilePath,

        [Parameter(Mandatory = $true)]
        [bool] $ProfilePathWasSpecified,

        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $candidatePaths = @(
        if ($ProfilePathWasSpecified) {
            $ProfilePath
        }
        else {
            Get-PshDefaultProfilePath
        }
    )
    if ($candidatePaths.Count -eq 0) {
        throw 'At least one profile path is required.'
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($candidatePath in $candidatePaths) {
        if ($null -eq $candidatePath -or [string]::IsNullOrWhiteSpace($candidatePath)) {
            throw 'ProfilePath cannot contain null, empty, or whitespace values.'
        }

        $fullPath = Resolve-PshFullPath -Path $candidatePath -Description 'Profile path'
        if (-not $seen.Add($fullPath)) {
            throw "ProfilePath contains the same target more than once: $fullPath"
        }

        if ([IO.Directory]::Exists($fullPath)) {
            throw "A profile target is a directory, not a file: $fullPath"
        }

        Assert-PshNotReparsePoint -Path $fullPath -Description 'A profile target'
        if (Test-PshPathWithinRoot -Path $fullPath -Root $StateRoot) {
            throw "A profile target must not be inside Psh profile state storage: $fullPath"
        }

        $resolved.Add($fullPath)
    }

    return $resolved.ToArray()
}

function Get-PshProfileStateRoot {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; Psh profile backup state cannot be resolved safely.'
        }

        $StateRoot = Join-Path -Path (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Psh') -ChildPath 'profile-state'
    }

    $fullStateRoot = Resolve-PshFullPath -Path $StateRoot -Description 'Profile state root'
    if ([IO.File]::Exists($fullStateRoot)) {
        throw "The profile state root is a file: $fullStateRoot"
    }

    Assert-PshNotReparsePoint -Path $fullStateRoot -Description 'The profile state root'
    return $fullStateRoot
}

function Get-PshSha256Hex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($Bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-PshProfileId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProfilePath
    )

    $normalized = (Resolve-PshFullPath -Path $ProfilePath -Description 'Profile path').ToUpperInvariant()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [byte[]] $normalizedBytes = $utf8.GetBytes($normalized)
    return Get-PshSha256Hex -Bytes $normalizedBytes
}

function Enter-PshProfileTransactionLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot,

        [Parameter()]
        [ValidateRange(1, 300000)]
        [int] $TimeoutMilliseconds = 30000
    )

    $normalized = Resolve-PshFullPath -Path $StateRoot -Description 'Profile state root'
    $pathRoot = [IO.Path]::GetPathRoot($normalized)
    $pathComparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $pathComparison = [StringComparison]::OrdinalIgnoreCase
    }
    if (-not [string]::Equals($normalized, $pathRoot, $pathComparison)) {
        $normalized = $normalized.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
    }
    $normalized = $normalized.ToUpperInvariant()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [byte[]] $normalizedBytes = $utf8.GetBytes($normalized)
    $mutexName = 'Psh.ProfileState.' + (Get-PshSha256Hex -Bytes $normalizedBytes)
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Timed out waiting for another Psh profile transaction to finish: $StateRoot"
        }

        return [pscustomobject]@{
            Mutex    = $mutex
            Acquired = $true
            Name     = $mutexName
        }
    }
    catch {
        $lockError = $_
        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }
        }
        $mutex.Dispose()
        throw $lockError
    }
}

function Exit-PshProfileTransactionLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Lock
    )

    try {
        if ([bool] $Lock.Acquired) {
            $Lock.Mutex.ReleaseMutex()
            $Lock.Acquired = $false
        }
    }
    finally {
        $Lock.Mutex.Dispose()
    }
}

function Test-PshByteArrayEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Left,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }

    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }

    return $true
}

function Get-PshStrictEncoding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $CodePage
    )

    $encoderFallback = New-Object System.Text.EncoderExceptionFallback
    $decoderFallback = New-Object System.Text.DecoderExceptionFallback
    return [Text.Encoding]::GetEncoding($CodePage, $encoderFallback, $decoderFallback)
}

function Get-PshWindowsAnsiCodePage {
    [CmdletBinding()]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The Windows ANSI code page is unavailable on this platform.'
    }

    $nativeType = 'Psh.Profile.NativeMethods' -as [type]
    if ($null -eq $nativeType) {
        try {
            $nativeType = Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

namespace Psh.Profile
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll")]
        public static extern uint GetACP();
    }
}
'@ -PassThru -ErrorAction Stop
        }
        catch {
            $nativeType = 'Psh.Profile.NativeMethods' -as [type]
            if ($null -eq $nativeType) {
                throw "The Windows ANSI code page could not be queried safely: $($_.Exception.Message)"
            }
        }
    }

    $method = $nativeType.GetMethod('GetACP', [Reflection.BindingFlags]'Static, Public')
    if ($null -eq $method) {
        throw 'The Windows ANSI code-page query is unavailable.'
    }
    $codePage = [int] $method.Invoke($null, @())
    if ($codePage -le 0) {
        throw "Windows returned an invalid ANSI code page: $codePage"
    }
    return $codePage
}

function Get-PshProfileTextInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $preambleLength = 0
    $codePage = 65001
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        $preambleLength = 4
        $codePage = 12000
    }
    elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $preambleLength = 4
        $codePage = 12001
    }
    elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $preambleLength = 3
        $codePage = 65001
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $preambleLength = 2
        $codePage = 1200
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $preambleLength = 2
        $codePage = 1201
    }

    $bodyLength = $Bytes.Length - $preambleLength
    $body = New-Object byte[] $bodyLength
    if ($bodyLength -gt 0) {
        [Array]::Copy($Bytes, $preambleLength, $body, 0, $bodyLength)
    }

    $encoding = $null
    $text = $null
    if ($preambleLength -eq 0) {
        try {
            $encoding = Get-PshStrictEncoding -CodePage 65001
            $text = $encoding.GetString($body)
        }
        catch [Text.DecoderFallbackException] {
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
                throw "Profile encoding is not losslessly decodable as UTF-8 on this platform: $Path"
            }
            $encoding = Get-PshStrictEncoding -CodePage (Get-PshWindowsAnsiCodePage)
            try {
                $text = $encoding.GetString($body)
            }
            catch [Text.DecoderFallbackException] {
                throw "Profile encoding is not losslessly decodable as UTF-8 or the current Windows ANSI code page: $Path"
            }
        }
    }
    else {
        $encoding = Get-PshStrictEncoding -CodePage $codePage
        try {
            $text = $encoding.GetString($body)
        }
        catch [Text.DecoderFallbackException] {
            throw "Profile contains invalid bytes for its byte-order mark: $Path"
        }
    }

    if ($text.IndexOf([char]0) -ge 0) {
        throw "Profile contains a NUL character and is not safe to edit as a PowerShell script: $Path"
    }

    [byte[]] $roundTrip = $encoding.GetBytes($text)
    if (-not (Test-PshByteArrayEqual -Left $body -Right $roundTrip)) {
        throw "Profile encoding cannot be preserved byte-for-byte: $Path"
    }

    $newLine = "`r`n"
    for ($index = 0; $index -lt $text.Length; $index++) {
        if ($text[$index] -eq "`r") {
            if (($index + 1) -lt $text.Length -and $text[$index + 1] -eq "`n") {
                $newLine = "`r`n"
            }
            else {
                $newLine = "`r"
            }
            break
        }

        if ($text[$index] -eq "`n") {
            $newLine = "`n"
            break
        }
    }

    return [pscustomobject]@{
        Bytes          = $Bytes
        Text           = $text
        Encoding       = $encoding
        PreambleLength = $preambleLength
        NewLine        = $newLine
    }
}

function ConvertTo-PshProfileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [Text.Encoding] $Encoding,

        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 2, 3, 4)]
        [int] $PreambleLength
    )

    [byte[]] $body = $Encoding.GetBytes($Text)
    $preamble = $Encoding.GetPreamble()
    if ($PreambleLength -eq 0) {
        $preamble = New-Object byte[] 0
    }
    elseif ($preamble.Length -ne $PreambleLength) {
        throw "The profile encoding preamble length changed unexpectedly (expected $PreambleLength, found $($preamble.Length))."
    }

    $bytes = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length -gt 0) {
        [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    }
    if ($body.Length -gt 0) {
        [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    }

    return ,$bytes
}

function Get-PshMarkerOccurrenceCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [string] $Marker
    )

    $count = 0
    $offset = 0
    while ($offset -lt $Text.Length) {
        $found = $Text.IndexOf($Marker, $offset, [StringComparison]::Ordinal)
        if ($found -lt 0) {
            break
        }

        $count++
        $offset = $found + $Marker.Length
    }

    return $count
}

function Get-PshLineStartIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [int] $Index
    )

    $lineStart = $Index
    while ($lineStart -gt 0 -and $Text[$lineStart - 1] -ne "`r" -and $Text[$lineStart - 1] -ne "`n") {
        $lineStart--
    }
    return $lineStart
}

function Get-PshLineEndIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [int] $Index
    )

    $lineEnd = $Index
    while ($lineEnd -lt $Text.Length -and $Text[$lineEnd] -ne "`r" -and $Text[$lineEnd] -ne "`n") {
        $lineEnd++
    }
    return $lineEnd
}

function Get-PshLineTerminatorEndIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [int] $LineEnd
    )

    if ($LineEnd -ge $Text.Length) {
        return $LineEnd
    }

    if ($Text[$LineEnd] -eq "`r" -and ($LineEnd + 1) -lt $Text.Length -and $Text[$LineEnd + 1] -eq "`n") {
        return $LineEnd + 2
    }

    return $LineEnd + 1
}

function Get-PshProfileMarkerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $startCount = Get-PshMarkerOccurrenceCount -Text $Text -Marker $script:PshProfileStartMarker
    $endCount = Get-PshMarkerOccurrenceCount -Text $Text -Marker $script:PshProfileEndMarker
    if ($startCount -eq 0 -and $endCount -eq 0) {
        return [pscustomobject]@{
            Present    = $false
            BlockStart = -1
            BlockEnd   = -1
            RemovalEnd = -1
        }
    }

    if ($startCount -ne 1 -or $endCount -ne 1) {
        throw "Psh profile markers are unmatched, duplicated, or nested in: $Path (start=$startCount, end=$endCount)."
    }

    $startIndex = $Text.IndexOf($script:PshProfileStartMarker, [StringComparison]::Ordinal)
    $endIndex = $Text.IndexOf($script:PshProfileEndMarker, [StringComparison]::Ordinal)
    if ($startIndex -ge $endIndex) {
        throw "Psh profile markers are reversed in: $Path"
    }

    $startLineStart = Get-PshLineStartIndex -Text $Text -Index $startIndex
    $startLineEnd = Get-PshLineEndIndex -Text $Text -Index $startIndex
    $endLineStart = Get-PshLineStartIndex -Text $Text -Index $endIndex
    $endLineEnd = Get-PshLineEndIndex -Text $Text -Index $endIndex
    if ($startIndex -ne $startLineStart -or ($startIndex + $script:PshProfileStartMarker.Length) -ne $startLineEnd -or
        $endIndex -ne $endLineStart -or ($endIndex + $script:PshProfileEndMarker.Length) -ne $endLineEnd) {
        throw "Psh profile markers must each occupy an exact, standalone line in: $Path"
    }

    $actualBlock = $Text.Substring($startLineStart, $endLineEnd - $startLineStart)
    $normalizedActual = $actualBlock.Replace("`r`n", "`n").Replace("`r", "`n")
    $normalizedExpected = Get-PshCanonicalProfileBlock -NewLine "`n"
    if (-not [string]::Equals($normalizedActual, $normalizedExpected, [StringComparison]::Ordinal)) {
        throw "The marked Psh profile block has unexpected or modified content in: $Path"
    }

    return [pscustomobject]@{
        Present    = $true
        BlockStart = $startLineStart
        BlockEnd   = $endLineEnd
        RemovalEnd = Get-PshLineTerminatorEndIndex -Text $Text -LineEnd $endLineEnd
    }
}

function Test-PshTextEndsWithNewLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text
    )

    if ($Text.Length -eq 0) {
        return $false
    }

    return $Text[$Text.Length - 1] -eq "`r" -or $Text[$Text.Length - 1] -eq "`n"
}

function New-PshInstalledProfileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $TextInfo
    )

    $text = $TextInfo.Text
    if ($text.Length -gt 0 -and -not (Test-PshTextEndsWithNewLine -Text $text)) {
        $text += $TextInfo.NewLine
    }
    $text += Get-PshCanonicalProfileBlock -NewLine $TextInfo.NewLine
    $text += $TextInfo.NewLine

    return ConvertTo-PshProfileByte -Text $text -Encoding $TextInfo.Encoding -PreambleLength $TextInfo.PreambleLength
}

function Remove-PshProfileBlockByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $TextInfo,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $MarkerState
    )

    if (-not $MarkerState.Present) {
        return ,$TextInfo.Bytes
    }

    $prefix = $TextInfo.Text.Substring(0, $MarkerState.BlockStart)
    $suffix = $TextInfo.Text.Substring($MarkerState.RemovalEnd)
    $text = $prefix + $suffix
    return ConvertTo-PshProfileByte -Text $text -Encoding $TextInfo.Encoding -PreambleLength $TextInfo.PreambleLength
}

function Write-PshNewFileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    $stream = $null
    try {
        $streamArguments = @(
            $Path
            [IO.FileMode]::CreateNew
            [IO.FileAccess]::Write
            [IO.FileShare]::None
            4096
            [IO.FileOptions]::WriteThrough
        )
        $stream = New-Object -TypeName IO.FileStream -ArgumentList $streamArguments
        if ($Bytes.Length -gt 0) {
            $stream.Write($Bytes, 0, $Bytes.Length)
        }
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Restore-PshDisplacedFileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $DisplacedBytes,

        [Parameter(Mandatory = $true)]
        [string] $DisplacedPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedCurrentBytes,

        [Parameter()]
        [ValidateRange(1, 32)]
        [int] $MaximumAttempts = 8
    )

    $parent = [IO.Path]::GetDirectoryName($Path)
    $candidatePath = $DisplacedPath
    [byte[]] $candidateBytes = $DisplacedBytes
    [byte[]] $expectedBytes = $ExpectedCurrentBytes
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $recoveryPath = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.recovery' -f ([Guid]::NewGuid()).ToString('N'))
        try {
            [IO.File]::Replace($candidatePath, $Path, $recoveryPath)
            $candidatePath = $null
        }
        catch {
            throw "A concurrent file change could not be rolled back safely. Recovery bytes remain at '$candidatePath'. $($_.Exception.Message)"
        }

        try {
            [byte[]] $replacedBytes = [IO.File]::ReadAllBytes($recoveryPath)
        }
        catch {
            throw "A concurrent file change was displaced, but its recovery file could not be read: '$recoveryPath'. $($_.Exception.Message)"
        }

        if (Test-PshByteArrayEqual -Left $replacedBytes -Right $expectedBytes) {
            try {
                [IO.File]::Delete($recoveryPath)
            }
            catch {
                Write-Verbose "A Psh compare-exchange recovery file containing only superseded Psh bytes remains: $recoveryPath"
            }
            return
        }

        # Another writer won between compare-exchange and rollback. The most
        # recently displaced bytes are now the next restoration candidate.
        $expectedBytes = $candidateBytes
        $candidateBytes = $replacedBytes
        $candidatePath = $recoveryPath
    }

    throw "A file kept changing while Psh tried to restore it. The latest displaced bytes remain at '$candidatePath'."
}

function Restore-PshUnreadDisplacedFileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $DisplacedPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedCurrentBytes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedDisplacedBytes
    )

    $parent = [IO.Path]::GetDirectoryName($Path)
    $currentRecoveryPath = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.recovery' -f ([Guid]::NewGuid()).ToString('N'))
    try {
        [IO.File]::Replace($DisplacedPath, $Path, $currentRecoveryPath)
    }
    catch {
        throw "Post-commit verification failed and the displaced bytes could not be restored. Recovery bytes remain at '$DisplacedPath'. $($_.Exception.Message)"
    }

    try {
        [byte[]] $replacedCurrentBytes = [IO.File]::ReadAllBytes($currentRecoveryPath)
    }
    catch {
        throw "The displaced bytes were restored after a verification failure, but the bytes replaced during recovery could not be read. Recovery evidence remains at '$currentRecoveryPath'. $($_.Exception.Message)"
    }

    if (Test-PshByteArrayEqual -Left $replacedCurrentBytes -Right $ExpectedCurrentBytes) {
        try {
            [IO.File]::Delete($currentRecoveryPath)
        }
        catch {
            Write-Verbose "A recovery file containing only superseded Psh bytes remains: $currentRecoveryPath"
        }
        return
    }

    # A writer changed the target after Psh committed. Put that newer image
    # back first, preserving whatever it displaces for one more comparison.
    $displacedRecoveryPath = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.recovery' -f ([Guid]::NewGuid()).ToString('N'))
    try {
        [IO.File]::Replace($currentRecoveryPath, $Path, $displacedRecoveryPath)
    }
    catch {
        throw "A post-commit concurrent image could not be restored. It remains at '$currentRecoveryPath'. $($_.Exception.Message)"
    }

    try {
        [byte[]] $secondDisplacedBytes = [IO.File]::ReadAllBytes($displacedRecoveryPath)
    }
    catch {
        throw "The post-commit concurrent image was restored, but earlier recovery bytes could not be read. Recovery evidence remains at '$displacedRecoveryPath'. $($_.Exception.Message)"
    }

    if (Test-PshByteArrayEqual -Left $secondDisplacedBytes -Right $ExpectedDisplacedBytes) {
        try {
            [IO.File]::Delete($displacedRecoveryPath)
        }
        catch {
            Write-Verbose "A recovery file containing a superseded preflight image remains: $displacedRecoveryPath"
        }
        return
    }

    # The newest post-commit writer is already live again. The older displaced
    # image did not match preflight, so retain it as evidence instead of
    # overwriting the newer image while trying to make the transaction appear
    # clean.
    throw "Both pre-commit and post-commit concurrent changes were detected. The newest image remains live and the older displaced bytes remain at '$displacedRecoveryPath'."
}

function Write-PshAtomicFileByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes,

        [Parameter(Mandatory = $true)]
        [bool] $ExpectedToExist,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedBytes
    )

    $parent = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw "The parent directory for an atomic write does not exist: $Path"
    }

    Assert-PshNotReparsePoint -Path $Path -Description 'An atomic-write target'
    $operationId = ([Guid]::NewGuid()).ToString('N')
    $temporaryPath = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.tmp' -f $operationId)
    $replacementBackupPath = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.replace' -f $operationId)
    $preserveReplacementBackup = $false
    try {
        Write-PshNewFileByte -Path $temporaryPath -Bytes $Bytes
        if ($ExpectedToExist) {
            $preserveReplacementBackup = $true
            [IO.File]::Replace($temporaryPath, $Path, $replacementBackupPath)
            try {
                [byte[]] $replacedBytes = [IO.File]::ReadAllBytes($replacementBackupPath)
            }
            catch {
                $verificationError = $_
                try {
                    Restore-PshUnreadDisplacedFileByte `
                        -Path $Path `
                        -DisplacedPath $replacementBackupPath `
                        -ExpectedCurrentBytes $Bytes `
                        -ExpectedDisplacedBytes $ExpectedBytes
                }
                catch {
                    throw "Atomic post-commit verification and recovery both failed for '$Path'. Verification error: $($verificationError.Exception.Message). Recovery error: $($_.Exception.Message)"
                }
                $preserveReplacementBackup = $false
                throw "Atomic post-commit verification failed, so the Psh write was rolled back: $Path. $($verificationError.Exception.Message)"
            }
            if (-not (Test-PshByteArrayEqual -Left $replacedBytes -Right $ExpectedBytes)) {
                Restore-PshDisplacedFileByte `
                    -Path $Path `
                    -DisplacedBytes $replacedBytes `
                    -DisplacedPath $replacementBackupPath `
                    -ExpectedCurrentBytes $Bytes
                throw "A file changed at the atomic commit point; the Psh write was rolled back: $Path"
            }
            $preserveReplacementBackup = $false
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
        $temporaryPath = $null
    }
    finally {
        if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if (-not $preserveReplacementBackup -and [IO.File]::Exists($replacementBackupPath)) {
            try {
                [IO.File]::Delete($replacementBackupPath)
            }
            catch {
                Write-Verbose "A stale uniquely named Psh replacement backup remains: $replacementBackupPath"
            }
        }
    }
}

function Move-PshFileToQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedBytes
    )

    $parent = [IO.Path]::GetDirectoryName($Path)
    $quarantine = Join-Path -Path $parent -ChildPath ('.psh-profile.{0}.removed' -f ([Guid]::NewGuid()).ToString('N'))
    [IO.File]::Move($Path, $quarantine)
    try {
        [byte[]] $movedBytes = [IO.File]::ReadAllBytes($quarantine)
    }
    catch {
        $verificationError = $_
        if (-not [IO.File]::Exists($Path)) {
            try {
                [IO.File]::Move($quarantine, $Path)
                $quarantine = $null
            }
            catch {
                throw "Atomic removal verification failed and the moved bytes could not be restored. Recovery bytes remain at '$quarantine'. Verification error: $($verificationError.Exception.Message). Recovery error: $($_.Exception.Message)"
            }
        }

        if ($null -ne $quarantine) {
            throw "Atomic removal verification failed after another writer created the target. The moved bytes remain at '$quarantine': $Path"
        }
        throw "Atomic removal verification failed, so removal was rolled back: $Path. $($verificationError.Exception.Message)"
    }
    if (-not (Test-PshByteArrayEqual -Left $movedBytes -Right $ExpectedBytes)) {
        if (-not [IO.File]::Exists($Path)) {
            try {
                [IO.File]::Move($quarantine, $Path)
                $quarantine = $null
            }
            catch {
                throw "A file changed at the atomic removal point and could not be restored. Recovery bytes remain at '$quarantine'. $($_.Exception.Message)"
            }
        }

        if ($null -ne $quarantine) {
            throw "A file changed at the atomic removal point. Recovery bytes remain at '$quarantine': $Path"
        }
        throw "A file changed at the atomic removal point; removal was rolled back: $Path"
    }

    return $quarantine
}

function Assert-PshFileUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [bool] $ExpectedToExist,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $ExpectedBytes
    )

    $exists = [IO.File]::Exists($Path)
    if ($exists -ne $ExpectedToExist) {
        throw "A profile changed after preflight and before its write: $Path"
    }
    if ($exists) {
        [byte[]] $currentBytes = [IO.File]::ReadAllBytes($Path)
        if (-not (Test-PshByteArrayEqual -Left $currentBytes -Right $ExpectedBytes)) {
            throw "A profile changed after preflight and before its write: $Path"
        }
    }
}

function Get-PshManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $manifestPath = Join-Path -Path $StateRoot -ChildPath $script:PshProfileManifestName
    $backupRoot = Join-Path -Path $StateRoot -ChildPath $script:PshProfileBackupDirectoryName
    if (-not (Test-PshPathWithinRoot -Path $manifestPath -Root $StateRoot) -or
        -not (Test-PshPathWithinRoot -Path $backupRoot -Root $StateRoot)) {
        throw 'Psh profile state paths did not remain within the state root.'
    }

    return [pscustomobject]@{
        ManifestPath = $manifestPath
        BackupRoot   = $backupRoot
    }
}

function Get-PshRequiredJsonProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }
    return $property.Value
}

function Assert-PshJsonPropertyName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]] $ExpectedNames,

        [Parameter(Mandatory = $true)]
        [string] $Context
    )

    $actualNames = @($InputObject.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actualNames.Count -ne $ExpectedNames.Count) {
        throw "$Context has unexpected properties."
    }
    foreach ($name in $ExpectedNames) {
        if ($actualNames -cnotcontains $name) {
            throw "$Context has unexpected properties or casing."
        }
    }
}

function Read-PshProfileManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateRoot
    )

    $paths = Get-PshManifestPath -StateRoot $StateRoot
    Assert-PshNotReparsePoint -Path $paths.BackupRoot -Description 'The profile backup directory'
    Assert-PshNotReparsePoint -Path $paths.ManifestPath -Description 'The profile manifest'
    if ([IO.File]::Exists($paths.BackupRoot)) {
        throw "The profile backup directory path is a file: $($paths.BackupRoot)"
    }
    if ([IO.Directory]::Exists($paths.ManifestPath)) {
        throw "The profile manifest path is a directory: $($paths.ManifestPath)"
    }

    if (-not [IO.File]::Exists($paths.ManifestPath)) {
        return [pscustomobject]@{
            Exists          = $false
            Bytes           = (New-Object byte[] 0)
            Entries         = @()
            BackupBytesById = @{}
            ManifestPath    = $paths.ManifestPath
            BackupRoot      = $paths.BackupRoot
        }
    }

    [byte[]] $manifestBytes = [IO.File]::ReadAllBytes($paths.ManifestPath)
    $manifestInfo = Get-PshProfileTextInfo -Bytes $manifestBytes -Path $paths.ManifestPath
    if ($manifestInfo.PreambleLength -ne 0 -or $manifestInfo.Encoding.CodePage -ne 65001) {
        throw "Psh profile manifest must be UTF-8 without a byte-order mark: $($paths.ManifestPath)"
    }

    try {
        $document = $manifestInfo.Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Psh profile manifest is invalid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $document -or $document -is [Array]) {
        throw 'Psh profile manifest must be one JSON object.'
    }
    Assert-PshJsonPropertyName -InputObject $document -ExpectedNames @('schemaVersion', 'product', 'profiles') -Context 'Psh profile manifest'

    $schemaVersion = Get-PshRequiredJsonProperty -InputObject $document -Name 'schemaVersion' -Context 'Psh profile manifest'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or $schemaVersion -ne 1) {
        throw 'Psh profile manifest has an unsupported schemaVersion.'
    }
    $product = Get-PshRequiredJsonProperty -InputObject $document -Name 'product' -Context 'Psh profile manifest'
    if ($product -isnot [string] -or $product -cne 'Psh') {
        throw 'Psh profile manifest has an invalid product identifier.'
    }

    $profilesValue = Get-PshRequiredJsonProperty -InputObject $document -Name 'profiles' -Context 'Psh profile manifest'
    if ($null -eq $profilesValue) {
        throw 'Psh profile manifest profiles must be an array.'
    }
    $entries = @($profilesValue)
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $validatedEntries = New-Object System.Collections.Generic.List[object]
    $validatedBackups = @{}

    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -is [Array]) {
            throw 'Psh profile manifest contains a non-object profile entry.'
        }
        Assert-PshJsonPropertyName -InputObject $entry -ExpectedNames @(
            'profileId', 'profilePath', 'backupFileName', 'originalExisted',
            'originalLength', 'originalSha256', 'installedSha256'
        ) -Context 'A Psh profile manifest entry'

        $profileId = Get-PshRequiredJsonProperty -InputObject $entry -Name 'profileId' -Context 'A Psh profile manifest entry'
        $profilePath = Get-PshRequiredJsonProperty -InputObject $entry -Name 'profilePath' -Context 'A Psh profile manifest entry'
        $backupFileName = Get-PshRequiredJsonProperty -InputObject $entry -Name 'backupFileName' -Context 'A Psh profile manifest entry'
        $originalExisted = Get-PshRequiredJsonProperty -InputObject $entry -Name 'originalExisted' -Context 'A Psh profile manifest entry'
        $originalLength = Get-PshRequiredJsonProperty -InputObject $entry -Name 'originalLength' -Context 'A Psh profile manifest entry'
        $originalSha256 = Get-PshRequiredJsonProperty -InputObject $entry -Name 'originalSha256' -Context 'A Psh profile manifest entry'
        $installedSha256 = Get-PshRequiredJsonProperty -InputObject $entry -Name 'installedSha256' -Context 'A Psh profile manifest entry'

        if ($profileId -isnot [string] -or $profileId -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'A Psh profile manifest entry has an invalid profileId.'
        }
        if ($profilePath -isnot [string]) {
            throw 'A Psh profile manifest entry has a non-string profilePath.'
        }
        $normalizedPath = Resolve-PshFullPath -Path $profilePath -Description 'Manifest profile path'
        if ($profilePath -cne $normalizedPath) {
            throw "A Psh profile manifest path is not normalized: $profilePath"
        }
        if ((Get-PshProfileId -ProfilePath $normalizedPath) -cne $profileId) {
            throw "A Psh profile manifest profileId does not match its path: $profilePath"
        }
        if (Test-PshPathWithinRoot -Path $normalizedPath -Root $StateRoot) {
            throw "A Psh profile manifest target is inside profile state storage: $profilePath"
        }
        if (-not $seenIds.Add($profileId) -or -not $seenPaths.Add($normalizedPath)) {
            throw 'Psh profile manifest contains duplicate profile targets.'
        }
        if ($backupFileName -isnot [string] -or $backupFileName -cne ($profileId + '.bin')) {
            throw "A Psh profile manifest backup filename is unsafe: $backupFileName"
        }
        if ($originalExisted -isnot [bool]) {
            throw 'A Psh profile manifest originalExisted value is not Boolean.'
        }
        if (($originalLength -isnot [int] -and $originalLength -isnot [long]) -or $originalLength -lt 0) {
            throw 'A Psh profile manifest originalLength is invalid.'
        }
        if ($originalSha256 -isnot [string] -or $originalSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            $installedSha256 -isnot [string] -or $installedSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'A Psh profile manifest contains an invalid SHA-256 value.'
        }

        $backupPath = Join-Path -Path $paths.BackupRoot -ChildPath $backupFileName
        if (-not (Test-PshPathWithinRoot -Path $backupPath -Root $paths.BackupRoot)) {
            throw "A Psh profile backup path escapes the backup root: $backupFileName"
        }
        Assert-PshNotReparsePoint -Path $backupPath -Description 'A profile backup'
        if (-not [IO.File]::Exists($backupPath)) {
            throw "A Psh profile backup is missing: $backupPath"
        }
        [byte[]] $backupBytes = [IO.File]::ReadAllBytes($backupPath)
        if ($backupBytes.LongLength -ne [long] $originalLength -or
            (Get-PshSha256Hex -Bytes $backupBytes) -cne $originalSha256) {
            throw "A Psh profile backup does not match its trusted metadata: $backupPath"
        }
        if (-not $originalExisted -and $backupBytes.Length -ne 0) {
            throw "A profile recorded as originally absent has a non-empty backup: $backupPath"
        }

        $backupTextInfo = Get-PshProfileTextInfo -Bytes $backupBytes -Path $backupPath
        $backupMarkerState = Get-PshProfileMarkerState -Text $backupTextInfo.Text -Path $backupPath
        if ($backupMarkerState.Present) {
            throw "An original Psh profile backup unexpectedly contains a managed block: $backupPath"
        }
        [byte[]] $expectedInstalledBytes = New-PshInstalledProfileByte -TextInfo $backupTextInfo
        if ((Get-PshSha256Hex -Bytes $expectedInstalledBytes) -cne $installedSha256) {
            throw "A Psh profile manifest installed-image hash cannot be derived from its original backup: $backupPath"
        }

        $validatedEntries.Add([pscustomobject][ordered]@{
            profileId        = $profileId
            profilePath      = $normalizedPath
            backupFileName   = $backupFileName
            originalExisted  = $originalExisted
            originalLength   = [long] $originalLength
            originalSha256   = $originalSha256
            installedSha256  = $installedSha256
        })
        $validatedBackups[$profileId] = $backupBytes
    }

    return [pscustomobject]@{
        Exists          = $true
        Bytes           = $manifestBytes
        Entries         = $validatedEntries.ToArray()
        BackupBytesById = $validatedBackups
        ManifestPath    = $paths.ManifestPath
        BackupRoot      = $paths.BackupRoot
    }
}

function ConvertTo-PshProfileManifestByte {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Entries
    )

    $document = [ordered]@{
        schemaVersion = 1
        product       = 'Psh'
        profiles      = @($Entries)
    }
    $json = ($document | ConvertTo-Json -Depth 5) + "`r`n"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [byte[]] $manifestBytes = $utf8.GetBytes($json)
    return ,$manifestBytes
}

function Find-PshManifestEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Entries,

        [Parameter(Mandatory = $true)]
        [string] $ProfileId
    )

    foreach ($entry in $Entries) {
        if ($entry.profileId -ceq $ProfileId) {
            return $entry
        }
    }
    return $null
}
