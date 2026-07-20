# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

$script:PshTarCommandNames = @('tar')

function Get-PshEnabledTarCommandNames {
    $disabledVariable = Get-Variable -Name PshDisabledCommands -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $disabledVariable -or $null -eq $disabledVariable.Value) {
        return $script:PshTarCommandNames
    }

    $enabled = @()
    foreach ($name in $script:PshTarCommandNames) {
        if (-not $disabledVariable.Value.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function Set-PshTarExitCode {
    param([Parameter(Mandatory = $true)][int] $Code)

    $setter = Get-Command -Name Set-PshLastExitCode -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $setter) {
        Set-PshLastExitCode -Code $Code
    }
    else {
        $global:LASTEXITCODE = $Code
    }
}

function Write-PshTarFailure {
    param(
        [Parameter(Mandatory = $true)][int] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $writer = Get-Command -Name Write-PshCommandFailure -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $writer) {
        Write-PshCommandFailure -Command 'tar' -Code $Code -Message $Message
        return
    }

    $kind = if ($Code -eq 2) { 'usage error' } elseif ($Code -eq 5) { 'integrity failure' } else { 'runtime error' }
    Microsoft.PowerShell.Utility\Write-Output ('tar: {0}: {1}' -f $kind, (($Message -replace '[\r\n]+', ' ').Trim()))
    Set-PshTarExitCode -Code $Code
}

function Throw-PshTarInvalidData {
    param([Parameter(Mandatory = $true)][string] $Message)

    throw (New-Object IO.InvalidDataException($Message))
}

function Test-PshTarInvalidDataException {
    param([Parameter(Mandatory = $true)][Exception] $Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.InvalidDataException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function ConvertTo-PshTarArgumentArray {
    param([AllowNull()][object[]] $InputArguments)

    $result = @()
    foreach ($argument in @($InputArguments)) {
        if ($null -eq $argument) { $result += '' }
        else { $result += [string]$argument }
    }
    return $result
}

function Get-PshTarCurrentDirectory {
    $location = Microsoft.PowerShell.Management\Get-Location
    if ($null -eq $location.Provider -or $location.Provider.Name -ne 'FileSystem') {
        throw 'the current location is not in the file-system provider.'
    }
    return [IO.Path]::GetFullPath([string]$location.ProviderPath)
}

function Resolve-PshTarPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'an empty file-system path is not supported.'
    }

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath([IO.Path]::Combine($BasePath, $Path))
}

function Get-PshTarPathComparison {
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Test-PshTarSamePath {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [string]::Equals($leftPath, $rightPath, (Get-PshTarPathComparison))
}

function Test-PshTarPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($fullPath, $fullRoot, (Get-PshTarPathComparison))) {
        return $true
    }
    $rootPrefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootPrefix, (Get-PshTarPathComparison))
}

function Get-PshTarExistingItem {
    param([Parameter(Mandatory = $true)][string] $Path)

    $items = @(Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Assert-PshTarRegularItem {
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][string] $DisplayPath
    )

    if (([IO.FileAttributes]$Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('symbolic links and reparse points are not supported: {0}' -f $DisplayPath)
    }
    if ($Item.PSIsContainer) { return 'Directory' }
    if ($Item -isnot [IO.FileInfo]) {
        throw ('unsupported file-system item: {0}' -f $DisplayPath)
    }
    return 'File'
}

function Assert-PshTarNoReparseComponents {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-PshTarPathWithinRoot -Path $fullPath -Root $fullRoot)) {
        throw ('path escapes its allowed root: {0}' -f $Path)
    }

    $rootItem = Get-PshTarExistingItem -Path $fullRoot
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer) {
        throw ('directory does not exist: {0}' -f $Root)
    }
    [void](Assert-PshTarRegularItem -Item $rootItem -DisplayPath $Root)

    if (Test-PshTarSamePath -Left $fullPath -Right $fullRoot) { return }
    $relative = $fullPath.Substring($fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length)
    $relative = $relative.TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = $fullRoot
    foreach ($component in $relative.Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [IO.Path]::Combine($current, $component)
        $item = Get-PshTarExistingItem -Path $current
        if ($null -eq $item) { continue }
        [void](Assert-PshTarRegularItem -Item $item -DisplayPath $current)
    }
}

function New-PshTarTemporaryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)][string] $Prefix
    )

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $candidate = [IO.Path]::Combine($Directory, ('{0}{1}' -f $Prefix, [Guid]::NewGuid().ToString('N')))
        if ($null -eq (Get-PshTarExistingItem -Path $candidate)) {
            return $candidate
        }
    }
    throw 'unable to allocate a staging path.'
}

function Test-PshTarPortablePathComponent {
    param([Parameter(Mandatory = $true)][string] $Component)

    if ($Component.Length -eq 0 -or $Component -eq '..') { return $false }
    if ($Component -eq '.') { return $true }
    if ($Component.EndsWith('.') -or $Component.EndsWith(' ')) { return $false }
    if ($Component.IndexOfAny([char[]]'<>:"|?*') -ge 0) { return $false }
    foreach ($character in $Component.ToCharArray()) {
        if ([int]$character -lt 32) { return $false }
    }

    $stem = $Component.Split('.')[0]
    if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $false }
    return $true
}

function ConvertTo-PshTarCanonicalEntryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $AllowRootDirectory
    )

    if ($Path.IndexOf([char]0) -ge 0 -or $Path.Contains('\')) {
        throw ('unsafe archive entry path: {0}' -f $Path)
    }
    if ($Path.StartsWith('/') -or $Path.StartsWith('//') -or $Path -match '^[A-Za-z]:') {
        throw ('absolute, drive-qualified, and UNC archive paths are not supported: {0}' -f $Path)
    }

    $trimmed = $Path.TrimEnd('/')
    $components = New-Object Collections.ArrayList
    foreach ($component in $trimmed.Split('/')) {
        if ($component -eq '.') { continue }
        if (-not (Test-PshTarPortablePathComponent -Component $component)) {
            throw ('unsafe archive entry path: {0}' -f $Path)
        }
        [void]$components.Add($component)
    }

    if ($components.Count -eq 0) {
        if ($AllowRootDirectory) { return '' }
        throw ('archive entry path is empty: {0}' -f $Path)
    }
    return (($components | ForEach-Object { [string]$_ }) -join '/')
}

function ConvertTo-PshTarUtf8Bytes {
    param([Parameter(Mandatory = $true)][string] $Value)

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return ,([byte[]]$encoding.GetBytes($Value))
}

function ConvertFrom-PshTarUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Buffer,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][int] $Length
    )

    $end = $Offset
    $limit = $Offset + $Length
    while (($end -lt $limit) -and ($Buffer[$end] -ne 0)) {
        $end++
    }

    if ($end -eq $Offset) {
        return ''
    }

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $encoding.GetString($Buffer, $Offset, $end - $Offset) }
    catch {
        Throw-PshTarInvalidData -Message ('invalid UTF-8 in a USTAR header field: {0}' -f $_.Exception.Message)
    }
}

function Set-PshTarBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Destination,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][int] $Length,
        [Parameter(Mandatory = $true)][byte[]] $Value
    )

    if ($Value.Length -gt $Length) {
        throw 'USTAR header field is too long.'
    }

    [Array]::Copy($Value, 0, $Destination, $Offset, $Value.Length)
}

function Set-PshTarOctalField {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Header,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][int] $Length,
        [Parameter(Mandatory = $true)][long] $Value
    )

    if ($Value -lt 0) {
        throw 'USTAR numeric fields cannot be negative.'
    }

    $digits = [Convert]::ToString($Value, 8)
    if ($digits.Length -gt ($Length - 1)) {
        throw 'Value is too large for a USTAR numeric field.'
    }

    $text = $digits.PadLeft($Length - 1, '0') + [char]0
    Set-PshTarBytes -Destination $Header -Offset $Offset -Length $Length -Value ([Text.Encoding]::ASCII.GetBytes($text))
}

function Get-PshTarOctalField {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Header,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][int] $Length
    )

    if (($Header[$Offset] -band 0x80) -ne 0) {
        Throw-PshTarInvalidData -Message 'Base-256 TAR numeric fields are not supported.'
    }

    $text = [Text.Encoding]::ASCII.GetString($Header, $Offset, $Length).Trim([char]0, [char]32)
    if ($text.Length -eq 0) {
        return [long]0
    }
    if ($text -notmatch '^[0-7]+$') {
        Throw-PshTarInvalidData -Message 'Invalid octal value in USTAR header.'
    }

    $value = [long]0
    foreach ($character in $text.ToCharArray()) {
        $digit = [int]$character - [int][char]'0'
        if ($value -gt (([long]::MaxValue - $digit) / 8)) {
            Throw-PshTarInvalidData -Message 'USTAR numeric field is too large.'
        }
        $value = ($value * 8) + $digit
    }
    return $value
}

function Get-PshTarHeaderChecksum {
    param([Parameter(Mandatory = $true)][byte[]] $Header)

    if ($Header.Length -ne 512) {
        throw 'A USTAR header must be exactly 512 bytes.'
    }

    [long] $sum = 0
    for ($index = 0; $index -lt 512; $index++) {
        if (($index -ge 148) -and ($index -lt 156)) {
            $sum += 32
        }
        else {
            $sum += $Header[$index]
        }
    }
    return $sum
}

function Get-PshTarStringField {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Header,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][int] $Length
    )

    $end = $Offset
    $limit = $Offset + $Length
    while (($end -lt $limit) -and ($Header[$end] -ne 0)) { $end++ }
    for ($index = $end; $index -lt $limit; $index++) {
        if ($Header[$index] -ne 0) {
            Throw-PshTarInvalidData -Message 'invalid non-zero padding in a USTAR string field.'
        }
    }
    if ($end -eq $Offset) { return '' }
    return ConvertFrom-PshTarUtf8Bytes -Buffer $Header -Offset $Offset -Length ($end - $Offset)
}

function Split-PshTarHeaderPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    [byte[]]$pathBytes = ConvertTo-PshTarUtf8Bytes -Value $Path
    if ($pathBytes.Length -le 100) {
        return [PSCustomObject]@{ Name = $Path; Prefix = '' }
    }

    $slashIndex = $Path.LastIndexOf('/')
    while ($slashIndex -gt 0) {
        $prefix = $Path.Substring(0, $slashIndex)
        $name = $Path.Substring($slashIndex + 1)
        if ($name.Length -gt 0 -and
            ([byte[]](ConvertTo-PshTarUtf8Bytes -Value $prefix)).Length -le 155 -and
            ([byte[]](ConvertTo-PshTarUtf8Bytes -Value $name)).Length -le 100) {
            return [PSCustomObject]@{ Name = $name; Prefix = $prefix }
        }
        $slashIndex = $Path.LastIndexOf('/', $slashIndex - 1)
    }
    throw ('archive entry path is too long for USTAR: {0}' -f $Path)
}

function New-PshTarHeader {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string] $Kind,
        [Parameter(Mandatory = $true)][long] $Size,
        [Parameter(Mandatory = $true)][long] $ModifiedTime
    )

    # The typeflag carries directory semantics; omitting the trailing slash
    # from the name also permits a full 100-byte final path component.
    $headerPath = if ($Kind -eq 'Directory') { $Path.TrimEnd('/') } else { $Path }
    $fields = Split-PshTarHeaderPath -Path $headerPath
    $header = New-Object byte[] 512
    Set-PshTarBytes -Destination $header -Offset 0 -Length 100 -Value (ConvertTo-PshTarUtf8Bytes -Value ([string]$fields.Name))
    Set-PshTarOctalField -Header $header -Offset 100 -Length 8 -Value $(if ($Kind -eq 'Directory') { 493 } else { 420 })
    Set-PshTarOctalField -Header $header -Offset 108 -Length 8 -Value 0
    Set-PshTarOctalField -Header $header -Offset 116 -Length 8 -Value 0
    Set-PshTarOctalField -Header $header -Offset 124 -Length 12 -Value $Size
    Set-PshTarOctalField -Header $header -Offset 136 -Length 12 -Value $ModifiedTime
    for ($index = 148; $index -lt 156; $index++) { $header[$index] = 32 }
    $header[156] = if ($Kind -eq 'Directory') { [byte][char]'5' } else { [byte][char]'0' }
    Set-PshTarBytes -Destination $header -Offset 257 -Length 6 -Value ([byte[]](117, 115, 116, 97, 114, 0))
    Set-PshTarBytes -Destination $header -Offset 263 -Length 2 -Value ([Text.Encoding]::ASCII.GetBytes('00'))
    if (-not [string]::IsNullOrEmpty([string]$fields.Prefix)) {
        Set-PshTarBytes -Destination $header -Offset 345 -Length 155 -Value (ConvertTo-PshTarUtf8Bytes -Value ([string]$fields.Prefix))
    }

    $checksum = Get-PshTarHeaderChecksum -Header $header
    $checksumText = [Convert]::ToString($checksum, 8).PadLeft(6, '0') + [char]0 + ' '
    Set-PshTarBytes -Destination $header -Offset 148 -Length 8 -Value ([Text.Encoding]::ASCII.GetBytes($checksumText))
    return ,([byte[]]$header)
}

function Test-PshTarZeroBlock {
    param([Parameter(Mandatory = $true)][byte[]] $Block)

    foreach ($value in $Block) {
        if ($value -ne 0) { return $false }
    }
    return $true
}

function ConvertFrom-PshTarHeader {
    param([Parameter(Mandatory = $true)][byte[]] $Header)

    if ($Header.Length -ne 512) { Throw-PshTarInvalidData -Message 'truncated USTAR header.' }
    $storedChecksum = Get-PshTarOctalField -Header $Header -Offset 148 -Length 8
    $actualChecksum = Get-PshTarHeaderChecksum -Header $Header
    if ($storedChecksum -ne $actualChecksum) { Throw-PshTarInvalidData -Message 'USTAR header checksum mismatch.' }

    $magic = [byte[]](117, 115, 116, 97, 114, 0)
    for ($index = 0; $index -lt $magic.Length; $index++) {
        if ($Header[257 + $index] -ne $magic[$index]) { Throw-PshTarInvalidData -Message 'unsupported TAR format; only POSIX USTAR is accepted.' }
    }
    if ($Header[263] -ne [byte][char]'0' -or $Header[264] -ne [byte][char]'0') {
        Throw-PshTarInvalidData -Message 'unsupported USTAR version.'
    }

    $name = Get-PshTarStringField -Header $Header -Offset 0 -Length 100
    $prefix = Get-PshTarStringField -Header $Header -Offset 345 -Length 155
    $linkName = Get-PshTarStringField -Header $Header -Offset 157 -Length 100
    if ($linkName.Length -ne 0) { Throw-PshTarInvalidData -Message 'archive links are not supported.' }
    if ($name.Length -eq 0) { Throw-PshTarInvalidData -Message 'USTAR entry name is empty.' }
    $path = if ($prefix.Length -eq 0) { $name } else { $prefix + '/' + $name }

    $typeFlag = $Header[156]
    if ($typeFlag -eq 0 -or $typeFlag -eq [byte][char]'0') { $kind = 'File' }
    elseif ($typeFlag -eq [byte][char]'5') { $kind = 'Directory' }
    elseif ($typeFlag -eq [byte][char]'1' -or $typeFlag -eq [byte][char]'2') { Throw-PshTarInvalidData -Message 'archive links are not supported.' }
    else { Throw-PshTarInvalidData -Message ('unsupported USTAR type flag 0x{0:X2}.' -f $typeFlag) }

    [void](Get-PshTarOctalField -Header $Header -Offset 100 -Length 8)
    [void](Get-PshTarOctalField -Header $Header -Offset 108 -Length 8)
    [void](Get-PshTarOctalField -Header $Header -Offset 116 -Length 8)
    $size = Get-PshTarOctalField -Header $Header -Offset 124 -Length 12
    $modifiedTime = Get-PshTarOctalField -Header $Header -Offset 136 -Length 12
    if ($kind -eq 'Directory' -and $size -ne 0) { Throw-PshTarInvalidData -Message 'USTAR directory entries must have size zero.' }

    try {
        $canonicalPath = ConvertTo-PshTarCanonicalEntryPath -Path $path -AllowRootDirectory:($kind -eq 'Directory')
    }
    catch {
        if (Test-PshTarInvalidDataException -Exception $_.Exception) { throw }
        Throw-PshTarInvalidData -Message $_.Exception.Message
    }
    $displayPath = $path
    if ($kind -eq 'Directory' -and -not $displayPath.EndsWith('/')) { $displayPath += '/' }
    return [PSCustomObject]@{
        Path = $canonicalPath
        DisplayPath = $displayPath
        Kind = $kind
        Size = [long]$size
        ModifiedTime = [long]$modifiedTime
    }
}

function Read-PshTarBlock {
    param([Parameter(Mandatory = $true)][IO.Stream] $Stream)

    $buffer = New-Object byte[] 512
    $offset = 0
    while ($offset -lt $buffer.Length) {
        $count = $Stream.Read($buffer, $offset, $buffer.Length - $offset)
        if ($count -eq 0) {
            if ($offset -eq 0) { return $null }
            Throw-PshTarInvalidData -Message 'truncated TAR block.'
        }
        $offset += $count
    }
    return ,([byte[]]$buffer)
}

function Copy-PshTarExactBytes {
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $InputStream,
        [AllowNull()][IO.Stream] $OutputStream,
        [Parameter(Mandatory = $true)][long] $Count,
        [switch] $ArchiveContent
    )

    $buffer = New-Object byte[] 65536
    $remaining = $Count
    while ($remaining -gt 0) {
        $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
        $read = $InputStream.Read($buffer, 0, $requested)
        if ($read -eq 0) {
            if ($ArchiveContent) { Throw-PshTarInvalidData -Message 'archive data is truncated.' }
            throw 'input data was truncated while creating the archive.'
        }
        if ($null -ne $OutputStream) { $OutputStream.Write($buffer, 0, $read) }
        $remaining -= $read
    }
}

function Read-PshTarPadding {
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][long] $Size
    )

    $padding = [int]((512 - ($Size % 512)) % 512)
    if ($padding -eq 0) { return }
    $buffer = New-Object byte[] $padding
    $offset = 0
    while ($offset -lt $padding) {
        $read = $Stream.Read($buffer, $offset, $padding - $offset)
        if ($read -eq 0) { Throw-PshTarInvalidData -Message 'archive data padding is truncated.' }
        $offset += $read
    }
    foreach ($value in $buffer) {
        if ($value -ne 0) { Throw-PshTarInvalidData -Message 'archive data padding is not zero-filled.' }
    }
}

function Write-PshTarPadding {
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][long] $Size
    )

    $padding = [int]((512 - ($Size % 512)) % 512)
    if ($padding -gt 0) {
        $Stream.Write((New-Object byte[] $padding), 0, $padding)
    }
}

function ConvertFrom-PshTarArguments {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq '--help') {
        return [PSCustomObject]@{ Help = $true }
    }

    $initialDirectory = Get-PshTarCurrentDirectory
    $currentDirectory = $initialDirectory
    $action = $null
    $archiveOperand = $null
    $gzip = $false
    $verbose = $false
    $operands = New-Object Collections.ArrayList
    $endOptions = $false

    for ($argumentIndex = 0; $argumentIndex -lt $Arguments.Count; $argumentIndex++) {
        $token = $Arguments[$argumentIndex]
        if (-not $endOptions -and $token -ceq '--') {
            $endOptions = $true
            continue
        }

        if (-not $endOptions -and $token.Length -gt 1 -and $token[0] -eq '-') {
            if ($token.StartsWith('--')) { throw ('unsupported option "{0}".' -f $token) }
            for ($optionIndex = 1; $optionIndex -lt $token.Length; $optionIndex++) {
                $option = [string]$token[$optionIndex]
                if ($option -ceq 'c' -or $option -ceq 'x' -or $option -ceq 't') {
                    if ($null -ne $action) { throw 'exactly one of -c, -x, and -t must be specified.' }
                    $action = $option
                    continue
                }
                if ($option -ceq 'z') { $gzip = $true; continue }
                if ($option -ceq 'v') { $verbose = $true; continue }
                if ($option -ceq 'f' -or $option -ceq 'C') {
                    $value = $null
                    if ($optionIndex + 1 -lt $token.Length) {
                        $value = $token.Substring($optionIndex + 1)
                        $optionIndex = $token.Length
                    }
                    else {
                        $argumentIndex++
                        if ($argumentIndex -ge $Arguments.Count) { throw ('-{0} requires a value.' -f $option) }
                        $value = $Arguments[$argumentIndex]
                    }
                    if ([string]::IsNullOrEmpty($value)) { throw ('-{0} requires a non-empty value.' -f $option) }

                    if ($option -ceq 'f') {
                        if ($null -ne $archiveOperand) { throw '-f may be specified only once.' }
                        $archiveOperand = $value
                    }
                    else {
                        $currentDirectory = Resolve-PshTarPath -Path $value -BasePath $currentDirectory
                    }
                    break
                }
                throw ('unsupported option "-{0}".' -f $option)
            }
            continue
        }

        [void]$operands.Add([PSCustomObject]@{ Value = $token; BasePath = $currentDirectory })
    }

    if ($null -eq $action) { throw 'exactly one of -c, -x, and -t must be specified.' }
    if ($null -eq $archiveOperand) { throw '-f is required.' }
    if ($archiveOperand -ceq '-') { throw 'standard input and standard output archives are not supported; -f must name a file.' }
    if ($action -ceq 'c' -and $operands.Count -eq 0) { throw 'archive creation requires at least one input path.' }
    if ($action -cne 'c' -and $operands.Count -ne 0) { throw 'member selection operands are not supported.' }

    return [PSCustomObject]@{
        Help = $false
        Action = $action
        ArchivePath = (Resolve-PshTarPath -Path $archiveOperand -BasePath $initialDirectory)
        DestinationPath = $currentDirectory
        Gzip = $gzip
        Verbose = $verbose
        Operands = @($operands)
    }
}

function ConvertTo-PshTarCreateEntryPath {
    param([Parameter(Mandatory = $true)][string] $Operand)

    if ([IO.Path]::IsPathRooted($Operand) -or $Operand.StartsWith('/') -or
        $Operand.StartsWith('\') -or $Operand -match '^[A-Za-z]:') {
        throw ('input paths must be relative archive paths: {0}' -f $Operand)
    }
    $portable = $Operand
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $portable = $portable.Replace('\', '/') }
    return ConvertTo-PshTarCanonicalEntryPath -Path $portable -AllowRootDirectory
}

function Get-PshTarModifiedTime {
    param([Parameter(Mandatory = $true)][DateTime] $Value)

    $utcValue = $Value.ToUniversalTime()
    $epoch = [DateTime]::SpecifyKind((New-Object DateTime 1970, 1, 1, 0, 0, 0), [DateTimeKind]::Utc)
    if ($utcValue -lt $epoch) { return [long]0 }
    $seconds = [long][Math]::Floor(($utcValue - $epoch).TotalSeconds)
    if ($seconds -gt 8589934591) { throw 'file modification time is too large for USTAR.' }
    return $seconds
}

function Add-PshTarCreateTree {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $EntryPath,
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.ArrayList] $Manifest,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Names
    )

    Assert-PshTarNoReparseComponents -Path $SourcePath -Root $SourceRoot
    $item = Get-PshTarExistingItem -Path $SourcePath
    if ($null -eq $item) { throw ('input path does not exist: {0}' -f $SourcePath) }
    $kind = Assert-PshTarRegularItem -Item $item -DisplayPath $SourcePath

    if ($kind -eq 'File' -and (Test-PshTarSamePath -Left $SourcePath -Right $ArchivePath)) {
        return
    }

    if ($EntryPath.Length -gt 0) {
        $canonicalPath = ConvertTo-PshTarCanonicalEntryPath -Path $EntryPath
        if (-not $Names.Add($canonicalPath)) { throw ('duplicate archive entry path: {0}' -f $canonicalPath) }
        [void]$Manifest.Add([PSCustomObject]@{
            Path = $canonicalPath
            SourcePath = [string]$item.FullName
            SourceRoot = $SourceRoot
            Kind = $kind
        })
    }

    if ($kind -ne 'Directory') { return }
    $children = @(
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop |
            Microsoft.PowerShell.Utility\Sort-Object -Property Name
    )
    foreach ($child in $children) {
        [void](Assert-PshTarRegularItem -Item $child -DisplayPath ([string]$child.FullName))
        $childPath = if ($EntryPath.Length -eq 0) { [string]$child.Name } else { $EntryPath + '/' + [string]$child.Name }
        $childCanonicalPath = ConvertTo-PshTarCanonicalEntryPath -Path $childPath
        Add-PshTarCreateTree -SourcePath ([string]$child.FullName) -EntryPath $childCanonicalPath -SourceRoot $SourceRoot -ArchivePath $ArchivePath -Manifest $Manifest -Names $Names
    }
}

function Get-PshTarCreateManifest {
    param(
        [Parameter(Mandatory = $true)][object[]] $Operands,
        [Parameter(Mandatory = $true)][string] $ArchivePath
    )

    $manifest = New-Object Collections.ArrayList
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($operand in $Operands) {
        $basePath = [IO.Path]::GetFullPath([string]$operand.BasePath)
        Assert-PshTarNoReparseComponents -Path $basePath -Root $basePath
        $entryPath = ConvertTo-PshTarCreateEntryPath -Operand ([string]$operand.Value)
        $sourcePath = Resolve-PshTarPath -Path ([string]$operand.Value) -BasePath $basePath
        if (-not (Test-PshTarPathWithinRoot -Path $sourcePath -Root $basePath)) {
            throw ('input path escapes the -C directory: {0}' -f [string]$operand.Value)
        }
        Add-PshTarCreateTree -SourcePath $sourcePath -EntryPath $entryPath -SourceRoot $basePath -ArchivePath $ArchivePath -Manifest $manifest -Names $names
    }
    if ($manifest.Count -eq 0) { throw 'no archive entries remain after excluding the output archive.' }
    return @($manifest)
}

function Move-PshTarArchiveCommitFile {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    [IO.File]::Move($SourcePath, $DestinationPath)
}

function Remove-PshTarArchiveCommitFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    [IO.File]::Delete($Path)
}

function Commit-PshTarStagedArchive {
    param(
        [Parameter(Mandatory = $true)][string] $StagePath,
        [Parameter(Mandatory = $true)][string] $TargetPath
    )

    $targetItem = Get-PshTarExistingItem -Path $TargetPath
    if ($null -ne $targetItem) {
        $targetKind = Assert-PshTarRegularItem -Item $targetItem -DisplayPath $TargetPath
        if ($targetKind -ne 'File') { throw ('archive target is not a regular file: {0}' -f $TargetPath) }
        $parent = [IO.Path]::GetDirectoryName($TargetPath)
        $backupPath = New-PshTarTemporaryPath -Directory $parent -Prefix '.psh-tar-backup-'
        Move-PshTarArchiveCommitFile -SourcePath $TargetPath -DestinationPath $backupPath
        try {
            Move-PshTarArchiveCommitFile -SourcePath $StagePath -DestinationPath $TargetPath
        }
        catch {
            $commitFailure = $_.Exception
            $rollbackFailures = New-Object Collections.ArrayList
            if ([IO.File]::Exists($TargetPath)) {
                try { Remove-PshTarArchiveCommitFile -Path $TargetPath }
                catch {
                    [void]$rollbackFailures.Add(('delete partially installed archive "{0}" failed: {1}' -f $TargetPath, $_.Exception.Message))
                }
            }
            if ([IO.File]::Exists($backupPath)) {
                try { Move-PshTarArchiveCommitFile -SourcePath $backupPath -DestinationPath $TargetPath }
                catch {
                    [void]$rollbackFailures.Add(('restore previous archive "{0}" from "{1}" failed: {2}' -f $TargetPath, $backupPath, $_.Exception.Message))
                }
            }
            if ($rollbackFailures.Count -ne 0) {
                $message = 'archive replacement failed: {0}; rollback failed: {1}' -f $commitFailure.Message, ($rollbackFailures -join ' | ')
                if ([IO.File]::Exists($backupPath)) {
                    $message += '. Previous archive backup remains at: {0}' -f $backupPath
                }
                throw (New-Object IO.IOException($message, $commitFailure))
            }
            throw
        }
        try {
            Remove-PshTarArchiveCommitFile -Path $backupPath
        }
        catch {
            $cleanupFailure = $_.Exception
            $message = 'archive replacement committed, but previous archive backup cleanup failed: {0}' -f $cleanupFailure.Message
            if ([IO.File]::Exists($backupPath)) {
                $message += '. Previous archive backup remains at: {0}' -f $backupPath
            }
            else {
                $message += '. The backup path no longer exists: {0}' -f $backupPath
            }
            throw (New-Object IO.IOException($message, $cleanupFailure))
        }
        return
    }
    Move-PshTarArchiveCommitFile -SourcePath $StagePath -DestinationPath $TargetPath
}

function Invoke-PshTarCreate {
    param([Parameter(Mandatory = $true)][object] $Options)

    $archivePath = [IO.Path]::GetFullPath([string]$Options.ArchivePath)
    $archiveParent = [IO.Path]::GetDirectoryName($archivePath)
    $parentItem = Get-PshTarExistingItem -Path $archiveParent
    if ($null -eq $parentItem -or -not $parentItem.PSIsContainer) {
        throw ('archive parent directory does not exist: {0}' -f $archiveParent)
    }
    [void](Assert-PshTarRegularItem -Item $parentItem -DisplayPath $archiveParent)
    $manifest = @(Get-PshTarCreateManifest -Operands @($Options.Operands) -ArchivePath $archivePath)
    $stagePath = New-PshTarTemporaryPath -Directory $archiveParent -Prefix '.psh-tar-stage-'
    $fileStream = $null
    $archiveStream = $null
    try {
        $fileStream = New-Object IO.FileStream($stagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ([bool]$Options.Gzip) {
            $archiveStream = New-Object IO.Compression.GZipStream($fileStream, [IO.Compression.CompressionMode]::Compress, $true)
        }
        else {
            $archiveStream = $fileStream
        }

        foreach ($entry in $manifest) {
            Assert-PshTarNoReparseComponents -Path ([string]$entry.SourcePath) -Root ([string]$entry.SourceRoot)
            $item = Get-PshTarExistingItem -Path ([string]$entry.SourcePath)
            if ($null -eq $item) { throw ('input disappeared while creating archive: {0}' -f [string]$entry.SourcePath) }
            $actualKind = Assert-PshTarRegularItem -Item $item -DisplayPath ([string]$entry.SourcePath)
            if ($actualKind -cne [string]$entry.Kind) { throw ('input type changed while creating archive: {0}' -f [string]$entry.SourcePath) }
            $modifiedTime = Get-PshTarModifiedTime -Value ([DateTime]$item.LastWriteTimeUtc)

            if ($actualKind -eq 'Directory') {
                $header = New-PshTarHeader -Path ([string]$entry.Path) -Kind Directory -Size 0 -ModifiedTime $modifiedTime
                $archiveStream.Write($header, 0, $header.Length)
                continue
            }

            $inputStream = New-Object IO.FileStream(([string]$entry.SourcePath), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $size = [long]$inputStream.Length
                $header = New-PshTarHeader -Path ([string]$entry.Path) -Kind File -Size $size -ModifiedTime $modifiedTime
                $archiveStream.Write($header, 0, $header.Length)
                Copy-PshTarExactBytes -InputStream $inputStream -OutputStream $archiveStream -Count $size
                Write-PshTarPadding -Stream $archiveStream -Size $size
            }
            finally { $inputStream.Dispose() }
        }

        $endBlocks = New-Object byte[] 1024
        $archiveStream.Write($endBlocks, 0, $endBlocks.Length)
        if ($archiveStream -ne $fileStream) { $archiveStream.Dispose(); $archiveStream = $null }
        $fileStream.Flush()
        $fileStream.Dispose()
        $fileStream = $null
        Commit-PshTarStagedArchive -StagePath $stagePath -TargetPath $archivePath
    }
    finally {
        if ($null -ne $archiveStream -and $archiveStream -ne $fileStream) { $archiveStream.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if ([IO.File]::Exists($stagePath)) { [IO.File]::Delete($stagePath) }
    }
    return $manifest
}

function Get-PshTarCollisionKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Path)

    return $Path.Normalize([Text.NormalizationForm]::FormC).ToUpperInvariant()
}

function Get-PshTarExtractionPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $EntryPath
    )

    if ($EntryPath.Length -eq 0) { return [IO.Path]::GetFullPath($Root) }
    $relativePath = $EntryPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $targetPath = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $relativePath))
    if (-not (Test-PshTarPathWithinRoot -Path $targetPath -Root $Root)) {
        Throw-PshTarInvalidData -Message ('archive entry escapes the extraction directory: {0}' -f $EntryPath)
    }
    return $targetPath
}

function Assert-PshTarArchiveRecordPath {
    param(
        [Parameter(Mandatory = $true)][object] $Record,
        [Parameter(Mandatory = $true)][AllowNull()][object] $ExplicitNames,
        [Parameter(Mandatory = $true)][AllowNull()][object] $RequiredDirectories,
        [Parameter(Mandatory = $true)][AllowNull()][object] $FileNames
    )

    $path = [string]$Record.Path
    $key = Get-PshTarCollisionKey -Path $path
    if (-not $ExplicitNames.Add($key)) {
        Throw-PshTarInvalidData -Message ('duplicate or non-portable colliding archive path: {0}' -f [string]$Record.DisplayPath)
    }
    if ($path.Length -eq 0) { return }

    $components = $path.Split('/')
    $ancestor = ''
    for ($index = 0; $index -lt ($components.Length - 1); $index++) {
        $ancestor = if ($ancestor.Length -eq 0) { $components[$index] } else { $ancestor + '/' + $components[$index] }
        $ancestorKey = Get-PshTarCollisionKey -Path $ancestor
        if ($FileNames.Contains($ancestorKey)) {
            Throw-PshTarInvalidData -Message ('archive file conflicts with descendant path: {0}' -f [string]$Record.DisplayPath)
        }
        [void]$RequiredDirectories.Add($ancestorKey)
    }

    if ([string]$Record.Kind -eq 'File') {
        if ($RequiredDirectories.Contains($key)) {
            Throw-PshTarInvalidData -Message ('archive file conflicts with a directory path: {0}' -f [string]$Record.DisplayPath)
        }
        [void]$FileNames.Add($key)
    }
    else {
        if ($FileNames.Contains($key)) {
            Throw-PshTarInvalidData -Message ('archive directory conflicts with a file path: {0}' -f [string]$Record.DisplayPath)
        }
        [void]$RequiredDirectories.Add($key)
    }
}

function Read-PshTarTrailingData {
    param([Parameter(Mandatory = $true)][IO.Stream] $Stream)

    $buffer = New-Object byte[] 65536
    [long]$total = 0
    while ($true) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -eq 0) { break }
        for ($index = 0; $index -lt $read; $index++) {
            if ($buffer[$index] -ne 0) { Throw-PshTarInvalidData -Message 'non-zero data follows the USTAR end markers.' }
        }
        $total += $read
    }
    if (($total % 512) -ne 0) { Throw-PshTarInvalidData -Message 'trailing TAR data is not block-aligned.' }
}

function Read-PshTarArchive {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][bool] $Gzip,
        [AllowNull()][string] $PayloadRoot
    )

    $archiveParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ArchivePath))
    Assert-PshTarNoReparseComponents -Path $ArchivePath -Root $archiveParent
    $archiveItem = Get-PshTarExistingItem -Path $ArchivePath
    if ($null -eq $archiveItem) { throw ('archive does not exist: {0}' -f $ArchivePath) }
    $archiveKind = Assert-PshTarRegularItem -Item $archiveItem -DisplayPath $ArchivePath
    if ($archiveKind -ne 'File') { throw ('archive is not a regular file: {0}' -f $ArchivePath) }

    $records = New-Object Collections.ArrayList
    $explicitNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $requiredDirectories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $fileNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $fileStream = $null
    $archiveStream = $null
    try {
        $fileStream = New-Object IO.FileStream($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($Gzip) {
            $archiveStream = New-Object IO.Compression.GZipStream($fileStream, [IO.Compression.CompressionMode]::Decompress, $true)
        }
        else {
            $archiveStream = $fileStream
        }

        while ($true) {
            $headerBlock = Read-PshTarBlock -Stream $archiveStream
            if ($null -eq $headerBlock) { Throw-PshTarInvalidData -Message 'archive is missing its USTAR end markers.' }
            if (Test-PshTarZeroBlock -Block $headerBlock) {
                $secondEndBlock = Read-PshTarBlock -Stream $archiveStream
                if ($null -eq $secondEndBlock -or -not (Test-PshTarZeroBlock -Block $secondEndBlock)) {
                    Throw-PshTarInvalidData -Message 'archive has an invalid USTAR end marker.'
                }
                Read-PshTarTrailingData -Stream $archiveStream
                break
            }

            $parsed = ConvertFrom-PshTarHeader -Header $headerBlock
            Assert-PshTarArchiveRecordPath -Record $parsed -ExplicitNames $explicitNames -RequiredDirectories $requiredDirectories -FileNames $fileNames
            $stagePath = $null
            if (-not [string]::IsNullOrEmpty($PayloadRoot) -and [string]$parsed.Path -ne '') {
                $stagePath = Get-PshTarExtractionPath -Root $PayloadRoot -EntryPath ([string]$parsed.Path)
            }

            if ([string]$parsed.Kind -eq 'Directory') {
                if ($null -ne $stagePath) { [void][IO.Directory]::CreateDirectory($stagePath) }
            }
            else {
                $outputStream = $null
                try {
                    if ($null -ne $stagePath) {
                        $stageParent = [IO.Path]::GetDirectoryName($stagePath)
                        [void][IO.Directory]::CreateDirectory($stageParent)
                        $outputStream = New-Object IO.FileStream($stagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    }
                    Copy-PshTarExactBytes -InputStream $archiveStream -OutputStream $outputStream -Count ([long]$parsed.Size) -ArchiveContent
                }
                finally {
                    if ($null -ne $outputStream) { $outputStream.Dispose() }
                }
                Read-PshTarPadding -Stream $archiveStream -Size ([long]$parsed.Size)
            }

            [void]$records.Add([PSCustomObject]@{
                Path = [string]$parsed.Path
                DisplayPath = [string]$parsed.DisplayPath
                Kind = [string]$parsed.Kind
                Size = [long]$parsed.Size
                ModifiedTime = [long]$parsed.ModifiedTime
                StagePath = $stagePath
            })
        }
    }
    finally {
        if ($null -ne $archiveStream -and $archiveStream -ne $fileStream) { $archiveStream.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
    }
    return @($records)
}

function Get-PshTarRequiredDirectoryPaths {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Records)

    $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($record in $Records) {
        $path = [string]$record.Path
        if ($path.Length -eq 0) { continue }
        if ([string]$record.Kind -eq 'Directory') { [void]$paths.Add($path) }
        $parent = $path
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            if ($parent.Length -gt 0) { [void]$paths.Add($parent) }
        }
    }
    return @($paths | Microsoft.PowerShell.Utility\Sort-Object @{ Expression = { ([string]$_).Split('/').Length } }, @{ Expression = { [string]$_ } })
}

function Assert-PshTarExtractionTarget {
    param(
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string] $Kind,
        [Parameter(Mandatory = $true)][string] $StageRoot
    )

    if (-not (Test-PshTarPathWithinRoot -Path $TargetPath -Root $DestinationRoot)) {
        throw ('extraction target escapes the destination: {0}' -f $TargetPath)
    }
    if (Test-PshTarPathWithinRoot -Path $TargetPath -Root $StageRoot) {
        throw ('archive entry conflicts with the extraction staging directory: {0}' -f $TargetPath)
    }

    $relative = $TargetPath.Substring($DestinationRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Length)
    $relative = $relative.TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $components = $relative.Split(@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)
    $current = $DestinationRoot
    for ($index = 0; $index -lt $components.Length; $index++) {
        $current = [IO.Path]::Combine($current, $components[$index])
        $item = Get-PshTarExistingItem -Path $current
        if ($null -eq $item) { continue }
        $actualKind = Assert-PshTarRegularItem -Item $item -DisplayPath $current
        $expectedKind = if ($index -eq ($components.Length - 1)) { $Kind } else { 'Directory' }
        if ($actualKind -cne $expectedKind) {
            throw ('extraction path has a {0} where a {1} is required: {2}' -f $actualKind.ToLowerInvariant(), $expectedKind.ToLowerInvariant(), $current)
        }
    }
}

function Move-PshTarExtractionFile {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    [IO.File]::Move($SourcePath, $DestinationPath)
}

function Commit-PshTarExtraction {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Records,
        [Parameter(Mandatory = $true)][string] $DestinationRoot,
        [Parameter(Mandatory = $true)][string] $StageRoot
    )

    $directoryPaths = @(Get-PshTarRequiredDirectoryPaths -Records $Records)
    foreach ($directoryPath in $directoryPaths) {
        $target = Get-PshTarExtractionPath -Root $DestinationRoot -EntryPath $directoryPath
        Assert-PshTarExtractionTarget -DestinationRoot $DestinationRoot -TargetPath $target -Kind Directory -StageRoot $StageRoot
    }
    foreach ($record in $Records) {
        if ([string]$record.Kind -ne 'File') { continue }
        $target = Get-PshTarExtractionPath -Root $DestinationRoot -EntryPath ([string]$record.Path)
        Assert-PshTarExtractionTarget -DestinationRoot $DestinationRoot -TargetPath $target -Kind File -StageRoot $StageRoot
    }

    $createdDirectories = New-Object Collections.ArrayList
    $operations = New-Object Collections.ArrayList
    $rollbackRoot = [IO.Path]::Combine($StageRoot, 'rollback')
    [void][IO.Directory]::CreateDirectory($rollbackRoot)
    try {
        foreach ($directoryPath in $directoryPaths) {
            $target = Get-PshTarExtractionPath -Root $DestinationRoot -EntryPath $directoryPath
            if ($null -eq (Get-PshTarExistingItem -Path $target)) {
                [void][IO.Directory]::CreateDirectory($target)
                [void]$createdDirectories.Add($target)
            }
        }

        $operationIndex = 0
        foreach ($record in $Records) {
            if ([string]$record.Kind -ne 'File') { continue }
            $target = Get-PshTarExtractionPath -Root $DestinationRoot -EntryPath ([string]$record.Path)
            Assert-PshTarExtractionTarget -DestinationRoot $DestinationRoot -TargetPath $target -Kind File -StageRoot $StageRoot
            $backupPath = [IO.Path]::Combine($rollbackRoot, ('{0:D8}.bak' -f $operationIndex))
            $operationIndex++
            $operation = [PSCustomObject]@{ Target = $target; Backup = $backupPath; HadOriginal = $false; Installed = $false }
            [void]$operations.Add($operation)

            if ($null -ne (Get-PshTarExistingItem -Path $target)) {
                Move-PshTarExtractionFile -SourcePath $target -DestinationPath $backupPath
                $operation.HadOriginal = $true
            }
            Move-PshTarExtractionFile -SourcePath ([string]$record.StagePath) -DestinationPath $target
            $operation.Installed = $true
        }
    }
    catch {
        $commitFailure = $_.Exception
        $rollbackFailures = New-Object Collections.ArrayList
        for ($index = $operations.Count - 1; $index -ge 0; $index--) {
            $operation = $operations[$index]
            if ($operation.Installed -and [IO.File]::Exists([string]$operation.Target)) {
                try {
                    [IO.File]::Delete([string]$operation.Target)
                }
                catch {
                    [void]$rollbackFailures.Add(('delete installed target "{0}" failed: {1}' -f [string]$operation.Target, $_.Exception.Message))
                }
            }
            if ($operation.HadOriginal -and [IO.File]::Exists([string]$operation.Backup)) {
                try {
                    Move-PshTarExtractionFile -SourcePath ([string]$operation.Backup) -DestinationPath ([string]$operation.Target)
                }
                catch {
                    [void]$rollbackFailures.Add(('restore original target "{0}" from "{1}" failed: {2}' -f [string]$operation.Target, [string]$operation.Backup, $_.Exception.Message))
                }
            }
        }
        for ($index = $createdDirectories.Count - 1; $index -ge 0; $index--) {
            try { [IO.Directory]::Delete([string]$createdDirectories[$index], $false) }
            catch {
                [void]$rollbackFailures.Add(('remove created directory "{0}" failed: {1}' -f [string]$createdDirectories[$index], $_.Exception.Message))
            }
        }
        if ($rollbackFailures.Count -ne 0) {
            $remainingBackups = @(
                $operations |
                    Where-Object { $_.HadOriginal -and [IO.File]::Exists([string]$_.Backup) } |
                    ForEach-Object { [string]$_.Backup }
            )
            $message = 'extraction commit failed: {0}; rollback failed: {1}' -f $commitFailure.Message, ($rollbackFailures -join ' | ')
            if ($remainingBackups.Count -ne 0) {
                $message += '. Original file backup(s) remain at: {0}' -f ($remainingBackups -join ' | ')
            }
            throw (New-Object IO.IOException($message, $commitFailure))
        }
        throw
    }
}

function Invoke-PshTarExtract {
    param([Parameter(Mandatory = $true)][object] $Options)

    $destinationRoot = [IO.Path]::GetFullPath([string]$Options.DestinationPath)
    Assert-PshTarNoReparseComponents -Path $destinationRoot -Root $destinationRoot
    $destinationItem = Get-PshTarExistingItem -Path $destinationRoot
    if ($null -eq $destinationItem -or -not $destinationItem.PSIsContainer) {
        throw ('extraction directory does not exist: {0}' -f $destinationRoot)
    }

    $stageRoot = New-PshTarTemporaryPath -Directory $destinationRoot -Prefix '.psh-tar-extract-'
    [void][IO.Directory]::CreateDirectory($stageRoot)
    $payloadRoot = [IO.Path]::Combine($stageRoot, 'payload')
    [void][IO.Directory]::CreateDirectory($payloadRoot)
    $preserveStageRoot = $false
    try {
        $records = @(Read-PshTarArchive -ArchivePath ([string]$Options.ArchivePath) -Gzip ([bool]$Options.Gzip) -PayloadRoot $payloadRoot)
        Commit-PshTarExtraction -Records $records -DestinationRoot $destinationRoot -StageRoot $stageRoot
        return $records
    }
    catch {
        $failure = $_.Exception
        $rollbackRoot = [IO.Path]::Combine($stageRoot, 'rollback')
        $remainingBackups = @()
        $inspectionFailure = $null
        try {
            if ([IO.Directory]::Exists($rollbackRoot)) {
                $remainingBackups = @([IO.Directory]::GetFiles($rollbackRoot, '*.bak', [IO.SearchOption]::TopDirectoryOnly))
            }
        }
        catch {
            $inspectionFailure = $_.Exception
        }

        if ($remainingBackups.Count -ne 0 -or $null -ne $inspectionFailure) {
            $preserveStageRoot = $true
            if ($remainingBackups.Count -ne 0) {
                $preservationReason = 'rollback backup(s) remain: {0}' -f ($remainingBackups -join ' | ')
            }
            else {
                $preservationReason = 'rollback backups could not be inspected: {0}' -f $inspectionFailure.Message
            }
            $message = '{0}. Extraction staging was preserved at "{1}" because {2}' -f $failure.Message, $stageRoot, $preservationReason
            throw (New-Object IO.IOException($message, $failure))
        }
        throw
    }
    finally {
        if (-not $preserveStageRoot -and [IO.Directory]::Exists($stageRoot)) { [IO.Directory]::Delete($stageRoot, $true) }
    }
}

function Format-PshTarListRecord {
    param(
        [Parameter(Mandatory = $true)][object] $Record,
        [Parameter(Mandatory = $true)][bool] $LongListing
    )

    if (-not $LongListing) { return [string]$Record.DisplayPath }
    $kind = if ([string]$Record.Kind -eq 'Directory') { 'd' } else { '-' }
    return ('{0}--------- 0/0 {1,12} {2}' -f $kind, [long]$Record.Size, [string]$Record.DisplayPath)
}

function Invoke-PshTarList {
    param([Parameter(Mandatory = $true)][object] $Options)

    return @(Read-PshTarArchive -ArchivePath ([string]$Options.ArchivePath) -Gzip ([bool]$Options.Gzip) -PayloadRoot $null)
}

function tar {
    $arguments = @(ConvertTo-PshTarArgumentArray -InputArguments $args)
    Set-PshTarExitCode -Code 0
    try {
        $options = ConvertFrom-PshTarArguments -Arguments $arguments
    }
    catch {
        Write-PshTarFailure -Code 2 -Message $_.Exception.Message
        return
    }

    if ([bool]$options.Help) {
        Microsoft.PowerShell.Utility\Write-Output 'Usage: tar -c|-x|-t -f ARCHIVE [-zv] [-C DIRECTORY] [PATH ...]'
        Set-PshTarExitCode -Code 0
        return
    }

    try {
        if ([string]$options.Action -ceq 'c') {
            $records = @(Invoke-PshTarCreate -Options $options)
            if ([bool]$options.Verbose) {
                foreach ($record in $records) {
                    $displayPath = [string]$record.Path
                    if ([string]$record.Kind -eq 'Directory') { $displayPath += '/' }
                    Microsoft.PowerShell.Utility\Write-Output $displayPath
                }
            }
        }
        elseif ([string]$options.Action -ceq 't') {
            $records = @(Invoke-PshTarList -Options $options)
            foreach ($record in $records) {
                Microsoft.PowerShell.Utility\Write-Output (Format-PshTarListRecord -Record $record -LongListing ([bool]$options.Verbose))
            }
        }
        else {
            $records = @(Invoke-PshTarExtract -Options $options)
            if ([bool]$options.Verbose) {
                foreach ($record in $records) {
                    Microsoft.PowerShell.Utility\Write-Output ([string]$record.DisplayPath)
                }
            }
        }
        Set-PshTarExitCode -Code 0
    }
    catch {
        $code = if (Test-PshTarInvalidDataException -Exception $_.Exception) { 5 } else { 3 }
        Write-PshTarFailure -Code $code -Message $_.Exception.Message
    }
}
