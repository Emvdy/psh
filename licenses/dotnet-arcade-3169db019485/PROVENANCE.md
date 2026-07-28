<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# dotnet/arcade managed FileCatalog provenance

## Source revision

- Repository: https://github.com/dotnet/arcade
- Commit: `3169db01948537e61a9102477fab4a39663ba79d`
- Commit subject: `Add managed FileCatalog MSBuild task (#17098)`
- License: MIT, copyright .NET Foundation and Contributors
- Fixed license URL: https://raw.githubusercontent.com/dotnet/arcade/3169db01948537e61a9102477fab4a39663ba79d/LICENSE.TXT
- Fixed license SHA256: `ae48df11a335dc1a615f4f938b69cba73bcf4485c4f97af49b38efb0f216353b`

The retained `LICENSE.TXT` adds one terminal LF to the 1115-byte upstream
file. Removing that LF reproduces the fixed-source bytes and SHA256. The
retained file SHA256 is
`cfc21f5e8bd655ae997eec916138b707b1d290b83272c02a95c9f821b8c87310`.

## Vendored files

| File | Upstream path | Upstream SHA256 | Vendored SHA256 |
| --- | --- | --- | --- |
| `CatalogBuilder.cs` | `src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogBuilder.cs` | `bee5cdeb03d46f3fc11220d145d120c8eb45235a38962d4f7d175e55fc1ccc53` | `6736fb213729cd9777b2b96c25dd0ad3238d4b7977ce5b455cf134d3595f0d07` |
| `CatalogEntry.cs` | `src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogEntry.cs` | `a9d3ccfa7ec3ce989fa5582fc26e1a68ecd44c7e039c5b130a969c228917c501` | `77a594a1c88f4ac952a5b9d89f877bc05f6312cac2d338383c7459694f6b9bdf` |
| `CatalogMemberEncoder.cs` | `src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogMemberEncoder.cs` | `bf9997625bce5f75dfcaf44b9c2f7f05c50f49b05828f51515b55b734352824d` | `45a1c2b0c82f17bbae7f03272ab0efa0156795fefdaed7a1efc211443e44c0b4` |
| `CatalogOids.cs` | `src/Microsoft.DotNet.Build.Tasks.FileCatalog/CatalogOids.cs` | `2a06d1c3ede8aa08c2f586c630582a0ed76e6e594f9076bbfb6192929200915b` | `5ca7f357b8677df86664bd7dbfca57e5918c4eb72b62347ae47de54708300469` |

The original files were retrieved and hashed from the exact commit above.
`GenerateFileCatalog.cs` was intentionally not vendored because it introduces
Microsoft.Build dependencies that the standalone CLI does not need.

## Psh modifications

Psh retains the Arcade CTL and unsigned PKCS#7 encoding design, with these
compatibility and determinism changes:

- SHA256 members include the `1.3.6.1.4.1.311.12.2.1` `FilePath` name/value
  attribute expected by PowerShell `CatalogHelper`.
- Members sort by raw identifier and logical relative path. Legacy SHA1 marker
  members carry no path and deduplicate by identifier; SHA256 path members
  deduplicate only identical identifier/path tuples, so identical bytes at
  distinct paths remain distinct catalog entries.
- A project-owned `net10.0` CLI validates relative Windows paths, rejects
  ordinal-ignore-case duplicates and empty input files, and accepts explicit
  logical-path/source-path mappings.
- The project contains no `PackageReference` and uses only the .NET shared
  framework plus these four vendored Arcade source files.
