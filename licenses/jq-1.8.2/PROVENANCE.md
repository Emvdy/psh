<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# jq 1.8.2 provenance

## Source revision

- Repository: https://github.com/jqlang/jq
- Tag: `jq-1.8.2`
- Commit: `34f7186b86743a083a589741b6cea95293524108`

## Release assets

| Architecture | Asset ID | Fixed URL | Asset and installed SHA256 |
| --- | ---: | --- | --- |
| x86_64 | 453012788 | https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe | `a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627` |
| aarch64 | 453012789 | https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-arm64.exe | `083b5377392bc57cf27052b6d20a2d927770683bca844632901ff38b4b7b0ac7` |

The release URLs identify fixed versioned assets but are not treated as immutable trust anchors;
the recorded hashes are authoritative. The numeric asset API URLs are
`https://api.github.com/repos/jqlang/jq/releases/assets/453012788`
and `https://api.github.com/repos/jqlang/jq/releases/assets/453012789`. The release assets are
the executables themselves, so archive and installed hashes are identical. Their PE machines
are `0x8664` for x86_64 and `0xAA64` for aarch64.

## License

- SPDX expression: `MIT AND LicenseRef-jq-embedded-notices`
- `COPYING`: 7887 bytes, SHA256 `ad2b4a266b2268939c1446979759706077421cf906a203aa188c6f396e8cfd74`
- Fixed source: https://raw.githubusercontent.com/jqlang/jq/34f7186b86743a083a589741b6cea95293524108/COPYING

The complete upstream `COPYING` file is retained. It includes jq's MIT license plus the
embedded dtoa, ICU, Heimdal, and NetBSD notices and must not be reduced to the MIT text alone.
