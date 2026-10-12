# Source attribution

This project ports and adapts existing Wine multimedia work to macOS. Original
file copyright notices, author credits and applicable license terms are retained.
Project additions cover macOS rendering, child-window coordinates, WoW64 cleanup,
source preparation, isolated builds and diagnostics.

| Upstream | Version / provenance | Use |
| --- | --- | --- |
| [Wine](https://gitlab.winehq.org/wine/wine), [source mirror](https://github.com/wine-mirror/wine) | wine-11.0 | Upstream Wine implementation and baseline build; retain source AUTHORS and license files |
| [CodeWeavers CrossOver FOSS sources](https://www.codeweavers.com/crossover/source) | 26.3.0; archive SHA-256 in configs/crossover-source-lock.json | CrossOver Wine base, macOS drivers and existing Rosetta thunk adaptation |
| [ValveSoftware/wine](https://github.com/ValveSoftware/wine) | 46b29104e3741fe23bf5e2547196a253aab88c89 | GE PoC Wine base and prerequisite implementations |
| [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) | GE-Proton11-7; c191f35dcebbeccfacd3b4c6f6eea026e588c1c2 | 64 multimedia patches and supporting hotfix; retain individual patch authors including GloriousEggroll and atty303 |
| [vkd3d](https://gitlab.winehq.org/wine/vkd3d) | Henri Verbeet, MR 2063, commit 2d2b02426363c8fb3bb02388a1d945ec2e4b7353 | Backport partial shader I/O initialization for the Vulkan renderer; LGPL-2.1-or-later and original author credit retained |
| [WineForge](https://github.com/Alien4042x/WineForge/blob/main/dlls/wow64cpu/cpu.c) | Reference file SHA-256 0fc33bffbd7066449853547d9a4c25a352cb7a1d6c6f1e1e4518f3caf7839afc | Rosetta thunk adaptation in the GE/Valve PoC; copyright/license header retained. CrossOver branch uses its existing CodeWeavers implementation |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | 9047fa1b084f76b1b4d065af2d743df1b40dfb56 | Media decode and sample generation; configuration in scripts/build-deps.sh; license copies in licenses/ |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | 1.4.2; official macOS binary archive with locked SHA-256 | Vulkan-to-Metal runtime; x86_64 slice retained for Rosetta; original bundled license notices in licenses/MoltenVK-LICENSE.txt |
| [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) | 1.4.357; locked source archive | Vulkan development headers; Apache-2.0 and MIT notices retained in licenses/ |
| [FreeType](https://freetype.org/) | 2.13.3 | Font support; FTL license copy in licenses/ |
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
