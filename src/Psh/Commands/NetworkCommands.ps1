# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

$script:PshNetworkCommandNames = @('curl', 'wget')

function Get-PshEnabledNetworkCommandNames {
    $enabled = @()
    foreach ($name in $script:PshNetworkCommandNames) {
        if (-not $script:PshDisabledCommands.ContainsKey($name)) {
            $enabled += $name
        }
    }
    return $enabled
}

function Throw-PshNetworkUsageError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw (New-Object ArgumentException($Message))
}

function ConvertTo-PshNetworkTimeoutMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$OptionName
    )

    if ($Value -notmatch '^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$') {
        Throw-PshNetworkUsageError -Message ('{0} requires a non-negative number of seconds.' -f $OptionName)
    }
    $seconds = [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($seconds -eq 0) { return -1 }
    $milliseconds = [Math]::Ceiling($seconds * 1000.0)
    if ($milliseconds -gt [int]::MaxValue) {
        Throw-PshNetworkUsageError -Message ('{0} is too large.' -f $OptionName)
    }
    return [int][Math]::Max(1, $milliseconds)
}

function Assert-PshNetworkMethod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method
    )

    if ([string]::IsNullOrWhiteSpace($Method) -or $Method -notmatch '^[A-Za-z][A-Za-z0-9._-]*$') {
        Throw-PshNetworkUsageError -Message ('invalid HTTP method "{0}".' -f $Method)
    }
}

function Assert-PshNetworkHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Header
    )

    $separator = $Header.IndexOf(':')
    if ($separator -le 0) {
        Throw-PshNetworkUsageError -Message ('invalid header "{0}"; expected Name: value.' -f $Header)
    }
    $name = $Header.Substring(0, $separator).Trim()
    if ($name -notmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$') {
        Throw-PshNetworkUsageError -Message ('invalid header name "{0}".' -f $name)
    }
    if ($Header.IndexOf("`r") -ge 0 -or $Header.IndexOf("`n") -ge 0) {
        Throw-PshNetworkUsageError -Message 'header values cannot contain newlines.'
    }
}

function Get-PshNetworkOptionValue {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [ref]$Index,

        [Parameter(Mandatory = $true)]
        [string]$OptionName
    )

    $Index.Value++
    if ($Index.Value -ge $Arguments.Count) {
        Throw-PshNetworkUsageError -Message ('{0} requires a value.' -f $OptionName)
    }
    return [string]$Arguments[$Index.Value]
}

function Get-PshCurlOptions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $failOnHttpError = $false
    $followRedirects = $false
    $silent = $false
    $showError = $false
    $headersOnly = $false
    $method = $null
    $outputMode = 'stdout'
    $outputPath = $null
    $headers = New-Object 'System.Collections.Generic.List[string]'
    $dataParts = New-Object 'System.Collections.Generic.List[string]'
    $connectTimeout = -1
    $totalTimeout = -1
    $urlText = $null

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $token = [string]$Arguments[$index]
        if ($token.StartsWith('--', [StringComparison]::Ordinal)) {
            $value = $null
            $option = $token
            $equals = $token.IndexOf('=')
            if ($equals -ge 0) {
                $option = $token.Substring(0, $equals)
                $value = $token.Substring($equals + 1)
            }
            switch -CaseSensitive ($option) {
                '--data' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--data' }
                    [void]$dataParts.Add([string]$value)
                }
                '--connect-timeout' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--connect-timeout' }
                    $connectTimeout = ConvertTo-PshNetworkTimeoutMilliseconds -Value ([string]$value) -OptionName '--connect-timeout'
                }
                '--max-time' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--max-time' }
                    $totalTimeout = ConvertTo-PshNetworkTimeoutMilliseconds -Value ([string]$value) -OptionName '--max-time'
                }
                default { Throw-PshNetworkUsageError -Message ('unsupported argument "{0}".' -f $token) }
            }
            continue
        }

        if ($token.Length -gt 1 -and $token[0] -eq '-') {
            $shortIndex = 1
            while ($shortIndex -lt $token.Length) {
                $shortName = [string]$token[$shortIndex]
                switch -CaseSensitive ($shortName) {
                    'f' { $failOnHttpError = $true; $shortIndex++; continue }
                    'L' { $followRedirects = $true; $shortIndex++; continue }
                    's' { $silent = $true; $shortIndex++; continue }
                    'S' { $showError = $true; $shortIndex++; continue }
                    'I' { $headersOnly = $true; $shortIndex++; continue }
                    'O' { $outputMode = 'remote'; $outputPath = $null; $shortIndex++; continue }
                    { $_ -in @('o', 'X', 'H', 'd') } {
                        if ($shortIndex + 1 -lt $token.Length) {
                            $value = $token.Substring($shortIndex + 1)
                        }
                        else {
                            $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName ('-{0}' -f $shortName)
                        }
                        switch -CaseSensitive ($shortName) {
                            'o' { $outputMode = if ($value -ceq '-') { 'stdout' } else { 'path' }; $outputPath = [string]$value }
                            'X' { Assert-PshNetworkMethod -Method ([string]$value); $method = [string]$value }
                            'H' { Assert-PshNetworkHeader -Header ([string]$value); [void]$headers.Add([string]$value) }
                            'd' { [void]$dataParts.Add([string]$value) }
                        }
                        $shortIndex = $token.Length
                        continue
                    }
                    default { Throw-PshNetworkUsageError -Message ('unsupported argument "{0}".' -f $token) }
                }
            }
            continue
        }

        if ($null -ne $urlText) {
            Throw-PshNetworkUsageError -Message 'exactly one URL is required.'
        }
        $urlText = $token
    }

    if ([string]::IsNullOrWhiteSpace($urlText)) { Throw-PshNetworkUsageError -Message 'exactly one URL is required.' }
    $uri = $null
    if (-not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        Throw-PshNetworkUsageError -Message ('unsupported URL "{0}"; expected http or https.' -f $urlText)
    }
    if ($headersOnly -and $dataParts.Count -gt 0) {
        Throw-PshNetworkUsageError -Message '-I cannot be combined with -d or --data.'
    }
    if ($null -eq $method) {
        if ($headersOnly) { $method = 'HEAD' }
        elseif ($dataParts.Count -gt 0) { $method = 'POST' }
        else { $method = 'GET' }
    }
    if ($outputMode -eq 'path' -and [string]::IsNullOrEmpty($outputPath)) {
        Throw-PshNetworkUsageError -Message '-o requires a non-empty path.'
    }

    return [PSCustomObject]@{
        Command = 'curl'; Uri = $uri; FailOnHttpError = $failOnHttpError
        FollowRedirects = $followRedirects; Silent = $silent; ShowError = $showError
        HeadersOnly = $headersOnly; Method = $method; Headers = [string[]]$headers.ToArray()
        BodyData = if ($dataParts.Count -eq 0) { $null } else { $dataParts.ToArray() -join '&' }
        OutputMode = $outputMode; OutputPath = $outputPath
        ConnectTimeoutMilliseconds = $connectTimeout; TotalTimeoutMilliseconds = $totalTimeout
        ReadTimeoutMilliseconds = -1
    }
}

function Get-PshWgetOptions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $quiet = $false
    $resume = $false
    $showHeaders = $false
    $outputMode = 'remote'
    $outputPath = $null
    $timeout = -1
    $method = $null
    $bodyData = $null
    $headers = New-Object 'System.Collections.Generic.List[string]'
    $urlText = $null

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $token = [string]$Arguments[$index]
        if ($token.StartsWith('--', [StringComparison]::Ordinal)) {
            $value = $null
            $option = $token
            $equals = $token.IndexOf('=')
            if ($equals -ge 0) {
                $option = $token.Substring(0, $equals)
                $value = $token.Substring($equals + 1)
            }
            switch -CaseSensitive ($option) {
                '--timeout' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--timeout' }
                    $timeout = ConvertTo-PshNetworkTimeoutMilliseconds -Value ([string]$value) -OptionName '--timeout'
                }
                '--header' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--header' }
                    Assert-PshNetworkHeader -Header ([string]$value)
                    [void]$headers.Add([string]$value)
                }
                '--method' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--method' }
                    Assert-PshNetworkMethod -Method ([string]$value)
                    $method = [string]$value
                }
                '--body-data' {
                    if ($null -eq $value) { $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '--body-data' }
                    $bodyData = [string]$value
                }
                default { Throw-PshNetworkUsageError -Message ('unsupported argument "{0}".' -f $token) }
            }
            continue
        }

        if ($token.Length -gt 1 -and $token[0] -eq '-') {
            $shortIndex = 1
            while ($shortIndex -lt $token.Length) {
                $shortName = [string]$token[$shortIndex]
                switch -CaseSensitive ($shortName) {
                    'q' { $quiet = $true; $shortIndex++; continue }
                    'c' { $resume = $true; $shortIndex++; continue }
                    'S' { $showHeaders = $true; $shortIndex++; continue }
                    'O' {
                        if ($shortIndex + 1 -lt $token.Length) {
                            $value = $token.Substring($shortIndex + 1)
                        }
                        else {
                            $value = Get-PshNetworkOptionValue -Arguments $Arguments -Index ([ref]$index) -OptionName '-O'
                        }
                        if ([string]::IsNullOrEmpty([string]$value)) {
                            Throw-PshNetworkUsageError -Message '-O requires a non-empty path.'
                        }
                        $outputMode = if ($value -ceq '-') { 'stdout' } else { 'path' }
                        $outputPath = [string]$value
                        $shortIndex = $token.Length
                        continue
                    }
                    default { Throw-PshNetworkUsageError -Message ('unsupported argument "{0}".' -f $token) }
                }
            }
            continue
        }

        if ($null -ne $urlText) {
            Throw-PshNetworkUsageError -Message 'exactly one URL is required.'
        }
        $urlText = $token
    }

    if ([string]::IsNullOrWhiteSpace($urlText)) { Throw-PshNetworkUsageError -Message 'exactly one URL is required.' }
    $uri = $null
    if (-not [Uri]::TryCreate($urlText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        Throw-PshNetworkUsageError -Message ('unsupported URL "{0}"; expected http or https.' -f $urlText)
    }
    if ($resume -and $outputMode -eq 'stdout') {
        Throw-PshNetworkUsageError -Message '-c cannot be used with standard output.'
    }
    if ($null -eq $method) {
        if ($null -ne $bodyData) { $method = 'POST' }
        else { $method = 'GET' }
    }

    return [PSCustomObject]@{
        Command = 'wget'; Uri = $uri; FailOnHttpError = $true
        FollowRedirects = $true; Quiet = $quiet; ShowHeaders = $showHeaders
        HeadersOnly = [string]::Equals($method, 'HEAD', [StringComparison]::OrdinalIgnoreCase)
        Method = $method; Headers = [string[]]$headers.ToArray(); BodyData = $bodyData
        OutputMode = $outputMode; OutputPath = $outputPath; Resume = $resume
        ConnectTimeoutMilliseconds = $timeout; TotalTimeoutMilliseconds = -1
        ReadTimeoutMilliseconds = $timeout
    }
}

function Get-PshNetworkRemoteFileName {
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri,

        [switch]$UseIndexFallback
    )

    $path = [Uri]::UnescapeDataString($Uri.AbsolutePath)
    $name = [IO.Path]::GetFileName($path.TrimEnd('/'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        if ($UseIndexFallback) { return 'index.html' }
        Throw-PshNetworkUsageError -Message ('cannot determine a remote file name from URL "{0}".' -f $Uri.AbsoluteUri)
    }
    return $name
}

function Resolve-PshNetworkOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { throw 'output path cannot be empty.' }
    $fullPath = Resolve-PshFileSystemPath -Path $Path -AllowMissing
    if ([IO.Directory]::Exists($fullPath)) {
        throw ('output path is an existing directory: {0}' -f $Path)
    }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw ('output parent directory does not exist: {0}' -f $Path)
    }
    return $fullPath
}

function Get-PshNetworkRemainingMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [int]$TotalTimeoutMilliseconds = -1
    )

    if ($TotalTimeoutMilliseconds -lt 0) { return -1 }
    $remaining = [long]$TotalTimeoutMilliseconds - [long]$Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { throw (New-Object TimeoutException('operation timed out.')) }
    return [int][Math]::Min([long][int]::MaxValue, $remaining)
}

function Get-PshNetworkEffectiveTimeout {
    param(
        [int]$OperationTimeoutMilliseconds = -1,

        [int]$RemainingTimeoutMilliseconds = -1
    )

    if ($OperationTimeoutMilliseconds -lt 0) { return $RemainingTimeoutMilliseconds }
    if ($RemainingTimeoutMilliseconds -lt 0) { return $OperationTimeoutMilliseconds }
    return [Math]::Min($OperationTimeoutMilliseconds, $RemainingTimeoutMilliseconds)
}

function Get-PshNetworkPreHeaderTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [int]$ConnectTimeoutMilliseconds = -1,

        [int]$TotalTimeoutMilliseconds = -1
    )

    $remainingConnect = Get-PshNetworkRemainingMilliseconds `
        -Stopwatch $Stopwatch `
        -TotalTimeoutMilliseconds $ConnectTimeoutMilliseconds
    $remainingTotal = Get-PshNetworkRemainingMilliseconds `
        -Stopwatch $Stopwatch `
        -TotalTimeoutMilliseconds $TotalTimeoutMilliseconds
    return Get-PshNetworkEffectiveTimeout `
        -OperationTimeoutMilliseconds $remainingConnect `
        -RemainingTimeoutMilliseconds $remainingTotal
}

function Wait-PshNetworkPreHeaderOperation {
    param(
        [Parameter(Mandatory = $true)]
        [Threading.WaitHandle]$WaitHandle,

        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest]$Request,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [int]$ConnectTimeoutMilliseconds = -1,

        [int]$TotalTimeoutMilliseconds = -1
    )

    try {
        $remaining = Get-PshNetworkPreHeaderTimeout `
            -Stopwatch $Stopwatch `
            -ConnectTimeoutMilliseconds $ConnectTimeoutMilliseconds `
            -TotalTimeoutMilliseconds $TotalTimeoutMilliseconds
    }
    catch [TimeoutException] {
        try { $Request.Abort() }
        catch {}
        if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') {
            try { [void]$WaitHandle.WaitOne(1000) }
            catch {}
        }
        throw
    }
    if ($WaitHandle.WaitOne([int]$remaining)) { return }

    try { $Request.Abort() }
    catch {}
    if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') {
        try { [void]$WaitHandle.WaitOne(1000) }
        catch {}
    }
    throw (New-Object TimeoutException('operation timed out.'))
}

function Get-PshNetworkOwnedAsyncWaitHandle {
    param(
        [Parameter(Mandatory = $true)]
        [IAsyncResult]$AsyncResult
    )

    $waitHandle = $AsyncResult.AsyncWaitHandle
    if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') { return $waitHandle }

    # PowerShell Core may reuse framework-owned SafeWaitHandle instances.
    $ownedHandle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset)
    $ownedHandle.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new(
        $waitHandle.SafeWaitHandle.DangerousGetHandle(),
        $false
    )
    return $ownedHandle
}

function Close-PshNetworkOwnedAsyncWaitHandles {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Threading.WaitHandle]]$WaitHandles
    )

    foreach ($waitHandle in $WaitHandles) {
        if ([string]$PSVersionTable.PSEdition -ceq 'Desktop') {
            try {
                if (-not $waitHandle.WaitOne(0)) { continue }
            }
            catch { continue }
        }
        try { $waitHandle.Dispose() }
        catch {}
    }
}

function Get-PshNetworkRequestStream {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest]$Request,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Threading.WaitHandle]]$WaitHandles
    )

    $asyncResult = $Request.BeginGetRequestStream($null, $null)
    $waitHandle = Get-PshNetworkOwnedAsyncWaitHandle -AsyncResult $asyncResult
    [void]$WaitHandles.Add($waitHandle)
    Wait-PshNetworkPreHeaderOperation `
        -WaitHandle $waitHandle `
        -Request $Request `
        -Stopwatch $Stopwatch `
        -ConnectTimeoutMilliseconds ([int]$Options.ConnectTimeoutMilliseconds) `
        -TotalTimeoutMilliseconds ([int]$Options.TotalTimeoutMilliseconds)
    return $Request.EndGetRequestStream($asyncResult)
}

function Write-PshNetworkRequestBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest]$Request,

        [Parameter(Mandatory = $true)]
        [IO.Stream]$RequestStream,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$BodyBytes,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Threading.WaitHandle]]$WaitHandles
    )

    $asyncResult = $RequestStream.BeginWrite($BodyBytes, 0, $BodyBytes.Length, $null, $null)
    $waitHandle = Get-PshNetworkOwnedAsyncWaitHandle -AsyncResult $asyncResult
    [void]$WaitHandles.Add($waitHandle)
    Wait-PshNetworkPreHeaderOperation `
        -WaitHandle $waitHandle `
        -Request $Request `
        -Stopwatch $Stopwatch `
        -ConnectTimeoutMilliseconds ([int]$Options.ConnectTimeoutMilliseconds) `
        -TotalTimeoutMilliseconds ([int]$Options.TotalTimeoutMilliseconds)
    $RequestStream.EndWrite($asyncResult)
}

function Get-PshNetworkResponseHeaderText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebResponse]$Response
    )

    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendFormat(
        [Globalization.CultureInfo]::InvariantCulture,
        'HTTP/{0}.{1} {2} {3}',
        $Response.ProtocolVersion.Major,
        $Response.ProtocolVersion.Minor,
        [int]$Response.StatusCode,
        [string]$Response.StatusDescription
    )
    [void]$builder.Append("`r`n")
    foreach ($name in $Response.Headers.AllKeys) {
        foreach ($value in @($Response.Headers.GetValues($name))) {
            [void]$builder.Append($name)
            [void]$builder.Append(': ')
            [void]$builder.Append([string]$value)
            [void]$builder.Append("`r`n")
        }
    }
    [void]$builder.Append("`r`n")
    return $builder.ToString()
}

function Write-PshNetworkText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -ne $Text -and $Text.Length -gt 0) {
        Write-PshTextValue -Text $Text
    }
}

function Write-PshNetworkBodyBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) { return }
    Write-PshRawBytes -Bytes $Bytes
}

function Commit-PshNetworkStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagePath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if ([IO.Directory]::Exists($Destination)) {
        throw ('output path is an existing directory: {0}' -f $Destination)
    }
    if ([IO.File]::Exists($Destination)) {
        Replace-PshFileEntry -Replacement $StagePath -Destination $Destination
    }
    else {
        Move-PshLiteralEntry -Source $StagePath -Destination $Destination
    }
}

function Set-PshNetworkRequestHeader {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest]$Request,

        [Parameter(Mandatory = $true)]
        [string]$Header
    )

    $separator = $Header.IndexOf(':')
    $name = $Header.Substring(0, $separator).Trim()
    $value = $Header.Substring($separator + 1).TrimStart()
    switch ($name.ToLowerInvariant()) {
        'accept' { $Request.Accept = $value; return }
        'content-type' { $Request.ContentType = $value; return }
        'user-agent' { $Request.UserAgent = $value; return }
        'referer' { $Request.Referer = $value; return }
        'host' { $Request.Host = $value; return }
        'expect' {
            if ([string]::Equals($value, '100-continue', [StringComparison]::OrdinalIgnoreCase)) {
                $Request.ServicePoint.Expect100Continue = $true
            }
            else { $Request.Expect = $value }
            return
        }
        'connection' {
            if ([string]::Equals($value, 'close', [StringComparison]::OrdinalIgnoreCase)) { $Request.KeepAlive = $false }
            elseif ([string]::Equals($value, 'keep-alive', [StringComparison]::OrdinalIgnoreCase)) { $Request.KeepAlive = $true }
            else { $Request.Connection = $value }
            return
        }
        'content-length' {
            $length = [long]0
            if (-not [long]::TryParse($value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$length)) {
                throw ('invalid Content-Length header value "{0}".' -f $value)
            }
            $Request.ContentLength = $length
            return
        }
        'range' {
            if ($value -notmatch '^bytes=(?<start>[0-9]+)-(?<end>[0-9]*)$') {
                throw ('unsupported Range header value "{0}".' -f $value)
            }
            $start = [long]::Parse($Matches.start, [Globalization.CultureInfo]::InvariantCulture)
            if ([string]::IsNullOrEmpty($Matches.end)) { $Request.AddRange($start) }
            else {
                $end = [long]::Parse($Matches.end, [Globalization.CultureInfo]::InvariantCulture)
                if ($end -lt $start) { throw ('invalid Range header value "{0}".' -f $value) }
                $Request.AddRange($start, $end)
            }
            return
        }
        'if-modified-since' {
            $dateValue = [DateTime]::MinValue
            if (-not [DateTime]::TryParse(
                $value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$dateValue
            )) { throw ('invalid If-Modified-Since header value "{0}".' -f $value) }
            $Request.IfModifiedSince = $dateValue.ToUniversalTime()
            return
        }
        'date' {
            $dateValue = [DateTime]::MinValue
            if (-not [DateTime]::TryParse(
                $value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$dateValue
            )) { throw ('invalid Date header value "{0}".' -f $value) }
            $Request.Date = $dateValue.ToUniversalTime()
            return
        }
        'transfer-encoding' {
            $Request.SendChunked = $true
            $Request.TransferEncoding = $value
            return
        }
        default { [void]$Request.Headers.Add($name, $value) }
    }
}

function New-PshNetworkRequest {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Threading.WaitHandle]]$WaitHandles,

        [long]$ResumeOffset = 0
    )

    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create([Uri]$Options.Uri)
    $request.Method = [string]$Options.Method
    $request.AllowAutoRedirect = [bool]$Options.FollowRedirects
    $request.MaximumAutomaticRedirections = 50
    $request.UserAgent = 'Psh/0.1'
    $request.Timeout = [Threading.Timeout]::Infinite
    $request.ReadWriteTimeout = [int]$Options.ReadTimeoutMilliseconds
    if ([Uri]$Options.Uri -and ([Uri]$Options.Uri).IsLoopback) { $request.Proxy = $null }
    $originalExpect100Continue = $request.ServicePoint.Expect100Continue
    try {
        foreach ($header in @($Options.Headers)) {
            Set-PshNetworkRequestHeader -Request $request -Header ([string]$header)
        }
        if ($ResumeOffset -gt 0) { $request.AddRange($ResumeOffset) }

        if ($null -ne $Options.BodyData) {
            $bodyBytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string]$Options.BodyData)
            if ([string]::IsNullOrWhiteSpace($request.ContentType)) {
                $request.ContentType = 'application/x-www-form-urlencoded'
            }
            $request.ContentLength = $bodyBytes.Length
            $request.AllowWriteStreamBuffering = $false
            $requestStream = $null
            try {
                $requestStream = Get-PshNetworkRequestStream `
                    -Request $request `
                    -Options $Options `
                    -Stopwatch $Stopwatch `
                    -WaitHandles $WaitHandles
                Write-PshNetworkRequestBody `
                    -Request $request `
                    -RequestStream $requestStream `
                    -BodyBytes $bodyBytes `
                    -Options $Options `
                    -Stopwatch $Stopwatch `
                    -WaitHandles $WaitHandles
            }
            finally {
                if ($null -ne $requestStream) { $requestStream.Dispose() }
            }
        }
        return $request
    }
    catch {
        try { $request.Abort() }
        catch {}
        throw
    }
    finally {
        try { $request.ServicePoint.Expect100Continue = $originalExpect100Continue }
        catch {}
    }
}

function Get-PshNetworkResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebRequest]$Request,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[Threading.WaitHandle]]$WaitHandles
    )

    $asyncResult = $Request.BeginGetResponse($null, $null)
    $waitHandle = Get-PshNetworkOwnedAsyncWaitHandle -AsyncResult $asyncResult
    [void]$WaitHandles.Add($waitHandle)
    try {
        Wait-PshNetworkPreHeaderOperation `
            -WaitHandle $waitHandle `
            -Request $Request `
            -Stopwatch $Stopwatch `
            -ConnectTimeoutMilliseconds ([int]$Options.ConnectTimeoutMilliseconds) `
            -TotalTimeoutMilliseconds ([int]$Options.TotalTimeoutMilliseconds)
        return [System.Net.HttpWebResponse]$Request.EndGetResponse($asyncResult)
    }
    catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response -and $_.Exception.Response -is [System.Net.HttpWebResponse]) {
            return [System.Net.HttpWebResponse]$_.Exception.Response
        }
        if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            throw (New-Object TimeoutException('operation timed out.', $_.Exception))
        }
        throw
    }
}

function Copy-PshNetworkResponseBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebResponse]$Response,

        [Parameter(Mandatory = $true)]
        [IO.Stream]$Destination,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch
    )

    $source = $null
    try {
        $source = $Response.GetResponseStream()
        if ($null -eq $source) { return }
        $buffer = New-Object byte[] 65536
        while ($true) {
            $remaining = Get-PshNetworkRemainingMilliseconds -Stopwatch $Stopwatch -TotalTimeoutMilliseconds ([int]$Options.TotalTimeoutMilliseconds)
            $readTimeout = Get-PshNetworkEffectiveTimeout `
                -OperationTimeoutMilliseconds ([int]$Options.ReadTimeoutMilliseconds) `
                -RemainingTimeoutMilliseconds $remaining
            if ($source.CanTimeout) {
                try { $source.ReadTimeout = $readTimeout }
                catch [InvalidOperationException] {}
                catch [NotSupportedException] {}
            }
            try { $count = $source.Read($buffer, 0, $buffer.Length) }
            catch [IO.IOException] {
                if ($_.Exception.InnerException -is [System.Net.Sockets.SocketException] -or
                    $_.Exception.Message -match '(?i)timed?\s*out|timeout') {
                    throw (New-Object TimeoutException('operation timed out.', $_.Exception))
                }
                throw
            }
            if ($count -le 0) { break }
            $Destination.Write($buffer, 0, $count)
            $remaining = Get-PshNetworkRemainingMilliseconds -Stopwatch $Stopwatch -TotalTimeoutMilliseconds ([int]$Options.TotalTimeoutMilliseconds)
        }
        $Destination.Flush()
    }
    finally {
        if ($null -ne $source) { $source.Dispose() }
    }
}

function Read-PshNetworkResponseBytes {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebResponse]$Response,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch
    )

    $memory = New-Object IO.MemoryStream
    try {
        Copy-PshNetworkResponseBody -Response $Response -Destination $memory -Options $Options -Stopwatch $Stopwatch
        return [byte[]]$memory.ToArray()
    }
    finally {
        $memory.Dispose()
    }
}

function Save-PshNetworkResponseFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpWebResponse]$Response,

        [Parameter(Mandatory = $true)]
        [object]$Options,

        [Parameter(Mandatory = $true)]
        [Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$AppendExisting,

        [AllowNull()]
        [string]$HeaderText
    )

    $stagePath = New-PshSiblingTemporaryPath -Destination $Destination -Purpose 'download'
    $stream = $null
    try {
        if ($AppendExisting) {
            if (-not [IO.File]::Exists($Destination)) { throw ('resume destination does not exist: {0}' -f $Destination) }
            [IO.File]::Copy($Destination, $stagePath, $false)
            $stream = New-Object IO.FileStream($stagePath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        else {
            $stream = New-Object IO.FileStream($stagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }

        if ($PSBoundParameters.ContainsKey('HeaderText') -and $null -ne $HeaderText) {
            $headerBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($HeaderText)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Flush()
        }
        else {
            Copy-PshNetworkResponseBody -Response $Response -Destination $stream -Options $Options -Stopwatch $Stopwatch
        }
        $stream.Dispose()
        $stream = $null
        Commit-PshNetworkStage -StagePath $stagePath -Destination $Destination
        $stagePath = $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $stagePath -and [IO.File]::Exists($stagePath)) { [IO.File]::Delete($stagePath) }
    }
}

function Get-PshNetworkContentRangeStart {
    param(
        [AllowNull()]
        [string]$ContentRange
    )

    if ($ContentRange -match '^bytes\s+(?<start>[0-9]+)-[0-9]+/(?:[0-9]+|\*)$') {
        return [long]::Parse($Matches.start, [Globalization.CultureInfo]::InvariantCulture)
    }
    return -1
}

function Get-PshNetworkUnsatisfiedRangeLength {
    param(
        [AllowNull()]
        [string]$ContentRange
    )

    if ($ContentRange -match '^bytes\s+\*/(?<length>[0-9]+)$') {
        return [long]::Parse($Matches.length, [Globalization.CultureInfo]::InvariantCulture)
    }
    return -1
}

function Write-PshNetworkFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet(2, 3)]
        [int]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$Suppress
    )

    if ($Suppress) { Set-PshLastExitCode -Code $Code }
    else { Write-PshCommandFailure -Command $Command -Code $Code -Message $Message }
}

function Invoke-PshNetworkTransfer {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Options
    )

    $outputToStdout = [string]$Options.OutputMode -eq 'stdout'
    $destination = $null
    if (-not $outputToStdout) {
        $requestedPath = [string]$Options.OutputPath
        if ([string]$Options.OutputMode -eq 'remote') {
            $requestedPath = Get-PshNetworkRemoteFileName -Uri ([Uri]$Options.Uri) -UseIndexFallback
        }
        $destination = Resolve-PshNetworkOutputPath -Path $requestedPath
    }

    $resumeOffset = 0L
    if ($Options.PSObject.Properties['Resume'] -and [bool]$Options.Resume) {
        if ($outputToStdout) { throw 'resume cannot target standard output.' }
        if ([IO.File]::Exists($destination)) {
            $resumeOffset = [IO.FileInfo]::new($destination).Length
        }
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $waitHandles = New-Object 'System.Collections.Generic.List[System.Threading.WaitHandle]'
    $request = $null
    $response = $null
    try {
        $request = New-PshNetworkRequest `
            -Options $Options `
            -Stopwatch $stopwatch `
            -WaitHandles $waitHandles `
            -ResumeOffset $resumeOffset
        $response = Get-PshNetworkResponse `
            -Request $request `
            -Options $Options `
            -Stopwatch $stopwatch `
            -WaitHandles $waitHandles
        $status = [int]$response.StatusCode
        $httpError = $status -ge 400
        $headerText = $null
        if (([bool]$Options.HeadersOnly) -or ([bool]($Options.PSObject.Properties['ShowHeaders']) -and [bool]$Options.ShowHeaders)) {
            $headerText = Get-PshNetworkResponseHeaderText -Response $response
            if ([bool]($Options.PSObject.Properties['ShowHeaders']) -and [bool]$Options.ShowHeaders -and
                -not ([bool]($Options.PSObject.Properties['Quiet']) -and [bool]$Options.Quiet)) {
                Write-PshNetworkText -Text $headerText
            }
        }

        $isResumeRequest = $Options.PSObject.Properties['Resume'] -and [bool]$Options.Resume
        if ($isResumeRequest -and $status -eq 416) {
            $remoteLength = Get-PshNetworkUnsatisfiedRangeLength -ContentRange ([string]$response.Headers['Content-Range'])
            if ($resumeOffset -gt 0 -and $remoteLength -ge 0 -and $resumeOffset -eq $remoteLength) {
                return
            }
            throw ('server rejected resume range (HTTP {0} {1}).' -f $status, [string]$response.StatusDescription)
        }

        $failOnHttpError = [bool]$Options.FailOnHttpError
        if ($httpError -and $failOnHttpError) {
            throw ('server returned HTTP {0} {1}.' -f $status, [string]$response.StatusDescription)
        }

        if ([bool]$Options.HeadersOnly) {
            if ($outputToStdout) { Write-PshNetworkText -Text $headerText }
            else { Save-PshNetworkResponseFile -Response $response -Options $Options -Stopwatch $stopwatch -Destination $destination -HeaderText $headerText }
            return
        }

        $appendExisting = $false
        if ($isResumeRequest -and $resumeOffset -gt 0 -and $status -eq 206) {
            $rangeStart = Get-PshNetworkContentRangeStart -ContentRange ([string]$response.Headers['Content-Range'])
            if ($rangeStart -lt 0 -or $rangeStart -ne $resumeOffset) {
                throw ('server returned an invalid resume range.')
            }
            $appendExisting = $true
        }

        if ($outputToStdout) {
            $bodyBytes = Read-PshNetworkResponseBytes -Response $response -Options $Options -Stopwatch $stopwatch
            Write-PshNetworkBodyBytes -Bytes $bodyBytes
        }
        else {
            Save-PshNetworkResponseFile `
                -Response $response `
                -Options $Options `
                -Stopwatch $stopwatch `
                -Destination $destination `
                -AppendExisting:$appendExisting
        }
    }
    finally {
        try {
            if ($null -ne $response) { $response.Dispose() }
        }
        finally {
            try {
                if ($null -ne $request) { $request.Abort() }
            }
            finally {
                Close-PshNetworkOwnedAsyncWaitHandles -WaitHandles $waitHandles
                $stopwatch.Stop()
            }
        }
    }
}

function curl {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: curl [-fL] [-o file|-O] [-sS] [-I] [-X method] [-H header] [-d data] [--connect-timeout seconds] [--max-time seconds] URL'
        return
    }

    $options = $null
    try { $options = Get-PshCurlOptions -Arguments $arguments }
    catch { Write-PshCommandFailure -Command 'curl' -Code 2 -Message $_.Exception.Message; return }

    try {
        Invoke-PshNetworkTransfer -Options $options
        Set-PshLastExitCode -Code 0
    }
    catch {
        $suppress = [bool]$options.Silent -and -not [bool]$options.ShowError
        Write-PshNetworkFailure -Command 'curl' -Code 3 -Message $_.Exception.Message -Suppress:$suppress
    }
}

function wget {
    $arguments = @(ConvertTo-PshArgumentArray -InputArguments $args)
    Set-PshLastExitCode -Code 0
    if (Test-PshLongHelp -Arguments $arguments) {
        Write-PshCommandHelp -Usage 'Usage: wget [-O file|-q|-c|-S] [--timeout seconds] [--header header] [--method method] [--body-data data] URL'
        return
    }

    $options = $null
    try { $options = Get-PshWgetOptions -Arguments $arguments }
    catch { Write-PshCommandFailure -Command 'wget' -Code 2 -Message $_.Exception.Message; return }

    try {
        Invoke-PshNetworkTransfer -Options $options
        Set-PshLastExitCode -Code 0
    }
    catch {
        Write-PshNetworkFailure -Command 'wget' -Code 3 -Message $_.Exception.Message -Suppress:$options.Quiet
    }
}
