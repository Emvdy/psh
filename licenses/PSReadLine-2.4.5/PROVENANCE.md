<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# PSReadLine 2.4.5 provenance

## Package

- Gallery page: https://www.powershellgallery.com/packages/PSReadLine/2.4.5
- Fixed download URL: https://www.powershellgallery.com/api/v2/package/PSReadLine/2.4.5
- Resolved CDN URL: https://cdn.powershellgallery.com/packages/psreadline.2.4.5.nupkg
- Package SHA256: `cb9390e9733208456c234a7971d1ec4a917886c239502aab68f4b71aa4bba235`
- Package size: 234360 bytes
- Gallery SHA512 verification: passed
- The package contains a NuGet `.signature.p7s` CMS signed-data entry. The
  entry parsed successfully, but its trust chain was not independently
  validated during this vendoring step.

The nupkg passed CRC validation and checks for absolute paths, parent path
segments, symlinks, case-insensitive duplicate paths, encrypted entries, and
unexpected `.exe` files.

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

## Source revision

- Repository: https://github.com/PowerShell/PSReadLine
- Annotated tag: `v2.4.5`
- Tag object: `da9e153e3185ed333926cc6da5834f29f03ddc14`
- Peeled commit: `98d5610f7210924b79f553d982e10a9bd64dd52f`

The package nuspec does not include NuGet repository commit metadata. The
fixed upstream tag is recorded as release-source evidence, not as a claim
that the compiled nupkg was reproducibly rebuilt during this step.

## License

- SPDX identifier: `BSD-2-Clause`
- Vendored file: `licenses/PSReadLine-2.4.5/LICENSE.txt`
- Vendored SHA256: `25c2fdfcdc653f65629233f5ef217a83287733d3c0299c207b0bca865508c463`
- Vendored size: 1324 bytes
- Fixed source URL: https://raw.githubusercontent.com/PowerShell/PSReadLine/98d5610f7210924b79f553d982e10a9bd64dd52f/License.txt
- Fixed-source SHA256: `577273b040bdddb01b02768d9ad07fcb40415479fc2e65c8287294c6abf56de6`

The vendored license is the original file extracted byte-for-byte from the
nupkg. It differs from the fixed-commit source file only by CRLF versus LF
line endings. The package contains no separate NOTICE file.
