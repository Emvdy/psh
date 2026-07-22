# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

$script:PshCompressionChecksumCommandNames = @(
    'gzip', 'gunzip', 'sha256sum', 'md5sum'
)

function Get-PshEnabledCompressionChecksumCommandNames {
    $enabled = @()
    foreach ($name in $script:PshCompressionChecksumCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function Test-PshGzipInvalidDataException {
    param(
        [Parameter(Mandatory = $true)]
        [Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.InvalidDataException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Throw-PshGzipInvalidData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-Object IO.InvalidDataException($Message))
}

function New-PshChecksumAlgorithm {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SHA256', 'MD5')]
        [string]$Algorithm
    )

    if ($Algorithm -ceq 'SHA256') { return [Security.Cryptography.SHA256]::Create() }
    return [Security.Cryptography.MD5]::Create()
}

function Get-PshChecksumHexFromStream {
    param(
        [Parameter(Mandatory = $true)]
        [IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SHA256', 'MD5')]
        [string]$Algorithm
    )

    $hasher = New-PshChecksumAlgorithm -Algorithm $Algorithm
    try {
        $hash = [byte[]]$hasher.ComputeHash($Stream)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    }
    finally { $hasher.Dispose() }
}

function ConvertTo-PshChecksumInputBytes {
    param(
        [AllowNull()]
        [object[]]$Items
    )

    $source = New-PshPipelineTextSource -Items $Items
    return ,([byte[]]$source.Bytes)
}

function New-PshChecksumInputState {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    return [PSCustomObject]@{
        Bytes = [byte[]]$Bytes
        Consumed = $false
    }
}

function Open-PshChecksumOperandStream {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operand,

        [Parameter(Mandatory = $true)]
        [object]$InputState
    )

    if ($Operand -ceq '-') {
        $bytes = [byte[]]@()
        if (-not [bool]$InputState.Consumed) {
            $bytes = [byte[]]$InputState.Bytes
            $InputState.Consumed = $true
        }
        return (New-Object IO.MemoryStream(,$bytes))
    }

    $path = Resolve-PshFileSystemPath -Path $Operand
    if (-not [IO.File]::Exists($path)) {
        throw ('not a regular file: {0}' -f $Operand)
    }
    return (New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
}

function ConvertTo-PshChecksumUtf8Bytes {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) { $Text = '' }
    $encoding = New-Object Text.UTF8Encoding($false)
    return ,([byte[]]$encoding.GetBytes($Text))
}

function ConvertFrom-PshChecksumUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $encoding = New-Object Text.UTF8Encoding($false, $true)
    return $encoding.GetString($Bytes)
}

function ConvertTo-PshEscapedChecksumName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $escaped = $Name.Replace('\', '\\').Replace("`r", '\r').Replace("`n", '\n')
    return [PSCustomObject]@{
        Text = $escaped
        Required = -not [string]::Equals($escaped, $Name, [StringComparison]::Ordinal)
    }
}

function ConvertFrom-PshEscapedChecksumName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $Name.Length; $index++) {
        $character = $Name[$index]
        if ($character -ne '\') {
            [void]$builder.Append($character)
            continue
        }
        $index++
        if ($index -ge $Name.Length) { throw 'trailing checksum filename escape.' }
        switch ([string]$Name[$index]) {
            '\' { [void]$builder.Append('\') }
            'n' { [void]$builder.Append("`n") }
            'r' { [void]$builder.Append("`r") }
            default { throw ('unsupported checksum filename escape "\{0}".' -f [string]$Name[$index]) }
        }
    }
    return $builder.ToString()
}

function Test-PshChecksumHexText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    if ($Text.Length -ne $Length) { return $false }
    foreach ($character in $Text.ToCharArray()) {
        if (-not (($character -ge '0' -and $character -le '9') -or
            ($character -ge 'a' -and $character -le 'f') -or
            ($character -ge 'A' -and $character -le 'F'))) {
            return $false
        }
    }
    return $true
}

function ConvertFrom-PshChecksumRecord {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Record,

        [Parameter(Mandatory = $true)]
        [int]$HashLength,

        [switch]$NullDelimited
    )

    $offset = 0
    $escaped = $false
    if (-not $NullDelimited -and $Record.Length -gt 0 -and $Record[0] -eq '\') {
        $escaped = $true
        $offset = 1
    }
    if (($Record.Length - $offset) -lt ($HashLength + 3)) { throw 'checksum record is too short.' }

    $hash = $Record.Substring($offset, $HashLength)
    if (-not (Test-PshChecksumHexText -Text $hash -Length $HashLength)) { throw 'checksum hash is malformed.' }
    if ($Record[$offset + $HashLength] -ne ' ') { throw 'checksum hash must be followed by a space.' }
    $marker = $Record[$offset + $HashLength + 1]
    if ($marker -ne ' ' -and $marker -ne '*') { throw 'checksum mode marker must be a space or asterisk.' }

    $name = $Record.Substring($offset + $HashLength + 2)
    if ($name.Length -eq 0) { throw 'checksum filename is empty.' }
    if ($escaped) { $name = ConvertFrom-PshEscapedChecksumName -Name $name }
    if ($name.IndexOf([char]0) -ge 0) { throw 'checksum filename contains NUL.' }

    return [PSCustomObject]@{
        Hash = $hash.ToLowerInvariant()
        Marker = [string]$marker
        Name = $name
    }
}

function Split-PshChecksumRecords {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [switch]$NullDelimited
    )

    $records = New-Object 'System.Collections.Generic.List[string]'
    if (-not $NullDelimited) {
        $text = ConvertFrom-PshChecksumUtf8Bytes -Bytes $Bytes
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        $reader = New-Object IO.StringReader($text)
        try {
            while ($null -ne ($line = $reader.ReadLine())) { $records.Add([string]$line) }
        }
        finally { $reader.Dispose() }
        return $records.ToArray()
    }

    $start = 0
    for ($index = 0; $index -le $Bytes.Length; $index++) {
        if ($index -lt $Bytes.Length -and $Bytes[$index] -ne 0) { continue }
        if ($index -eq $Bytes.Length -and $start -eq $Bytes.Length) { break }
        $length = $index - $start
        $segment = New-Object byte[] $length
        if ($length -gt 0) { [Array]::Copy($Bytes, $start, $segment, 0, $length) }
        $record = ConvertFrom-PshChecksumUtf8Bytes -Bytes $segment
        if ($records.Count -eq 0 -and $record.Length -gt 0 -and $record[0] -eq [char]0xFEFF) {
            $record = $record.Substring(1)
        }
        $records.Add($record)
        $start = $index + 1
    }
    return $records.ToArray()
}

function Get-PshChecksumSafeDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $Name.Replace('\', '\\').Replace("`r", '\r').Replace("`n", '\n')
}

function Invoke-PshChecksumCompute {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SHA256', 'MD5')]
        [string]$Algorithm,

        [Parameter(Mandatory = $true)]
        [string[]]$Operands,

        [Parameter(Mandatory = $true)]
        [object]$InputState,

        [Parameter(Mandatory = $true)]
        [ValidateSet(' ', '*')]
        [string]$Marker,

        [switch]$NullDelimited
    )

    $failed = $false
    foreach ($operand in $Operands) {
        $stream = $null
        try {
            $stream = Open-PshChecksumOperandStream -Operand $operand -InputState $InputState
            $hash = Get-PshChecksumHexFromStream -Stream $stream -Algorithm $Algorithm
            if ($NullDelimited) {
                $recordBytes = ConvertTo-PshChecksumUtf8Bytes -Text ('{0} {1}{2}{3}' -f $hash, $Marker, $operand, [char]0)
                Write-PshRawBytes -Bytes $recordBytes
            }
            else {
                $name = ConvertTo-PshEscapedChecksumName -Name $operand
                $prefix = if ([bool]$name.Required) { '\' } else { '' }
                Write-Output ('{0}{1} {2}{3}' -f $prefix, $hash, $Marker, [string]$name.Text)
            }
        }
        catch {
            Write-PshCommandFailure -Command $Command -Code 3 -Message ('{0}: {1}' -f $operand, $_.Exception.Message)
            $failed = $true
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    if ($failed) { Set-PshLastExitCode -Code 3 } else { Set-PshLastExitCode -Code 0 }
}

function Invoke-PshChecksumCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SHA256', 'MD5')]
        [string]$Algorithm,

        [Parameter(Mandatory = $true)]
        [string[]]$Operands,

        [Parameter(Mandatory = $true)]
        [object]$InputState,

        [switch]$NullDelimited
    )

    $hashLength = if ($Algorithm -ceq 'SHA256') { 64 } else { 32 }
    $verificationFailed = $false
    $runtimeFailed = $false
    foreach ($operand in $Operands) {
        $listStream = $null
        try {
            $listStream = Open-PshChecksumOperandStream -Operand $operand -InputState $InputState
            $buffer = New-Object IO.MemoryStream
            try {
                $listStream.CopyTo($buffer)
                $records = @(Split-PshChecksumRecords -Bytes ([byte[]]$buffer.ToArray()) -NullDelimited:$NullDelimited)
            }
            finally { $buffer.Dispose() }
            if ($records.Count -eq 0) {
                Write-Output ('{0}: no checksum records found' -f (Get-PshChecksumSafeDisplayName -Name $operand))
                $verificationFailed = $true
                continue
            }

            for ($recordIndex = 0; $recordIndex -lt $records.Count; $recordIndex++) {
                try {
                    $record = ConvertFrom-PshChecksumRecord -Record ([string]$records[$recordIndex]) -HashLength $hashLength -NullDelimited:$NullDelimited
                }
                catch {
                    Write-Output ('{0}: record {1}: malformed' -f (Get-PshChecksumSafeDisplayName -Name $operand), ($recordIndex + 1))
                    $verificationFailed = $true
                    continue
                }

                $dataStream = $null
                $matches = $false
                try {
                    $dataStream = Open-PshChecksumOperandStream -Operand ([string]$record.Name) -InputState $InputState
                    $actual = Get-PshChecksumHexFromStream -Stream $dataStream -Algorithm $Algorithm
                    $matches = [string]::Equals($actual, [string]$record.Hash, [StringComparison]::OrdinalIgnoreCase)
                }
                catch { $matches = $false }
                finally { if ($null -ne $dataStream) { $dataStream.Dispose() } }

                $displayName = Get-PshChecksumSafeDisplayName -Name ([string]$record.Name)
                if ($matches) { Write-Output ('{0}: OK' -f $displayName) }
                else {
                    Write-Output ('{0}: FAILED' -f $displayName)
                    $verificationFailed = $true
                }
            }
        }
        catch {
            Write-PshCommandFailure -Command $Command -Code 3 -Message ('{0}: {1}' -f $operand, $_.Exception.Message)
            $runtimeFailed = $true
        }
        finally { if ($null -ne $listStream) { $listStream.Dispose() } }
    }

    if ($runtimeFailed) { Set-PshLastExitCode -Code 3 }
    elseif ($verificationFailed) { Set-PshLastExitCode -Code 1 }
    else { Set-PshLastExitCode -Code 0 }
}

function Invoke-PshChecksumCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SHA256', 'MD5')]
        [string]$Algorithm,

        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [AllowNull()]
        [object[]]$PipelineItems
    )

    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $Arguments) {
        Write-PshCommandHelp -Usage ('Usage: {0} [-c] [-b|-t] [-z] [file ...]' -f $Command)
        return
    }

    $check = $false
    $marker = ' '
    $nullDelimited = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $Arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed @('c', 'b', 't', 'z'))
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -ceq 'c') { $check = $true }
                elseif ($option -ceq 'b') { $marker = '*' }
                elseif ($option -ceq 't') { $marker = ' ' }
                elseif ($option -ceq 'z') { $nullDelimited = $true }
            }
            continue
        }
        $operands += $argument
    }
    if ($operands.Count -eq 0) { $operands = @('-') }

    $inputBytes = ConvertTo-PshChecksumInputBytes -Items $PipelineItems
    $inputState = New-PshChecksumInputState -Bytes $inputBytes
    if ($check) {
        Invoke-PshChecksumCheck -Command $Command -Algorithm $Algorithm -Operands $operands -InputState $inputState -NullDelimited:$nullDelimited
    }
    else {
        Invoke-PshChecksumCompute -Command $Command -Algorithm $Algorithm -Operands $operands -InputState $inputState -Marker $marker -NullDelimited:$nullDelimited
    }
}

function sha256sum {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Invoke-PshChecksumCommand -Command 'sha256sum' -Algorithm 'SHA256' -Arguments $arguments -PipelineItems $pipelineItems
}

function md5sum {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Invoke-PshChecksumCommand -Command 'md5sum' -Algorithm 'MD5' -Arguments $arguments -PipelineItems $pipelineItems
}

function Get-PshGzipCrc32Table {
    if ($null -ne $script:PshGzipCrc32Table) { return $script:PshGzipCrc32Table }

    # PowerShell 5.1 promotes bitwise results to signed Int32.  Keep the
    # intermediate values in UInt64 and mask to 32 bits after each step.
    $table = New-Object 'System.UInt64[]' 256
    for ($index = 0; $index -lt 256; $index++) {
        [uint64]$value = [uint64]$index
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($value -band [uint64]1) -ne 0) {
                $value = (($value -shr 1) -bxor [uint64]3988292384) -band [uint64]4294967295
            }
            else {
                $value = ($value -shr 1) -band [uint64]4294967295
            }
        }
        $table[$index] = $value
    }
    $script:PshGzipCrc32Table = $table
    return $table
}

function Update-PshGzipCrc32 {
    param(
        [Parameter(Mandatory = $true)]
        [uint64]$Crc,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    $table = Get-PshGzipCrc32Table
    [uint64]$value = $Crc
    for ($index = 0; $index -lt $Count; $index++) {
        [int]$tableIndex = [int](($value -bxor [uint64]$Bytes[$index]) -band [uint64]255)
        $value = (($value -shr 8) -bxor [uint64]$table[$tableIndex]) -band [uint64]4294967295
    }
    return $value
}

function ConvertTo-PshGzipUInt32Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [uint64]$Value
    )

    return ,([byte[]]@(
        [byte]($Value -band 0xff),
        [byte](($Value -shr 8) -band 0xff),
        [byte](($Value -shr 16) -band 0xff),
        [byte](($Value -shr 24) -band 0xff)
    ))
}

function Get-PshGzipUInt32FromBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )

    if ($Offset -lt 0 -or ($Offset + 4) -gt $Bytes.Length) {
        Throw-PshGzipInvalidData -Message 'gzip integer field is truncated.'
    }
    return ([uint64]$Bytes[$Offset] -bor
        ([uint64]$Bytes[$Offset + 1] -shl 8) -bor
        ([uint64]$Bytes[$Offset + 2] -shl 16) -bor
        ([uint64]$Bytes[$Offset + 3] -shl 24))
}

function Get-PshGzipMemberMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -lt 18) { Throw-PshGzipInvalidData -Message 'gzip stream is truncated.' }
    if ($Bytes[0] -ne 0x1f -or $Bytes[1] -ne 0x8b) { Throw-PshGzipInvalidData -Message 'gzip magic header is invalid.' }
    if ($Bytes[2] -ne 8) { Throw-PshGzipInvalidData -Message ('unsupported gzip compression method {0}.' -f $Bytes[2]) }

    $flags = [int]$Bytes[3]
    if (($flags -band 0xe0) -ne 0) { Throw-PshGzipInvalidData -Message 'gzip header uses reserved flags.' }
    $trailerOffset = $Bytes.Length - 8
    $offset = 10

    if (($flags -band 4) -ne 0) {
        if (($offset + 2) -gt $trailerOffset) { Throw-PshGzipInvalidData -Message 'gzip extra-field length is truncated.' }
        $extraLength = [int]$Bytes[$offset] -bor ([int]$Bytes[$offset + 1] -shl 8)
        $offset += 2
        if (($offset + $extraLength) -gt $trailerOffset) { Throw-PshGzipInvalidData -Message 'gzip extra field is truncated.' }
        $offset += $extraLength
    }

    foreach ($flag in @(8, 16)) {
        if (($flags -band $flag) -eq 0) { continue }
        while ($offset -lt $trailerOffset -and $Bytes[$offset] -ne 0) { $offset++ }
        if ($offset -ge $trailerOffset) { Throw-PshGzipInvalidData -Message 'gzip header string is not NUL-terminated.' }
        $offset++
    }

    if (($flags -band 2) -ne 0) {
        if (($offset + 2) -gt $trailerOffset) { Throw-PshGzipInvalidData -Message 'gzip header checksum is truncated.' }
        $expectedHeaderCrc = [int]$Bytes[$offset] -bor ([int]$Bytes[$offset + 1] -shl 8)
        $headerBytes = New-Object byte[] $offset
        if ($offset -gt 0) { [Array]::Copy($Bytes, 0, $headerBytes, 0, $offset) }
        [uint64]$headerCrc = Update-PshGzipCrc32 -Crc ([uint64]4294967295) -Bytes $headerBytes -Count $headerBytes.Length
        $headerCrc = ($headerCrc -bxor [uint64]4294967295) -band [uint64]4294967295
        if ([int]($headerCrc -band [uint64]65535) -ne $expectedHeaderCrc) {
            Throw-PshGzipInvalidData -Message 'gzip header checksum mismatch.'
        }
        $offset += 2
    }

    if ($offset -ge $trailerOffset) { Throw-PshGzipInvalidData -Message 'gzip deflate payload is missing.' }
    return [PSCustomObject]@{
        ExpectedCrc = [uint64](Get-PshGzipUInt32FromBytes -Bytes $Bytes -Offset $trailerOffset)
        ExpectedSize = [uint64](Get-PshGzipUInt32FromBytes -Bytes $Bytes -Offset ($trailerOffset + 4))
    }
}

function ConvertTo-PshGzipLatin1NameBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($character in $Name.ToCharArray()) {
        $code = [int][char]$character
        if ($code -eq 0 -or $code -gt 255) { $code = [int][char]'_' }
        $bytes.Add([byte]$code)
    }
    $bytes.Add([byte]0)
    return $bytes.ToArray()
}

function Get-PshGzipHeaderBytes {
    param(
        [AllowNull()]
        [string]$SourcePath,

        [switch]$NoNameTime
    )

    $header = New-Object 'System.Collections.Generic.List[byte]'
    $header.Add([byte]0x1f)
    $header.Add([byte]0x8b)
    $header.Add([byte]8)

    $nameBytes = [byte[]]@()
    if (-not $NoNameTime -and -not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $nameBytes = [byte[]](ConvertTo-PshGzipLatin1NameBytes -Name ([IO.Path]::GetFileName($SourcePath)))
    }
    $flags = if ($nameBytes.Length -gt 0) { 8 } else { 0 }
    $header.Add([byte]$flags)

    [uint32]$modified = 0
    if (-not $NoNameTime -and -not [string]::IsNullOrWhiteSpace($SourcePath) -and [IO.File]::Exists($SourcePath)) {
        $epoch = [DateTime]::SpecifyKind((New-Object DateTime(1970, 1, 1, 0, 0, 0)), [DateTimeKind]::Utc)
        $seconds = ([IO.FileInfo]$SourcePath).LastWriteTimeUtc.Subtract($epoch).TotalSeconds
        if ($seconds -gt 0) {
            if ($seconds -gt [double][uint32]::MaxValue) { $modified = [uint32]::MaxValue }
            else { $modified = [uint32][Math]::Floor($seconds) }
        }
    }
    foreach ($byte in [byte[]](ConvertTo-PshGzipUInt32Bytes -Value $modified)) { $header.Add($byte) }

    # XFL=0 (default compression), OS=255 (unknown) keep the wrapper portable.
    $header.Add([byte]0)
    $header.Add([byte]255)
    foreach ($byte in $nameBytes) { $header.Add($byte) }
    return $header.ToArray()
}

function Invoke-PshGzipCompressStream {
    param(
        [Parameter(Mandatory = $true)]
        [IO.Stream]$InputStream,

        [Parameter(Mandatory = $true)]
        [IO.Stream]$OutputStream,

        [AllowNull()]
        [string]$SourcePath,

        [switch]$NoNameTime
    )

    $header = [byte[]](Get-PshGzipHeaderBytes -SourcePath $SourcePath -NoNameTime:$NoNameTime)
    $OutputStream.Write($header, 0, $header.Length)

    $deflate = $null
    [uint64]$crc = [uint64]4294967295
    [uint64]$total = 0
    $buffer = New-Object byte[] 81920
    try {
        $deflate = New-Object IO.Compression.DeflateStream($OutputStream, [IO.Compression.CompressionMode]::Compress, $true)
        while (($read = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $crc = Update-PshGzipCrc32 -Crc $crc -Bytes $buffer -Count $read
            $total += [uint64]$read
            $deflate.Write($buffer, 0, $read)
        }
        $deflate.Dispose()
        $deflate = $null
    }
    finally {
        if ($null -ne $deflate) { $deflate.Dispose() }
    }

    [uint64]$finalCrc = (($crc -bxor [uint64]4294967295) -band [uint64]4294967295)
    [uint64]$size32 = $total % 4294967296
    $trailer = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($byte in [byte[]](ConvertTo-PshGzipUInt32Bytes -Value $finalCrc)) { $trailer.Add($byte) }
    foreach ($byte in [byte[]](ConvertTo-PshGzipUInt32Bytes -Value $size32)) { $trailer.Add($byte) }
    $trailerBytes = $trailer.ToArray()
    $OutputStream.Write($trailerBytes, 0, $trailerBytes.Length)
}

function Invoke-PshGzipDecompressStream {
    param(
        [Parameter(Mandatory = $true)]
        [IO.Stream]$InputStream,

        [Parameter(Mandatory = $true)]
        [IO.Stream]$OutputStream
    )

    $compressed = New-Object IO.MemoryStream
    try { $InputStream.CopyTo($compressed) }
    catch {
        $compressed.Dispose()
        throw
    }

    $compressedBytes = [byte[]]$compressed.ToArray()
    $compressed.Dispose()
    $metadata = Get-PshGzipMemberMetadata -Bytes $compressedBytes
    $compressedInput = New-Object IO.MemoryStream(,$compressedBytes)
    $gzipStream = $null
    $buffer = New-Object byte[] 81920
    [uint64]$crc = [uint64]4294967295
    [uint64]$total = 0
    try {
        try {
            $gzipStream = New-Object IO.Compression.GZipStream($compressedInput, [IO.Compression.CompressionMode]::Decompress, $true)
        }
        catch {
            if (Test-PshGzipInvalidDataException -Exception $_.Exception) { throw }
            Throw-PshGzipInvalidData -Message $_.Exception.Message
        }
        while ($true) {
            try { $read = $gzipStream.Read($buffer, 0, $buffer.Length) }
            catch {
                if (Test-PshGzipInvalidDataException -Exception $_.Exception) { throw }
                Throw-PshGzipInvalidData -Message $_.Exception.Message
            }
            if ($read -le 0) { break }
            $crc = Update-PshGzipCrc32 -Crc $crc -Bytes $buffer -Count $read
            $total += [uint64]$read
            $OutputStream.Write($buffer, 0, $read)
        }
        $gzipStream.Dispose()
        $gzipStream = $null

        [uint64]$actualCrc = (($crc -bxor [uint64]4294967295) -band [uint64]4294967295)
        [uint64]$actualSize = $total % [uint64]4294967296
        if ($actualCrc -ne [uint64]$metadata.ExpectedCrc) { Throw-PshGzipInvalidData -Message 'gzip payload checksum mismatch.' }
        if ($actualSize -ne [uint64]$metadata.ExpectedSize) { Throw-PshGzipInvalidData -Message 'gzip payload size does not match its trailer.' }
    }
    finally {
        if ($null -ne $gzipStream) { $gzipStream.Dispose() }
        $compressedInput.Dispose()
    }
}

function Invoke-PshGzipBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [bool]$Decompress,

        [AllowNull()]
        [string]$SourcePath,

        [switch]$NoNameTime
    )

    $inputStream = New-Object IO.MemoryStream(,$Bytes)
    $outputStream = New-Object IO.MemoryStream
    try {
        if ($Decompress) {
            Invoke-PshGzipDecompressStream -InputStream $inputStream -OutputStream $outputStream
        }
        else {
            Invoke-PshGzipCompressStream -InputStream $inputStream -OutputStream $outputStream -SourcePath $SourcePath -NoNameTime:$NoNameTime
        }
        return ,([byte[]]$outputStream.ToArray())
    }
    finally {
        $inputStream.Dispose()
        $outputStream.Dispose()
    }
}

function Get-PshGzipDestinationPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [bool]$Decompress
    )

    if (-not $Decompress) { return ($SourcePath + '.gz') }
    $directory = [IO.Path]::GetDirectoryName($SourcePath)
    $leaf = [IO.Path]::GetFileName($SourcePath)
    if ($leaf.EndsWith('.tgz', [StringComparison]::OrdinalIgnoreCase)) {
        $leaf = $leaf.Substring(0, $leaf.Length - 4) + '.tar'
    }
    elseif ($leaf.EndsWith('.gz', [StringComparison]::OrdinalIgnoreCase)) {
        $leaf = $leaf.Substring(0, $leaf.Length - 3)
    }
    else {
        throw ('unknown gzip suffix: {0}' -f $SourcePath)
    }
    return (Join-Path -Path $directory -ChildPath $leaf)
}

function Install-PshGzipStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$Force
    )

    if ([IO.Directory]::Exists($Destination)) {
        throw ('refusing to replace an existing directory: {0}' -f $Destination)
    }
    if ([IO.File]::Exists($Destination)) {
        if (-not $Force) { throw ('output file already exists: {0}' -f $Destination) }
        Replace-PshFileEntry -Replacement $Stage -Destination $Destination
    }
    else {
        Move-PshLiteralEntry -Source $Stage -Destination $Destination
    }
}

function Invoke-PshGzipFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$SourceOperand,

        [Parameter(Mandatory = $true)]
        [bool]$Decompress,

        [switch]$Force,
        [switch]$Keep,
        [switch]$NoNameTime
    )

    $sourcePath = Resolve-PshFileSystemPath -Path $SourceOperand
    if (-not [IO.File]::Exists($sourcePath)) { throw ('not a regular file: {0}' -f $SourceOperand) }
    $destination = Get-PshGzipDestinationPath -SourcePath $sourcePath -Decompress:$Decompress
    if (Test-PshPathEqual -Left $sourcePath -Right $destination) {
        throw 'input and output paths must differ.'
    }
    if ([IO.Directory]::Exists($destination)) {
        throw ('output path is a directory: {0}' -f $destination)
    }
    if ([IO.File]::Exists($destination) -and -not $Force) {
        throw ('output file already exists: {0}' -f $destination)
    }

    $stage = New-PshSiblingTemporaryPath -Destination $destination -Purpose 'gzip'
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = New-Object IO.FileStream($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $outputStream = New-Object IO.FileStream($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($Decompress) {
            Invoke-PshGzipDecompressStream -InputStream $inputStream -OutputStream $outputStream
        }
        else {
            Invoke-PshGzipCompressStream -InputStream $inputStream -OutputStream $outputStream -SourcePath $sourcePath -NoNameTime:$NoNameTime
        }
        $outputStream.Flush()
        $outputStream.Dispose()
        $outputStream = $null
        $inputStream.Dispose()
        $inputStream = $null

        Install-PshGzipStage -Stage $stage -Destination $destination -Force:$Force
        $stage = $null
        if (-not $Keep) { Remove-PshLiteralEntry -Path $sourcePath }
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $stage -and [IO.File]::Exists($stage)) {
            try { Remove-PshLiteralEntry -Path $stage } catch { }
        }
    }
}

function Invoke-PshGzipCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [AllowNull()]
        [object[]]$PipelineItems
    )

    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $Arguments) {
        if ($Command -ceq 'gunzip') { Write-PshCommandHelp -Usage 'Usage: gunzip [-cfk] [file ...]' }
        else { Write-PshCommandHelp -Usage 'Usage: gzip [-cdfkn] [file ...]' }
        return
    }

    $decompress = $Command -ceq 'gunzip'
    $toStdout = $false
    $force = $false
    $keep = $false
    $noNameTime = $false
    $operands = @()
    $parseOptions = $true
    foreach ($argument in $Arguments) {
        if ($parseOptions -and $argument -ceq '--') { $parseOptions = $false; continue }
        if ($parseOptions -and $argument.StartsWith('-') -and $argument -ne '-') {
            $allowed = if ($decompress) { @('c', 'f', 'k') } else { @('c', 'd', 'f', 'k', 'n') }
            $expanded = @(Expand-PshShortOptions -Token $argument -Allowed $allowed)
            if ($expanded.Count -eq 0) {
                Write-PshCommandFailure -Command $Command -Code 2 -Message ('unsupported argument "{0}".' -f $argument)
                return
            }
            foreach ($option in $expanded) {
                if ($option -ceq 'c') { $toStdout = $true }
                elseif ($option -ceq 'd') { $decompress = $true }
                elseif ($option -ceq 'f') { $force = $true }
                elseif ($option -ceq 'k') { $keep = $true }
                elseif ($option -ceq 'n') { $noNameTime = $true }
            }
            continue
        }
        $operands += $argument
    }
    if ($operands.Count -eq 0) { $operands = @('-') }

    $source = New-PshPipelineTextSource -Items $PipelineItems
    $inputState = [PSCustomObject]@{ Bytes = [byte[]]$source.Bytes; Consumed = $false }
    $failed = $false
    $failureCode = 0
    foreach ($operand in $operands) {
        try {
            if ($operand -ceq '-') {
                $bytes = [byte[]]@()
                if (-not [bool]$inputState.Consumed) {
                    $bytes = [byte[]]$inputState.Bytes
                    $inputState.Consumed = $true
                }
                $result = Invoke-PshGzipBytes -Bytes $bytes -Decompress:$decompress -NoNameTime:$noNameTime
                Write-PshRawBytes -Bytes ([byte[]]$result)
            }
            elseif ($toStdout) {
                $sourcePath = Resolve-PshFileSystemPath -Path $operand
                if (-not [IO.File]::Exists($sourcePath)) { throw ('not a regular file: {0}' -f $operand) }
                $inputStream = New-Object IO.FileStream($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $resultStream = New-Object IO.MemoryStream
                    try {
                        if ($decompress) { Invoke-PshGzipDecompressStream -InputStream $inputStream -OutputStream $resultStream }
                        else { Invoke-PshGzipCompressStream -InputStream $inputStream -OutputStream $resultStream -SourcePath $sourcePath -NoNameTime:$noNameTime }
                        Write-PshRawBytes -Bytes ([byte[]]$resultStream.ToArray())
                    }
                    finally { $resultStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
            }
            else {
                Invoke-PshGzipFile -Command $Command -SourceOperand $operand -Decompress:$decompress -Force:$force -Keep:$keep -NoNameTime:$noNameTime
            }
        }
        catch {
            $code = if (Test-PshGzipInvalidDataException -Exception $_.Exception) { 5 } else { 3 }
            Write-PshCommandFailure -Command $Command -Code $code -Message ('{0}: {1}' -f $operand, $_.Exception.Message)
            $failed = $true
            if ($code -eq 5) { $failureCode = 5 }
            elseif ($failureCode -eq 0) { $failureCode = 3 }
        }
    }
    if ($failed) { Set-PshLastExitCode -Code $failureCode } else { Set-PshLastExitCode -Code 0 }
}

function gzip {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Invoke-PshGzipCommand -Command 'gzip' -Arguments $arguments -PipelineItems $pipelineItems
}

function gunzip {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    $pipelineItems = @($input)
    Invoke-PshGzipCommand -Command 'gunzip' -Arguments $arguments -PipelineItems $pipelineItems
}
