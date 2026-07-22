# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', 'Process')
$reportRoot = [Environment]::GetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', 'Process')
if ([string]::IsNullOrWhiteSpace($repositoryRoot)) { throw 'PSH_GOAL6_REPOSITORY_ROOT is required.' }
if ([string]::IsNullOrWhiteSpace($reportRoot)) { throw 'PSH_GOAL6_REPORT_ROOT is required.' }
$repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)
$reportRoot = [IO.Path]::GetFullPath($reportRoot)

$goal6InstallerCases = @(
    @{ Name = 'true non-admin child with Unicode and space user path'; Scenario = 'non-admin' }
    @{ Name = 'current-user install in a Unicode and space path'; Scenario = 'unicode-space' }
    @{ Name = 'wrong architecture package'; Scenario = 'wrong-architecture' }
    @{ Name = 'Core package without native tools'; Scenario = 'core-without-tools' }
    @{ Name = 'Full package missing a pinned native tool'; Scenario = 'full-missing-tool' }
    @{ Name = 'profile marker conflict'; Scenario = 'profile-conflict' }
    @{ Name = 'corrupted downloaded package bytes'; Scenario = 'corrupted-download' }
)

Describe 'Goal 6 installer edge matrix' {
    BeforeAll {
        $script:Goal6RepositoryRoot = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_REPOSITORY_ROOT', 'Process'))
        $script:Goal6ReportRoot = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('PSH_GOAL6_REPORT_ROOT', 'Process'))
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'Goal 6 installer edge tests require Windows; coverage cannot be skipped.'
        }
        $processArchitecture = [string]$env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($processArchitecture)) { $processArchitecture = [string]$env:PROCESSOR_ARCHITECTURE }
        if ($processArchitecture -cne 'AMD64') {
            throw "Goal 6 installer edge tests require the supported Windows x64 matrix; found '$processArchitecture'."
        }

        $script:Goal6Utf8 = New-Object Text.UTF8Encoding($false, $true)
        $script:Goal6InstallScript = Join-Path $script:Goal6RepositoryRoot 'src/install/Install-PshPackage.ps1'
        $script:Goal6LifecycleScript = Join-Path $script:Goal6RepositoryRoot 'src/install/PackageLifecycle.ps1'
        $script:Goal6EnginePath = [string](Get-Process -Id $PID -ErrorAction Stop).Path
        $script:Goal6NonAdminTimeoutMilliseconds = 300000
        foreach ($requiredPath in @($script:Goal6InstallScript, $script:Goal6LifecycleScript, $script:Goal6EnginePath)) {
            if (-not [IO.File]::Exists($requiredPath)) { throw "Required Goal 6 installer input is missing: $requiredPath" }
        }
        . $script:Goal6LifecycleScript

        function Write-PshGoal6Text {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text
            )

            $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            [IO.File]::WriteAllText($Path, $Text, $script:Goal6Utf8)
        }

        function Get-PshGoal6FileSha256 {
            param([Parameter(Mandatory = $true)][string] $Path)

            return [string](Get-PshLifecycleFileSha256 -Path $Path).Sha256
        }

        function Get-PshGoal6RelativePath {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [Parameter(Mandatory = $true)][string] $Path
            )

            $rootUri = New-Object Uri(([IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar))
            $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
            return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('\', '/')
        }

        function Get-PshGoal6UnicodeSpaceSegment {
            $prefix = -join ([char[]]@(0x7528, 0x6237))
            return $prefix + ' space'
        }

        function Build-PshGoal6InstallerPackage {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [ValidateSet('Core', 'Full')][string] $Edition = 'Core',
                [ValidateSet('any', 'win-x64', 'win-arm64')][string] $Architecture
            )

            [void][IO.Directory]::CreateDirectory($Root)
            Write-PshGoal6Text -Path (Join-Path $Root 'install-offline.ps1') -Text "# synthetic offline entrypoint`n"
            Write-PshGoal6Text -Path (Join-Path $Root 'uninstall.ps1') -Text "# synthetic uninstall entrypoint`n"
            Write-PshGoal6Text -Path (Join-Path $Root 'install.sh') -Text "#!/bin/sh`n# synthetic shell entrypoint`n"
            [IO.File]::WriteAllBytes((Join-Path $Root 'psh-installer.exe'), [Text.Encoding]::ASCII.GetBytes("MZ synthetic AnyCPU bootstrapper`n"))

            $payloadRoot = Join-Path $Root 'payload'
            [void][IO.Directory]::CreateDirectory($payloadRoot)
            Copy-Item -LiteralPath (Join-Path $script:Goal6RepositoryRoot 'src/Psh') -Destination $payloadRoot -Recurse -Force
            $moduleRoot = Join-Path $payloadRoot 'Psh'
            $moduleToolsRoot = Join-Path $moduleRoot 'Tools'
            if ([IO.Directory]::Exists($moduleToolsRoot)) { Remove-Item -LiteralPath $moduleToolsRoot -Recurse -Force }

            $payloadInstall = Join-Path $payloadRoot 'install'
            [void][IO.Directory]::CreateDirectory($payloadInstall)
            foreach ($name in @('bootstrap.ps1', 'config.psd1', 'Set-PshCurrentVersion.ps1')) {
                Copy-Item -LiteralPath (Join-Path $script:Goal6RepositoryRoot ('src/install/' + $name)) -Destination (Join-Path $payloadInstall $name)
            }
            if ($Edition -ceq 'Full') {
                $configPath = Join-Path $payloadInstall 'config.psd1'
                $configText = [IO.File]::ReadAllText($configPath, $script:Goal6Utf8)
                if ([regex]::Matches($configText, "'Core'").Count -ne 1) { throw 'Config fixture does not contain exactly one Core edition value.' }
                Write-PshGoal6Text -Path $configPath -Text $configText.Replace("'Core'", "'Full'")
            }

            $payloadProfile = Join-Path $payloadRoot 'profile'
            [void][IO.Directory]::CreateDirectory($payloadProfile)
            foreach ($name in @('ProfileBlock.ps1', 'Install-PshProfile.ps1', 'Uninstall-PshProfile.ps1')) {
                Copy-Item -LiteralPath (Join-Path $script:Goal6RepositoryRoot ('src/profile/' + $name)) -Destination (Join-Path $payloadProfile $name)
            }

            $effectiveArchitecture = if ([string]::IsNullOrWhiteSpace($Architecture)) {
                if ($Edition -ceq 'Core') { 'any' } else { 'win-x64' }
            }
            else { $Architecture }
            $nativeLockSha256 = $null
            if ($Edition -ceq 'Full') {
                [void][IO.Directory]::CreateDirectory($moduleToolsRoot)
                $nativeLockPath = Join-Path $moduleToolsRoot 'native-tools.lock.json'
                Copy-Item -LiteralPath (Join-Path $script:Goal6RepositoryRoot 'tools/native-tools.lock.json') -Destination $nativeLockPath
                foreach ($toolName in @('bat', 'fd', 'jq', 'rg')) {
                    $relative = "$effectiveArchitecture/$toolName/$toolName.exe"
                    $destination = Join-Path $moduleToolsRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                    Copy-Item -LiteralPath (Join-Path (Join-Path $script:Goal6RepositoryRoot 'tools') $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Destination $destination
                }
                $nativeLockSha256 = Get-PshGoal6FileSha256 -Path $nativeLockPath
            }

            $files = New-Object System.Collections.Generic.List[object]
            foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
                if ($file.Name -ceq 'package.manifest.json' -and [string]::Equals($file.DirectoryName, [IO.Path]::GetFullPath($Root), [StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = Get-PshGoal6RelativePath -Root $Root -Path $file.FullName
                $role = if ($relative -ceq 'psh-installer.exe') { 'bootstrapper' } elseif ($relative -in @('install-offline.ps1', 'uninstall.ps1', 'install.sh')) { 'entrypoint' } else { 'payload' }
                [void]$files.Add([pscustomobject][ordered]@{
                        relativePath = $relative
                        length = [int64]$file.Length
                        sha256 = Get-PshGoal6FileSha256 -Path $file.FullName
                        role = $role
                    })
            }
            $manifest = [pscustomobject][ordered]@{
                schemaVersion = 1
                product = 'Psh'
                version = '0.1.0'
                edition = $Edition
                architecture = $effectiveArchitecture
                payloadRoot = 'payload'
                files = $files.ToArray()
                treeSha256 = Get-PshPackageTreeDigest -Manifest ([pscustomobject]@{ files = $files.ToArray() })
                entrypoints = [pscustomobject][ordered]@{
                    offlinePowerShell = 'install-offline.ps1'
                    uninstallPowerShell = 'uninstall.ps1'
                    shell = 'install.sh'
                    bootstrapper = 'psh-installer.exe'
                }
                testOnly = $true
                source = [pscustomobject][ordered]@{
                    repository = 'https://github.com/Emvdy/psh'
                    commit = ('1' * 40)
                }
                bootstrapper = [pscustomobject][ordered]@{
                    relativePath = 'psh-installer.exe'
                    sha256 = Get-PshGoal6FileSha256 -Path (Join-Path $Root 'psh-installer.exe')
                    anyCpu = $true
                }
                nativeToolsLockSha256 = $nativeLockSha256
            }
            Write-PshGoal6Text -Path (Join-Path $Root 'package.manifest.json') -Text (($manifest | ConvertTo-Json -Depth 20) + "`n")
            return $Root
        }

        function Invoke-PshGoal6PackageInstall {
            param(
                [Parameter(Mandatory = $true)][string] $PackageRoot,
                [Parameter(Mandatory = $true)][string] $InstallRoot,
                [ValidateSet('Core', 'Full')][string] $Edition,
                [AllowNull()][string[]] $ProfilePath = @(),
                [AllowNull()][string[]] $ModuleRoot = @()
            )

            try {
                $output = @(& $script:Goal6InstallScript -PackageRoot $PackageRoot -InstallRoot $InstallRoot -Edition $Edition -Version '0.1.0' -ProfilePath $ProfilePath -ModuleRoot $ModuleRoot -Confirm:$false)
                return [pscustomobject][ordered]@{ Succeeded = $true; Result = @($output)[-1]; Error = $null; Metadata = $null }
            }
            catch {
                return [pscustomobject][ordered]@{ Succeeded = $false; Result = $null; Error = $_; Metadata = Get-PshLifecycleErrorMetadata -ErrorRecord $_ }
            }
        }

        function Assert-PshGoal6CoreCapabilitySet {
            param(
                [Parameter(Mandatory = $true)][string] $InstallRoot,
                [Parameter(Mandatory = $true)][string] $LocalAppData
            )

            $oldLocalAppData = $env:LOCALAPPDATA
            $oldEdition = $env:PSH_EDITION
            try {
                $env:LOCALAPPDATA = $LocalAppData
                $env:PSH_EDITION = 'Core'
                $manifestPath = Join-Path $InstallRoot 'versions/0.1.0/Psh/Psh.psd1'
                Import-Module -Name $manifestPath -Force -ErrorAction Stop
                $capabilities = Get-PshCapabilities
                if (@($capabilities.commands).Count -ne 64) { throw 'Installed Core did not report all 64 commands.' }
            }
            finally {
                Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
                if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
                if ($null -eq $oldEdition) { Remove-Item Env:PSH_EDITION -ErrorAction SilentlyContinue } else { $env:PSH_EDITION = $oldEdition }
            }
        }

        function Assert-PshGoal6InstallFailure {
            param(
                [Parameter(Mandatory = $true)][object] $Result,
                [Parameter(Mandatory = $true)][string] $Label,
                [Parameter(Mandatory = $true)][int] $ExpectedExitCode,
                [Parameter(Mandatory = $true)][string] $ExpectedErrorId,
                [Parameter(Mandatory = $true)][string] $ExpectedMessagePattern
            )

            if ([bool]$Result.Succeeded) { throw "$Label unexpectedly installed successfully." }
            if ($null -eq $Result.Metadata) { throw "$Label returned no structured failure metadata." }
            if ([int]$Result.Metadata.ExitCode -ne $ExpectedExitCode) {
                throw ("$Label used exit code $($Result.Metadata.ExitCode), expected $ExpectedExitCode: $($Result.Metadata.Message)")
            }
            if ([string]$Result.Metadata.ErrorId -cne $ExpectedErrorId) {
                throw ("$Label used error id '$($Result.Metadata.ErrorId)', expected '$ExpectedErrorId': $($Result.Metadata.Message)")
            }
            if ([string]$Result.Metadata.Message -cnotmatch $ExpectedMessagePattern) {
                throw ("$Label returned an unexpected diagnostic: $($Result.Metadata.Message)")
            }
        }

        function Invoke-PshGoal6ChildProcessTreeTermination {
            param([Parameter(Mandatory = $true)][Diagnostics.Process] $Process)

            $taskKillPath = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { $null } else { Join-Path $env:SystemRoot 'System32/taskkill.exe' }
            if (-not [string]::IsNullOrWhiteSpace($taskKillPath) -and [IO.File]::Exists($taskKillPath)) {
                $oldPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $taskKillPath /PID ([string]$Process.Id) /T /F 2>&1 | Microsoft.PowerShell.Core\Out-Null
                }
                catch { [void]$_.Exception.Message }
                finally {
                    $ErrorActionPreference = $oldPreference
                    $global:LASTEXITCODE = 0
                }
            }
            try {
                if (-not $Process.HasExited) { $Process.Kill() }
            }
            catch { [void]$_.Exception.Message }
            if (-not $Process.WaitForExit(5000)) {
                throw "Timed-out non-admin child process $($Process.Id) could not be terminated."
            }
        }

        function Grant-PshGoal6FixtureAccess {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][Security.Principal.SecurityIdentifier] $Sid
            )

            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $rule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                $Sid,
                [Security.AccessControl.FileSystemRights]::Modify,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        }

        function Invoke-PshGoal6TemporaryUserProfileCleanup {
            param([Parameter(Mandatory = $true)][string] $Sid)

            $removalRequested = $false
            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                $userProfile = @(Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='{0}'" -f $Sid) -ErrorAction Stop | Select-Object -First 1)
                if ($userProfile.Count -eq 0) { return }
                if (-not [bool]$userProfile[0].Loaded -and -not $removalRequested) {
                    $userProfile[0] | Remove-CimInstance -ErrorAction Stop
                    $removalRequested = $true
                }
                Start-Sleep -Milliseconds 250
            }
            throw "Temporary standard-user profile remained present after cleanup: $Sid"
        }

        function Invoke-PshGoal6NonAdminChild {
            param([Parameter(Mandatory = $true)][string] $PackageRoot)

            foreach ($commandName in @('New-LocalUser', 'Get-LocalUser', 'Remove-LocalUser', 'Get-CimInstance', 'Remove-CimInstance')) {
                if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                    throw "Required non-admin test capability is unavailable: $commandName"
                }
            }
            $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'The Goal 6 CI account must be an administrator only to create and remove the temporary standard user.'
            }

            $machineTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Machine')
            if ([string]::IsNullOrWhiteSpace($machineTemp) -or -not [IO.Directory]::Exists($machineTemp)) {
                throw 'The machine temporary directory is unavailable for the non-admin fixture.'
            }
            $testRoot = Join-Path $machineTemp ('psh-goal6-non-admin-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($testRoot)
            $childPackageRoot = Join-Path $testRoot 'package'
            Copy-Item -LiteralPath $PackageRoot -Destination $childPackageRoot -Recurse -Force
            $userName = 'pshg6' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
            [char[]] $passwordCharacters = [char[]]('aA1!' + [Guid]::NewGuid().ToString('N') + 'zZ9!')
            $securePassword = New-Object Security.SecureString
            foreach ($passwordCharacter in $passwordCharacters) { $securePassword.AppendChar($passwordCharacter) }
            $securePassword.MakeReadOnly()
            [Array]::Clear($passwordCharacters, 0, $passwordCharacters.Length)
            $user = $null
            $sidValue = $null
            $credential = $null
            $cleanupErrors = New-Object System.Collections.Generic.List[string]
            try {
                $user = New-LocalUser -Name $userName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Temporary Psh Goal 6 standard-user fixture' -ErrorAction Stop
                $sidValue = [string]$user.SID.Value
                Grant-PshGoal6FixtureAccess -Path $testRoot -Sid $user.SID
                $credential = New-Object System.Management.Automation.PSCredential(($env:COMPUTERNAME + '\' + $userName), $securePassword)

                $unicodeRoot = Join-Path $testRoot (Get-PshGoal6UnicodeSpaceSegment)
                $localAppData = Join-Path $unicodeRoot 'local app data'
                $profilePath = Join-Path $unicodeRoot 'profile path/profile.ps1'
                $resultPath = Join-Path $testRoot 'child-result.json'
                $configPath = Join-Path $testRoot 'child-config.json'
                $childPath = Join-Path $testRoot 'Invoke-NonAdminInstall.ps1'
                $stdoutPath = Join-Path $testRoot 'child-stdout.log'
                $stderrPath = Join-Path $testRoot 'child-stderr.log'
                $config = [pscustomobject][ordered]@{
                    InstallScript = $script:Goal6InstallScript
                    PackageRoot = $childPackageRoot
                    LocalAppData = $localAppData
                    ProfilePath = $profilePath
                    ResultPath = $resultPath
                }
                Write-PshGoal6Text -Path $configPath -Text (($config | ConvertTo-Json -Depth 5) + "`n")
                $childScript = @'
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ConfigPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$config = [IO.File]::ReadAllText($ConfigPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
$oldLocalAppData = $env:LOCALAPPDATA
$oldEdition = $env:PSH_EDITION
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $env:LOCALAPPDATA = [string]$config.LocalAppData
    $env:PSH_EDITION = 'Core'
    [void][IO.Directory]::CreateDirectory([string]$config.LocalAppData)
    $installOutput = @(& ([string]$config.InstallScript) -PackageRoot ([string]$config.PackageRoot) -Edition Core -Version '0.1.0' -ProfilePath @([string]$config.ProfilePath) -ModuleRoot @() -Confirm:$false)
    $installResult = @($installOutput)[-1]
    $installRoot = Join-Path ([string]$config.LocalAppData) 'Psh'
    Import-Module -Name (Join-Path $installRoot 'versions/0.1.0/Psh/Psh.psd1') -Force -ErrorAction Stop
    $capabilities = Get-PshCapabilities
    $profileText = [IO.File]::ReadAllText([string]$config.ProfilePath, $utf8)
    $result = [pscustomobject][ordered]@{
        success = [bool]$installResult.success
        code = [int]$installResult.code
        userName = [string]$identity.Name
        userSid = [string]$identity.User.Value
        isAdministrator = [bool]$isAdministrator
        localAppData = [string]$env:LOCALAPPDATA
        installRoot = [string]$installRoot
        commandCount = @($capabilities.commands).Count
        profileHasMarker = $profileText.Contains('# >>> Psh managed profile >>>')
    }
    [IO.File]::WriteAllText([string]$config.ResultPath, (($result | ConvertTo-Json -Depth 6) + "`n"), $utf8)
    exit 0
}
catch {
    $exception = $_.Exception
    while ($null -ne $exception -and -not $exception.Data.Contains('PshExitCode') -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $failure = [pscustomobject][ordered]@{
        success = $false
        code = if ($null -ne $exception -and $exception.Data.Contains('PshExitCode')) { [int]$exception.Data['PshExitCode'] } else { 1 }
        errorId = if ($null -ne $exception -and $exception.Data.Contains('PshErrorId')) { [string]$exception.Data['PshErrorId'] } else { [string]$_.FullyQualifiedErrorId }
        message = [string]$_.Exception.Message
    }
    try { [IO.File]::WriteAllText([string]$config.ResultPath, (($failure | ConvertTo-Json -Depth 6) + "`n"), $utf8) }
    catch { [Console]::Error.WriteLine(('Unable to persist the non-admin child failure result: {0}' -f $_.Exception.Message)) }
    exit 1
}
finally {
    Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
    if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
    if ($null -eq $oldEdition) { Remove-Item Env:PSH_EDITION -ErrorAction SilentlyContinue } else { $env:PSH_EDITION = $oldEdition }
}
'@
                Write-PshGoal6Text -Path $childPath -Text $childScript
                Grant-PshGoal6FixtureAccess -Path $testRoot -Sid $user.SID
                $argumentList = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigPath "{1}"' -f $childPath, $configPath
                $process = $null
                $processExitCode = $null
                $timedOut = $false
                try {
                    $process = Start-Process -FilePath $script:Goal6EnginePath -Credential $credential -LoadUserProfile -WorkingDirectory $testRoot -ArgumentList $argumentList -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -ErrorAction Stop
                    if (-not $process.WaitForExit($script:Goal6NonAdminTimeoutMilliseconds)) {
                        $timedOut = $true
                        Invoke-PshGoal6ChildProcessTreeTermination -Process $process
                    }
                    [void]$process.WaitForExit()
                    $processExitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
                }
                finally {
                    if ($null -ne $process) { $process.Dispose() }
                }

                $retainedRoot = Join-Path $script:Goal6ReportRoot 'installer-edges/non-admin'
                [void][IO.Directory]::CreateDirectory($retainedRoot)
                foreach ($retained in @($stdoutPath, $stderrPath, $resultPath)) {
                    if ([IO.File]::Exists($retained)) { Copy-Item -LiteralPath $retained -Destination (Join-Path $retainedRoot ([IO.Path]::GetFileName($retained))) -Force }
                }
                if (-not [IO.File]::Exists($resultPath)) {
                    $reason = if ($timedOut) { 'timed out' } else { 'did not write its result' }
                    throw "Non-admin child $reason; exit=$processExitCode; reports: $retainedRoot"
                }
                $result = [IO.File]::ReadAllText($resultPath, $script:Goal6Utf8) | ConvertFrom-Json -ErrorAction Stop
                if ($timedOut -or $processExitCode -ne 0 -or -not [bool]$result.success) {
                    throw ("Non-admin child failed; timeout=$timedOut; exit=$processExitCode; code=$($result.code); message=$($result.message); reports: $retainedRoot")
                }
                if ([bool]$result.isAdministrator) { throw 'The temporary standard-user child unexpectedly had administrator membership.' }
                if ([string]$result.userSid -cne $sidValue) { throw 'The non-admin child ran under the wrong SID.' }
                if ([string]$result.localAppData -cne $localAppData -or [string]$result.installRoot -cne (Join-Path $localAppData 'Psh')) { throw 'The non-admin child did not use the Unicode and space current-user path.' }
                if ([int]$result.commandCount -ne 64 -or -not [bool]$result.profileHasMarker) { throw 'The non-admin child did not complete the Core install and profile projection.' }
            }
            finally {
                $credential = $null
                if ($null -ne $securePassword) { $securePassword.Dispose() }
                $securePassword = $null
                if (-not [string]::IsNullOrWhiteSpace($sidValue)) {
                    try { Invoke-PshGoal6TemporaryUserProfileCleanup -Sid $sidValue } catch { [void]$cleanupErrors.Add([string]$_) }
                }
                if ($null -ne $user) {
                    try { Remove-LocalUser -Name $userName -ErrorAction Stop } catch { [void]$cleanupErrors.Add([string]$_) }
                }
                try {
                    if ($null -ne (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue)) { [void]$cleanupErrors.Add("Temporary local user still exists: $userName") }
                }
                catch { [void]$cleanupErrors.Add([string]$_) }
                if ([IO.Directory]::Exists($testRoot)) {
                    try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop } catch { [void]$cleanupErrors.Add([string]$_) }
                }
                if ([IO.Directory]::Exists($testRoot) -or [IO.File]::Exists($testRoot)) { [void]$cleanupErrors.Add("Non-admin fixture root still exists: $testRoot") }
                if ($cleanupErrors.Count -ne 0) { throw ('Non-admin fixture cleanup failed: ' + ($cleanupErrors.ToArray() -join '; ')) }
            }
        }

        function Invoke-PshGoal6InstallerScenario {
            param([Parameter(Mandatory = $true)][string] $Scenario)

            $caseRoot = Join-Path ([IO.Path]::GetTempPath()) ('psh-goal6-installer-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($caseRoot)
            try {
                $packageRoot = Join-Path $caseRoot 'package'
                if ($Scenario -ceq 'non-admin') {
                    [void](Build-PshGoal6InstallerPackage -Root $packageRoot -Edition Core -Architecture any)
                    Invoke-PshGoal6NonAdminChild -PackageRoot $packageRoot
                    return
                }

                $unicodeRoot = Join-Path $caseRoot (Get-PshGoal6UnicodeSpaceSegment)
                $localAppData = Join-Path $unicodeRoot 'local app data'
                $installRoot = Join-Path $localAppData 'Psh'
                $profilePath = Join-Path $unicodeRoot 'profile path/profile.ps1'
                if ($Scenario -ceq 'wrong-architecture') {
                    [void](Build-PshGoal6InstallerPackage -Root $packageRoot -Edition Full -Architecture win-arm64)
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Full
                    Assert-PshGoal6InstallFailure -Result $result -Label 'Wrong-architecture package' -ExpectedExitCode 5 -ExpectedErrorId 'PshLifecycle.IntegrityFailure' -ExpectedMessagePattern '\AAn ARM64 package cannot run on this architecture\.\z'
                    if ([IO.File]::Exists((Join-Path $installRoot 'current.json'))) { throw 'Wrong-architecture package changed the active version.' }
                    return
                }
                if ($Scenario -ceq 'full-missing-tool') {
                    [void](Build-PshGoal6InstallerPackage -Root $packageRoot -Edition Full -Architecture win-x64)
                    Remove-Item -LiteralPath (Join-Path $packageRoot 'payload/Psh/Tools/win-x64/rg/rg.exe') -Force
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Full
                    Assert-PshGoal6InstallFailure -Result $result -Label 'Full package missing rg' -ExpectedExitCode 5 -ExpectedErrorId 'PshPackageFileSet' -ExpectedMessagePattern '\APackage file count does not match its manifest \(actual=[0-9]+, expected=[0-9]+\)\.\z'
                    if ([IO.File]::Exists((Join-Path $installRoot 'current.json'))) { throw 'Full missing-tool package changed the active version.' }
                    return
                }
                if ($Scenario -ceq 'corrupted-download') {
                    [void](Build-PshGoal6InstallerPackage -Root $packageRoot -Edition Core -Architecture any)
                    [IO.File]::AppendAllText((Join-Path $packageRoot 'payload/Psh/Psh.psm1'), "# corrupted downloaded byte`n", $script:Goal6Utf8)
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Core
                    Assert-PshGoal6InstallFailure -Result $result -Label 'Corrupted downloaded package' -ExpectedExitCode 5 -ExpectedErrorId 'PshPackageFileMismatch' -ExpectedMessagePattern '\APackage file integrity does not match its manifest: payload/Psh/Psh\.psm1\z'
                    if ([IO.File]::Exists((Join-Path $installRoot 'current.json'))) { throw 'Corrupted package changed the active version.' }
                    return
                }

                [void](Build-PshGoal6InstallerPackage -Root $packageRoot -Edition Core -Architecture any)
                if ($Scenario -ceq 'profile-conflict') {
                    $originalProfile = "# user content`r`n# >>> Psh managed profile >>>`r`n"
                    Write-PshGoal6Text -Path $profilePath -Text $originalProfile
                    $before = [IO.File]::ReadAllBytes($profilePath)
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Core -ProfilePath @($profilePath)
                    $profileDiagnostic = '\APsh profile markers are unmatched, duplicated, or nested in: ' + [regex]::Escape([IO.Path]::GetFullPath($profilePath)) + ' \(start=1, end=0\)\.\z'
                    Assert-PshGoal6InstallFailure -Result $result -Label 'Malformed profile markers' -ExpectedExitCode 3 -ExpectedErrorId 'PshLifecycle' -ExpectedMessagePattern $profileDiagnostic
                    $after = [IO.File]::ReadAllBytes($profilePath)
                    if ([Convert]::ToBase64String($before) -cne [Convert]::ToBase64String($after)) { throw 'Profile conflict changed the original profile bytes.' }
                    if ([IO.File]::Exists((Join-Path $installRoot 'current.json'))) { throw 'Profile conflict changed the active version.' }
                    return
                }

                if ($Scenario -ceq 'unicode-space') {
                    Write-PshGoal6Text -Path $profilePath -Text "# original profile`r`n"
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Core -ProfilePath @($profilePath)
                    if (-not [bool]$result.Succeeded -or -not [bool]$result.Result.success) { throw 'Unicode and space install failed.' }
                    if (-not [IO.File]::Exists((Join-Path $installRoot 'current.json'))) { throw 'Unicode and space install did not publish current.json.' }
                    Assert-PshGoal6CoreCapabilitySet -InstallRoot $installRoot -LocalAppData $localAppData
                    return
                }

                if ($Scenario -ceq 'core-without-tools') {
                    if ([IO.Directory]::Exists((Join-Path $packageRoot 'payload/Psh/Tools'))) { throw 'Core fixture unexpectedly contains native tools.' }
                    $result = Invoke-PshGoal6PackageInstall -PackageRoot $packageRoot -InstallRoot $installRoot -Edition Core
                    if (-not [bool]$result.Succeeded -or -not [bool]$result.Result.success) { throw 'Core without tools failed to install.' }
                    if ([IO.Directory]::Exists((Join-Path $installRoot 'versions/0.1.0/Psh/Tools'))) { throw 'Core install created a native tools directory.' }
                    Assert-PshGoal6CoreCapabilitySet -InstallRoot $installRoot -LocalAppData $localAppData
                    return
                }

                throw "Unknown Goal 6 installer scenario: $Scenario"
            }
            finally {
                Remove-Module -Name Psh -Force -ErrorAction SilentlyContinue
                if ([IO.Directory]::Exists($caseRoot)) { Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'passes <Name>' -TestCases $goal6InstallerCases {
        param($Name, $Scenario)

        [void]$Name
        Invoke-PshGoal6InstallerScenario -Scenario $Scenario
    }
}
