<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# ripgrep 15.2.0 provenance

## Source revision

- Repository: https://github.com/BurntSushi/ripgrep
- Annotated tag: `15.2.0`
- Tag object: `6ec72defacfb042f203ca0b4bf2513a0a5505a7e`
- Peeled commit: `e89fff89ac9af12e8d4ce9d5fd07beb408ca730f`

## Release assets

| Architecture | Asset ID | Fixed URL | Archive SHA256 | Installed SHA256 |
| --- | ---: | --- | --- | --- |
| x86_64 | 478119643 | https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip | `71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5` | `14231169855ec5205cf5a1b6f1db358ff4aed4247c86b69ce8aae647c77f6680` |
| aarch64 | 478119680 | https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-pc-windows-msvc.zip | `e4abca10c3a64ebea742667dd7009449d49403db5460dd6873e389fa2945360f` | `d33a29a9ef03c9f4c03be9e8d88498e6e2d2e566d64cdbdef97f9afc8f13120c` |

The release URLs identify fixed versioned assets but are not treated as immutable trust anchors;
the recorded archive hashes are authoritative. The numeric asset API URLs are
`https://api.github.com/repos/BurntSushi/ripgrep/releases/assets/478119643`
and `https://api.github.com/repos/BurntSushi/ripgrep/releases/assets/478119680`. Both ZIPs passed
archive integrity checks. Only the pinned `rg.exe` entry was retained; its PE machine is
`0x8664` for x86_64 and `0xAA64` for aarch64.

## License

- SPDX expression: `Unlicense OR MIT`
- `COPYING`: 126 bytes, SHA256 `01c266bced4a434da0051174d6bee16a4c82cf634e2679b6155d40d75012390f`
- `LICENSE-MIT`: 1081 bytes, SHA256 `0f96a83840e146e43c0ec96a22ec1f392e0680e6c1226e6f3ba87e0740af850f`
- `UNLICENSE`: 1211 bytes, SHA256 `7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c`

Each license byte stream was downloaded from `raw.githubusercontent.com` at the exact peeled
commit above. The fixed commit-pinned source URLs are recorded in `tools/native-tools.lock.json`.
