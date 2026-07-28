<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Psh v0.1.0 release notes

[简体中文](RELEASE_NOTES.zh-CN.md)

> [!IMPORTANT]
> These notes describe the contents of the `v0.1.0` candidate artifacts. They
> do not claim that release publication or Goal 7 VM acceptance has completed.

## What is included

The candidate targets Windows 10 and 11 on x64 and ARM64, with Windows
PowerShell 5.1 and PowerShell 7. Both editions ship the same 64 Psh command
names and bundle PSReadLine `2.4.5`.

- **Core** is the default, architecture-neutral package. It contains no
  third-party utility executables. `rg`, `fd`, `jq`, and `bat` use documented
  PowerShell subsets.
- **Full** is Windows-only. It adds architecture-matched native builds of
  `bat` `0.26.1`, `fd` `10.4.2`, `jq` `1.8.2`, and ripgrep `15.2.0`.
- Full has separate x64 and ARM64 packages. The ARM64 package contains native
  ARM64 tools; it does not relabel or silently substitute x64 executables.

| Edition | Offline package | Package architecture |
| --- | --- | --- |
| Core | `psh-0.1.0-core.zip` | Architecture-neutral (`any`) |
| Full | `psh-0.1.0-full-win-x64.zip` | Windows x64 (`win-x64`) |
| Full | `psh-0.1.0-full-win-arm64.zip` | Windows ARM64 (`win-arm64`) |

## Candidate assets

The fixed candidate set contains exactly these 13 assets:

| Asset | Purpose |
| --- | --- |
| `install.ps1` | Online Windows PowerShell entry |
| `install.sh` | Git Bash or WSL online/offline entry |
| `psh-installer.exe` | AnyCPU online/offline bootstrapper |
| `psh-0.1.0-core.zip` | Architecture-neutral Core offline package |
| `psh-0.1.0-full-win-x64.zip` | Full offline package with native x64 tools |
| `psh-0.1.0-full-win-arm64.zip` | Full offline package with native ARM64 tools |
| `sbom.spdx.json` | SPDX software bill of materials |
| `THIRD_PARTY_NOTICES.md` | Third-party versions, provenance, and licenses |
| `RELEASE_NOTES.md` | English release notes |
| `RELEASE_NOTES.zh-CN.md` | Simplified Chinese release notes |
| `psh-release-0.1.0.json` | Versioned release index and asset metadata |
| `SHA256SUMS` | SHA256 records for the content assets listed in the file |
| `psh-release-0.1.0.cat` | Unsigned Windows catalog binding the release index and checksum file |

## Online installation

Download the entry you intend to use from the same `v0.1.0` candidate. Core is
the default; replace `Core` with `Full` to select the host-matched Full package.

A browser-downloaded unsigned `install.ps1` normally carries Mark-of-the-Web
(MOTW), so `RemoteSigned` rejects it. The bootstrapper also refuses to launch
its adjacent `install.ps1` while that script retains Internet-zone MOTW. After
an attested release has been published, independently verify the exact entry
before running it. The direct attestation and independently authenticated
`SHA256SUMS` paths below are alternatives.

For direct Windows PowerShell installation, verify the script first, then
remove MOTW and run it:

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\install.ps1 --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'install.ps1 attestation verification failed.' }
Unblock-File -LiteralPath .\install.ps1
powershell.exe -NoLogo -NoProfile -File .\install.ps1 -Edition Core -Version 0.1.0
```

Alternatively, authenticate `SHA256SUMS`, verify the exact `install.ps1`
bytes against it, then remove MOTW and run the script:

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

For Git Bash or WSL, verify the shell entry before running it:

```bash
gh attestation verify ./install.sh --repo Emvdy/psh || exit 1
bash ./install.sh --edition Core --version 0.1.0
```

For the AnyCPU bootstrapper, keep `psh-installer.exe` next to the matching
`install.ps1` from the same candidate. Verify both files, then remove MOTW from
both before launch:

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\psh-installer.exe --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'psh-installer.exe attestation verification failed.' }
gh attestation verify .\install.ps1 --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'Adjacent install.ps1 attestation verification failed.' }
Unblock-File -LiteralPath @('.\psh-installer.exe', '.\install.ps1')
.\psh-installer.exe --edition Core --version 0.1.0
```

`Unblock-File` removes the verified file's MOTW alternate data stream. It does
not change or bypass PowerShell execution policy. `AllSigned`, enterprise GPO,
or another effective policy may still reject these unsigned files.

## Offline installation

Offline installation requires both the original archive path and its SHA256
value from a trusted external release channel. Keep the ZIP after extraction;
the installer binds the extracted package back to that archive evidence. The
examples below assume that `SHA256SUMS` has first been independently verified,
for example with its publish-time GitHub attestation. They read the expected
hash from that trusted file; they do not treat a hash calculated from the local
ZIP as its own trust source.

Core example using Windows PowerShell:

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

The extracted package also provides the Git Bash/WSL entry:

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

Or, using the already verified `$archive` and `$expectedSha256` values above,
run the bootstrapper inside the extracted package:

```powershell
& .\psh-0.1.0-core\psh-installer.exe --offline --edition Core --version 0.1.0 --archive-path $archive --archive-sha256 $expectedSha256
```

For Full, extract the x64 or ARM64 ZIP that matches the host and use
`--edition Full` or `-Edition Full`. The `install.sh` and
`psh-installer.exe` offline entries both require `--archive-path` and
`--archive-sha256`; `install-offline.ps1` requires `-ArchivePath` and
`-ArchiveSha256`.

## Checksums and runtime trust

After an attested release has been published, first authenticate
`SHA256SUMS`, then verify the unsigned bootstrapper against it in Windows
PowerShell:

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

From a directory containing all listed content assets, Git Bash can
authenticate the checksum file and verify every entry in it:

```bash
gh attestation verify ./SHA256SUMS --repo Emvdy/psh || exit 1
sha256sum --check SHA256SUMS
```

Directly verify the bootstrapper and selected archive when needed:

```powershell
$ErrorActionPreference = 'Stop'
gh attestation verify .\psh-installer.exe --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'psh-installer.exe attestation verification failed.' }
gh attestation verify .\psh-0.1.0-core.zip --repo Emvdy/psh
if ($LASTEXITCODE -ne 0) { throw 'Core archive attestation verification failed.' }
```

Substitute the selected Full archive when applicable. Attestation is a
separate publish-time and user verification step. At runtime, the production
trust path verifies SHA256 values, unsigned Windows catalog membership,
manifest/tree hashes, and archive binding where applicable. The unsigned
catalogs validate membership only and do not authenticate a publisher; the
runtime path does not validate a publisher Authenticode certificate chain. It
reports provenance attestation as `not-verified-at-runtime` and does not claim
to perform GitHub attestation verification itself.

## Security notes

- `psh-installer.exe` is an unsigned AnyCPU executable. Windows SmartScreen may
  warn before it runs. Verify both its SHA256 and, once available, its GitHub
  attestation before deciding whether to continue.
- Every installer respects the effective PowerShell execution policy. No entry
  changes execution policy or Group Policy, and no entry launches PowerShell
  with `-ExecutionPolicy Bypass`. If policy blocks the workflow, the installer
  exits with a diagnostic instead of bypassing it. The post-verification
  `Unblock-File` step above removes MOTW only; it does not weaken the effective
  policy.
- Installation is current-user scoped and does not require elevation or change
  the permanent system `PATH`.

## Known limits

- Full is Windows-only. Core is architecture-neutral as a package, but Psh
  `v0.1.0` targets Windows rather than providing a cross-platform POSIX layer.
- Psh is a command compatibility layer, not Bash, a POSIX environment, or a
  general `.sh` runtime.
- Tier 2 PowerShell-backed commands implement documented subsets and reject
  unsupported syntax with exit code `2`. Full native `rg`, `fd`, `jq`, and
  `bat` follow their pinned tools' argument contracts.
- Interactive editing, key bindings, completion display, and terminal behavior
  depend on PSReadLine and the host's virtual-terminal capabilities.
- PSCompletions is excluded from `v0.1.0`. Git completion is provided by a
  Psh-owned offline adapter and does not import PSCompletions.
- Separate Full x64 and ARM64 packages contain matching native tools, but that
  packaging fact is not a claim that the ARM64 CI matrix or Goal 7 VM
  acceptance has completed. The candidate CI contract requires native ARM64
  Windows PowerShell 5.1 and PowerShell 7 processes and rejects x64 emulation;
  success under emulation does not establish native ARM64 support.

## Version and license

- Version: `0.1.0`; intended tag: `v0.1.0`.
- Psh-owned source and documentation are licensed under GNU GPL v3.0 or later
  (`GPL-3.0-or-later`); the complete text is in `LICENSE`.
- Bundled PSReadLine and Full native tools retain their upstream licenses. See
  `THIRD_PARTY_NOTICES.md`, `sbom.spdx.json`, and the `licenses` directory in
  each offline package.
