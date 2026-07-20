# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$GoldenRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path -Path $RepositoryRoot -ChildPath 'src/Psh/Psh.psd1'
$testRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('psh-goal3-batch4-system-process-{0}' -f [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $testRoot 'local app data'
$fixtureRoot = Join-Path $testRoot 'fixtures with spaces'
$processRoot = Join-Path $testRoot 'process fixtures'
$timeoutNativeHelperAssemblyPath = Join-Path $processRoot 'PshBatch4.TimeoutNativeHelper.dll'
$originalLocalAppData = $env:LOCALAPPDATA
$originalEdition = $env:PSH_EDITION
$originalLocation = (Get-Location).ProviderPath
$utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
$assertionCount = 0
$goldenComparisonCount = 0
$covered = @{}
$trackedProcesses = New-Object Collections.ArrayList
$commandNames = @(
    'which', 'env', 'printenv', 'export', 'test', 'sleep', 'date', 'whoami',
    'hostname', 'clear', 'ps', 'kill', 'pgrep', 'pkill', 'timeout'
)
$aliasNames = @('ps', 'kill', 'sleep', 'clear')
$aliasBaseline = [ordered]@{}
$environmentNames = New-Object Collections.ArrayList

function Assert-PshBatch4 {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw ('Goal 3 Batch 4 system/process assertion failed: {0}' -f $Message) }
    $script:assertionCount++
}

function Get-PshBatch4AliasSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)

    $alias = Get-Alias -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $alias) {
        return [PSCustomObject]@{
            Exists = $false
            Definition = $null
            Description = $null
            Options = [System.Management.Automation.ScopedItemOptions]::None
            Visibility = [System.Management.Automation.SessionStateEntryVisibility]::Public
        }
    }
    return [PSCustomObject]@{
        Exists = $true
        Definition = [string]$alias.Definition
        Description = [string]$alias.Description
        Options = $alias.Options
        Visibility = $alias.Visibility
    }
}

function Test-PshBatch4AliasSnapshot {
    param(
        [AllowNull()][System.Management.Automation.AliasInfo]$Alias,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    if (-not $Snapshot.Exists) { return $null -eq $Alias }
    if ($null -eq $Alias) { return $false }
    return ([string]$Alias.Definition -ceq [string]$Snapshot.Definition -and
        [string]$Alias.Description -ceq [string]$Snapshot.Description -and
        $Alias.Options -eq $Snapshot.Options -and
        $Alias.Visibility -eq $Snapshot.Visibility)
}

function Invoke-PshBatch4Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [switch]$CountsAsBehavior
    )

    $module = Get-Module -Name Psh -ErrorAction Stop
    & $module {
        if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
        $script:PshRawByteSink = New-Object IO.MemoryStream
    }
    try {
        $command = Get-Command -Name ('Psh\{0}' -f $Name) -CommandType Function -ErrorAction Stop
        $global:LASTEXITCODE = 0
        $output = @(& $command @Arguments)
        $exitCode = [int]$global:LASTEXITCODE
        $rawBase64 = & $module { [Convert]::ToBase64String($script:PshRawByteSink.ToArray()) }
        $rawBytes = [Convert]::FromBase64String([string]$rawBase64)
        foreach ($value in $output) {
            $typeName = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
            Assert-PshBatch4 ($value -is [string]) ('{0} leaked a non-string object of type {1}.' -f $Name, $typeName)
        }
        if ($CountsAsBehavior) { $script:covered[$Name] = $true }
        return [PSCustomObject]@{
            Output = @($output | ForEach-Object { [string]$_ })
            RawBytes = [byte[]]$rawBytes
            ExitCode = $exitCode
        }
    }
    finally {
        & $module {
            if ($null -ne $script:PshRawByteSink) { $script:PshRawByteSink.Dispose() }
            $script:PshRawByteSink = $null
        }
    }
}

function Normalize-PshBatch4Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    $value = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($value.EndsWith("`n")) { $value = $value.Substring(0, $value.Length - 1) }
    return $value
}

function Test-PshBatch4ByteSequence {
    param(
        [AllowNull()][byte[]]$Left,
        [AllowNull()][byte[]]$Right
    )

    [byte[]]$leftValues = @()
    [byte[]]$rightValues = @()
    if ($null -ne $Left) { $leftValues = [byte[]]$Left }
    if ($null -ne $Right) { $rightValues = [byte[]]$Right }
    if ($leftValues.Length -ne $rightValues.Length) { return $false }
    for ($index = 0; $index -lt $leftValues.Length; $index++) {
        if ($leftValues[$index] -ne $rightValues[$index]) { return $false }
    }
    return $true
}

function Test-PshBatch4StringArray {
    param(
        [AllowNull()][object[]]$Actual,
        [AllowNull()][string[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }
    for ($index = 0; $index -lt $actualValues.Count; $index++) {
        if (-not [string]::Equals($actualValues[$index], $expectedValues[$index], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-PshBatch4EnvironmentLineNames {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $names = @()
    foreach ($line in $Lines) {
        $text = [string]$line
        $separator = $text.IndexOf('=')
        if ($separator -eq 0) { $separator = $text.IndexOf('=', 1) }
        if ($separator -le 0) { throw ('invalid environment line: {0}' -f $text) }
        $names += $text.Substring(0, $separator)
    }
    return $names
}

function Get-PshBatch4ProcessEnvironmentSnapshot {
    $environment = [Environment]::GetEnvironmentVariables('Process')
    [string[]]$names = @($environment.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $lines = @()
    foreach ($name in $names) { $lines += ('{0}={1}' -f $name, [string]$environment[$name]) }
    return $lines
}

function Compare-PshBatch4GoldenIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [AllowNull()][string[]]$Actual = @()
    )

    if ([string]::IsNullOrWhiteSpace($GoldenRoot)) { return }
    $path = Join-Path $GoldenRoot ($Id + '.txt')
    if (-not [IO.File]::Exists($path)) { return }
    $expected = Normalize-PshBatch4Text ([IO.File]::ReadAllText($path, $utf8NoBom))
    $actualText = Normalize-PshBatch4Text ($Actual -join "`n")
    Assert-PshBatch4 ([string]::Equals($expected, $actualText, [StringComparison]::Ordinal)) ('GNU golden mismatch for {0}. Expected <{1}>, actual <{2}>.' -f $Id, $expected, $actualText)
    $script:goldenComparisonCount++
}

function Get-PshBatch4RawText {
    param([Parameter(Mandatory = $true)][object]$Result)

    return Normalize-PshBatch4Text ($utf8NoBom.GetString([byte[]]$Result.RawBytes))
}

function Test-PshBatch4ProcessAlive {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    try { return (-not $Process.HasExited) }
    catch { return $false }
}

function Wait-PshBatch4ProcessExit {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds = 5000
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (-not (Test-PshBatch4ProcessAlive -Process $Process)) { return $true }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50
    }
    return (-not (Test-PshBatch4ProcessAlive -Process $Process))
}

function Stop-PshBatch4TrackedProcesses {
    foreach ($process in @($script:trackedProcesses)) {
        if ($null -eq $process) { continue }
        try {
            if (Test-PshBatch4ProcessAlive -Process $process) {
                $process.Kill()
                try { [void]$process.WaitForExit(3000) } catch { }
            }
        }
        catch { }
        finally { try { $process.Dispose() } catch { } }
    }
    $script:trackedProcesses.Clear()

}

function Start-PshBatch4TaggedChild {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [int]$DurationSeconds = 60
    )

    $pidPath = Join-Path $processRoot ('{0}-{1}.pid' -f $Tag, [Guid]::NewGuid().ToString('N'))
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:taggedChildScript, 'sleep', $Tag, $pidPath,
        ([string]$DurationSeconds)
    )
    $module = Get-Module -Name Psh -ErrorAction Stop
    $process = & $module {
        param($ExecutablePath, $ArgumentValues, $WorkingDirectory)

        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = [string]$ExecutablePath
        $startInfo.WorkingDirectory = [string]$WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        Set-PshProcessArguments -StartInfo $startInfo -Arguments ([string[]]$ArgumentValues)
        $child = New-Object Diagnostics.Process
        $child.StartInfo = $startInfo
        if (-not $child.Start()) { throw 'Failed to start the tagged process fixture.' }
        return $child
    } $script:powershellPath ([string[]]$arguments) $processRoot
    [void]$script:trackedProcesses.Add($process)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($pidPath) -and $watch.ElapsedMilliseconds -lt 10000) {
        if (-not (Test-PshBatch4ProcessAlive -Process $process)) { break }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50
    }
    Assert-PshBatch4 ([IO.File]::Exists($pidPath)) ('tagged child {0} did not publish its PID.' -f $Tag)
    $reportedPid = 0
    $pidText = [IO.File]::ReadAllText($pidPath, $utf8NoBom).Trim()
    Assert-PshBatch4 ([int]::TryParse($pidText, [ref]$reportedPid) -and $reportedPid -eq $process.Id) ('tagged child {0} published the wrong PID.' -f $Tag)
    Assert-PshBatch4 (Test-PshBatch4ProcessAlive -Process $process) ('tagged child {0} exited before its process test.' -f $Tag)
    return $process
}

function ConvertFrom-PshBatch4ProcessIds {
    param([AllowNull()][string[]]$Lines = @())

    $ids = @()
    foreach ($line in @($Lines)) {
        $first = @(([string]$line -split '\s+', 2))[0]
        $parsed = 0
        if (-not [int]::TryParse($first, [ref]$parsed)) { throw ('Invalid PID row: {0}' -f $line) }
        $ids += $parsed
    }
    return [int[]]$ids
}

function Assert-PshBatch4ExactProcessIds {
    param(
        [AllowNull()][string[]]$Lines = @(),
        [Parameter(Mandatory = $true)][int[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actual = @(ConvertFrom-PshBatch4ProcessIds -Lines $Lines | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    $equal = $actual.Count -eq $wanted.Count
    if ($equal) {
        for ($index = 0; $index -lt $actual.Count; $index++) {
            if ($actual[$index] -ne $wanted[$index]) { $equal = $false; break }
        }
    }
    Assert-PshBatch4 $equal ('{0} selected unexpected PIDs. Expected <{1}>, actual <{2}>.' -f $Context, ($wanted -join ','), ($actual -join ','))
}

function New-PshBatch4TimeoutNativeHelperAssembly {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Explicitly carry timeout's output pipes into the Windows grandchild;
    # standard-handle inheritance differs between the supported runtimes.
    $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class PshBatch4TimeoutNativeChildProcess
{
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;
    private const uint DUPLICATE_SAME_ACCESS = 0x00000002;
    private const uint FILE_TYPE_PIPE = 0x00000003;
    private const uint GENERIC_READ = 0x80000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint CREATE_NO_WINDOW = 0x08000000;

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public int bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateHandle(
        IntPtr sourceProcessHandle,
        IntPtr sourceHandle,
        IntPtr targetProcessHandle,
        out IntPtr targetHandle,
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        ref SECURITY_ATTRIBUTES securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    private static bool IsInvalidHandle(IntPtr handle)
    {
        return handle == IntPtr.Zero || handle == new IntPtr(-1);
    }

    private static void AssertPipeHandle(IntPtr handle, string name)
    {
        if (IsInvalidHandle(handle))
        {
            throw new InvalidOperationException(name + " is not available.");
        }
        if (GetFileType(handle) != FILE_TYPE_PIPE)
        {
            throw new InvalidOperationException(name + " is not a pipe.");
        }
    }

    private static void CloseOwnedHandle(IntPtr handle)
    {
        if (!IsInvalidHandle(handle))
        {
            CloseHandle(handle);
        }
    }

    public static int Start(string executablePath, string encodedCommand)
    {
        if (String.IsNullOrEmpty(executablePath) || executablePath.IndexOf('"') >= 0)
        {
            throw new ArgumentException("The executable path is invalid.", "executablePath");
        }
        if (String.IsNullOrEmpty(encodedCommand))
        {
            throw new ArgumentException("The encoded command is required.", "encodedCommand");
        }

        IntPtr borrowedStdout = GetStdHandle(STD_OUTPUT_HANDLE);
        IntPtr borrowedStderr = GetStdHandle(STD_ERROR_HANDLE);
        AssertPipeHandle(borrowedStdout, "stdout");
        AssertPipeHandle(borrowedStderr, "stderr");

        IntPtr inheritedStdout = IntPtr.Zero;
        IntPtr inheritedStderr = IntPtr.Zero;
        IntPtr inheritedStdin = new IntPtr(-1);
        PROCESS_INFORMATION processInformation = new PROCESS_INFORMATION();
        try
        {
            IntPtr currentProcess = GetCurrentProcess();
            if (!DuplicateHandle(currentProcess, borrowedStdout, currentProcess, out inheritedStdout, 0, true, DUPLICATE_SAME_ACCESS))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to duplicate stdout for inheritance.");
            }
            if (!DuplicateHandle(currentProcess, borrowedStderr, currentProcess, out inheritedStderr, 0, true, DUPLICATE_SAME_ACCESS))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to duplicate stderr for inheritance.");
            }

            SECURITY_ATTRIBUTES securityAttributes = new SECURITY_ATTRIBUTES();
            securityAttributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            securityAttributes.bInheritHandle = 1;
            inheritedStdin = CreateFileW(
                "NUL",
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ref securityAttributes,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);
            if (IsInvalidHandle(inheritedStdin))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open inherited NUL stdin.");
            }

            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startupInfo.dwFlags = STARTF_USESTDHANDLES;
            startupInfo.hStdInput = inheritedStdin;
            startupInfo.hStdOutput = inheritedStdout;
            startupInfo.hStdError = inheritedStderr;

            StringBuilder commandLine = new StringBuilder(executablePath.Length + encodedCommand.Length + 80);
            commandLine.Append('"');
            commandLine.Append(executablePath);
            commandLine.Append("\" -NoLogo -NoProfile -NonInteractive -EncodedCommand ");
            commandLine.Append(encodedCommand);

            if (!CreateProcessW(
                executablePath,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                CREATE_NO_WINDOW,
                IntPtr.Zero,
                null,
                ref startupInfo,
                out processInformation))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to start the inheriting timeout grandchild.");
            }
            return checked((int)processInformation.dwProcessId);
        }
        finally
        {
            CloseOwnedHandle(processInformation.hThread);
            CloseOwnedHandle(processInformation.hProcess);
            CloseOwnedHandle(inheritedStdin);
            CloseOwnedHandle(inheritedStderr);
            CloseOwnedHandle(inheritedStdout);
        }
    }
}
'@

    [void](Add-Type -TypeDefinition $source -OutputAssembly $Path -OutputType Library -ErrorAction Stop)
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [void][IO.Directory]::CreateDirectory($configRoot)
    [void][IO.Directory]::CreateDirectory($processRoot)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        New-PshBatch4TimeoutNativeHelperAssembly -Path $timeoutNativeHelperAssemblyPath
    }
    if (-not [string]::IsNullOrWhiteSpace($GoldenRoot)) {
        Assert-PshBatch4 ([IO.Directory]::Exists($GoldenRoot)) ('GNU golden root does not exist: {0}' -f $GoldenRoot)
    }
    $env:LOCALAPPDATA = $configRoot
    $env:PSH_EDITION = 'Core'
    foreach ($name in $aliasNames) { $aliasBaseline[$name] = Get-PshBatch4AliasSnapshot -Name $name }

    $commandSourceRoot = Join-Path $RepositoryRoot 'src/Psh/Commands'
    $commandSourcePaths = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $commandSourceRoot -Filter '*.ps1' -File -ErrorAction Stop)
    $commandSourcePaths += Microsoft.PowerShell.Management\Get-Item -LiteralPath (Join-Path $RepositoryRoot 'src/Psh/Psh.psm1') -ErrorAction Stop
    Assert-PshBatch4 ($commandSourcePaths.Count -ge 1) 'No command implementation source was found.'
    foreach ($sourcePath in $commandSourcePaths) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-PshBatch4 (@($parseErrors).Count -eq 0) ('PowerShell parser errors were found in {0}.' -f $sourcePath.Name)
        $expressionCommands = @(
            $ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                $name = $node.GetCommandName()
                return [string]::Equals($name, 'Invoke-Expression', [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals($name, 'iex', [StringComparison]::OrdinalIgnoreCase)
            }, $true)
        )
        Assert-PshBatch4 ($expressionCommands.Count -eq 0) ('{0} invokes Invoke-Expression/iex.' -f $sourcePath.Name)
    }

    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    foreach ($name in $commandNames) {
        $exported = Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -ErrorAction Stop
        Assert-PshBatch4 ($exported.Source -ceq 'Psh') ('{0} is not exported by Psh.' -f $name)
        $help = Invoke-PshBatch4Command -Name $name -Arguments @('--help')
        Assert-PshBatch4 ($help.ExitCode -eq 0 -and $help.Output.Count -ge 1 -and $help.Output[0] -match '^Usage:') ('{0} --help failed.' -f $name)
    }

    $coreCapabilities = Get-PshCapabilities
    $commandSpecificationPath = Join-Path $RepositoryRoot 'generated/commands.json'
    $commandSpecification = [IO.File]::ReadAllText($commandSpecificationPath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
    foreach ($name in $commandNames) {
        $capability = @($coreCapabilities.commands | Where-Object { [string]$_.name -ceq $name })[0]
        $specificationEntry = @($commandSpecification.Commands | Where-Object { [string]$_.Name -ceq $name })[0]
        Assert-PshBatch4 ($null -ne $capability -and $null -ne $specificationEntry) ('capability/specification entry is missing for {0}.' -f $name)
        $missingCapabilityFields = @(
            @('summary', 'flags', 'objectApi', 'coreBackend', 'fullBackend') | Where-Object {
                $capability.PSObject.Properties.Name -notcontains $_
            }
        )
        Assert-PshBatch4 ($missingCapabilityFields.Count -eq 0) ('Core capability for {0} is missing fields: {1}.' -f $name, ($missingCapabilityFields -join ', '))
        Assert-PshBatch4 ([string]$capability.summary -ceq [string]$specificationEntry.Summary) ('Core capability summary differs from commands.json for {0}.' -f $name)
        Assert-PshBatch4 (Test-PshBatch4StringArray @($capability.flags) @($specificationEntry.Flags)) ('Core capability flags differ from commands.json for {0}.' -f $name)
        Assert-PshBatch4 ([string]$capability.objectApi -ceq [string]$specificationEntry.ObjectApi) ('Core capability objectApi differs from commands.json for {0}.' -f $name)
        Assert-PshBatch4 ([string]$capability.coreBackend -ceq [string]$specificationEntry.CoreBackend -and [string]$capability.fullBackend -ceq [string]$specificationEntry.FullBackend) ('Core capability backend fields differ from commands.json for {0}.' -f $name)
        Assert-PshBatch4 ([string]$capability.activeBackend -ceq 'powershell') ('Core reports the wrong active backend for {0}.' -f $name)
    }

    $script:powershellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $whichCurrent = Invoke-PshBatch4Command -Name which -Arguments @($powershellPath) -CountsAsBehavior
    Assert-PshBatch4 ($whichCurrent.ExitCode -eq 0 -and $whichCurrent.Output.Count -eq 1 -and [IO.Path]::GetFullPath($whichCurrent.Output[0]) -ieq [IO.Path]::GetFullPath($powershellPath)) 'which did not locate the current PowerShell executable.'
    $whichAll = Invoke-PshBatch4Command -Name which -Arguments @('-a', $powershellPath)
    Assert-PshBatch4 ($whichAll.ExitCode -eq 0 -and $whichAll.Output.Count -eq 1) 'which -a did not deduplicate the current executable.'
    $whichMissing = Invoke-PshBatch4Command -Name which -Arguments @('psh-batch4-command-that-does-not-exist')
    Assert-PshBatch4 ($whichMissing.ExitCode -eq 1 -and $whichMissing.Output.Count -eq 0) 'which missing-command behavior failed.'

    $nameSuffix = [Guid]::NewGuid().ToString('N').ToUpperInvariant()
    $envAlpha = 'PSH_BATCH4_ALPHA_' + $nameSuffix
    $envZeta = 'PSH_BATCH4_ZETA_' + $nameSuffix
    $envRestore = 'PSH_BATCH4_RESTORE_' + $nameSuffix
    foreach ($name in @($envAlpha, $envZeta, $envRestore)) { [void]$environmentNames.Add($name) }
    [Environment]::SetEnvironmentVariable($envRestore, 'original value', 'Process')

    $parenthesizedPrefixLines = @('ProgramFiles=C:\Program Files', 'ProgramFiles(x86)=C:\Program Files (x86)')
    $parenthesizedPrefixWholeLineSort = @($parenthesizedPrefixLines)
    [Array]::Sort($parenthesizedPrefixWholeLineSort, [StringComparer]::Ordinal)
    $parenthesizedPrefixNames = @(Get-PshBatch4EnvironmentLineNames -Lines $parenthesizedPrefixLines)
    $parenthesizedPrefixNameSort = @($parenthesizedPrefixNames)
    [Array]::Sort($parenthesizedPrefixNameSort, [StringComparer]::Ordinal)
    Assert-PshBatch4 ((Test-PshBatch4StringArray $parenthesizedPrefixNames $parenthesizedPrefixNameSort) -and $parenthesizedPrefixWholeLineSort[0] -ceq $parenthesizedPrefixLines[1]) 'environment ordering regression did not distinguish name sorting from whole-line sorting.'

    $hiddenDriveNames = @(Get-PshBatch4EnvironmentLineNames -Lines @('=C:=C:\psh-batch4', 'Path=C:\Windows'))
    Assert-PshBatch4 (Test-PshBatch4StringArray $hiddenDriveNames @('=C:', 'Path')) 'environment line parsing did not preserve a Windows hidden drive variable name.'
    $invalidEnvironmentLineRejected = $false
    try { [void](Get-PshBatch4EnvironmentLineNames -Lines @('PSH_BATCH4_INVALID_ENVIRONMENT_LINE')) }
    catch { $invalidEnvironmentLineRejected = $true }
    Assert-PshBatch4 $invalidEnvironmentLineRejected 'environment line parsing accepted a line without a name/value separator.'

    $environmentBeforeInheritedListing = @(Get-PshBatch4ProcessEnvironmentSnapshot)
    $envInherited = Invoke-PshBatch4Command -Name env
    $environmentAfterInheritedListing = @(Get-PshBatch4ProcessEnvironmentSnapshot)
    $envInheritedNames = @(Get-PshBatch4EnvironmentLineNames -Lines ([string[]]$envInherited.Output))
    $envInheritedSortedNames = @($envInheritedNames)
    [Array]::Sort($envInheritedSortedNames, [StringComparer]::Ordinal)
    Assert-PshBatch4 ($envInherited.ExitCode -eq 0 -and (Test-PshBatch4StringArray $envInherited.Output $environmentBeforeInheritedListing)) 'env inherited output did not exactly match the current process environment in ordinal name order.'
    Assert-PshBatch4 (Test-PshBatch4StringArray $envInheritedNames $envInheritedSortedNames) 'env inherited output was not ordinally sorted by variable name.'
    Assert-PshBatch4 ($envInherited.Output -contains ($envRestore + '=original value')) 'env inherited output omitted the current process environment marker.'
    Assert-PshBatch4 (Test-PshBatch4StringArray $environmentAfterInheritedListing $environmentBeforeInheritedListing) 'env inherited listing changed the current process environment.'
    $envClean = Invoke-PshBatch4Command -Name env -Arguments @('-i', ($envZeta + '=two'), ($envAlpha + '=one')) -CountsAsBehavior
    Assert-PshBatch4 ($envClean.ExitCode -eq 0 -and (Test-PshBatch4StringArray $envClean.Output @(('{0}=two' -f $envZeta), ('{0}=one' -f $envAlpha)))) 'env -i did not preserve explicit assignment order.'
    $envCleanReverse = Invoke-PshBatch4Command -Name env -Arguments @('-i', ($envAlpha + '=one'), ($envZeta + '=two'))
    Assert-PshBatch4 ($envCleanReverse.ExitCode -eq 0 -and (Test-PshBatch4StringArray $envCleanReverse.Output @(('{0}=one' -f $envAlpha), ('{0}=two' -f $envZeta)))) 'env -i did not preserve reversed explicit assignment order.'
    $envCleanDuplicate = Invoke-PshBatch4Command -Name env -Arguments @('-i', ($envZeta + '=first'), ($envAlpha + '=middle'), ($envZeta + '=last'))
    Assert-PshBatch4 ($envCleanDuplicate.ExitCode -eq 0 -and (Test-PshBatch4StringArray $envCleanDuplicate.Output @(('{0}=last' -f $envZeta), ('{0}=middle' -f $envAlpha)))) 'env -i duplicate assignment did not keep its first position with the final value.'
    $envNull = Invoke-PshBatch4Command -Name env -Arguments @('-0', '-i', ($envZeta + '=two'), ($envAlpha + '=one'))
    $expectedEnvNull = [byte[]]$utf8NoBom.GetBytes(('{0}=two{1}{2}=one{1}' -f $envZeta, [char]0, $envAlpha))
    Assert-PshBatch4 ($envNull.ExitCode -eq 0 -and $envNull.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence $envNull.RawBytes $expectedEnvNull)) 'env -0 did not emit exact UTF-8 NUL-delimited bytes.'
    $envSuccess = Invoke-PshBatch4Command -Name env -Arguments @(($envRestore + '=temporary value'), 'Psh\printenv', $envRestore)
    Assert-PshBatch4 ($envSuccess.ExitCode -eq 0 -and $envSuccess.Output.Count -eq 1 -and $envSuccess.Output[0] -ceq 'temporary value') 'env did not run a command with its temporary assignment.'
    Assert-PshBatch4 ([Environment]::GetEnvironmentVariable($envRestore, 'Process') -ceq 'original value') 'env did not restore an assignment after command success.'
    $envChildFailure = Invoke-PshBatch4Command -Name env -Arguments @(($envRestore + '=temporary failure value'), 'Psh\test', '')
    Assert-PshBatch4 ($envChildFailure.ExitCode -eq 1) 'env did not preserve a child no-match exit.'
    Assert-PshBatch4 ([Environment]::GetEnvironmentVariable($envRestore, 'Process') -ceq 'original value') 'env did not restore an assignment after child failure.'
    $envMissingCommand = Invoke-PshBatch4Command -Name env -Arguments @(($envRestore + '=temporary missing value'), 'psh-batch4-missing-command')
    Assert-PshBatch4 ($envMissingCommand.ExitCode -eq 4) 'env missing command did not exit 4.'
    Assert-PshBatch4 ([Environment]::GetEnvironmentVariable($envRestore, 'Process') -ceq 'original value') 'env did not restore an assignment after command lookup failure.'

    [Environment]::SetEnvironmentVariable($envAlpha, 'first value', 'Process')
    [Environment]::SetEnvironmentVariable($envZeta, 'second value', 'Process')
    $printenvValues = Invoke-PshBatch4Command -Name printenv -Arguments @($envAlpha, $envZeta) -CountsAsBehavior
    Assert-PshBatch4 ($printenvValues.ExitCode -eq 0 -and (Test-PshBatch4StringArray $printenvValues.Output @('first value', 'second value'))) 'printenv did not preserve requested value order.'
    $printenvNull = Invoke-PshBatch4Command -Name printenv -Arguments @('-0', $envAlpha, $envZeta)
    $expectedPrintenvNull = [byte[]]$utf8NoBom.GetBytes(('first value{0}second value{0}' -f [char]0))
    Assert-PshBatch4 ($printenvNull.ExitCode -eq 0 -and $printenvNull.Output.Count -eq 0 -and (Test-PshBatch4ByteSequence $printenvNull.RawBytes $expectedPrintenvNull)) 'printenv -0 did not emit exact UTF-8 NUL-delimited bytes.'
    $printenvMissing = Invoke-PshBatch4Command -Name printenv -Arguments @($envAlpha, ('PSH_BATCH4_MISSING_' + $nameSuffix))
    Assert-PshBatch4 ($printenvMissing.ExitCode -eq 1 -and $printenvMissing.Output.Count -eq 1 -and $printenvMissing.Output[0] -ceq 'first value') 'printenv did not report a missing requested variable with exit 1.'

    $exportName = 'PSH_BATCH4_EXPORT_' + $nameSuffix
    [void]$environmentNames.Add($exportName)
    $exportSet = Invoke-PshBatch4Command -Name export -Arguments @(($exportName + '=persisted value')) -CountsAsBehavior
    Assert-PshBatch4 ($exportSet.ExitCode -eq 0 -and [Environment]::GetEnvironmentVariable($exportName, 'Process') -ceq 'persisted value') 'export assignment did not persist in the process environment.'
    $exportNameOnly = Invoke-PshBatch4Command -Name export -Arguments @($exportName)
    Assert-PshBatch4 ($exportNameOnly.ExitCode -eq 0 -and [Environment]::GetEnvironmentVariable($exportName, 'Process') -ceq 'persisted value') 'export NAME changed an existing value.'
    $exportPrint = Invoke-PshBatch4Command -Name export -Arguments @('-p')
    Assert-PshBatch4 ($exportPrint.ExitCode -eq 0 -and $exportPrint.Output -contains ('export {0}=persisted value' -f $exportName)) 'export -p did not display the persisted value.'
    $exportRemove = Invoke-PshBatch4Command -Name export -Arguments @('-n', $exportName)
    Assert-PshBatch4 ($exportRemove.ExitCode -eq 0 -and $null -eq [Environment]::GetEnvironmentVariable($exportName, 'Process')) 'export -n did not remove the variable.'
    $exportEmptyName = 'PSH_BATCH4_EXPORT_EMPTY_' + $nameSuffix
    [void]$environmentNames.Add($exportEmptyName)
    $exportEmpty = Invoke-PshBatch4Command -Name export -Arguments @(($exportEmptyName + '='))
    $printenvEmpty = Invoke-PshBatch4Command -Name printenv -Arguments @($exportEmptyName)
    Assert-PshBatch4 ($exportEmpty.ExitCode -eq 0 -and $printenvEmpty.ExitCode -eq 0 -and $printenvEmpty.Output.Count -eq 1 -and $printenvEmpty.Output[0] -ceq '') 'export NAME= did not create an existing empty environment variable.'
    $envUnsetEmpty = Invoke-PshBatch4Command -Name env -Arguments @('-u', $exportEmptyName, 'Psh\printenv', $exportEmptyName)
    Assert-PshBatch4 ($envUnsetEmpty.ExitCode -eq 1 -and $envUnsetEmpty.Output.Count -eq 0) 'env -u did not hide an existing empty variable from its command.'
    $printenvEmptyRestored = Invoke-PshBatch4Command -Name printenv -Arguments @($exportEmptyName)
    Assert-PshBatch4 ($printenvEmptyRestored.ExitCode -eq 0 -and $printenvEmptyRestored.Output.Count -eq 1 -and $printenvEmptyRestored.Output[0] -ceq '') 'env -u did not restore an existing empty variable exactly.'
    $neverExistedName = 'PSH_BATCH4_NEVER_EXISTED_' + $nameSuffix
    [void]$environmentNames.Add($neverExistedName)
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath ('Env:\{0}' -f $neverExistedName) -Force -ErrorAction SilentlyContinue
    $envUnsetAbsent = Invoke-PshBatch4Command -Name env -Arguments @('-u', $neverExistedName, 'Psh\test', 'value')
    $printenvStillAbsent = Invoke-PshBatch4Command -Name printenv -Arguments @($neverExistedName)
    Assert-PshBatch4 ($envUnsetAbsent.ExitCode -eq 0 -and $printenvStillAbsent.ExitCode -eq 1 -and $printenvStillAbsent.Output.Count -eq 0) 'env -u created a variable that was originally absent.'
    $exportTransactionalName = 'PSH_BATCH4_EXPORT_TRANSACTION_' + $nameSuffix
    [void]$environmentNames.Add($exportTransactionalName)
    $exportInvalid = Invoke-PshBatch4Command -Name export -Arguments @(($exportTransactionalName + '=must-not-apply'), 'invalid-name!')
    Assert-PshBatch4 ($exportInvalid.ExitCode -eq 2 -and $null -eq [Environment]::GetEnvironmentVariable($exportTransactionalName, 'Process')) 'export applied an earlier assignment before rejecting invalid syntax.'

    $testFile = Join-Path $fixtureRoot 'nonempty test file.txt'
    $emptyFile = Join-Path $fixtureRoot 'empty test file.txt'
    $testDirectory = Join-Path $fixtureRoot 'test directory'
    [IO.File]::WriteAllText($testFile, 'content', $utf8NoBom)
    [IO.File]::WriteAllBytes($emptyFile, [byte[]]@())
    [void][IO.Directory]::CreateDirectory($testDirectory)
    foreach ($fileTest in @(
            @('-e', $testFile), @('-f', $testFile), @('-d', $testDirectory),
            @('-s', $testFile), @('-r', $testFile), @('-w', $testFile), @('-x', $testDirectory)
        )) {
        $result = Invoke-PshBatch4Command -Name test -Arguments ([string[]]$fileTest) -CountsAsBehavior
        Assert-PshBatch4 ($result.ExitCode -eq 0 -and $result.Output.Count -eq 0) ('test file expression failed: {0}' -f ($fileTest -join ' '))
    }
    $testEmpty = Invoke-PshBatch4Command -Name test -Arguments @('-s', $emptyFile)
    $testMissing = Invoke-PshBatch4Command -Name test -Arguments @('-e', (Join-Path $fixtureRoot 'missing.txt'))
    Assert-PshBatch4 ($testEmpty.ExitCode -eq 1 -and $testMissing.ExitCode -eq 1) 'test false file expressions did not exit 1.'
    $testString = Invoke-PshBatch4Command -Name test -Arguments @('-n', 'value')
    $testZero = Invoke-PshBatch4Command -Name test -Arguments @('-z', '')
    $testEqual = Invoke-PshBatch4Command -Name test -Arguments @('alpha', '=', 'alpha')
    $testNotEqual = Invoke-PshBatch4Command -Name test -Arguments @('alpha', '!=', 'beta')
    $testNegated = Invoke-PshBatch4Command -Name test -Arguments @('!', '-n', '')
    Assert-PshBatch4 ($testString.ExitCode -eq 0 -and $testZero.ExitCode -eq 0 -and $testEqual.ExitCode -eq 0 -and $testNotEqual.ExitCode -eq 0 -and $testNegated.ExitCode -eq 0) 'test string or negation semantics failed.'
    $testNumericEqual = Invoke-PshBatch4Command -Name test -Arguments @('42', '-eq', '42')
    $testNumericLess = Invoke-PshBatch4Command -Name test -Arguments @('-2', '-lt', '3')
    $testNumericGreater = Invoke-PshBatch4Command -Name test -Arguments @('9', '-ge', '8')
    $testNumericFalse = Invoke-PshBatch4Command -Name test -Arguments @('9', '-lt', '8')
    $testNumericInvalid = Invoke-PshBatch4Command -Name test -Arguments @('not-an-integer', '-eq', '1')
    Assert-PshBatch4 ($testNumericEqual.ExitCode -eq 0 -and $testNumericLess.ExitCode -eq 0 -and $testNumericGreater.ExitCode -eq 0 -and $testNumericFalse.ExitCode -eq 1 -and $testNumericInvalid.ExitCode -eq 2) 'test numeric comparison semantics failed.'

    $sleepWatch = [Diagnostics.Stopwatch]::StartNew()
    $sleepResult = Invoke-PshBatch4Command -Name sleep -Arguments @('250ms') -CountsAsBehavior
    $sleepWatch.Stop()
    Assert-PshBatch4 ($sleepResult.ExitCode -eq 0 -and $sleepResult.Output.Count -eq 0 -and $sleepWatch.ElapsedMilliseconds -ge 200 -and $sleepWatch.ElapsedMilliseconds -lt 5000) ('sleep timing was outside the expected range: {0} ms.' -f $sleepWatch.ElapsedMilliseconds)
    $sleepInvalid = Invoke-PshBatch4Command -Name sleep -Arguments @('-1s')
    Assert-PshBatch4 ($sleepInvalid.ExitCode -eq 2) 'sleep accepted a negative duration.'

    $dateFixed = Invoke-PshBatch4Command -Name date -Arguments @('-u', '-d', '2024-02-03T04:05:06Z', '+%Y-%m-%dT%H:%M:%SZ') -CountsAsBehavior
    Assert-PshBatch4 ($dateFixed.ExitCode -eq 0 -and $dateFixed.Output.Count -eq 1 -and $dateFixed.Output[0] -ceq '2024-02-03T04:05:06Z') 'date fixed UTC formatting failed.'
    $dateIso = Invoke-PshBatch4Command -Name date -Arguments @('-u', '--date=2024-02-03T04:05:06Z', '-I=seconds')
    Assert-PshBatch4 ($dateIso.ExitCode -eq 0 -and $dateIso.Output.Count -eq 1 -and $dateIso.Output[0] -ceq '2024-02-03T04:05:06+00:00') 'date ISO seconds formatting failed.'
    $dateRfc = Invoke-PshBatch4Command -Name date -Arguments @('-u', '-R', '-d', '2024-02-03T04:05:06Z')
    Assert-PshBatch4 ($dateRfc.ExitCode -eq 0 -and $dateRfc.Output.Count -eq 1 -and $dateRfc.Output[0] -ceq 'Sat, 03 Feb 2024 04:05:06 +0000') 'date RFC formatting failed.'
    $datePercent = Invoke-PshBatch4Command -Name date -Arguments @('-u', '-d', '2024-02-03T04:05:06Z', '+%%')
    Assert-PshBatch4 ($datePercent.ExitCode -eq 0 -and $datePercent.Output.Count -eq 1 -and $datePercent.Output[0] -ceq '%') 'date %% formatting failed.'
    $dateInvalid = Invoke-PshBatch4Command -Name date -Arguments @('+%Q')
    Assert-PshBatch4 ($dateInvalid.ExitCode -eq 2) 'date accepted an unsupported format directive.'

    $whoamiResult = Invoke-PshBatch4Command -Name whoami -CountsAsBehavior
    Assert-PshBatch4 ($whoamiResult.ExitCode -eq 0 -and $whoamiResult.Output.Count -eq 1 -and $whoamiResult.Output[0] -ceq [Environment]::UserName) 'whoami did not return the current user name.'

    $hostDefault = Invoke-PshBatch4Command -Name hostname -CountsAsBehavior
    $hostFqdn = Invoke-PshBatch4Command -Name hostname -Arguments @('-f')
    $hostShort = Invoke-PshBatch4Command -Name hostname -Arguments @('-s')
    $hostAddresses = Invoke-PshBatch4Command -Name hostname -Arguments @('-i')
    Assert-PshBatch4 ($hostDefault.ExitCode -eq 0 -and $hostDefault.Output.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($hostDefault.Output[0])) 'hostname default output was empty.'
    Assert-PshBatch4 ($hostFqdn.ExitCode -eq 0 -and $hostFqdn.Output.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($hostFqdn.Output[0])) 'hostname -f did not return a fully qualified host name.'
    Assert-PshBatch4 ($hostShort.ExitCode -eq 0 -and $hostShort.Output.Count -eq 1 -and $hostShort.Output[0] -ceq $hostDefault.Output[0].Split('.')[0]) 'hostname -s did not return the short host name.'
    $addressTokens = @($hostAddresses.Output | ForEach-Object { @(([string]$_ -split '\s+') | Where-Object { $_ }) })
    $validAddressCount = 0
    foreach ($addressToken in $addressTokens) {
        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse([string]$addressToken, [ref]$parsedAddress)) { $validAddressCount++ }
    }
    Assert-PshBatch4 ($hostAddresses.ExitCode -eq 0 -and $addressTokens.Count -ge 1 -and $validAddressCount -eq $addressTokens.Count) 'hostname -i did not return only IP address values.'

    $clearDefault = Invoke-PshBatch4Command -Name clear -CountsAsBehavior
    $clearScrollback = Invoke-PshBatch4Command -Name clear -Arguments @('-x')
    Assert-PshBatch4 ($clearDefault.ExitCode -eq 0 -and $clearDefault.Output.Count -eq 0 -and $clearDefault.RawBytes.Length -eq 0) 'clear emitted output in a redirected test host.'
    Assert-PshBatch4 ($clearScrollback.ExitCode -eq 0 -and $clearScrollback.Output.Count -eq 0 -and $clearScrollback.RawBytes.Length -eq 0) 'clear -x failed or emitted output in a redirected test host.'

    $envGolden = Invoke-PshBatch4Command -Name env -Arguments @('-i', 'PSH_BATCH4_GOLDEN_ZETA=two', 'PSH_BATCH4_GOLDEN_ALPHA=one')
    Assert-PshBatch4 ($envGolden.ExitCode -eq 0) 'env deterministic GNU golden fixture failed.'
    Compare-PshBatch4GoldenIfPresent -Id 'env_clean' -Actual $envGolden.Output
    Compare-PshBatch4GoldenIfPresent -Id 'printenv_values' -Actual $printenvValues.Output
    Compare-PshBatch4GoldenIfPresent -Id 'test_true' -Actual @()
    $sleepGolden = Invoke-PshBatch4Command -Name sleep -Arguments @('0')
    Assert-PshBatch4 ($sleepGolden.ExitCode -eq 0) 'sleep 0 failed before GNU golden comparison.'
    Compare-PshBatch4GoldenIfPresent -Id 'sleep_zero' -Actual $sleepGolden.Output

    $unsupportedCommands = @('which', 'env', 'printenv', 'export', 'sleep', 'date', 'whoami', 'hostname', 'clear', 'ps', 'kill', 'pgrep', 'pkill', 'timeout')
    foreach ($name in $unsupportedCommands) {
        $bad = Invoke-PshBatch4Command -Name $name -Arguments @('--definitely-unsupported')
        Assert-PshBatch4 ($bad.ExitCode -eq 2) ('{0} silently accepted unsupported syntax.' -f $name)
    }
    $badTest = Invoke-PshBatch4Command -Name test -Arguments @('alpha', '=', 'alpha', 'extra')
    Assert-PshBatch4 ($badTest.ExitCode -eq 2) 'test silently accepted an unsupported expression.'

    $taggedChildText = @'
param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$Marker,
    [Parameter(Mandatory = $true)][string]$PidPath,
    [Parameter(Mandatory = $true)][int]$DurationSeconds
)

$encoding = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($PidPath, [string]$PID, $encoding)
if ($Mode -ceq 'sleep') {
    Start-Sleep -Seconds $DurationSeconds
    exit 0
}
exit 2
'@
    $script:taggedChildScript = Join-Path $processRoot 'tagged-child.ps1'
    [IO.File]::WriteAllText($taggedChildScript, $taggedChildText, $utf8NoBom)
    $pshModule = Get-Module -Name Psh -ErrorAction Stop
    $protectedProcessIds = @(& $pshModule { @(Get-PshProtectedProcessIds) })
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        Assert-PshBatch4 ($protectedProcessIds -contains $currentProcess.Id) 'the current PowerShell process was not protected from kill.'
        $killProtected = Invoke-PshBatch4Command -Name kill -Arguments @([string]$currentProcess.Id)
        $expectedProtectedFailure = 'kill: runtime error: refusing to signal protected process {0}.' -f $currentProcess.Id
        Assert-PshBatch4 ($killProtected.ExitCode -eq 3 -and $killProtected.Output.Count -eq 1 -and $killProtected.Output[0] -ceq $expectedProtectedFailure -and (Test-PshBatch4ProcessAlive -Process $currentProcess)) 'kill did not reject the current protected PID as a runtime failure while leaving it alive.'
    }
    finally { $currentProcess.Dispose() }

    $psTag = 'PshBatch4Ps' + [Guid]::NewGuid().ToString('N')
    $psChild = Start-PshBatch4TaggedChild -Tag $psTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $psChild.Id) 'the ps fixture unexpectedly resolved to a protected PID.'
    $psSelected = Invoke-PshBatch4Command -Name ps -Arguments @('-aefl', '-p', ([string]$psChild.Id)) -CountsAsBehavior
    Assert-PshBatch4 ($psSelected.ExitCode -eq 0 -and $psSelected.Output.Count -eq 2 -and $psSelected.Output[0] -match '^\s*PID\s+NAME\s+PATH$' -and $psSelected.Output[1] -match ('^\s*{0}\s+' -f $psChild.Id)) 'ps -aefl -p did not return the uniquely tagged child structurally.'
    $psComma = Invoke-PshBatch4Command -Name ps -Arguments @(('-p={0}' -f $psChild.Id))
    Assert-PshBatch4 ($psComma.ExitCode -eq 0 -and $psComma.Output.Count -eq 1 -and $psComma.Output[0] -match ('^{0}\s+' -f $psChild.Id)) 'ps -p=PID did not select the tagged child.'
    $psMissing = Invoke-PshBatch4Command -Name ps -Arguments @('-p', '2147483000')
    Assert-PshBatch4 ($psMissing.ExitCode -eq 1 -and $psMissing.Output.Count -eq 0) 'ps -p did not exit 1 when every requested PID was absent.'

    $pgrepCaseTag = 'PshBatch4CaseABC' + [Guid]::NewGuid().ToString('N')
    $pgrepCaseChild = Start-PshBatch4TaggedChild -Tag $pgrepCaseTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $pgrepCaseChild.Id) 'the pgrep fixture unexpectedly resolved to a protected PID.'
    $currentUser = [Environment]::UserName
    $pgrepSelectors = Invoke-PshBatch4Command -Name pgrep -Arguments @('-filu', $currentUser, ([Regex]::Escape($pgrepCaseTag.ToLowerInvariant()))) -CountsAsBehavior
    Assert-PshBatch4 ($pgrepSelectors.ExitCode -eq 0 -and $pgrepSelectors.Output.Count -eq 1 -and $pgrepSelectors.Output[0] -match ('^{0}\s+\S+' -f $pgrepCaseChild.Id)) 'pgrep -f/-i/-l/-u did not select only the uniquely tagged child.'

    $orderTag = 'PshBatch4Order' + [Guid]::NewGuid().ToString('N')
    $oldestChild = Start-PshBatch4TaggedChild -Tag $orderTag
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 1100
    $newestChild = Start-PshBatch4TaggedChild -Tag $orderTag
    $pgrepOldest = Invoke-PshBatch4Command -Name pgrep -Arguments @('-f', '-o', ([Regex]::Escape($orderTag)))
    $pgrepNewest = Invoke-PshBatch4Command -Name pgrep -Arguments @('-f', '-n', ([Regex]::Escape($orderTag)))
    Assert-PshBatch4ExactProcessIds -Lines $pgrepOldest.Output -Expected @($oldestChild.Id) -Context 'pgrep -o'
    Assert-PshBatch4ExactProcessIds -Lines $pgrepNewest.Output -Expected @($newestChild.Id) -Context 'pgrep -n'
    $pgrepMissing = Invoke-PshBatch4Command -Name pgrep -Arguments @('-f', ('PshBatch4Missing' + [Guid]::NewGuid().ToString('N')))
    Assert-PshBatch4 ($pgrepMissing.ExitCode -eq 1 -and $pgrepMissing.Output.Count -eq 0) 'pgrep no-match behavior failed.'

    $unsupportedSignalTag = 'PshBatch4UnsupportedSignal' + [Guid]::NewGuid().ToString('N')
    $unsupportedSignalChild = Start-PshBatch4TaggedChild -Tag $unsupportedSignalTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $unsupportedSignalChild.Id) 'the unsupported-signal fixture unexpectedly resolved to a protected PID.'
    $killUnsupportedStop = Invoke-PshBatch4Command -Name kill -Arguments @('-s', 'STOP', ([string]$unsupportedSignalChild.Id)) -CountsAsBehavior
    $killUnsupportedCont = Invoke-PshBatch4Command -Name kill -Arguments @('--signal', 'CONT', ([string]$unsupportedSignalChild.Id))
    $killUnsupportedTstp = Invoke-PshBatch4Command -Name kill -Arguments @('-s', 'TSTP', ([string]$unsupportedSignalChild.Id))
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 150
    Assert-PshBatch4 ($killUnsupportedStop.ExitCode -eq 2 -and $killUnsupportedCont.ExitCode -eq 2 -and $killUnsupportedTstp.ExitCode -eq 2 -and (Test-PshBatch4ProcessAlive -Process $unsupportedSignalChild)) 'kill accepted STOP/CONT/TSTP or translated a nontermination signal into process termination.'
    $killHard = Invoke-PshBatch4Command -Name kill -Arguments @('-s', 'KILL', ([string]$unsupportedSignalChild.Id))
    Assert-PshBatch4 ($killHard.ExitCode -eq 0 -and (Wait-PshBatch4ProcessExit -Process $unsupportedSignalChild)) 'kill KILL did not terminate the tracked child.'

    $termTag = 'PshBatch4Term' + [Guid]::NewGuid().ToString('N')
    $termChild = Start-PshBatch4TaggedChild -Tag $termTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $termChild.Id) 'the TERM fixture unexpectedly resolved to a protected PID.'
    $killTerm = Invoke-PshBatch4Command -Name kill -Arguments @('--signal', 'TERM', ([string]$termChild.Id))
    Assert-PshBatch4 ($killTerm.ExitCode -eq 0 -and (Wait-PshBatch4ProcessExit -Process $termChild)) 'kill TERM did not terminate the tracked child.'
    $killListTerm = Invoke-PshBatch4Command -Name kill -Arguments @('-l=15')
    $killListKill = Invoke-PshBatch4Command -Name kill -Arguments @('-l', '9')
    Assert-PshBatch4 ($killListTerm.ExitCode -eq 0 -and $killListTerm.Output.Count -eq 1 -and $killListTerm.Output[0] -ceq 'TERM') 'kill -l=15 did not map signal 15 to TERM.'
    Assert-PshBatch4 ($killListKill.ExitCode -eq 0 -and $killListKill.Output.Count -eq 1 -and $killListKill.Output[0] -ceq 'KILL') 'kill -l 9 did not map a separated signal operand to KILL.'
    $killMissing = Invoke-PshBatch4Command -Name kill -Arguments @('2147483000')
    Assert-PshBatch4 ($killMissing.ExitCode -eq 1 -and $killMissing.Output.Count -eq 0) 'kill did not return NoMatch when every requested PID was absent.'
    $killPartialTag = 'PshBatch4KillPartial' + [Guid]::NewGuid().ToString('N')
    $killPartialChild = Start-PshBatch4TaggedChild -Tag $killPartialTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $killPartialChild.Id) 'the partial-kill fixture unexpectedly resolved to a protected PID.'
    $killPartial = Invoke-PshBatch4Command -Name kill -Arguments @('--signal', 'TERM', '2147483000', ([string]$killPartialChild.Id))
    Assert-PshBatch4 ($killPartial.ExitCode -eq 3 -and (Wait-PshBatch4ProcessExit -Process $killPartialChild)) 'kill silently reported success after only some requested PIDs were signaled.'

    $pkillTag = 'PshBatch4Pkill' + [Guid]::NewGuid().ToString('N')
    $pkillChild = Start-PshBatch4TaggedChild -Tag $pkillTag
    $unrelatedTag = 'PshBatch4Unrelated' + [Guid]::NewGuid().ToString('N')
    $unrelatedChild = Start-PshBatch4TaggedChild -Tag $unrelatedTag
    Assert-PshBatch4 ($protectedProcessIds -notcontains $pkillChild.Id -and $protectedProcessIds -notcontains $unrelatedChild.Id) 'the pkill fixtures unexpectedly resolved to protected PIDs.'
    $pkillPattern = [Regex]::Escape($pkillTag)
    $pkillPreflight = Invoke-PshBatch4Command -Name pgrep -Arguments @('-f', $pkillPattern)
    Assert-PshBatch4ExactProcessIds -Lines $pkillPreflight.Output -Expected @($pkillChild.Id) -Context 'pkill preflight'
    $pkillResult = Invoke-PshBatch4Command -Name pkill -Arguments @('-f', '--signal', 'TERM', $pkillPattern) -CountsAsBehavior
    Assert-PshBatch4 ($pkillResult.ExitCode -eq 0 -and (Wait-PshBatch4ProcessExit -Process $pkillChild)) 'pkill did not terminate its uniquely tagged child.'
    Assert-PshBatch4 (Test-PshBatch4ProcessAlive -Process $unrelatedChild) 'pkill terminated an unrelated tracked child.'

    $timeoutChildText = @'
param([string]$Mode)

$encoding = New-Object Text.UTF8Encoding($false)
if ($Mode -ceq 'capture') {
    foreach ($value in @($args)) {
        $bytes = $encoding.GetBytes([string]$value)
        Write-Output ("ARG`t" + [Convert]::ToBase64String($bytes))
    }
    exit 0
}
if ($Mode -ceq 'exit') {
    if ($args.Count -ne 1) { exit 2 }
    exit [int]$args[0]
}
if ($Mode -ceq 'sleep') {
    if ($args.Count -ne 2) { exit 2 }
    [IO.File]::WriteAllText([string]$args[0], [string]$PID, $encoding)
    Start-Sleep -Seconds ([int]$args[1])
    exit 0
}
if ($Mode -ceq 'inherit-output') {
    if ($args.Count -ne 5) { exit 2 }
    $readyPathBase64 = [Convert]::ToBase64String($encoding.GetBytes([string]$args[1]))
    $grandchildCommand = '$stdoutBytes=[Text.Encoding]::UTF8.GetBytes("GRANDCHILD-PIPE-READY`n");$stdout=[Console]::OpenStandardOutput();$stdout.Write($stdoutBytes,0,$stdoutBytes.Length);$stdout.Flush();$stderrBytes=[Text.Encoding]::UTF8.GetBytes("GRANDCHILD-PIPE-ERR-READY`n");$stderr=[Console]::OpenStandardError();$stderr.Write($stderrBytes,0,$stderrBytes.Length);$stderr.Flush();$readyPath=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("{0}"));[IO.File]::WriteAllText($readyPath,"ready");Start-Sleep -Seconds {1}' -f $readyPathBase64, ([int]$args[3])
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($grandchildCommand))
    $grandchild = $null
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void][Reflection.Assembly]::LoadFrom([string]$args[4])
        $executablePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $grandchildPid = [PshBatch4TimeoutNativeChildProcess]::Start($executablePath, $encodedCommand)
        $grandchild = [Diagnostics.Process]::GetProcessById($grandchildPid)
    }
    else {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $grandchild = New-Object Diagnostics.Process
        $grandchild.StartInfo = $startInfo
        if (-not $grandchild.Start()) { exit 3 }
        $grandchildPid = $grandchild.Id
    }
    [IO.File]::WriteAllText([string]$args[0], [string]$grandchildPid, $encoding)
    $readyWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists([string]$args[1]) -and $readyWatch.ElapsedMilliseconds -lt 10000) {
        if ($grandchild.HasExited) { exit 4 }
        Start-Sleep -Milliseconds 10
    }
    $readyWatch.Stop()
    if (-not [IO.File]::Exists([string]$args[1])) { exit 5 }
    $prefix = $encoding.GetBytes("PARENT-PIPE-READY`n")
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($prefix, 0, $prefix.Length)
    $stdout.Flush()
    $errorPrefix = $encoding.GetBytes("PARENT-PIPE-ERR-READY`n")
    $stderr = [Console]::OpenStandardError()
    $stderr.Write($errorPrefix, 0, $errorPrefix.Length)
    $stderr.Flush()
    Start-Sleep -Seconds ([int]$args[2])
    exit 0
}
exit 2
'@
    $timeoutChildScript = Join-Path $processRoot 'timeout-child.ps1'
    [IO.File]::WriteAllText($timeoutChildScript, $timeoutChildText, $utf8NoBom)
    $timeoutArguments = @('', 'a"b', 'trail\', 'space value', ([string][char]0x6c49 + [string][char]0x5b57))
    $timeoutCapture = Invoke-PshBatch4Command -Name timeout -Arguments (@('inf', $timeoutChildScript, 'capture') + $timeoutArguments) -CountsAsBehavior
    $capturedTimeoutArguments = @()
    foreach ($line in @((Get-PshBatch4RawText -Result $timeoutCapture) -split "`n" | Where-Object { $_ })) {
        Assert-PshBatch4 ($line.StartsWith("ARG`t", [StringComparison]::Ordinal)) ('timeout argv fixture emitted an unexpected row: {0}' -f $line)
        $capturedTimeoutArguments += $utf8NoBom.GetString([Convert]::FromBase64String($line.Substring(4)))
    }
    Assert-PshBatch4 ($timeoutCapture.ExitCode -eq 0 -and (Test-PshBatch4StringArray $capturedTimeoutArguments $timeoutArguments)) 'timeout did not preserve empty, quoted, trailing-backslash, spaced, or Unicode argv.'

    $timeoutPidPath = Join-Path $processRoot 'timeout-expiry.pid'
    $timeoutWatch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutExpired = Invoke-PshBatch4Command -Name timeout -Arguments @('-k', '100ms', '2s', $timeoutChildScript, 'sleep', $timeoutPidPath, '30')
    $timeoutWatch.Stop()
    Assert-PshBatch4 ($timeoutExpired.ExitCode -eq 3 -and $timeoutWatch.ElapsedMilliseconds -ge 1000 -and $timeoutWatch.ElapsedMilliseconds -lt 10000) ('timeout expiry returned the wrong status or duration: exit {0}, {1} ms.' -f $timeoutExpired.ExitCode, $timeoutWatch.ElapsedMilliseconds)
    Assert-PshBatch4 ([IO.File]::Exists($timeoutPidPath)) 'the timeout expiry fixture did not publish its PID before termination.'
    $timeoutPid = 0
    Assert-PshBatch4 ([int]::TryParse([IO.File]::ReadAllText($timeoutPidPath, $utf8NoBom).Trim(), [ref]$timeoutPid) -and $timeoutPid -gt 0) 'the timeout expiry fixture published an invalid PID.'
    $timeoutProcessStillAlive = $false
    $timeoutProcess = $null
    $timeoutProcessTracked = $false
    try {
        $timeoutProcess = [Diagnostics.Process]::GetProcessById($timeoutPid)
        $timeoutProcessStillAlive = -not $timeoutProcess.HasExited
        if ($timeoutProcessStillAlive) {
            [void]$trackedProcesses.Add($timeoutProcess)
            $timeoutProcessTracked = $true
        }
    }
    catch { $timeoutProcessStillAlive = $false }
    finally {
        if ($null -ne $timeoutProcess -and -not $timeoutProcessTracked) { $timeoutProcess.Dispose() }
    }
    Assert-PshBatch4 (-not $timeoutProcessStillAlive) 'timeout returned while its expired child was still running.'

    $timeoutPipeMarkers = @('PARENT-PIPE-READY', 'GRANDCHILD-PIPE-READY', 'PARENT-PIPE-ERR-READY', 'GRANDCHILD-PIPE-ERR-READY')
    $timeoutDescendantPidPath = Join-Path $processRoot 'timeout-descendant.pid'
    $timeoutDescendantReadyPath = Join-Path $processRoot 'timeout-descendant.ready'
    $timeoutDescendantWatch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutDescendantResult = Invoke-PshBatch4Command -Name timeout -Arguments @('-k', '100ms', '3s', $timeoutChildScript, 'inherit-output', $timeoutDescendantPidPath, $timeoutDescendantReadyPath, '15', '15', $timeoutNativeHelperAssemblyPath)
    $timeoutDescendantWatch.Stop()
    $timeoutDescendantText = Get-PshBatch4RawText -Result $timeoutDescendantResult
    $timeoutDescendantCapturedText = $timeoutDescendantText.Replace("`n", '\n')
    $timeoutDescendantMissingMarkers = @($timeoutPipeMarkers | Where-Object { -not $timeoutDescendantText.Contains([string]$_) })
    Assert-PshBatch4 ($timeoutDescendantResult.ExitCode -eq 3 -and $timeoutDescendantWatch.ElapsedMilliseconds -lt 5000) ('timeout waited for a descendant-held output pipe: exit {0}, {1} ms.' -f $timeoutDescendantResult.ExitCode, $timeoutDescendantWatch.ElapsedMilliseconds)
    Assert-PshBatch4 ([IO.File]::Exists($timeoutDescendantReadyPath)) ('the descendant-pipe fixture did not confirm that grandchild output was flushed. Captured text: <{0}>.' -f $timeoutDescendantCapturedText)
    Assert-PshBatch4 ($timeoutDescendantMissingMarkers.Count -eq 0) ('timeout lost stdout or stderr produced before closing descendant-held pipes. Missing markers: <{0}>. Captured text: <{1}>.' -f ($timeoutDescendantMissingMarkers -join ', '), $timeoutDescendantCapturedText)
    Assert-PshBatch4 ([IO.File]::Exists($timeoutDescendantPidPath)) 'the descendant-pipe fixture did not publish its grandchild PID.'
    $timeoutDescendantPid = 0
    Assert-PshBatch4 ([int]::TryParse([IO.File]::ReadAllText($timeoutDescendantPidPath, $utf8NoBom).Trim(), [ref]$timeoutDescendantPid) -and $timeoutDescendantPid -gt 0) 'the descendant-pipe fixture published an invalid grandchild PID.'
    $timeoutDescendantProcess = $null
    try {
        $timeoutDescendantProcess = [Diagnostics.Process]::GetProcessById($timeoutDescendantPid)
        Assert-PshBatch4 (Test-PshBatch4ProcessAlive -Process $timeoutDescendantProcess) 'timeout waited for the pipe-holding grandchild to exit.'
        [void]$trackedProcesses.Add($timeoutDescendantProcess)
        $timeoutDescendantProcess = $null
    }
    finally {
        if ($null -ne $timeoutDescendantProcess) { $timeoutDescendantProcess.Dispose() }
    }

    $timeoutInfiniteDescendantPidPath = Join-Path $processRoot 'timeout-infinite-descendant.pid'
    $timeoutInfiniteDescendantReadyPath = Join-Path $processRoot 'timeout-infinite-descendant.ready'
    $timeoutInfiniteDescendantWatch = [Diagnostics.Stopwatch]::StartNew()
    $timeoutInfiniteDescendantResult = Invoke-PshBatch4Command -Name timeout -Arguments @('inf', $timeoutChildScript, 'inherit-output', $timeoutInfiniteDescendantPidPath, $timeoutInfiniteDescendantReadyPath, '1', '15', $timeoutNativeHelperAssemblyPath)
    $timeoutInfiniteDescendantWatch.Stop()
    $timeoutInfiniteDescendantText = Get-PshBatch4RawText -Result $timeoutInfiniteDescendantResult
    $timeoutInfiniteDescendantCapturedText = $timeoutInfiniteDescendantText.Replace("`n", '\n')
    $timeoutInfiniteDescendantMissingMarkers = @($timeoutPipeMarkers | Where-Object { -not $timeoutInfiniteDescendantText.Contains([string]$_) })
    Assert-PshBatch4 ($timeoutInfiniteDescendantResult.ExitCode -eq 0 -and $timeoutInfiniteDescendantWatch.ElapsedMilliseconds -lt 5000) ('timeout inf waited for a descendant-held output pipe: exit {0}, {1} ms.' -f $timeoutInfiniteDescendantResult.ExitCode, $timeoutInfiniteDescendantWatch.ElapsedMilliseconds)
    Assert-PshBatch4 ([IO.File]::Exists($timeoutInfiniteDescendantReadyPath)) ('the timeout inf descendant-pipe fixture did not confirm that grandchild output was flushed. Captured text: <{0}>.' -f $timeoutInfiniteDescendantCapturedText)
    Assert-PshBatch4 ($timeoutInfiniteDescendantMissingMarkers.Count -eq 0) ('timeout inf lost stdout or stderr produced before closing descendant-held pipes. Missing markers: <{0}>. Captured text: <{1}>.' -f ($timeoutInfiniteDescendantMissingMarkers -join ', '), $timeoutInfiniteDescendantCapturedText)
    Assert-PshBatch4 ([IO.File]::Exists($timeoutInfiniteDescendantPidPath)) 'the timeout inf descendant-pipe fixture did not publish its grandchild PID.'
    $timeoutInfiniteDescendantPid = 0
    Assert-PshBatch4 ([int]::TryParse([IO.File]::ReadAllText($timeoutInfiniteDescendantPidPath, $utf8NoBom).Trim(), [ref]$timeoutInfiniteDescendantPid) -and $timeoutInfiniteDescendantPid -gt 0) 'the timeout inf descendant-pipe fixture published an invalid grandchild PID.'
    $timeoutInfiniteDescendantProcess = $null
    try {
        $timeoutInfiniteDescendantProcess = [Diagnostics.Process]::GetProcessById($timeoutInfiniteDescendantPid)
        Assert-PshBatch4 (Test-PshBatch4ProcessAlive -Process $timeoutInfiniteDescendantProcess) 'timeout inf waited for the pipe-holding grandchild to exit.'
        [void]$trackedProcesses.Add($timeoutInfiniteDescendantProcess)
        $timeoutInfiniteDescendantProcess = $null
    }
    finally {
        if ($null -ne $timeoutInfiniteDescendantProcess) { $timeoutInfiniteDescendantProcess.Dispose() }
    }

    $timeoutNormalized = Invoke-PshBatch4Command -Name timeout -Arguments @('inf', $timeoutChildScript, 'exit', '5')
    $timeoutPreserved = Invoke-PshBatch4Command -Name timeout -Arguments @('--preserve-status', 'inf', $timeoutChildScript, 'exit', '5')
    Assert-PshBatch4 ($timeoutNormalized.ExitCode -eq 3 -and $timeoutPreserved.ExitCode -eq 5) 'timeout --preserve-status did not preserve a documented child exit while default mode normalized it.'
    $timeoutMissing = Invoke-PshBatch4Command -Name timeout -Arguments @('1s', ('psh-batch4-missing-executable-' + [Guid]::NewGuid().ToString('N')))
    Assert-PshBatch4 ($timeoutMissing.ExitCode -eq 4) 'timeout missing command did not exit 4.'

    Stop-PshBatch4TrackedProcesses

    foreach ($name in $commandNames) {
        Assert-PshBatch4 ($covered.ContainsKey($name)) ('no behavior row executed for {0}.' -f $name)
    }

    Remove-Module -Name Psh -Force -ErrorAction Stop
    foreach ($name in $aliasNames) {
        Assert-PshBatch4 (Test-PshBatch4AliasSnapshot -Alias (Get-Alias -Name $name -ErrorAction SilentlyContinue) -Snapshot $aliasBaseline[$name]) ('Remove-Module did not restore {0} exactly after Core.' -f $name)
    }

    $env:PSH_EDITION = 'Full'
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $fullCapabilities = Get-PshCapabilities
    foreach ($name in $commandNames) {
        $exported = Get-Command -Name ('Psh\{0}' -f $name) -CommandType Function -ErrorAction Stop
        Assert-PshBatch4 ($exported.Source -ceq 'Psh') ('Full did not export {0}.' -f $name)
        $capability = @($fullCapabilities.commands | Where-Object { [string]$_.name -ceq $name })[0]
        Assert-PshBatch4 ($null -ne $capability -and [string]$capability.activeBackend -ceq 'powershell') ('Full reports the wrong active backend for {0}.' -f $name)
        $fullHelp = Invoke-PshBatch4Command -Name $name -Arguments @('--help')
        Assert-PshBatch4 ($fullHelp.ExitCode -eq 0 -and $fullHelp.Output.Count -ge 1 -and $fullHelp.Output[0] -match '^Usage:') ('Full {0} --help failed.' -f $name)
    }
    $fullPrintenv = Invoke-PshBatch4Command -Name printenv -Arguments @($envRestore)
    Assert-PshBatch4 ($fullPrintenv.ExitCode -eq 0 -and $fullPrintenv.Output.Count -eq 1 -and $fullPrintenv.Output[0] -ceq 'original value') 'Full changed the shared PowerShell system-command behavior.'
    Remove-Module -Name Psh -Force -ErrorAction Stop
    foreach ($name in $aliasNames) {
        Assert-PshBatch4 (Test-PshBatch4AliasSnapshot -Alias (Get-Alias -Name $name -ErrorAction SilentlyContinue) -Snapshot $aliasBaseline[$name]) ('Remove-Module did not restore {0} exactly after Full.' -f $name)
    }

    Write-Output ('Goal 3 Batch 4 system/process acceptance passed: 15 commands, {0} assertions, Core/Full exports and capabilities, exact NUL output, environment restoration, and uniquely scoped process control{1}.' -f $assertionCount, $(if ($goldenComparisonCount -eq 0) { '' } else { ', with {0} GNU golden comparisons' -f $goldenComparisonCount }))
    $global:LASTEXITCODE = 0
}
finally {
    Stop-PshBatch4TrackedProcesses
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    Set-Location -LiteralPath $originalLocation -ErrorAction SilentlyContinue
    foreach ($name in @($environmentNames)) {
        [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:PSH_EDITION = $originalEdition
    foreach ($name in $aliasNames) {
        $snapshot = $aliasBaseline[$name]
        if ($null -eq $snapshot) { continue }
        $current = Get-Alias -Name $name -ErrorAction SilentlyContinue
        if (-not $snapshot.Exists) {
            if ($null -ne $current) { Remove-Item -LiteralPath ('Alias:{0}' -f $name) -Force -ErrorAction SilentlyContinue }
        }
        elseif (-not (Test-PshBatch4AliasSnapshot -Alias $current -Snapshot $snapshot)) {
            Remove-Item -LiteralPath ('Alias:{0}' -f $name) -Force -ErrorAction SilentlyContinue
            Set-Alias -Name $name -Value ([string]$snapshot.Definition) -Description ([string]$snapshot.Description) -Option $snapshot.Options -Scope Global -Force
            (Get-Alias -Name $name -Scope Global -ErrorAction Stop).Visibility = $snapshot.Visibility
        }
    }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

# GitHub's PowerShell shell propagates a leftover native status after a successful script.
$global:LASTEXITCODE = 0
