<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# fd 10.4.2 provenance

## Source revision

- Repository: https://github.com/sharkdp/fd
- Tag: `v10.4.2`
- Commit: `7027d45303b412be6fa9c09d689cc6276748fb38`

## Release assets

| Architecture | Asset ID | Fixed URL | Archive SHA256 | Installed SHA256 |
| --- | ---: | --- | --- | --- |
| x86_64 | 370661516 | https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-x86_64-pc-windows-msvc.zip | `b2816e506390a89941c63c9187d58a3cc10e9a55f2ef0685f9ea0eccaf7c98c8` | `4c9d082ee20f0d9e44881ac4e92adf765efc314d82103c53d7f576bd78dc5761` |
| aarch64 | 370662661 | https://github.com/sharkdp/fd/releases/download/v10.4.2/fd-v10.4.2-aarch64-pc-windows-msvc.zip | `4f9110c2d5b33a7f760bfa5510f4c113d828109f7277d421b1053a9943c0fc92` | `e5f456004d0f550b5a67a0e33415e6d40520c57d1d3860dafca9bd0e24a8f977` |

The release URLs identify fixed versioned assets but are not treated as immutable trust anchors;
the recorded archive hashes are authoritative. The numeric asset API URLs are
`https://api.github.com/repos/sharkdp/fd/releases/assets/370661516`
and `https://api.github.com/repos/sharkdp/fd/releases/assets/370662661`. Both ZIPs passed
archive integrity checks. Only the pinned `fd.exe` entry was retained; its PE machine is
`0x8664` for x86_64 and `0xAA64` for aarch64.

## License

- SPDX expression: `MIT OR Apache-2.0`
- `LICENSE-APACHE`: 10838 bytes, SHA256 `73c83c60d817e7df1943cb3f0af81e4939a8352c9a96c2fd00451b1116fa635c`
- `LICENSE-MIT`: 1082 bytes, SHA256 `322cfc7aa0c774d0eca3b2610f1d414de3ddbd7d8dd4b9dea941a13a6eb07455`

Each license byte stream was downloaded from `raw.githubusercontent.com` at the exact commit
above. The fixed commit-pinned source URLs are recorded in `tools/native-tools.lock.json`.
