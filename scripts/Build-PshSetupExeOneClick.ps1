# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build-PshSetupExeOneClick.ps1 — 一键在 Windows 上构建 psh-setup.exe
#
# 用法（在仓库根目录或任意位置）：
#
#   .\scripts\Build-PshSetupExeOneClick.ps1 -CandidateRoot C:\path\to\candidate
#
# 参数说明：
#   -CandidateRoot  包含 psh-0.2.0-core.zip 的目录（由 New-Goal6Candidate.ps1 生成）
#   -Version        版本号，默认 0.2.0
#   -SkipInstall    若为 $true，跳过 winget 自动安装步骤，只检测环境
#
# 本脚本会自动：
#   1. 检查 Windows 环境
#   2. 检查并通过 winget 安装 .NET SDK（dotnet build 所需）
#   3. 检查并通过 winget 安装 .NET Framework 4.7.2 Developer Pack（net472 编译所需）
#   4. 验证 CandidateRoot / psh-0.2.0-core.zip 存在
#   5. 调用 Build-PshSetupExe.ps1 完成构建
#   6. 打印最终 exe 路径和大小

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $CandidateRoot,

    [string] $Version = '0.2.0',

    [switch] $SkipInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ─── 颜色辅助函数 ────────────────────────────────────────────────────────────

function Write-Banner {
    param([string] $Text)
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
}

function Write-Step {
    param([string] $Num, [string] $Text)
    Write-Host ""
    Write-Host "  [$Num] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string] $Text)
    Write-Host "      [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string] $Text)
    Write-Host "      [!!] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string] $Text)
    Write-Host "      [XX] $Text" -ForegroundColor Red
}

function Write-Info {
    param([string] $Text)
    Write-Host "           $Text" -ForegroundColor Gray
}

# ─── 步骤 1：检查 Windows 平台 ───────────────────────────────────────────────

Write-Banner "psh-setup.exe 一键构建脚本  v$Version"

Write-Step "1/5" "检查运行环境 ..."

if ($env:OS -ne 'Windows_NT') {
    Write-Fail "此脚本只能在 Windows 上运行。当前系统：$($PSVersionTable.OS)"
    Write-Fail "请将整个仓库拷贝到 Windows 机器后重新执行。"
    exit 1
}

$osCaption = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
Write-Ok "操作系统：$osCaption"
Write-Ok "PowerShell：$($PSVersionTable.PSVersion)"

# ─── 步骤 2：检测 / 安装 winget ──────────────────────────────────────────────

Write-Step "2/5" "检测包管理器 winget ..."

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Fail "未检测到 winget（Windows 程序包管理器）。"
    Write-Info "请先在 Microsoft Store 安装「应用安装程序」，或访问："
    Write-Info "  https://aka.ms/getwinget"
    Write-Info "安装后重新运行本脚本。"
    exit 1
}

Write-Ok "winget 版本：$(winget --version)"

# ─── 步骤 3：检测 / 安装编译工具 ────────────────────────────────────────────

Write-Step "3/5" "检测并安装编译依赖 ..."

# ── 3a. 检测 dotnet ──────────────────────────────────────────────────────────

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue

if ($dotnet) {
    Write-Ok ".NET SDK 已安装：$(dotnet --version)"
} else {
    Write-Warn ".NET SDK 未检测到。"
    if ($SkipInstall) {
        Write-Fail "-SkipInstall 已启用，跳过安装。请手动安装 .NET SDK 后重试。"
        exit 1
    }
    Write-Info "正在通过 winget 安装 .NET SDK 9 ..."
    winget install Microsoft.DotNet.SDK.9 --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget 安装 .NET SDK 失败（退出码 $LASTEXITCODE）。"
        Write-Info "可手动访问 https://dotnet.microsoft.com/download 下载安装。"
        exit 1
    }
    # 刷新 PATH（winget 安装后不自动更新当前会话）
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-Warn ".NET SDK 安装完成，但当前会话 PATH 尚未刷新。"
        Write-Warn "请关闭此 PowerShell 窗口，重新打开后再次运行本脚本。"
        exit 1
    }
    Write-Ok ".NET SDK 安装成功：$(dotnet --version)"
}

# ── 3b. 检测 .NET Framework 4.7.2 Developer Pack ─────────────────────────────
#
# net472 项目编译时需要 Developer Pack（包含引用程序集）。
# 如果只装了运行时（Runtime），dotnet build / msbuild 会报：
#   error MSB3644: The reference assemblies for .NETFramework,Version=v4.7.2 were not found.
#
# 检测方法：查找 Reference Assemblies 目录或注册表键。

Write-Info "检测 .NET Framework 4.7.2 Developer Pack ..."

$refAsmPath = 'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2'
$regKey     = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'

$devPackInstalled = $false

if (Test-Path $refAsmPath) {
    $devPackInstalled = $true
    Write-Ok ".NET Framework 4.7.2 Reference Assemblies 已存在：$refAsmPath"
} else {
    # 进一步查注册表中 Developer Pack 是否留有标记
    try {
        $ndpVersion = (Get-ItemProperty -Path $regKey -ErrorAction Stop).Release
        # 461808 = 4.7.2；461814 = 4.7.2 on Win10 1803+
        if ($ndpVersion -ge 461808) {
            # Runtime 存在；但 Developer Pack 可能仍未安装（Reference Assemblies 缺失）
            Write-Warn "检测到 .NET Framework $ndpVersion（运行时），但 Reference Assemblies 目录不存在。"
            Write-Info "  -> 需安装 Developer Pack 才能编译 net472 项目。"
        }
    } catch {
        Write-Warn ".NET Framework 4.7.2 注册表键读取失败。"
    }
}

if (-not $devPackInstalled) {
    if ($SkipInstall) {
        Write-Fail "-SkipInstall 已启用，跳过安装。请手动安装 .NET Framework 4.7.2 Developer Pack 后重试。"
        exit 1
    }
    Write-Info "正在通过 winget 安装 .NET Framework 4.7.2 Developer Pack ..."
    Write-Info "  （此步骤约需 1-3 分钟，请耐心等待）"
    winget install Microsoft.DotNet.Framework.DeveloperPack_4 --version 4.7.2 `
        --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget 安装 .NET Framework 4.7.2 Developer Pack 失败（退出码 $LASTEXITCODE）。"
        Write-Info "可手动下载：https://dotnet.microsoft.com/download/dotnet-framework/net472"
        Write-Info "选择「Developer Pack」下载安装，完成后重新运行本脚本。"
        exit 1
    }
    # 安装后再次检测
    if (Test-Path $refAsmPath) {
        Write-Ok ".NET Framework 4.7.2 Developer Pack 安装成功。"
        $devPackInstalled = $true
    } else {
        Write-Warn "winget 报告安装成功，但 Reference Assemblies 目录仍不存在。"
        Write-Warn "可能需要重启机器使安装生效。重启后重新运行本脚本。"
        exit 1
    }
}

# ── 3c. msbuild fallback 提示（可选）────────────────────────────────────────

$msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
if ($msbuild) {
    Write-Ok "msbuild 也可用（fallback）：$($msbuild.Source)"
}

# ─── 步骤 4：验证 CandidateRoot / psh-core.zip ───────────────────────────────

Write-Step "4/5" "验证构建素材 ..."

$coreZipName = "psh-$Version-core.zip"

if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    # 尝试仓库旁边的默认 candidate 目录
    $repoRoot       = Split-Path -Parent $PSScriptRoot
    $defaultCandidate = Join-Path (Split-Path -Parent $repoRoot) 'candidate'
    if (Test-Path (Join-Path $defaultCandidate $coreZipName)) {
        $CandidateRoot = $defaultCandidate
        Write-Info "自动检测到 CandidateRoot：$CandidateRoot"
    } else {
        Write-Fail "未指定 -CandidateRoot，且默认路径不含 $coreZipName。"
        Write-Info ""
        Write-Info "请先生成 candidate 目录："
        Write-Info "  .\scripts\goal6\New-Goal6Candidate.ps1 -CandidateRoot C:\psh-candidate ..."
        Write-Info ""
        Write-Info "然后重新运行："
        Write-Info "  .\scripts\Build-PshSetupExeOneClick.ps1 -CandidateRoot C:\psh-candidate"
        exit 1
    }
}

$coreZipPath = Join-Path $CandidateRoot $coreZipName
if (-not (Test-Path $coreZipPath)) {
    Write-Fail "在 CandidateRoot 中未找到 $coreZipName。"
    Write-Info "  CandidateRoot : $CandidateRoot"
    Write-Info "  期望文件      : $coreZipPath"
    Write-Info ""
    Write-Info "请先运行 New-Goal6Candidate.ps1 生成完整的 candidate 目录，再重试。"
    exit 1
}

$zipSize = (Get-Item $coreZipPath).Length
Write-Ok "$coreZipName 存在（$([math]::Round($zipSize / 1MB, 1)) MB）"
Write-Ok "CandidateRoot : $CandidateRoot"

# ─── 步骤 5：调用 Build-PshSetupExe.ps1 ─────────────────────────────────────

Write-Step "5/5" "调用 Build-PshSetupExe.ps1 ..."

$repoRoot    = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $repoRoot 'scripts\Build-PshSetupExe.ps1'

if (-not (Test-Path $buildScript)) {
    Write-Fail "Build-PshSetupExe.ps1 不存在：$buildScript"
    exit 1
}

Write-Info "仓库根目录 : $repoRoot"
Write-Info "构建脚本   : $buildScript"
Write-Info "CandidateRoot : $CandidateRoot"
Write-Info ""

& $buildScript -CandidateRoot $CandidateRoot -Version $Version -RepositoryRoot $repoRoot

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Build-PshSetupExe.ps1 以退出码 $LASTEXITCODE 结束。"
    exit $LASTEXITCODE
}

# ─── 完成提示 ────────────────────────────────────────────────────────────────

Write-Banner "构建完成"

# 找到输出 exe（兼容双路径）
$exePath    = Join-Path $repoRoot 'src\setup-exe\bin\Release\psh-setup.exe'
$exePathAlt = Join-Path $repoRoot 'src\setup-exe\bin\Release\net472\psh-setup.exe'
$finalExe   = if (Test-Path $exePath) { $exePath } elseif (Test-Path $exePathAlt) { $exePathAlt } else { $null }

if ($finalExe) {
    $exeSize = (Get-Item $finalExe).Length
    Write-Host ""
    Write-Host "  psh-setup.exe 路径 : $finalExe" -ForegroundColor Green
    Write-Host "  文件大小           : $([math]::Round($exeSize / 1MB, 2)) MB" -ForegroundColor Green
}

$destExe = Join-Path $CandidateRoot 'psh-setup.exe'
if (Test-Path $destExe) {
    Write-Host "  已复制到候选目录   : $destExe" -ForegroundColor Green
}

Write-Host ""
Write-Host "  下一步：将 psh-setup.exe 上传至 GitHub Release，或直接分发给用户使用。" -ForegroundColor Cyan
Write-Host ""
