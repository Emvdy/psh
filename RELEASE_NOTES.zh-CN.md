<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Psh v0.1.0 发布说明

[English](RELEASE_NOTES.md)

> [!IMPORTANT]
> 本文描述 `v0.1.0` 候选产物的内容，不表示版本发布已经完成，也不表示
> Goal 7 虚拟机验收已经完成。

## 本版本内容

候选版本面向 Windows 10/11 的 x64 与 ARM64 环境，适用于 Windows
PowerShell 5.1 和 PowerShell 7。两个版本类型均提供相同的 64 个 Psh
命令名，并内置 PSReadLine `2.4.5`。

- **Core** 是默认且与架构无关的包，不包含第三方工具可执行文件；
  `rg`、`fd`、`jq` 和 `bat` 使用有明确文档的 PowerShell 子集实现。
- **Full** 仅适用于 Windows，增加了与架构匹配的原生工具：
  `bat` `0.26.1`、`fd` `10.4.2`、`jq` `1.8.2` 和 ripgrep `15.2.0`。
- Full 分别提供 x64 与 ARM64 包。ARM64 包包含原生 ARM64 工具，不会把
  x64 可执行文件改名或静默替换为 ARM64 版本。

| 版本类型 | 离线包 | 包架构 |
| --- | --- | --- |
| Core | `psh-0.1.0-core.zip` | 与架构无关（`any`） |
| Full | `psh-0.1.0-full-win-x64.zip` | Windows x64（`win-x64`） |
| Full | `psh-0.1.0-full-win-arm64.zip` | Windows ARM64（`win-arm64`） |

## 候选资产

固定候选集合仅包含以下 13 个资产：

| 资产 | 用途 |
| --- | --- |
| `install.ps1` | Windows PowerShell 在线安装入口 |
| `install.sh` | Git Bash 或 WSL 在线/离线安装入口 |
| `psh-installer.exe` | AnyCPU 在线/离线引导程序 |
| `psh-0.1.0-core.zip` | 与架构无关的 Core 离线包 |
| `psh-0.1.0-full-win-x64.zip` | 包含原生 x64 工具的 Full 离线包 |
| `psh-0.1.0-full-win-arm64.zip` | 包含原生 ARM64 工具的 Full 离线包 |
| `sbom.spdx.json` | SPDX 软件物料清单 |
| `THIRD_PARTY_NOTICES.md` | 第三方版本、来源与许可证声明 |
| `RELEASE_NOTES.md` | 英文发布说明 |
| `RELEASE_NOTES.zh-CN.md` | 简体中文发布说明 |
| `psh-release-0.1.0.json` | 带版本的发布索引与资产元数据 |
| `SHA256SUMS` | 文件中所列内容资产的 SHA256 记录 |
| `psh-release-0.1.0.cat` | 绑定发布索引与校验文件的未签名 Windows 目录文件 |

## 在线安装

请从同一个 `v0.1.0` 候选集合下载准备使用的入口。Core 是默认版本；将
`Core` 替换为 `Full`，即可选择与当前主机架构匹配的 Full 包。

浏览器下载的未签名 `install.ps1` 通常带有网络来源标记（Mark-of-the-Web，
MOTW），因此会被 `RemoteSigned` 拒绝。只要相邻的 `install.ps1` 仍带有 Internet
区域 MOTW，引导程序也会拒绝启动它。带 attestation 的版本发布后，必须先独立
验证准备使用的准确入口，再运行该入口。下面的直接 attestation 路径与独立认证
`SHA256SUMS` 路径是两种可选方案。

直接通过 Windows PowerShell 安装时，先验证脚本，再移除 MOTW 并运行：

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\install.ps1 --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'install.ps1 attestation verification failed.' }
Unblock-File -LiteralPath .\install.ps1
powershell.exe -NoLogo -NoProfile -File .\install.ps1 -Edition Core -Version 0.1.0
```

也可以先认证 `SHA256SUMS`，根据该文件精确核对 `install.ps1` 字节，再移除
MOTW 并运行脚本：

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\SHA256SUMS --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'SHA256SUMS attestation verification failed.' }
$record = @(Get-Content -LiteralPath .\SHA256SUMS | Where-Object { $_ -match '\A[0-9a-f]{64}  install\.ps1\z' })
if ($record.Count -ne 1) { throw 'Expected one install.ps1 checksum record.' }
$expected = $record[0].Substring(0, 64)
$actual = (Get-FileHash -LiteralPath .\install.ps1 -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne $expected) { throw 'install.ps1 SHA256 mismatch.' }
Unblock-File -LiteralPath .\install.ps1
powershell.exe -NoLogo -NoProfile -File .\install.ps1 -Edition Core -Version 0.1.0
```

通过 Git Bash 或 WSL 安装时，先验证 shell 入口再运行：

```bash
gh attestation verify ./install.sh --repo Emvdy/psh || exit 1
bash ./install.sh --edition Core --version 0.1.0
```

使用 AnyCPU 引导程序时，必须将 `psh-installer.exe` 与同一候选集合中匹配的
`install.ps1` 放在同一目录。先验证两个文件，再移除两者的 MOTW 并启动：

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\psh-installer.exe --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'psh-installer.exe attestation verification failed.' }
gh attestation verify .\install.ps1 --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'Adjacent install.ps1 attestation verification failed.' }
Unblock-File -LiteralPath @('.\psh-installer.exe', '.\install.ps1')
.\psh-installer.exe --edition Core --version 0.1.0
```

`Unblock-File` 只移除已验证文件的 MOTW 备用数据流，不会修改或绕过
PowerShell 执行策略。`AllSigned`、企业 GPO 或其他当前生效的策略仍可能拒绝
这些未签名文件。

## 离线安装

离线安装必须同时提供原始归档路径，以及来自可信外部发布渠道的 SHA256
值。解压后仍需保留 ZIP；安装器会把解压后的包与这份归档证据绑定验证。以下
示例假定 `SHA256SUMS` 已经独立验证，例如已通过发布阶段的 GitHub attestation
验证。示例从该可信文件读取期望哈希，不会把根据本地 ZIP 自算的哈希当作其自身
的信任来源。

通过 Windows PowerShell 安装 Core 的示例：

```powershell
$archive = (Resolve-Path .\psh-0.1.0-core.zip).Path
$record = @(Get-Content -LiteralPath .\SHA256SUMS | Where-Object { $_ -match '\A[0-9a-f]{64}  psh-0\.1\.0-core\.zip\z' })
if ($record.Count -ne 1) { throw 'Expected one Core archive checksum record.' }
$expectedSha256 = $record[0].Substring(0, 64)
$actualSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -cne $expectedSha256) { throw 'Core archive SHA256 mismatch.' }
Expand-Archive -LiteralPath $archive -DestinationPath .\psh-0.1.0-core
& .\psh-0.1.0-core\install-offline.ps1 -Edition Core -Version 0.1.0 -ArchivePath $archive -ArchiveSha256 $expectedSha256
```

解压后的包也提供 Git Bash/WSL 入口：

```bash
archive_path="$(pwd -P)/psh-0.1.0-core.zip"
archive_sha256="$(awk '$2 == "psh-0.1.0-core.zip" { print $1 }' ./SHA256SUMS)"
test "${#archive_sha256}" -eq 64
printf '%s  %s\n' "$archive_sha256" "$archive_path" | sha256sum --check -
bash ./psh-0.1.0-core/install.sh --offline \
  --edition Core --version 0.1.0 \
  --archive-path "$archive_path" \
  --archive-sha256 "$archive_sha256"
```

也可以复用上面已经验证的 `$archive` 与 `$expectedSha256`，运行解压包内的
引导程序：

```powershell
& .\psh-0.1.0-core\psh-installer.exe --offline --edition Core --version 0.1.0 --archive-path $archive --archive-sha256 $expectedSha256
```

安装 Full 时，请解压与主机匹配的 x64 或 ARM64 ZIP，并使用
`--edition Full` 或 `-Edition Full`。`install.sh` 与
`psh-installer.exe` 离线入口都要求提供 `--archive-path` 和
`--archive-sha256`；`install-offline.ps1` 要求提供 `-ArchivePath` 和
`-ArchiveSha256`。

## 校验和运行时信任

带 attestation 的版本发布后，先认证 `SHA256SUMS`，再在 Windows PowerShell
中根据该文件验证未签名的引导程序：

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\SHA256SUMS --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'SHA256SUMS attestation verification failed.' }
$record = @(Get-Content -LiteralPath .\SHA256SUMS | Where-Object { $_ -match '\A[0-9a-f]{64}  psh-installer\.exe\z' })
if ($record.Count -ne 1) { throw 'Expected one psh-installer.exe checksum record.' }
$expected = $record[0].Substring(0, 64)
$actual = (Get-FileHash -LiteralPath .\psh-installer.exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne $expected) { throw 'psh-installer.exe SHA256 mismatch.' }
"SHA256 verified: $actual"
```

在包含文件中所列全部内容资产的目录中，Git Bash 可先认证校验文件，再验证
其中的每条记录：

```bash
gh attestation verify ./SHA256SUMS --repo Emvdy/psh || exit 1
sha256sum --check SHA256SUMS
```

需要时可直接验证引导程序与所选归档：

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\psh-installer.exe --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'psh-installer.exe attestation verification failed.' }
gh attestation verify .\psh-0.1.0-core.zip --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'Core archive attestation verification failed.' }
```

使用 Full 时请替换为对应归档。Attestation 是独立的发布阶段门禁和用户验证
步骤。生产信任路径在运行时按适用情况验证 SHA256、未签名 Windows 目录成员
关系、manifest/文件树哈希和归档绑定。未签名目录只验证成员关系，不认证
发布者；运行时路径不会验证发布者 Authenticode 证书链。它会将 provenance
attestation 报告为 `not-verified-at-runtime`，也不声称自行执行 GitHub
attestation 验证。

## 安全说明

- `psh-installer.exe` 是未签名的 AnyCPU 可执行文件，Windows SmartScreen
  可能在运行前发出警告。决定是否继续前，请先验证其 SHA256，并在可用后验证
  GitHub attestation。
- 所有安装入口都遵守当前生效的 PowerShell 执行策略。任何入口都不会修改执行
  策略或组策略，也不会使用 `-ExecutionPolicy Bypass` 启动 PowerShell。如果
  策略阻止安装流程，安装器会退出并给出诊断，而不是绕过策略。上面的验证后
  `Unblock-File` 步骤只移除 MOTW，不会削弱当前生效的策略。
- 安装范围仅限当前用户，不要求提升权限，也不会修改永久系统 `PATH`。

## 已知限制

- Full 仅适用于 Windows。Core 包本身与架构无关，但 Psh `v0.1.0` 的目标是
  Windows，而不是跨平台 POSIX 环境。
- Psh 是命令兼容层，不是 Bash、POSIX 环境或通用 `.sh` 运行时。
- Tier 2 的 PowerShell 后端命令只实现有明确文档的子集，不支持的语法以退出码
  `2` 拒绝。Full 的原生 `rg`、`fd`、`jq` 和 `bat` 遵循各自固定版本工具的
  参数约定。
- 交互式编辑、按键绑定、补全显示和终端行为取决于 PSReadLine 以及宿主的虚拟
  终端能力。
- `v0.1.0` 不包含 PSCompletions。Git 补全由 Psh 自有的离线适配器提供，不会
  导入 PSCompletions。
- Full 的 x64 与 ARM64 包各自包含架构匹配的原生工具，但这一打包事实不表示
  ARM64 CI 矩阵或 Goal 7 虚拟机验收已经完成。候选版本的 CI 合约强制要求原生
  ARM64 Windows PowerShell 5.1 与 PowerShell 7 进程，并拒绝 x64 模拟；在模拟
  环境中成功运行不能证明原生 ARM64 支持。

## 版本与许可证

- 版本：`0.1.0`；预期标签：`v0.1.0`。
- Psh 自有源码与文档采用 GNU GPL v3.0 or later（`GPL-3.0-or-later`）许可；
  完整文本见 `LICENSE`。
- 内置的 PSReadLine 与 Full 原生工具保留各自上游许可证。详见每个离线包中的
  `THIRD_PARTY_NOTICES.md`、`sbom.spdx.json` 和 `licenses` 目录。
