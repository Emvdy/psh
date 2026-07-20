# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch4-network-{0}' -f [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path -Path $testRoot -ChildPath 'local app data'
$fixtureRoot = Join-Path -Path $testRoot -ChildPath 'fixtures with spaces'
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$originalLocation = (Get-Location).ProviderPath
$assertionCount = 0
$covered = @{}
$serverJob = $null
$module = $null
$aliasOriginal = [ordered]@{}
$aliasFixture = [ordered]@{}

function Assert-PshBatch4Network {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) { throw ('Goal 3 Batch 4 network assertion failed: {0}' -f $Message) }
    $script:assertionCount++
}

function Test-PshBatch4NetworkBytes {
    param(
        [AllowNull()][byte[]]$Actual,
        [AllowNull()][byte[]]$Expected
    )

    [byte[]]$actualBytes = @()
    [byte[]]$expectedBytes = @()
    if ($null -ne $Actual) { $actualBytes = [byte[]]$Actual }
    if ($null -ne $Expected) { $expectedBytes = [byte[]]$Expected }
    if ($actualBytes.Length -ne $expectedBytes.Length) { return $false }
    for ($index = 0; $index -lt $actualBytes.Length; $index++) {
        if ($actualBytes[$index] -ne $expectedBytes[$index]) { return $false }
    }
    return $true
}

function Format-PshBatch4NetworkBytes {
    param([AllowNull()][byte[]]$Bytes)

    [byte[]]$values = @()
    if ($null -ne $Bytes) { $values = [byte[]]$Bytes }
    if ($values.Length -eq 0) { return '<empty>' }
    return ('length={0}; hex={1}; base64={2}' -f $values.Length, [BitConverter]::ToString($values), [Convert]::ToBase64String($values))
}

function Invoke-PshBatch4NetworkCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('curl', 'wget')]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $effectiveArguments = @($Arguments)
    if ($Name -ceq 'curl' -and @($effectiveArguments | Where-Object { $_ -eq '--max-time' -or $_ -like '--max-time=*' }).Count -eq 0) {
        $effectiveArguments = @('--max-time', '5') + $effectiveArguments
    }
    if ($Name -ceq 'wget' -and @($effectiveArguments | Where-Object { $_ -eq '--timeout' -or $_ -like '--timeout=*' }).Count -eq 0) {
        $effectiveArguments = @('--timeout', '5') + $effectiveArguments
    }
    Write-Verbose ('BEGIN {0} {1}' -f $Name, ($effectiveArguments -join ' '))

    $currentModule = Get-Module -Name Psh -ErrorAction Stop
    & $currentModule {
        if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
        $script:PshRawByteSink = New-Object IO.MemoryStream
    }

    $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
    $global:LASTEXITCODE = 0
    $output = @(& $command @effectiveArguments)
    $exitCode = [int]$global:LASTEXITCODE
    foreach ($value in $output) {
        $typeName = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
        Assert-PshBatch4Network ($value -is [string]) ('{0} leaked a non-string object of type {1}.' -f $Name, $typeName)
    }
    $rawBase64 = & $currentModule { [Convert]::ToBase64String($script:PshRawByteSink.ToArray()) }
    Write-Verbose ('END {0} exit={1} text={2} raw={3}' -f $Name, $exitCode, $output.Count, ([Convert]::FromBase64String([string]$rawBase64)).Length)
    $script:covered[$Name] = $true
    return [PSCustomObject]@{
        Output = @($output | ForEach-Object { [string]$_ })
        RawBytes = [byte[]][Convert]::FromBase64String([string]$rawBase64)
        ExitCode = $exitCode
    }
}

function Assert-PshBatch4NetworkRawResult {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    Assert-PshBatch4Network ($Result.ExitCode -eq 0) ('{0} exited {1}: {2}' -f $Context, $Result.ExitCode, ($Result.Output -join ' | '))
    Assert-PshBatch4Network ($Result.Output.Count -eq 0) ('{0} emitted text objects for a response body: {1}' -f $Context, ($Result.Output -join ' | '))
    Assert-PshBatch4Network (Test-PshBatch4NetworkBytes -Actual $Result.RawBytes -Expected $Expected) ('{0} changed response bytes. Actual {1}; expected {2}.' -f $Context, (Format-PshBatch4NetworkBytes $Result.RawBytes), (Format-PshBatch4NetworkBytes $Expected))
}

function Assert-PshBatch4NetworkNoStageFiles {
    param([Parameter(Mandatory = $true)][string]$Context)

    $stages = @(
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $fixtureRoot -Force -ErrorAction Stop |
            Where-Object { $_.Name -like '.psh-*.tmp' }
    )
    Assert-PshBatch4Network ($stages.Count -eq 0) ('{0} left transaction stages: {1}' -f $Context, (($stages | ForEach-Object { $_.Name }) -join ', '))
}

function Remove-PshBatch4NetworkModule {
    $currentModule = Get-Module -Name Psh -ErrorAction SilentlyContinue
    if ($null -ne $currentModule) {
        & $currentModule {
            if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
            $script:PshRawByteSink = $null
        }
        Remove-Module -Name Psh -Force -ErrorAction Stop
    }
}

function Get-PshBatch4NetworkAliasSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)

    $alias = Get-Alias -Name $Name -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $alias) {
        return [PSCustomObject]@{ Exists = $false; Definition = $null; Description = $null; Options = 0; Visibility = 0 }
    }
    return [PSCustomObject]@{
        Exists = $true
        Definition = [string]$alias.Definition
        Description = [string]$alias.Description
        Options = [int]$alias.Options
        Visibility = [int]$alias.Visibility
    }
}

function Test-PshBatch4NetworkAliasSnapshot {
    param(
        [AllowNull()][System.Management.Automation.AliasInfo]$Alias,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    if (-not [bool]$Snapshot.Exists) { return $null -eq $Alias }
    return $null -ne $Alias -and
        [string]$Alias.Definition -ceq [string]$Snapshot.Definition -and
        [string]$Alias.Description -ceq [string]$Snapshot.Description -and
        [int]$Alias.Options -eq [int]$Snapshot.Options -and
        [int]$Alias.Visibility -eq [int]$Snapshot.Visibility
}

function Set-PshBatch4NetworkAliasSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $existing = Get-Alias -Name $Name -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $existing) { Remove-Item -LiteralPath ('Alias:{0}' -f $Name) -Force -ErrorAction Stop }
    if ([bool]$Snapshot.Exists) {
        Set-Alias `
            -Name $Name `
            -Value ([string]$Snapshot.Definition) `
            -Description ([string]$Snapshot.Description) `
            -Option ([System.Management.Automation.ScopedItemOptions][int]$Snapshot.Options) `
            -Scope Global `
            -Force
        (Get-Alias -Name $Name -Scope Global -ErrorAction Stop).Visibility = [System.Management.Automation.SessionStateEntryVisibility][int]$Snapshot.Visibility
    }
}

function Import-PshBatch4NetworkEdition {
    param([Parameter(Mandatory = $true)][ValidateSet('Core', 'Full')][string]$Edition)

    Remove-PshBatch4NetworkModule
    $env:PSH_EDITION = $Edition
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($name in @('curl', 'wget')) {
        $command = Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -ErrorAction SilentlyContinue
        Assert-PshBatch4Network ($null -ne $command -and [string]$command.Source -ceq 'Psh') ('{0} did not export Psh\{1}.' -f $Edition, $name)
    }
}

function Get-PshBatch4NetworkUnusedPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally { $listener.Stop() }
}

try {
    [void][IO.Directory]::CreateDirectory($configRoot)
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $env:LOCALAPPDATA = $configRoot
    $env:PSH_EDITION = 'Core'
    $webRequestAliasTarget = 'Invoke-' + 'WebRequest'

    foreach ($aliasName in @('curl', 'wget')) {
        $aliasOriginal[$aliasName] = Get-PshBatch4NetworkAliasSnapshot -Name $aliasName
        $existingAlias = Get-Alias -Name $aliasName -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $existingAlias) { Remove-Item -LiteralPath ('Alias:{0}' -f $aliasName) -Force -ErrorAction Stop }
        Set-Alias -Name $aliasName -Value $webRequestAliasTarget -Description ('Psh Batch 4 known alias fixture: {0}' -f $aliasName) -Option None -Scope Global -Force
        $aliasFixture[$aliasName] = Get-PshBatch4NetworkAliasSnapshot -Name $aliasName
    }

    $port = Get-PshBatch4NetworkUnusedPort
    $serverJob = Start-Job -ArgumentList $port -ScriptBlock {
        param([int]$Port)

        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $ascii = [Text.Encoding]::ASCII
        $utf8 = New-Object Text.UTF8Encoding($false)
        $resumeBody = $ascii.GetBytes('0123456789ABCDEFGHIJ')
        $crlf = "`r`n"

        function Write-PshBatch4LoopbackResponse {
            param(
                [Parameter(Mandatory = $true)][IO.Stream]$Stream,
                [Parameter(Mandatory = $true)][string]$Method,
                [Parameter(Mandatory = $true)][int]$Status,
                [Parameter(Mandatory = $true)][string]$Reason,
                [Parameter(Mandatory = $true)]
                [AllowEmptyCollection()]
                [byte[]]$Body,
                [Parameter(Mandatory = $true)][string]$ContentType,
                [hashtable]$ExtraHeaders = @{},
                [int]$DelayBeforeHeadersMilliseconds = 0,
                [int]$DelayAfterPrefixMilliseconds = 0,
                [int]$PrefixLength = 0
            )

            if ($DelayBeforeHeadersMilliseconds -gt 0) {
                Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $DelayBeforeHeadersMilliseconds
            }
            $builder = New-Object Text.StringBuilder
            [void]$builder.Append(('HTTP/1.1 {0} {1}' -f $Status, $Reason))
            [void]$builder.Append($script:crlf)
            [void]$builder.Append(('Content-Length: {0}' -f $Body.Length))
            [void]$builder.Append($script:crlf)
            [void]$builder.Append(('Content-Type: {0}' -f $ContentType))
            [void]$builder.Append($script:crlf)
            [void]$builder.Append('X-Psh-Batch4: loopback')
            [void]$builder.Append($script:crlf)
            foreach ($name in $ExtraHeaders.Keys) {
                [void]$builder.Append(('{0}: {1}' -f $name, [string]$ExtraHeaders[$name]))
                [void]$builder.Append($script:crlf)
            }
            [void]$builder.Append('Connection: close')
            [void]$builder.Append($script:crlf)
            [void]$builder.Append($script:crlf)
            $headerBytes = $script:ascii.GetBytes($builder.ToString())
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            $Stream.Flush()
            if ([string]::Equals($Method, 'HEAD', [StringComparison]::OrdinalIgnoreCase) -or $Body.Length -eq 0) { return }

            if ($DelayAfterPrefixMilliseconds -gt 0 -and $PrefixLength -gt 0) {
                $count = [Math]::Min($PrefixLength, $Body.Length)
                $Stream.Write($Body, 0, $count)
                $Stream.Flush()
                Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $DelayAfterPrefixMilliseconds
                if ($count -lt $Body.Length) { $Stream.Write($Body, $count, $Body.Length - $count) }
            }
            else { $Stream.Write($Body, 0, $Body.Length) }
            $Stream.Flush()
        }

        $listener.Start()
        Microsoft.PowerShell.Utility\Write-Output 'READY'
        $stopServer = $false
        try {
            while (-not $stopServer) {
                $client = $listener.AcceptTcpClient()
                $requestDescription = '<unparsed>'
                try {
                    $stream = $client.GetStream()
                    $requestBytes = New-Object 'System.Collections.Generic.List[byte]'
                    while ($true) {
                        $value = $stream.ReadByte()
                        if ($value -lt 0) { break }
                        [void]$requestBytes.Add([byte]$value)
                        $count = $requestBytes.Count
                        if ($count -ge 4 -and
                            $requestBytes[$count - 4] -eq 13 -and $requestBytes[$count - 3] -eq 10 -and
                            $requestBytes[$count - 2] -eq 13 -and $requestBytes[$count - 1] -eq 10) { break }
                    }
                    $requestText = $ascii.GetString($requestBytes.ToArray())
                    $lines = $requestText.Split([string[]]@($crlf), [StringSplitOptions]::None)
                    $requestParts = $lines[0].Split(' ')
                    $method = [string]$requestParts[0]
                    $requestTarget = [string]$requestParts[1]
                    $uri = [Uri]('http://127.0.0.1' + $requestTarget)
                    $path = [string]$uri.AbsolutePath
                    $headers = @{}
                    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
                        $line = [string]$lines[$lineIndex]
                        if ([string]::IsNullOrEmpty($line)) { break }
                        $separator = $line.IndexOf(':')
                        if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).TrimStart() }
                    }

                    $contentLength = 0
                    if ($headers.ContainsKey('Content-Length')) { $contentLength = [int]$headers['Content-Length'] }
                    if ($contentLength -gt 0 -and $headers.ContainsKey('Expect') -and [string]$headers['Expect'] -match '(?i)100-continue') {
                        if ($path -ceq '/slow-post-phases') {
                            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 300
                        }
                        $continueBytes = $ascii.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                        $stream.Write($continueBytes, 0, $continueBytes.Length)
                        $stream.Flush()
                        Microsoft.PowerShell.Utility\Write-Output ('CONTINUE {0} {1}' -f $method, $path)
                    }
                    $body = New-Object byte[] $contentLength
                    $bodyOffset = 0
                    while ($bodyOffset -lt $contentLength) {
                        $read = $stream.Read($body, $bodyOffset, $contentLength - $bodyOffset)
                        if ($read -le 0) { break }
                        $bodyOffset += $read
                    }
                    $rangeText = if ($headers.ContainsKey('Range')) { [string]$headers['Range'] } else { '<none>' }
                    $requestDescription = '{0} {1} Range={2}' -f $method, $path, $rangeText
                    Microsoft.PowerShell.Utility\Write-Output ('REQUEST {0}' -f $requestDescription)

                    $status = 200
                    $reason = 'OK'
                    $contentType = 'application/octet-stream'
                    [byte[]]$responseBody = @()
                    $extraHeaders = @{}
                    $delayBeforeHeaders = 0
                    $delayAfterPrefix = 0
                    $prefixLength = 0
                    $shutdownAfterResponse = $false
                    switch ($path) {
                        '/bytes/bom' {
                            $contentType = 'text/plain; charset=utf-8'
                            $responseBody = [byte[]](239, 187, 191, 66, 79, 77, 45, 98, 111, 100, 121)
                        }
                        '/bytes/nonutf8' {
                            $contentType = 'text/plain; charset=windows-1252'
                            $responseBody = [byte[]](128, 129, 254, 65)
                        }
                        '/bytes/binary' {
                            $contentType = 'text/plain'
                            $responseBody = [byte[]](0, 255, 1, 2, 13, 10, 128, 127)
                        }
                        '/bytes/no-final-newline' {
                            $contentType = 'text/plain; charset=utf-8'
                            $responseBody = $utf8.GetBytes('no-final-newline')
                        }
                        '/headers' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('header-body')
                        }
                        '/redirect' {
                            $status = 302
                            $reason = 'Found'
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('redirect-not-followed')
                            $extraHeaders['Location'] = '/bytes/no-final-newline'
                        }
                        '/error' {
                            $status = 404
                            $reason = 'Not Found'
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('http-error-body')
                        }
                        '/inspect' {
                            $contentType = 'text/plain; charset=utf-8'
                            $headerValue = if ($headers.ContainsKey('X-Psh-Request')) { [string]$headers['X-Psh-Request'] } else { '<missing>' }
                            $responseText = 'METHOD={0};HEADER={1};BODY={2}' -f $method, $headerValue, [Convert]::ToBase64String([byte[]]$body)
                            $responseBody = $utf8.GetBytes($responseText)
                        }
                        '/download/curl-remote.bin' {
                            $responseBody = [byte[]](67, 85, 82, 76, 0, 255)
                        }
                        '/download/wget-remote.bin' {
                            $responseBody = [byte[]](87, 71, 69, 84, 0, 255)
                        }
                        '/resume.bin' {
                            $contentType = 'application/octet-stream'
                            if ($headers.ContainsKey('Range') -and [string]$headers['Range'] -match '^bytes=(?<start>[0-9]+)-$') {
                                $start = [int]$Matches.start
                                if ($start -ge $resumeBody.Length) {
                                    $status = 416
                                    $reason = 'Range Not Satisfiable'
                                    $responseBody = [byte[]]@()
                                    $extraHeaders['Content-Range'] = ('bytes */{0}' -f $resumeBody.Length)
                                }
                                else {
                                    $status = 206
                                    $reason = 'Partial Content'
                                    $responseBody = New-Object byte[] ($resumeBody.Length - $start)
                                    [Array]::Copy($resumeBody, $start, $responseBody, 0, $responseBody.Length)
                                    $extraHeaders['Content-Range'] = ('bytes {0}-{1}/{2}' -f $start, ($resumeBody.Length - 1), $resumeBody.Length)
                                }
                            }
                            else { $responseBody = [byte[]]$resumeBody }
                        }
                        '/stall' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('too-late')
                            $delayBeforeHeaders = 700
                        }
                        '/slow-headers' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('slow-header-success')
                            $delayBeforeHeaders = 600
                        }
                        '/abort-prewait' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('abort-prewait-success')
                            $delayBeforeHeaders = 200
                        }
                        '/slow-post-phases' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('slow-post-phase-success')
                            $delayBeforeHeaders = 800
                        }
                        '/slow-body' {
                            $contentType = 'application/octet-stream'
                            $responseBody = $ascii.GetBytes('slow-body-data')
                            $prefixLength = 2
                            $delayAfterPrefix = 700
                        }
                        '/shutdown' {
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('shutdown')
                            $shutdownAfterResponse = $true
                        }
                        default {
                            $status = 404
                            $reason = 'Not Found'
                            $contentType = 'text/plain'
                            $responseBody = $ascii.GetBytes('unknown-path')
                        }
                    }

                    Write-PshBatch4LoopbackResponse `
                        -Stream $stream `
                        -Method $method `
                        -Status $status `
                        -Reason $reason `
                        -Body $responseBody `
                        -ContentType $contentType `
                        -ExtraHeaders $extraHeaders `
                        -DelayBeforeHeadersMilliseconds $delayBeforeHeaders `
                        -DelayAfterPrefixMilliseconds $delayAfterPrefix `
                        -PrefixLength $prefixLength
                    Microsoft.PowerShell.Utility\Write-Output ('RESPONSE {0} status={1} length={2} content-range={3}' -f $requestDescription, $status, $responseBody.Length, $(if ($extraHeaders.ContainsKey('Content-Range')) { [string]$extraHeaders['Content-Range'] } else { '<none>' }))
                    if ($shutdownAfterResponse) { $stopServer = $true }
                }
                catch {
                    # Clients intentionally abort timeout cases. Keep the loopback
                    # server alive for the remaining deterministic requests.
                    Microsoft.PowerShell.Utility\Write-Output ('SERVER_ERROR {0}: {1}' -f $requestDescription, $_.Exception.ToString())
                }
                finally { $client.Dispose() }
            }
        }
        finally { $listener.Stop() }
    }

    $ready = $false
    for ($attempt = 0; $attempt -lt 800; $attempt++) {
        $serverOutput = @(Receive-Job -Job $serverJob -Keep)
        if ($serverOutput -contains 'READY') { $ready = $true; break }
        if ($serverJob.State -in @('Failed', 'Stopped', 'Completed')) { break }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 25
    }
    Assert-PshBatch4Network $ready ('loopback server did not start: {0}' -f [string]$serverJob.ChildJobs[0].JobStateInfo.Reason)

    $baseUrl = 'http://127.0.0.1:{0}' -f $port
    $rawCases = @(
        [PSCustomObject]@{ Name = 'utf8-bom'; Path = '/bytes/bom'; Bytes = [byte[]](239, 187, 191, 66, 79, 77, 45, 98, 111, 100, 121) }
        [PSCustomObject]@{ Name = 'non-utf8'; Path = '/bytes/nonutf8'; Bytes = [byte[]](128, 129, 254, 65) }
        [PSCustomObject]@{ Name = 'nul-ff-binary'; Path = '/bytes/binary'; Bytes = [byte[]](0, 255, 1, 2, 13, 10, 128, 127) }
        [PSCustomObject]@{ Name = 'no-final-newline'; Path = '/bytes/no-final-newline'; Bytes = [Text.Encoding]::UTF8.GetBytes('no-final-newline') }
    )

    Import-PshBatch4NetworkEdition -Edition Core
    foreach ($aliasName in @('curl', 'wget')) {
        $projected = Get-Command -Name $aliasName -ErrorAction Stop
        Assert-PshBatch4Network ($projected.CommandType -eq 'Function' -and [string]$projected.Source -ceq 'Psh') ('Psh did not peel the known {0} alias.' -f $aliasName)
    }
    Remove-PshBatch4NetworkModule
    foreach ($aliasName in @('curl', 'wget')) {
        Assert-PshBatch4Network (Test-PshBatch4NetworkAliasSnapshot -Alias (Get-Alias -Name $aliasName -Scope Global -ErrorAction SilentlyContinue) -Snapshot $aliasFixture[$aliasName]) ('Remove-Module did not restore alias {0} exactly.' -f $aliasName)
    }

    $configDirectory = Join-Path -Path $configRoot -ChildPath 'Psh'
    [void][IO.Directory]::CreateDirectory($configDirectory)
    $configPath = Join-Path -Path $configDirectory -ChildPath 'config.psd1'
    [IO.File]::WriteAllText($configPath, "@{ SchemaVersion = 1; Edition = 'Core'; DisabledCommands = @('curl', 'wget') }`n", (New-Object Text.UTF8Encoding($false)))
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($aliasName in @('curl', 'wget')) {
        Assert-PshBatch4Network ($null -eq (Get-Command -Name ('Psh\{0}' -f $aliasName) -ErrorAction SilentlyContinue)) ('DisabledCommands left Psh\{0} exported.' -f $aliasName)
        $fallback = Get-Command -Name $aliasName -ErrorAction Stop
        Assert-PshBatch4Network ($fallback.CommandType -eq 'Alias' -and [string]$fallback.Definition -ceq $webRequestAliasTarget) ('DisabledCommands did not fall through to alias {0}.' -f $aliasName)
    }
    Remove-PshBatch4NetworkModule
    [IO.File]::Delete($configPath)
    Import-PshBatch4NetworkEdition -Edition Core
    foreach ($case in $rawCases) {
        $url = $baseUrl + [string]$case.Path
        $curlResult = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @($url)
        Assert-PshBatch4NetworkRawResult -Result $curlResult -Expected ([byte[]]$case.Bytes) -Context ('Core curl {0}' -f $case.Name)
        $wgetResult = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-O', '-', $url)
        Assert-PshBatch4NetworkRawResult -Result $wgetResult -Expected ([byte[]]$case.Bytes) -Context ('Core wget {0}' -f $case.Name)
    }

    $headersUrl = $baseUrl + '/headers'
    $curlHeaders = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-I', $headersUrl)
    Assert-PshBatch4Network ($curlHeaders.ExitCode -eq 0 -and $curlHeaders.RawBytes.Length -eq 0 -and ($curlHeaders.Output -join '') -match 'X-Psh-Batch4: loopback') 'curl -I did not emit text-only response headers.'
    $wgetHeaders = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('--method', 'HEAD', '-O', '-', $headersUrl)
    Assert-PshBatch4Network ($wgetHeaders.ExitCode -eq 0 -and $wgetHeaders.RawBytes.Length -eq 0 -and ($wgetHeaders.Output -join '') -match 'X-Psh-Batch4: loopback') 'wget HEAD did not emit text-only response headers.'
    $wgetShowHeaders = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-S', '-O', '-', $headersUrl)
    Assert-PshBatch4Network ($wgetShowHeaders.ExitCode -eq 0 -and ($wgetShowHeaders.Output -join '') -match 'X-Psh-Batch4: loopback') 'wget -S did not preserve text header output.'
    Assert-PshBatch4Network (Test-PshBatch4NetworkBytes $wgetShowHeaders.RawBytes ([Text.Encoding]::ASCII.GetBytes('header-body'))) 'wget -S changed its raw response body.'

    $redirectUrl = $baseUrl + '/redirect'
    $curlNoFollow = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @($redirectUrl)
    Assert-PshBatch4NetworkRawResult -Result $curlNoFollow -Expected ([Text.Encoding]::ASCII.GetBytes('redirect-not-followed')) -Context 'curl redirect rejection'
    $curlFollow = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-L', $redirectUrl)
    Assert-PshBatch4NetworkRawResult -Result $curlFollow -Expected ([Text.Encoding]::UTF8.GetBytes('no-final-newline')) -Context 'curl -L redirect follow'
    $wgetFollow = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-O', '-', $redirectUrl)
    Assert-PshBatch4NetworkRawResult -Result $wgetFollow -Expected ([Text.Encoding]::UTF8.GetBytes('no-final-newline')) -Context 'wget redirect follow'

    $errorUrl = $baseUrl + '/error'
    $curlHttpError = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @($errorUrl)
    Assert-PshBatch4NetworkRawResult -Result $curlHttpError -Expected ([Text.Encoding]::ASCII.GetBytes('http-error-body')) -Context 'curl HTTP error body without -f'
    $curlFail = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-f', $errorUrl)
    Assert-PshBatch4Network ($curlFail.ExitCode -eq 3 -and $curlFail.RawBytes.Length -eq 0 -and $curlFail.Output.Count -gt 0) 'curl -f did not turn HTTP error into runtime exit 3.'
    $wgetHttpError = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-O', '-', $errorUrl)
    Assert-PshBatch4Network ($wgetHttpError.ExitCode -eq 3 -and $wgetHttpError.RawBytes.Length -eq 0 -and $wgetHttpError.Output.Count -gt 0) 'wget did not reject an HTTP error with runtime exit 3.'

    $inspectUrl = $baseUrl + '/inspect'
    $curlInspect = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-X', 'PATCH', '-H', 'X-Psh-Request: curl-custom', '-d', 'curl-body', $inspectUrl)
    $curlInspectExpected = 'METHOD=PATCH;HEADER=curl-custom;BODY={0}' -f [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('curl-body'))
    Assert-PshBatch4NetworkRawResult -Result $curlInspect -Expected ([Text.Encoding]::UTF8.GetBytes($curlInspectExpected)) -Context 'curl method/header/body'
    $wgetInspect = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('--method', 'PUT', '--header', 'X-Psh-Request: wget-custom', '--body-data', 'wget-body', '-O', '-', $inspectUrl)
    $wgetInspectExpected = 'METHOD=PUT;HEADER=wget-custom;BODY={0}' -f [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('wget-body'))
    Assert-PshBatch4NetworkRawResult -Result $wgetInspect -Expected ([Text.Encoding]::UTF8.GetBytes($wgetInspectExpected)) -Context 'wget method/header/body'

    Set-Location -LiteralPath $fixtureRoot
    $curlOutputPath = Join-Path $fixtureRoot 'curl-output.bin'
    $curlOutput = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-o', $curlOutputPath, ($baseUrl + '/bytes/binary'))
    Assert-PshBatch4Network ($curlOutput.ExitCode -eq 0 -and $curlOutput.Output.Count -eq 0 -and $curlOutput.RawBytes.Length -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes($curlOutputPath)) ([byte[]](0, 255, 1, 2, 13, 10, 128, 127)))) 'curl -o did not write exact response bytes.'
    $curlRemote = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-O', ($baseUrl + '/download/curl-remote.bin'))
    Assert-PshBatch4Network ($curlRemote.ExitCode -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes((Join-Path $fixtureRoot 'curl-remote.bin'))) ([byte[]](67, 85, 82, 76, 0, 255)))) 'curl -O did not use the remote name with exact bytes.'
    $wgetOutputPath = Join-Path $fixtureRoot 'wget-output.bin'
    $wgetOutput = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-O', $wgetOutputPath, ($baseUrl + '/bytes/nonutf8'))
    Assert-PshBatch4Network ($wgetOutput.ExitCode -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes($wgetOutputPath)) ([byte[]](128, 129, 254, 65)))) 'wget -O file did not write exact response bytes.'
    $wgetRemote = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @(($baseUrl + '/download/wget-remote.bin'))
    Assert-PshBatch4Network ($wgetRemote.ExitCode -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes((Join-Path $fixtureRoot 'wget-remote.bin'))) ([byte[]](87, 71, 69, 84, 0, 255)))) 'wget remote-name output did not write exact bytes.'
    Assert-PshBatch4NetworkNoStageFiles -Context 'successful file downloads'

    $resumeExpected = [Text.Encoding]::ASCII.GetBytes('0123456789ABCDEFGHIJ')
    $resumePath = Join-Path $fixtureRoot 'resume.bin'
    [IO.File]::WriteAllBytes($resumePath, [Text.Encoding]::ASCII.GetBytes('0123456'))
    $resume = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-c', '-O', $resumePath, ($baseUrl + '/resume.bin'))
    Assert-PshBatch4Network ($resume.ExitCode -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes($resumePath)) $resumeExpected)) 'wget -c did not append a valid 206 range.'
    $alreadyComplete = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-c', '-O', $resumePath, ($baseUrl + '/resume.bin'))
    $resumeDiagnostics = @(Receive-Job -Job $serverJob -Keep | Where-Object { [string]$_ -ne 'READY' })
    Assert-PshBatch4Network ($alreadyComplete.ExitCode -eq 0 -and (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes($resumePath)) $resumeExpected)) ('wget -c did not accept matching 416 already-complete state. Exit={0}; output={1}; server={2}' -f $alreadyComplete.ExitCode, ($alreadyComplete.Output -join ' | '), ($resumeDiagnostics -join ' || '))
    Assert-PshBatch4NetworkNoStageFiles -Context 'wget resume'

    $curlSilent = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-sf', $errorUrl)
    Assert-PshBatch4Network ($curlSilent.ExitCode -eq 3 -and $curlSilent.Output.Count -eq 0 -and $curlSilent.RawBytes.Length -eq 0) 'curl -s did not suppress a runtime diagnostic.'
    $curlShowError = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('-sSf', $errorUrl)
    Assert-PshBatch4Network ($curlShowError.ExitCode -eq 3 -and $curlShowError.Output.Count -gt 0) 'curl -sS did not restore the runtime diagnostic.'
    $wgetQuiet = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-q', '-O', '-', $errorUrl)
    Assert-PshBatch4Network ($wgetQuiet.ExitCode -eq 3 -and $wgetQuiet.Output.Count -eq 0 -and $wgetQuiet.RawBytes.Length -eq 0) 'wget -q did not suppress a runtime diagnostic.'

    foreach ($unsupported in @(
            [PSCustomObject]@{ Name = 'curl'; Arguments = @('--unsupported', $headersUrl) }
            [PSCustomObject]@{ Name = 'wget'; Arguments = @('--unsupported', $headersUrl) }
        )) {
        $result = Invoke-PshBatch4NetworkCommand -Name $unsupported.Name -Arguments $unsupported.Arguments
        Assert-PshBatch4Network ($result.ExitCode -eq 2 -and $result.Output.Count -gt 0 -and $result.RawBytes.Length -eq 0) ('{0} unsupported flag did not exit 2.' -f $unsupported.Name)
    }

    Import-PshBatch4NetworkEdition -Edition Full
    $fullCurl = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @(($baseUrl + '/bytes/binary'))
    Assert-PshBatch4NetworkRawResult -Result $fullCurl -Expected ([byte[]](0, 255, 1, 2, 13, 10, 128, 127)) -Context 'Full curl raw bytes'
    $fullWget = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('-O', '-', ($baseUrl + '/bytes/bom'))
    Assert-PshBatch4NetworkRawResult -Result $fullWget -Expected ([byte[]](239, 187, 191, 66, 79, 77, 45, 98, 111, 100, 121)) -Context 'Full wget raw bytes'

    Import-PshBatch4NetworkEdition -Edition Core
    $expiredBudgetAbort = & (Get-Module -Name Psh -ErrorAction Stop) {
        param([Parameter(Mandatory = $true)][string]$TargetUrl)

        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create([Uri]$TargetUrl)
        $request.Proxy = $null
        $request.Timeout = [Threading.Timeout]::Infinite
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $asyncResult = $request.BeginGetResponse($null, $null)
        $waitHandle = Get-PshNetworkOwnedAsyncWaitHandle -AsyncResult $asyncResult
        $waitHandles = New-Object 'System.Collections.Generic.List[System.Threading.WaitHandle]'
        [void]$waitHandles.Add($waitHandle)
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 20
        $timedOut = $false
        $requestCanceled = $false
        try {
            try {
                Wait-PshNetworkPreHeaderOperation `
                    -WaitHandle $waitHandle `
                    -Request $request `
                    -Stopwatch $watch `
                    -ConnectTimeoutMilliseconds 1
            }
            catch [TimeoutException] { $timedOut = $true }

            try { [void]$request.EndGetResponse($asyncResult) }
            catch {
                $exception = $_.Exception
                while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
                $requestCanceled = $exception -is [System.Net.WebException] -and
                    $exception.Status -eq [System.Net.WebExceptionStatus]::RequestCanceled
            }
            return [PSCustomObject]@{ TimedOut = $timedOut; RequestCanceled = $requestCanceled }
        }
        finally {
            try { $request.Abort() }
            catch {}
            Close-PshNetworkOwnedAsyncWaitHandles -WaitHandles $waitHandles
        }
    } ($baseUrl + '/abort-prewait')
    Assert-PshBatch4Network ($expiredBudgetAbort.TimedOut -and $expiredBudgetAbort.RequestCanceled) 'pre-WaitOne budget expiry did not abort the pending HttpWebRequest before throwing TimeoutException.'
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 250

    $connectHealthy = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('--connect-timeout', '0.5', ($baseUrl + '/bytes/no-final-newline'))
    Assert-PshBatch4NetworkRawResult -Result $connectHealthy -Expected ([Text.Encoding]::UTF8.GetBytes('no-final-newline')) -Context 'curl connect timeout option'
    $slowHeaderWatch = [Diagnostics.Stopwatch]::StartNew()
    $slowHeaderResult = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('--connect-timeout', '0.1', '--max-time', '2', ($baseUrl + '/slow-headers'))
    $slowHeaderWatch.Stop()
    $slowHeaderDiagnostics = @(Receive-Job -Job $serverJob -Keep)
    $slowHeaderRequests = @($slowHeaderDiagnostics | Where-Object { [string]$_ -ceq 'REQUEST GET /slow-headers Range=<none>' })
    Assert-PshBatch4Network ($slowHeaderResult.ExitCode -eq 3 -and $slowHeaderResult.Output.Count -gt 0 -and $slowHeaderResult.RawBytes.Length -eq 0) 'curl --connect-timeout did not conservatively time out while waiting for delayed response headers.'
    Assert-PshBatch4Network ($slowHeaderWatch.ElapsedMilliseconds -ge 50 -and $slowHeaderWatch.ElapsedMilliseconds -lt 1000) ('curl --connect-timeout did not stop the real request near its 100 ms limit: {0} ms.' -f $slowHeaderWatch.ElapsedMilliseconds)
    Assert-PshBatch4Network ($slowHeaderRequests.Count -eq 1) ('curl --connect-timeout did not send exactly one real HTTP request: {0}' -f ($slowHeaderDiagnostics -join ' | '))
    Assert-PshBatch4Network ($slowHeaderDiagnostics -notcontains 'CONNECT') 'curl --connect-timeout used an extra connection probe.'
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 650
    $twoPhaseResult = & (Get-Module -Name Psh -ErrorAction Stop) {
        param([Parameter(Mandatory = $true)][string]$TargetUrl)

        $options = Get-PshCurlOptions -Arguments @(
            '-H', 'Expect: 100-continue',
            '-d', 'two-phase-body',
            '--connect-timeout', '1',
            '--max-time', '2',
            $TargetUrl
        )
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $waitHandles = New-Object 'System.Collections.Generic.List[System.Threading.WaitHandle]'
        $request = $null
        $response = $null
        $requestPhaseElapsed = -1L
        $timedOut = $false
        $result = $null
        try {
            $request = New-PshNetworkRequest -Options $options -Stopwatch $watch -WaitHandles $waitHandles
            $requestPhaseElapsed = $watch.ElapsedMilliseconds
            try {
                $response = Get-PshNetworkResponse `
                    -Request $request `
                    -Options $options `
                    -Stopwatch $watch `
                    -WaitHandles $waitHandles
            }
            catch [TimeoutException] { $timedOut = $true }
            $result = [PSCustomObject]@{
                RequestPhaseElapsedMilliseconds = $requestPhaseElapsed
                TotalElapsedMilliseconds = $watch.ElapsedMilliseconds
                TimedOut = $timedOut
                ReceivedResponse = $null -ne $response
                WaitHandleCount = $waitHandles.Count
                DisposedWaitHandleCount = 0
                CleanupSucceeded = $false
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
                catch {}
                finally {
                    Close-PshNetworkOwnedAsyncWaitHandles -WaitHandles $waitHandles
                    $disposedWaitHandleCount = 0
                    $cleanupSucceeded = $true
                    foreach ($waitHandle in $waitHandles) {
                        try {
                            [void]$waitHandle.WaitOne(0)
                            $cleanupSucceeded = $false
                        }
                        catch {
                            $exception = $_.Exception
                            while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
                            if ($exception -is [ObjectDisposedException]) { $disposedWaitHandleCount++ }
                            else { $cleanupSucceeded = $false }
                        }
                    }
                    if ($null -ne $result) {
                        $result.DisposedWaitHandleCount = $disposedWaitHandleCount
                        $result.CleanupSucceeded = $cleanupSucceeded -and $disposedWaitHandleCount -eq $waitHandles.Count
                    }
                }
            }
        }
        return $result
    } ($baseUrl + '/slow-post-phases')
    $twoPhaseDiagnostics = @()
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $twoPhaseDiagnostics = @(Receive-Job -Job $serverJob -Keep)
        if (@($twoPhaseDiagnostics | Where-Object {
                    [string]$_ -like 'RESPONSE POST /slow-post-phases *' -or
                    [string]$_ -like 'SERVER_ERROR POST /slow-post-phases *'
                }).Count -gt 0) { break }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50
    }
    $twoPhaseRequests = @($twoPhaseDiagnostics | Where-Object { [string]$_ -ceq 'REQUEST POST /slow-post-phases Range=<none>' })
    Assert-PshBatch4Network ($twoPhaseResult.RequestPhaseElapsedMilliseconds -ge 200 -and $twoPhaseResult.RequestPhaseElapsedMilliseconds -lt 1000) ('POST request-stream/body phase did not consume its real 100-continue delay inside the shared budget: {0} ms.' -f $twoPhaseResult.RequestPhaseElapsedMilliseconds)
    Assert-PshBatch4Network ($twoPhaseResult.TimedOut -and -not $twoPhaseResult.ReceivedResponse) 'POST two-phase request reset the connect timeout before waiting for response headers.'
    Assert-PshBatch4Network ($twoPhaseResult.TotalElapsedMilliseconds -ge 850 -and $twoPhaseResult.TotalElapsedMilliseconds -lt 1200) ('POST two-phase request did not time out before a reset per-phase budget could complete: {0} ms.' -f $twoPhaseResult.TotalElapsedMilliseconds)
    Assert-PshBatch4Network ($twoPhaseResult.WaitHandleCount -eq 3 -and $twoPhaseResult.DisposedWaitHandleCount -eq 3 -and $twoPhaseResult.CleanupSucceeded) ('POST two-phase request did not release all three APM wait handles in finally: recorded={0}; disposed={1}; cleanup={2}.' -f $twoPhaseResult.WaitHandleCount, $twoPhaseResult.DisposedWaitHandleCount, $twoPhaseResult.CleanupSucceeded)
    Assert-PshBatch4Network ($twoPhaseRequests.Count -eq 1 -and $twoPhaseDiagnostics -contains 'CONTINUE POST /slow-post-phases') ('POST two-phase request did not use one real 100-continue HTTP exchange: {0}' -f ($twoPhaseDiagnostics -join ' | '))

    $slowBodyWatch = [Diagnostics.Stopwatch]::StartNew()
    $slowBodyWithConnectLimit = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('--connect-timeout', '0.1', '--max-time', '2', ($baseUrl + '/slow-body'))
    $slowBodyWatch.Stop()
    Assert-PshBatch4NetworkRawResult -Result $slowBodyWithConnectLimit -Expected ([Text.Encoding]::ASCII.GetBytes('slow-body-data')) -Context 'curl fast headers followed by slow body'
    Assert-PshBatch4Network ($slowBodyWatch.ElapsedMilliseconds -ge 500 -and $slowBodyWatch.ElapsedMilliseconds -lt 1500) ('curl connect timeout leaked into response-body reads: {0} ms.' -f $slowBodyWatch.ElapsedMilliseconds)
    $unusedPort = Get-PshBatch4NetworkUnusedPort
    $missingUrl = 'http://127.0.0.1:{0}/missing' -f $unusedPort
    $curlMissing = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('--connect-timeout', '0.2', $missingUrl)
    Assert-PshBatch4Network ($curlMissing.ExitCode -eq 3 -and $curlMissing.Output.Count -gt 0 -and $curlMissing.RawBytes.Length -eq 0) 'curl missing endpoint did not exit runtime 3.'
    $wgetMissing = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('--timeout', '0.2', '-O', '-', $missingUrl)
    Assert-PshBatch4Network ($wgetMissing.ExitCode -eq 3 -and $wgetMissing.Output.Count -gt 0 -and $wgetMissing.RawBytes.Length -eq 0) 'wget missing endpoint did not exit runtime 3.'

    $curlTotalTimeout = Invoke-PshBatch4NetworkCommand -Name curl -Arguments @('--max-time', '0.2', ($baseUrl + '/stall'))
    Assert-PshBatch4Network ($curlTotalTimeout.ExitCode -eq 3 -and $curlTotalTimeout.Output.Count -gt 0) 'curl --max-time did not produce runtime exit 3.'
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 800
    $wgetTimeout = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('--timeout', '0.2', '-O', '-', ($baseUrl + '/stall'))
    Assert-PshBatch4Network ($wgetTimeout.ExitCode -eq 3 -and $wgetTimeout.Output.Count -gt 0) 'wget --timeout did not produce runtime exit 3.'
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 800

    $transactionPath = Join-Path $fixtureRoot 'transaction.bin'
    $transactionOriginal = [Text.Encoding]::ASCII.GetBytes('original-transaction')
    [IO.File]::WriteAllBytes($transactionPath, $transactionOriginal)
    $transactionFailure = Invoke-PshBatch4NetworkCommand -Name wget -Arguments @('--timeout', '0.2', '-O', $transactionPath, ($baseUrl + '/slow-body'))
    Assert-PshBatch4Network ($transactionFailure.ExitCode -eq 3) 'timed-out wget file transfer did not exit runtime 3.'
    Assert-PshBatch4Network (Test-PshBatch4NetworkBytes ([IO.File]::ReadAllBytes($transactionPath)) $transactionOriginal) 'failed wget file transfer changed the existing destination.'
    Assert-PshBatch4NetworkNoStageFiles -Context 'failed file transaction'

    foreach ($name in @('curl', 'wget')) {
        Assert-PshBatch4Network ($covered.ContainsKey($name)) ('no behavior row executed for {0}.' -f $name)
    }
    Microsoft.PowerShell.Utility\Write-Output ('Goal 3 Batch 4 network-command acceptance passed: 2 commands, Core/Full exports, exact raw bytes, local HTTP semantics, timeouts, resume, and {0} assertions.' -f $assertionCount)
    $global:LASTEXITCODE = 0
}
finally {
    Write-Verbose 'CLEANUP module begin'
    try { Remove-PshBatch4NetworkModule } catch {}
    Write-Verbose 'CLEANUP module end'
    Set-Location -LiteralPath $originalLocation -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    if ($null -ne $serverJob) {
        Write-Verbose 'CLEANUP server job begin'
        if ($serverJob.State -notin @('Completed', 'Failed', 'Stopped')) {
            $shutdownClient = $null
            try {
                $shutdownClient = [Net.Sockets.TcpClient]::new()
                $shutdownClient.ReceiveTimeout = 2000
                $shutdownClient.SendTimeout = 2000
                $shutdownClient.Connect([Net.IPAddress]::Loopback, [int]$port)
                $shutdownStream = $shutdownClient.GetStream()
                $shutdownRequest = [Text.Encoding]::ASCII.GetBytes("GET /shutdown HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
                $shutdownStream.Write($shutdownRequest, 0, $shutdownRequest.Length)
                $shutdownStream.Flush()
                $shutdownBuffer = New-Object byte[] 256
                [void]$shutdownStream.Read($shutdownBuffer, 0, $shutdownBuffer.Length)
            }
            catch {}
            finally { if ($null -ne $shutdownClient) { $shutdownClient.Dispose() } }
            $completedJob = Wait-Job -Job $serverJob -Timeout 5
            if ($null -eq $completedJob) { Stop-Job -Job $serverJob -ErrorAction SilentlyContinue }
        }
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
        Write-Verbose 'CLEANUP server job end'
    }
    foreach ($aliasName in @('curl', 'wget')) {
        if ($aliasOriginal.Contains($aliasName)) {
            try { Set-PshBatch4NetworkAliasSnapshot -Name $aliasName -Snapshot $aliasOriginal[$aliasName] } catch {}
        }
    }
    Write-Verbose 'CLEANUP directory begin'
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
    Write-Verbose 'CLEANUP directory end'
}
