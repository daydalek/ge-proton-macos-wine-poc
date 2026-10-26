# GE-Proton macOS Wine PoC

简体中文 | [English](README.en.md)

把 **GE-Proton** 的多媒体解码与播放重构方案，移植到 **Apple Silicon (macOS / Rosetta 2)** 上的实验性 PoC 与补丁套件。

本项目基于 Wine、Valve Wine 与 CrossOver Wine 开源核心，移植 [GE-Proton11-7](https://github.com/GloriousEggroll/proton-ge-custom/tree/GE-Proton11-7) 的 64 个多媒体重构补丁。多媒体实现的核心重构工作来自 GloriousEggroll 及相关上游贡献者。

本项目的新增工作集中于 Apple Silicon／macOS 的构建适配、视频窗口呈现、坐标与尺寸修复，以及 WoW64 兼容性适配；完整来源、作者与许可证见 [UPSTREAMS.md](UPSTREAMS.md)。

主要解决 macOS 原生 Wine 环境下常见的音视频痛点：
- 缺失 GStreamer 多媒体管道导致游戏无法解码视频
- Quartz 视频回放崩溃与 DirectShow 32 位子窗口错位
- VMR7 渲染黑屏 / 透明窗口问题
- Rosetta 2 环境下的 WoW64 Thunk 异常与 Demuxer 析构崩溃

支持 **Valve Wine (GE-Proton 11-7)** 与 **CrossOver Wine 26.3** 两个源码基线。

Linux x86_64 的共享补丁构建、依赖安装、隔离回归与打包入口见 [Linux 构建说明](README.linux.md)。Linux 支持的实际验证范围以对应构建报告为准。

---

## 项目结构

```text
ge-proton-macos-wine-poc/
├── patches/                            # 核心移植补丁
│   ├── wine-ge/                       # 原生 Wine / GE-Proton 适配补丁 (平台支持、VMR7、Quartz、WoW64 等)
│   └── crossover/                     # CrossOver Wine 26.3 多媒体移植补丁
├── scripts/                            # 自动化构建与测试脚本
│   ├── build-deps.sh                  # 编译 x86_64 依赖 (FFmpeg, FreeType, autoconf 等)
│   ├── prepare.py                     # 拉取/准备源码并应用补丁
│   ├── build-wine.sh                  # 编译 GE-Proton Wine (baseline / media 变体)
│   ├── run-wine.sh / run-packaged.sh  # 运行 Wine 环境 / 游戏
│   ├── package.py                     # 打包为独立分发套件
│   ├── static-check.py                # 产物依赖与最低系统版本检查
│   └── crossover/                     # CrossOver Wine 专项构建脚本 (prepare-source.sh, build.sh)
├── tools/
│   ├── probes/                        # 交叉编译测试探针 (DirectShow 播放、子窗口、SEH 异常)
│   └── samples/                       # 音视频测试样片 (WMV2, MPEG-1, PCM)
├── configs/                            # 构建配置与源码/依赖版本锁定 (lockfile)
└── outputs/                            # 编译与打包产物输出目录
```

---

## 快速上手

### 环境准备

- Apple Silicon Mac（需安装 Rosetta 2：`softwareupdate --install-rosetta`）
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.9+、CMake、pkg-config、Git

### 方案 A：构建 GE-Proton 修复版 Wine

```bash
# 1. 下载并编译 x86_64 工具链与依赖 (FFmpeg 等)
bash scripts/build-deps.sh

# 2. 准备源码并打入补丁
python3 scripts/prepare.py

# 3. 编译集成多媒体补丁的 Wine (media 变体)
bash scripts/build-wine.sh media
```

> **提示**：如果需要纯净上游版本做对照测试，可执行 `bash scripts/build-wine.sh baseline`。

#### FFmpeg 格式覆盖

`scripts/build-deps.sh` 默认开启锁定 FFmpeg 源码中所有依赖满足的内置解码器、解封装器、解析器和码流过滤器，不再使用播放格式白名单。包括 WMA Lossless、AAC、Vorbis、Opus、FLAC、MPEG-4、HEVC、VP8/VP9 等；编码器、封装器和滤镜仍仅保留合成测试样片所需部分。

该配置关闭外部库自动检测、网络、硬件加速和 GPL/nonfree/version3 组件，保持 FFmpeg 的 LGPL-2.1-or-later 构建。它不是“包含所有第三方编解码器”的 FFmpeg；实际可用格式取决于源码与依赖，FFmpeg 可解码也不等于 Wine 已接入对应格式。

#### Wine 加密与 TLS

依赖构建同时编译私有 x86_64 GnuTLS、GMP、Nettle/Hogweed、libtasn1 和 libunistring；已有构建可单独运行 `bash scripts/build-crypto-deps.sh`，随后重新配置并编译 Wine。Wine 配置显式要求 GnuTLS，缺失时构建失败，不再静默生成无加密后端的运行库。Whisky 打包携带依赖并使用 `@rpath` 加载，不依赖 Homebrew 路径，也不关闭证书验证。完整 CI 会检查相关库及加密模块的可重定位加载名。各依赖许可证独立于 FFmpeg，见 [UPSTREAMS.md](UPSTREAMS.md)。

#### 运行游戏与回放验证

```bash
# 编译 DirectShow 等 Windows 测试探针 (.exe)
bash tools/probes/build-probes.sh

# 运行你的游戏或应用
bash scripts/run-wine.sh media /path/to/game.exe
```

---

### 方案 B：移植到 CrossOver Wine 26.3 源码

若已有或想基于官方 CrossOver Wine 26.3 源码构建：

```bash
# 1. 确保已执行过 scripts/build-deps.sh
# 2. 下载并解压 CrossOver Wine 源码，打入 GE 媒体补丁
bash scripts/crossover/prepare-source.sh

# 3. 编译 CrossOver Wine 核心
bash scripts/crossover/build.sh full

# (可选) 仅重新编译 12 个多媒体相关模块
bash scripts/crossover/build.sh media
```

补丁顺序统一记录在 `configs/crossover-patch-series.txt`。其中移植了上游 Wine 的 syscall 参数规范化包装（commit `f43402c`）：Unix 侧由 clang 编译，clang 假定调用方已对小整数参数（`BOOLEAN`/`UCHAR` 等）做零/符号扩展，而 Win64 ABI 不保证高位清零，Windows 程序传入的参数高位可能是垃圾，导致 Steam 的连接协程（`YieldingConnect`）无法启动。另外 `wine.inf` 会为 `steam.exe` / `steamwebhelper.exe` 写入默认的 `HKCU\Software\Wine\AppDefaults\<exe>\CommandLineAppend`，不会覆盖已有值；设为空字符串即可关闭。

产物将安装到 `work/crossover-port/stage`，完全独立隔离，不会影响本机已有的 CrossOver 应用与 Bottles。

#### Whisky 的 D3DMetal／WineD3D 切换

CrossOver 核心补丁支持 Whisky 已有的 `WINED3DMETAL=0`：将 `dxgi`、`d3d10`、`d3d10core`、`d3d11`、`d3d12` 的 builtin 加载路由到 `Wine/lib/wine/wined3d/{x86_64,i386}-windows/` 中的同次构建原版 DLL，不加载 Apple 的同名 Unix 桥接。完整构建和 Whisky 打包会生成这套文件；它们属于运行库，不依赖 GPTK 仓库的回滚备份，也不写入 Bottle。

因此可按程序选择 D3DMetal 或 WineD3D，而无需反复替换共享 DLL。`WINED3DMETAL` 未设置或不等于 `0` 时保持原有加载行为；DXVK／DXMT 的 native DLL 选择不变。指定 WineD3D 但配套 DLL 缺失时明确失败，不会静默使用 D3DMetal。直接从构建树启动仍使用构建树中的 Wine 实现。

`WINE_D3D_CONFIG=renderer=gl` 或 `renderer=gdi` 仍需配合 WineD3D 使用；GDI 模式禁用 3D，不能用“D3D11 设备创建成功”作为通过标准。本机制只负责 DLL 路由，不增加 WineD3D 或 D3D12 的图形能力。

#### i386 传统 Windows 热补丁入口兼容

`llvm-mingw`（Clang + LLD）在 `-fms-hotpatch` 下为 32 位 PE 函数生成 `66 90` 入口，并由链接器以 `0xcc` 填充节间空隙。`patches/crossover/i386-hotpatch-prologue.patch` 将 Clang i386 的 `DECLSPEC_HOTPATCH` 映射为 `__patchable_function_entry__(8, 6)` 与 `__noinline__`，由 `winebuild --builtin` 将带五字节 `0x90` 预留区的 `66 90` 入口改写为传统 `8b ff`（`mov edi, edi`），并为 `CreateFontIndirectA`、`GetGlyphOutlineA`、`EnumFontFamiliesExA`、`AppendMenuA`（连同已有的 `CreateWindowExA`、`SetWindowTextA`）补齐热补丁标注，兼容依赖 `90 90 90 90 90 | 8b ff` 入口假设的旧式汉化与注入组件。

#### WMP ActiveX 内嵌播放

`patches/crossover/wmp-activex-player2-embedding.patch` 为 ActiveX 宿主提供
IDL 生成的 `IWMPPlayer2` 接口、播放器属性与状态、暂停和关闭处理，以及重复
设置站点时的窗口保留。DirectShow 视频窗口跟随控件父窗口和尺寸。
macOS 内嵌播放优先使用 VMR9 独立视频表面；其他驱动沿用 DirectShow 默认选择。
补丁按宿主模式和驱动选择行为，可用于采用相同 WMP 接口的应用。

`full` 和 `media` 构建均包含 `wmp.dll`。通过以下探针检查接口、ATL 内嵌窗口和
静音播放；视频参数由调用者提供，建议使用超过 5 秒的文件：

```sh
bash tools/probes/build-probes.sh
wine tools/probes/wmp-probe-x86.exe
wine tools/probes/wmp-probe-x86.exe --embed
wine tools/probes/wmp-probe-x86.exe --embed 'Z:\path\to\video.wmv'
```

x64 验证使用 `wmp-probe-x64.exe`。返回码 0 表示探针通过；实际应用的画面、
同步和帧间隔需要在宿主内验证。当前实现范围为窗口化视频播放，完整 WMP 皮肤、
全屏和真正的无窗口视频另需实现。


#### WMReader 完整帧与嵌入播放修复

`winedmo-demuxed-frame-boundaries.patch` 将容器解复用后的完整帧标记传递到
FFmpeg 解析器，支持 ASF 中省略起始码的 VC-1 帧，并保留分片输入路径的解析行为。
`quartz-vmr9-backbuffer-scaling.patch` 在视频表面复制阶段缩放到可见区域，
修复视频缓冲大于嵌入窗口时的局部显示。
`wmp-volume-decibels.patch` 将播放器音量百分比按幅度对数换算为 DirectShow
分贝衰减，支持低音量设置；0 保持静音，100 保持满音量。

静音探针检查视频样本、连续时间戳及重复定位到开头后的输出：

```sh
wine tools/probes/wm-reader-video-probe-x86.exe 'Z:\path\to\video.wmv' 120 2
```

样本数使用 `0` 可完整读取至视频流末尾。x64 使用 `wm-reader-video-probe-x64.exe`。
实际画面、音量、同步和自然结束由宿主内播放验收。

#### DirectShow VFS 归档回退与旧版句柄兼容

`quartz-filesource-vfs-fallback.patch` 为 Wine DirectShow 文件源添加了对虚拟文件系统（VFS，如使用微软 Detours 钩取 Win32 文件 API 从封包内直接流式读取视频的汉化补丁或游戏引擎）的通用兼容：
- 当虚拟句柄不支持 `GetFileSizeEx` 时，自动回退到传统的 `GetFileSize`，修复了伪句柄导致 DirectShow 图构建抛出 `ERROR_INVALID_HANDLE` (0x80070006) 的缺陷；
- 针对仅拦截同步 `ReadFile` / `SetFilePointer` 而不支持重叠 I/O (Overlapped I/O) 的 VFS 句柄，提供同步定位读取回退与 `IAsyncReader` 请求调度，确保封包内嵌视频流无需手动解压即可在 Wine 下直接完整流畅播放。

---

## 打包与发布检查

把编译结果打成便携包，并检查最低系统兼容性：

```bash
# 1. 编译探针
bash tools/probes/build-probes.sh

# 2. 生成便携安装包 (默认输出至 outputs/wine-poc/)
python3 scripts/package.py

# 3. 静态检查 Mach-O 依赖与最低 macOS 版本
python3 scripts/static-check.py
```

便携包运行时生成的数据（prefix、缓存与日志）默认保存在：  
`~/Library/Application Support/GE-Proton macOS Wine PoC`  
（可通过设置环境变量 `WINE_POC_DATA=/path/to/data` 自定义）。

---

## 构建配置与环境变量

如需自定义构建参数，可编辑 [configs/build.env](configs/build.env) 或通过环境变量覆盖：

```bash
# 目标 macOS 部署版本 (默认 11.0)
export POC_MACOSX_DEPLOYMENT_TARGET=11.0

# 编译并发数
export POC_JOBS=8

# 自定义工作目录 (切换部署版本时建议使用干净目录)
export POC_WORK_DIR="$PWD/work"
```

---

## 开源协议

- 本仓库自研的脚本、探针代码与文档采用 **LGPL-2.1-or-later** 授权，详见 [COPYING.LIB](COPYING.LIB)。
- 第三方源码与补丁（Wine、GE-Proton、FFmpeg、FreeType 等）保留其原有许可证，版本与上游说明见 [UPSTREAMS.md](UPSTREAMS.md)，许可证文本归档于 `licenses/`。


## CI 构建与发布

GitHub Actions 默认使用 `xcode-27` 托管预览节点，构建 macOS 27+ Apple Silicon＋Rosetta 2 的 x86_64 Wine 核心；同时在 `ubuntu-24.04` 节点上并行构建 Linux amd64 运行时（见 [README.linux.md](README.linux.md)）。分支 push 和 PR 执行源码与语法检查；手动运行执行两平台完整构建并上传产物；推送 `v*` 标签在构建成功后自动创建预发布 Release。

每次发布提供 Whisky 的 `Libraries.tar.gz`、`Libraries-sources.tar.gz`、版本 plist、隐私和静态检查报告、构建来源及 SHA256 校验摘要；Linux 侧统一添加 `-linux-amd64` 后缀，提供 `wine-linux-amd64.tar.gz`、`wine-linux-amd64-sources.tar.gz`、`linux-release-manifest.json` 等资产与 `SHA256SUMS-linux-amd64` 校验。Wine 与编译依赖从锁定归档开始，在独立工作目录构建；MoltenVK 使用已校验的官方 macOS 二进制归档。CI 编译 CrossOver 26.3 Wine＋GE 多媒体与全屏修复核心，Libraries 包含 x86_64 MoltenVK，并启用 Vulkan。本地双核心便携打包脚本保留用于开发验证。完整远端构建与目标设备播放验收状态以实际结果为准。

先从 Actions 手动执行一次构建，确认产物后创建版本标签：

```bash
git tag v0.1.0
git push origin v0.1.0
```

仓库变量 `MACOS_BUILD_RUNNER_JSON` 可覆盖节点选择，例如 `["self-hosted", "macOS", "ARM64", "macos-27"]`。工作流会校验实际系统、arm64 宿主和 Rosetta 环境。

## Whisky runtime update channel

Whisky reads the public static manifest at
`https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist`.
The dedicated branch contains only this public manifest and uses an anonymous CI author.
The manifest records the runtime version, SHA-256, component versions and exact Release download URL.

The publisher accepts stable releases and prereleases carrying both `Libraries.tar.gz`
and `WhiskyWineVersion.plist`. It verifies the archive digest, preserves newer runtime
versions already in the channel, and requires a version bump for changed archives.
The channel selects releases with the complete Whisky runtime assets.

The build/release workflow refreshes the channel after publishing. Release publication
or edits also trigger the channel workflow. After adding runtime assets to an existing
release, run **Publish Wine runtime channel** from Actions; leave the release tag empty
for automatic selection or provide a specific tag. Its authenticated GitHub API access
runs only in CI; client downloads use public HTTPS endpoints.

### Independent Whisky Libraries build

The CI builds the **CrossOver 26.3 Wine + GE media** core and publishes **Libraries.tar.gz**, **Libraries-sources.tar.gz**
and **WhiskyWineVersion.plist**. The runtime asset is the Whisky Libraries package.
`Libraries/Wine` contains the current build's **CrossOver** core and its runtime dependencies;
`Libraries/DXVK` supplies the digest-pinned DXVK-macOS 1.10.3 payload. The bootstrap archive
is used only for DXVK. Current Wine binaries always come from this run's stage.

Full builds prepare the digest-locked official CrossOver sources and apply the GE multimedia
port, stale fullscreen rectangle, OpenGL flush flag, macOS fullscreen surface, WoW64
present-rectangle fixes, default Steam `CommandLineAppend` values in `wine.inf`, and upstream
wine's **syscall parameter-normalization wrappers** (commit `f43402c`; the Unix side is built with
clang, which assumes callers zero/sign-extend small integer arguments, while the Win64 ABI leaves
their upper bits undefined — without it Steam's CM connection never starts). The ordered patch
series lives in `configs/crossover-patch-series.txt`. Both i386 and x86_64 Windows modules are
built and installed.
`Libraries-sources.tar.gz` carries the exact patched CrossOver tree, official source archive,
dependency archives and build recipes. Provenance identifies the CrossOver baseline explicitly.

The runtime version is `11.0.(GITHUB_RUN_NUMBER + 1)`, independent of the public release tag.
The inner plist records installed components; the outer plist additionally records the
exact archive SHA-256. `SHA256SUMS` covers the Libraries package, corresponding sources,
privacy and static-check reports, release manifest, release notes and version plist.

Before packing, the publisher removes development headers/import archives and debug info,
remaps personal build paths, preserves PE builtin markers, applies ad-hoc Mach-O signatures,
checks symlinks and private-state filenames, scans payload bytes, and anonymizes tar headers.
The package includes component license texts. Static checks inspect the final Libraries tree
for module architectures, dependencies, signatures and macOS deployment requirements.
Detailed build/test logs stay in the CI job.

On a tag build, CI creates a draft release with all files, then publishes it after upload.
The channel refresh uses that exact tag and verifies the uploaded archive digest against
its version plist. Existing complete releases preserve their published assets; incomplete
existing releases stop publication and require review. Manual CI runs retain their output
as downloadable Actions artifacts named `whisky-libraries`.
The `libraries_only` manual check currently repackages the pinned v0.1.0 Valve-based Libraries core and compiles
x86/x64 launch probes using the locked toolchain.

The current payload requires macOS 27+ Apple Silicon with Rosetta 2. DXMT and the licensed
GPTK payload retain their separate runtime capability gates in Whisky.

完整 CI 构建会读取最终 Libraries 中的 FFmpeg 动态库，检查常见游戏格式及 LGPL 许可，并发布 `Libraries-ffmpeg-capabilities.json` 格式清单（同时纳入 `release-manifest.json` 和 `SHA256SUMS`）。检查不启动 Wine 或游戏，也不代表实际播放验收；缺少 WMA Lossless、AAC 等关键解码器时构建失败。`libraries_only` 仅检查旧版发布核心的打包与启动，不重编 FFmpeg，也不验证当前格式覆盖；要发布新解码库，请使用默认完整构建。
