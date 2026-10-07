---
title: Audio dependencies
date: 2026-10-05
status: active
scope: swift-native-audio-build
---

# Audio dependencies

We vendor source releases, not precompiled libraries. The `.tar.gz` files are
compressed source distributions, not binary dependencies. Generated `.a` libraries
and object files stay in the ignored `.build` directory; they are not checked in.
The app includes the compiled code through static linking.

For users building from the repository, the only tool installation is
`xcode-select --install`. After Apple's installer finishes, run `make install-macos`
from the repository root. Dependency compilation is automatic; no separate setup
command is needed for this installation path.

Normal builds are offline. The exact source archives are checked in, verified by
SHA-256 in `scripts/build-audio-dependencies.sh`, and built with Apple Command Line
Tools (`clang`, `make`, `ar`, shell). No Homebrew, CMake, pkg-config, OpenSSL, or
download server is required. The normal Make entry points run this step once and
reuse `.build/native-audio-<architecture>/install` until the build script/compiler
or SDK version or deployment minimum changes. The final app statically links the libraries and includes
their license notices in `Contents/Resources/ThirdPartyLicenses`.

| Library | Version | Upstream source |
| --- | --- | --- |
| libogg | 1.3.6 | https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz |
| libopus | 1.6.1 | https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz |
| libopusfile | 0.12 | https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz |

Archives are unmodified. Checksums come from https://xiph.org/downloads/ and
https://opus-codec.org/downloads/. Licenses are also retained in `licenses/`.
libopus uses its upstream architecture detection/optimizations. libopusfile's
local-file target compiles `info.c`, `internal.c`, `opusfile.c`, and `stream.c` with
`OP_HAVE_LRINTF=1`, matching the source list and macOS feature in upstream CMake.
The unused HTTP/URL library is excluded.

For direct SwiftPM/Xcode use, first run:

```sh
bash scripts/build-audio-dependencies.sh
bash scripts/build-search-dependencies.sh
```

Builds target the current host architecture (arm64 or x86_64), with macOS 26 as
the minimum. This is not a universal-binary build. On a failed build, fix the
reported cause and rerun; incomplete builds never create the `ready` stamp. After
an interrupted shell, remove the indicated `lock` directory only after verifying
that no dependency build is running. To force a clean rebuild, remove the matching
`.build/native-audio-<architecture>` directory while the build is stopped.

To upgrade, fetch a stable release from Xiph, verify its published checksum,
replace the archive and license, update the script/version documentation, and run
a clean build plus the decoder, streaming, waveform, and app regression tests.
No automatic upstream upgrades occur during a user's build.

## Native semantic search

Local Search also statically links checksum-pinned USearch and NumKong sources.
See [search dependencies](search-licenses/README.md) for versions, native dispatch,
build details, and license packaging. Normal Make entry points build both audio
and search dependencies automatically.

## CLSP native inference

The native voice-search integration uses Swift Tokenizers and a Kaldi-compatible Swift audio frontend. Their notices and the separately downloaded model's inherited licenses are recorded in [CLSP attribution](clsp-licenses/NOTICE.md). Release packaging copies `clsp-licenses/` into `Contents/Resources/ThirdPartyLicenses/CLSP`. Model weights are not checked in or bundled with the app; the prepared Core ML distribution includes its own copy of these notices.

The app also bundles the [Swift tokenizer dependency notices](swift-tokenizer-licenses/README.md) in `Contents/Resources/ThirdPartyLicenses/SwiftTokenizers`. These app dependencies are separate from the downloaded model assets.
