# Psh v0.1.0 Release Builder for Windows 11
# Run as Administrator in PowerShell 7

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   Psh v0.1.0 Release Builder" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Stage 1: Install required software
Write-Host "Stage 1/3: Installing Development Tools" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Check winget
Write-Host "[1.1] Checking winget..." -ForegroundColor White
try {
    $wingetVersion = winget --version 2>$null
    Write-Host "  [OK] winget installed: $wingetVersion" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] winget not found. Install from Microsoft Store" -ForegroundColor Red
    Write-Host "  Visit: https://aka.ms/getwinget" -ForegroundColor Yellow
    pause
    exit 1
}

# Install Git
Write-Host ""
Write-Host "[1.2] Installing Git..." -ForegroundColor White
try {
    $gitVersion = git --version 2>$null
    Write-Host "  [OK] Git already installed: $gitVersion" -ForegroundColor Green
} catch {
    Write-Host "  [INSTALL] Installing Git..." -ForegroundColor Yellow
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Start-Sleep -Seconds 5
    $gitVersion = git --version 2>$null
    Write-Host "  [OK] Git installed: $gitVersion" -ForegroundColor Green
}

# Install .NET SDK
Write-Host ""
Write-Host "[1.3] Installing .NET SDK..." -ForegroundColor White
try {
    $dotnetVersion = dotnet --version 2>$null
    Write-Host "  [OK] .NET SDK already installed: $dotnetVersion" -ForegroundColor Green
} catch {
    Write-Host "  [INSTALL] Installing .NET SDK 8..." -ForegroundColor Yellow
    winget install --id Microsoft.DotNet.SDK.8 --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Start-Sleep -Seconds 5
    $dotnetVersion = dotnet --version 2>$null
    Write-Host "  [OK] .NET SDK installed: $dotnetVersion" -ForegroundColor Green
}

# Check PowerShell 7
Write-Host ""
Write-Host "[1.4] Checking PowerShell 7..." -ForegroundColor White
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "  [OK] PowerShell 7 installed: $($PSVersionTable.PSVersion)" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] Please install PowerShell 7 and rerun this script" -ForegroundColor Red
    winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements
    Write-Host "  After installation, open PowerShell 7 and rerun this script" -ForegroundColor Yellow
    pause
    exit 0
}

# Install GitHub CLI
Write-Host ""
Write-Host "[1.5] Installing GitHub CLI..." -ForegroundColor White
try {
    $ghVersion = gh --version 2>$null | Select-Object -First 1
    Write-Host "  [OK] GitHub CLI already installed" -ForegroundColor Green
} catch {
    Write-Host "  [INSTALL] Installing GitHub CLI..." -ForegroundColor Yellow
    winget install --id GitHub.cli --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Start-Sleep -Seconds 5
    Write-Host "  [OK] GitHub CLI installed" -ForegroundColor Green
}

Write-Host ""
Write-Host "[SUCCESS] All tools installed!" -ForegroundColor Green
Start-Sleep -Seconds 2

# Stage 2: Clone and build
Write-Host ""
Write-Host "Stage 2/3: Building Release Assets" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$BuildRoot = "C:\psh-release-build"
Write-Host "[2.1] Build directory: $BuildRoot" -ForegroundColor White
New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
Set-Location $BuildRoot

# Clone repository
Write-Host ""
Write-Host "[2.2] Cloning repository..." -ForegroundColor White
if (Test-Path ".\psh") {
    Write-Host "  Repository exists, updating..." -ForegroundColor Yellow
    Set-Location .\psh
    git fetch --all --tags 2>&1 | Out-Null
} else {
    Write-Host "  Cloning from GitHub..." -ForegroundColor Gray
    git clone https://github.com/Emvdy/psh.git 2>&1 | Out-Null
    Set-Location .\psh
}

# Checkout v0.1.0
Write-Host ""
Write-Host "[2.3] Checking out v0.1.0..." -ForegroundColor White
git checkout v0.1.0 2>&1 | Out-Null
$commit = git log -1 --format="%H"
$commitShort = git log -1 --format="%h"
Write-Host "  [OK] Current commit: $commitShort" -ForegroundColor Green

if ($commit -ne "f2fe53e7f7ee865504392870e91230e3866d833e") {
    Write-Error "Commit SHA mismatch!"
    pause
    exit 1
}

# Build bootstrapper
Write-Host ""
Write-Host "[2.4] Building bootstrapper..." -ForegroundColor White
Set-Location src\bootstrapper

Write-Host "  Building psh-installer.exe..." -ForegroundColor Gray
$buildOutput = dotnet build -c Release --nologo 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  [ERROR] Bootstrapper build failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Build output:" -ForegroundColor Yellow
    $buildOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "Common fix: Install .NET Framework 4.7.2 Developer Pack" -ForegroundColor Yellow
    Write-Host "  Download: https://download.visualstudio.microsoft.com/download/pr/158dce74-251c-4af3-b8cc-4608621341c8/9c1e178a11f55478e2112714a3897c1a/ndp472-devpack-enu.exe" -ForegroundColor Cyan
    Write-Host "  Or run: winget install Microsoft.DotNet.Framework.DeveloperPack_4" -ForegroundColor Cyan
    Write-Host ""
    pause
    exit 1
}

# Check both possible output paths (SDK version dependent)
$BootstrapperPath = "bin\Release\net472\psh-installer.exe"
if (-not (Test-Path $BootstrapperPath)) {
    $BootstrapperPath = "bin\Release\psh-installer.exe"
}

if (Test-Path $BootstrapperPath) {
    $size = (Get-Item $BootstrapperPath).Length
    Write-Host "  [OK] Build complete: $([math]::Round($size/1KB, 2)) KB" -ForegroundColor Green
} else {
    Write-Error "Bootstrapper exe not found at expected location"
    pause
    exit 1
}

Set-Location ..\..

# Generate release candidate
Write-Host ""
Write-Host "[2.5] Generating release assets..." -ForegroundColor White
Write-Host "  This may take a few minutes..." -ForegroundColor Gray

$CandidateRoot = "$BuildRoot\candidate"
$ReportPath = "$BuildRoot\candidate-report.json"
$Version = "0.1.0"
$SourceCommit = "f2fe53e7f7ee865504392870e91230e3866d833e"

# Check both possible bootstrapper paths (SDK version dependent)
$BootstrapperFullPath = "$BuildRoot\psh\src\bootstrapper\bin\Release\net472\psh-installer.exe"
if (-not (Test-Path $BootstrapperFullPath)) {
    $BootstrapperFullPath = "$BuildRoot\psh\src\bootstrapper\bin\Release\psh-installer.exe"
}

$ReleaseNotesPath = "$BuildRoot\psh\RELEASE_NOTES.md"
$ReleaseNotesZhCnPath = "$BuildRoot\psh\RELEASE_NOTES.zh-CN.md"

# Clean up existing candidate directory if it exists
if (Test-Path $CandidateRoot) {
    Write-Host "  Cleaning existing candidate directory..." -ForegroundColor Gray
    Remove-Item -Recurse -Force $CandidateRoot
}
if (Test-Path $ReportPath) {
    Remove-Item -Force $ReportPath
}

try {
    & .\scripts\goal6\New-Goal6Candidate.ps1 -CandidateRoot $CandidateRoot -ReportPath $ReportPath -Version $Version -SourceCommit $SourceCommit -BootstrapperPath $BootstrapperFullPath -ReleaseNotesPath $ReleaseNotesPath -ReleaseNotesZhCnPath $ReleaseNotesZhCnPath -ErrorAction Stop
    Write-Host ""
    Write-Host "  [SUCCESS] Assets generated!" -ForegroundColor Green
} catch {
    Write-Error "Asset generation failed: $_"
    Write-Host $_.Exception.Message -ForegroundColor Red
    pause
    exit 1
}

# Build psh-setup.exe (self-contained installer)
Write-Host ""
Write-Host "[2.6] Building psh-setup.exe (self-contained installer)..." -ForegroundColor White
Write-Host "  Bundles Core zip + installer script into a single exe" -ForegroundColor Gray

try {
    & .\scripts\Build-PshSetupExe.ps1 -CandidateRoot $CandidateRoot -Version $Version -ErrorAction Stop
    Write-Host "  [SUCCESS] psh-setup.exe built!" -ForegroundColor Green
} catch {
    Write-Host "  [WARNING] psh-setup.exe build failed: $_" -ForegroundColor Yellow
    Write-Host "  Continuing without psh-setup.exe (v0.1.0 assets are still complete)" -ForegroundColor Gray
}

# Stage 3: Validate
Write-Host ""
Write-Host "Stage 3/3: Validating Assets" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[3.1] Checking required assets..." -ForegroundColor White
$RequiredAssets = @(
    "install.ps1",
    "psh-installer.exe",
    "psh-0.1.0-core.zip",
    "psh-0.1.0-full-win-x64.zip",
    "psh-0.1.0-full-win-arm64.zip",
    "sbom.spdx.json",
    "THIRD_PARTY_NOTICES.md",
    "RELEASE_NOTES.md",
    "psh-release-0.1.0.json",
    "SHA256SUMS"
)

# psh-setup.exe is optional (v0.2.0 feature)
$OptionalAssets = @("psh-setup.exe")

$AllPresent = $true
$TotalSize = 0

foreach ($asset in $RequiredAssets) {
    $path = Join-Path $CandidateRoot $asset
    if (Test-Path $path) {
        $size = (Get-Item $path).Length
        $TotalSize += $size
        if ($size -gt 1MB) {
            $sizeStr = "$([math]::Round($size/1MB, 2)) MB"
        } else {
            $sizeStr = "$([math]::Round($size/1KB, 2)) KB"
        }
        Write-Host "  [OK] $($asset.PadRight(40)) $sizeStr" -ForegroundColor Green
    } else {
        Write-Host "  [MISSING] $asset" -ForegroundColor Red
        $AllPresent = $false
    }
}

Write-Host ""
Write-Host "  Total size: $([math]::Round($TotalSize/1MB, 2)) MB" -ForegroundColor Cyan

# Check optional assets
Write-Host ""
foreach ($asset in $OptionalAssets) {
    $path = Join-Path $CandidateRoot $asset
    if (Test-Path $path) {
        $size = (Get-Item $path).Length
        if ($size -gt 1MB) { $sizeStr = "$([math]::Round($size/1MB, 2)) MB" } else { $sizeStr = "$([math]::Round($size/1KB, 2)) KB" }
        Write-Host "  [OPTIONAL OK] $($asset.PadRight(36)) $sizeStr" -ForegroundColor Cyan
    } else {
        Write-Host "  [OPTIONAL SKIP] $asset (run Build-PshSetupExe.ps1 to generate)" -ForegroundColor Gray
    }
}

if (-not $AllPresent) {
    Write-Error "Some required assets are missing"
    pause
    exit 1
}

# Verify checksums
Write-Host ""
Write-Host "[3.2] Verifying SHA256 checksums..." -ForegroundColor White
$sha256Path = Join-Path $CandidateRoot "SHA256SUMS"
$checksums = Get-Content $sha256Path
$AllValid = $true
$CheckedCount = 0

foreach ($line in $checksums) {
    if ($line -match '^([a-f0-9]{64})\s+(.+)$') {
        $expectedHash = $matches[1]
        $filename = $matches[2]
        $filepath = Join-Path $CandidateRoot $filename

        if (Test-Path $filepath) {
            $actualHash = (Get-FileHash -Path $filepath -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -eq $expectedHash) {
                Write-Host "  [OK] $filename" -ForegroundColor Green
                $CheckedCount++
            } else {
                Write-Host "  [FAIL] $filename" -ForegroundColor Red
                $AllValid = $false
            }
        }
    }
}

Write-Host ""
Write-Host "  Verified: $CheckedCount files" -ForegroundColor Cyan

if (-not $AllValid) {
    Write-Error "SHA256 verification failed"
    pause
    exit 1
}

# Create transfer package
Write-Host ""
Write-Host "[3.3] Creating transfer package..." -ForegroundColor White
$TransferPath = "$BuildRoot\psh-v0.1.0-assets.zip"
if (Test-Path $TransferPath) {
    Remove-Item $TransferPath -Force
}

Compress-Archive -Path "$CandidateRoot\*" -DestinationPath $TransferPath -CompressionLevel Optimal
$zipSize = (Get-Item $TransferPath).Length
Write-Host "  [OK] Package created: $([math]::Round($zipSize/1MB, 2)) MB" -ForegroundColor Green
Write-Host "  Location: $TransferPath" -ForegroundColor Gray

# Done
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "              BUILD COMPLETE!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Assets location:" -ForegroundColor Cyan
Write-Host "  Directory: $CandidateRoot" -ForegroundColor White
Write-Host "  Package: $TransferPath" -ForegroundColor White
Write-Host ""

Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Method 1: Upload with GitHub CLI (recommended)" -ForegroundColor White
Write-Host "  gh auth login" -ForegroundColor Cyan
Write-Host "  Set-Location '$CandidateRoot'" -ForegroundColor Cyan
Write-Host "  gh release upload v0.1.0 * --clobber --repo Emvdy/psh" -ForegroundColor Cyan
Write-Host ""
Write-Host "Method 2: Manual upload" -ForegroundColor White
Write-Host "  Visit: https://github.com/Emvdy/psh/releases/tag/v0.1.0" -ForegroundColor Cyan
Write-Host "  Edit release and drag files from $CandidateRoot" -ForegroundColor Gray
Write-Host ""

Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
