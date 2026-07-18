<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# PSCompletions 6.10.0 provenance

## Package

- Gallery page: https://www.powershellgallery.com/packages/PSCompletions/6.10.0
- Fixed download URL: https://www.powershellgallery.com/api/v2/package/PSCompletions/6.10.0
- Resolved CDN URL: https://cdn.powershellgallery.com/packages/pscompletions.6.10.0.nupkg
- Package SHA256: `9f2bf9c6d143d2dc0c50a531b964f9f6ff30393077405914ca7d746ef8e38cb7`
- Package size: 59176 bytes
- Gallery SHA512 verification: passed

The nupkg passed CRC validation and checks for absolute paths, parent path
segments, symlinks, case-insensitive duplicate paths, encrypted entries, and
unexpected `.exe` files. It does not contain a `.signature.p7s` entry.

## Offline runtime trust anchor

The canonical package path, byte length, and SHA256 of each of the seven
selected runtime files are hardcoded in
`scripts/Test-InteractiveDependencies.ps1`. Those values were recorded from
the byte-for-byte extraction of the package identified by the fixed package
SHA256 above, after the Gallery SHA512 and archive CRC checks passed.

The offline verifier requires the hardcoded manifest, the lock-file entries,
the package selection list, and the checked-out bytes to agree exactly. The
lock is data under test rather than the source of trust, so changing a runtime
file and its lock hash together does not authorize a same-version byte change.
The separate immutable-commit comparison below remains additional provenance
for the selected script and data content.

## Source revision

- Repository: https://github.com/abgox/PSCompletions
- Release commit: `427212789d4df206d37d1d3c3d12b4341ac73644`
- Commit subject: `release(module): 6.10.0`
- Commit time: `2026-07-16T21:23:26+08:00`
- Tree: `33620d3218510688f3f4305ddfefc6343cdfdcd0`

The upstream repository has no Git tags, and the nupkg nuspec has no NuGet
repository commit metadata. Each of the seven selected runtime files was
compared with the corresponding file at the release commit. All content
matched after ignoring only the nupkg's CRLF versus repository LF line
endings. The vendored files retain the original nupkg bytes.

## License

The Gallery nupkg does not contain a license file. Its nuspec points to the
floating URL `https://github.com/abgox/PSCompletions/blob/main/LICENSE`, which
is not used as the sole license evidence. The license retained here came from
the immutable release commit whose runtime content matches the package.

- SPDX identifier: `MIT`
- Vendored file: `licenses/PSCompletions-6.10.0/LICENSE`
- Vendored SHA256: `ff823ba75e90563c3876fbe28df694c0cde5817c721397af7879db19e8ecdd5b`
- Vendored size: 1090 bytes
- Fixed source URL: https://raw.githubusercontent.com/abgox/PSCompletions/427212789d4df206d37d1d3c3d12b4341ac73644/LICENSE

The fixed raw file exactly matches the license blob at the release commit.
Neither the selected source tree nor the nupkg contains a separate NOTICE
file.

## Runtime audit note

The unmodified module contains `Invoke-Expression` in template replacement
code, starts an update job on import, can contact upstream endpoints, and
writes state below `$PSScriptRoot/data`. These facts must be considered by the
integration and acceptance tests; vendoring does not assert that default
import behavior satisfies Psh's no-startup-download requirement.
