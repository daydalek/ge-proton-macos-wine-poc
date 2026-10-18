# Source attribution

This project ports and adapts existing Wine multimedia work to macOS. Original
file copyright notices, author credits and applicable license terms are retained.
Project additions cover macOS rendering, child-window coordinates, WoW64 cleanup,
source preparation, isolated builds and diagnostics.
The project-authored `patches/crossover/wined3d-backend-selection.patch` adds
per-process Wine graphics builtin routing for Whisky's `WINED3DMETAL=0`;
it is not a port of an upstream Whisky loader-switch patch.
The project-authored `patches/crossover/i386-hotpatch-prologue.patch` adapts
Clang i386 `DECLSPEC_HOTPATCH` code generation and `winebuild --builtin` to emit
traditional Windows `90 90 90 90 90 | 8b ff` hotpatch prologues.

| Upstream | Version / provenance | Use |
| --- | --- | --- |
| [Wine](https://gitlab.winehq.org/wine/wine), [source mirror](https://github.com/wine-mirror/wine) | wine-11.0; syscall parameter-normalization wrappers ported from commit f43402c | Upstream Wine implementation and baseline build; the ported wrappers normalize small integer syscall arguments whose upper bits the Win64 ABI leaves undefined but clang-built Unix code assumes extended; retain source AUTHORS and license files |
| [CodeWeavers CrossOver FOSS sources](https://www.codeweavers.com/crossover/source) | 26.3.0; archive SHA-256 in configs/crossover-source-lock.json | CrossOver Wine base, macOS drivers and existing Rosetta thunk adaptation |
| [ValveSoftware/wine](https://github.com/ValveSoftware/wine) | 46b29104e3741fe23bf5e2547196a253aab88c89 | GE PoC Wine base and prerequisite implementations |
| [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) | GE-Proton11-7; c191f35dcebbeccfacd3b4c6f6eea026e588c1c2 | 64 multimedia patches and supporting hotfix; retain individual patch authors including GloriousEggroll and atty303 |
| [vkd3d](https://gitlab.winehq.org/wine/vkd3d) | Henri Verbeet, MR 2063, commit 2d2b02426363c8fb3bb02388a1d945ec2e4b7353 | Backport partial shader I/O initialization for the Vulkan renderer; LGPL-2.1-or-later and original author credit retained |
| [WineForge](https://github.com/Alien4042x/WineForge/blob/main/dlls/wow64cpu/cpu.c) | Reference file SHA-256 0fc33bffbd7066449853547d9a4c25a352cb7a1d6c6f1e1e4518f3caf7839afc | Rosetta thunk adaptation in the GE/Valve PoC; copyright/license header retained. CrossOver branch uses its existing CodeWeavers implementation |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | 9047fa1b084f76b1b4d065af2d743df1b40dfb56 | Broad dependency-satisfied built-in software decoding/demuxing/parsing and bitstream filters; limited sample-generation encoders/muxers; LGPL-2.1-or-later configuration in scripts/build-deps.sh, without GPL/nonfree/version3 components or external-library autodetection; license copies in licenses/ |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | 1.4.2; official macOS binary archive with locked SHA-256 | Vulkan-to-Metal runtime; x86_64 slice retained for Rosetta; original bundled license notices in licenses/MoltenVK-LICENSE.txt |
| [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) | 1.4.357; locked source archive | Vulkan development headers; Apache-2.0 and MIT notices retained in licenses/ |
| [FreeType](https://freetype.org/) | 2.13.3 | Font support; FTL license copy in licenses/ |
| [GnuTLS](https://www.gnutls.org/) | 3.8.13; archive digest in configs/dependency-lock.json | Wine bcrypt asymmetric cryptography and Schannel TLS; library LGPL-2.1-or-later; tools and optional PKCS#11/TPM/IDN dependencies disabled |
| [GMP](https://gmplib.org/) | 6.3.0 | Multiprecision arithmetic for Nettle/Hogweed; upstream LGPL-3.0-or-later / GPL-2.0-or-later dual licensing retained |
| [Nettle](https://www.lysator.liu.se/~nisse/nettle/) | 3.10.2 | GnuTLS cryptographic primitives, including Hogweed; upstream LGPL-3.0-or-later / GPL-2.0-or-later dual licensing and individual file notices retained |
| [libtasn1](https://www.gnu.org/software/libtasn1/) | 4.21.0 | ASN.1 parsing for GnuTLS; library LGPL-2.1-or-later |
| [libunistring](https://www.gnu.org/software/libunistring/) | 1.4.2 | Unicode support for GnuTLS; upstream LGPL-3.0-or-later / GPL-2.0-or-later dual licensing retained |
| [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) | 20260616 UCRT macOS universal | Windows PE build toolchain; component terms in upstream distribution |
| [GNU Autoconf, Bison and M4](https://www.gnu.org/software/) | Versions and archive digests in configs/dependency-lock.json | Build tools; original archive licenses retained |

Wine-derived changes generally follow LGPL-2.1-or-later. The Linux UAPI
ntsync_tmp.h headers retain GPL-2.0-only WITH Linux-syscall-note, as marked in
their original SPDX headers; corresponding texts are in licenses/. Individual bundled components
retain their own licenses; the top-level license applies to project-authored
work. Source archives include their upstream license and author records.

Versions, download URLs and SHA-256 digests are locked in configs/. Patch origins
and per-file licenses are recorded in patches/ and configs/source-license-inventory.json.
Public releases should pair binaries with the matching source revision, patches,
configuration and build recipes. CrossOver integration in this repository covers
the published open-source Wine core and isolated source builds.

The patch/file inventory is in configs/source-license-inventory.json. New source
builds insert dated modification notices and MODIFICATIONS.json while retaining
upstream file headers. Proton top-level BSD-3-Clause terms are included as
upstream context; individual Wine files use their own applicable terms.
