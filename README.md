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

产物将安装到 `work/crossover-port/stage`，完全独立隔离，不会影响本机已有的 CrossOver 应用与 Bottles。

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

GitHub Actions 默认使用 `xcode-27` 托管预览节点，构建 macOS 27+ Apple Silicon＋Rosetta 2 的 x86_64 Wine 核心。分支 push 和 PR 执行源码与语法检查；手动运行执行完整构建并上传产物；推送 `v*` 标签在构建成功后自动创建预发布 Release。

每次发布提供运行包、对应源码、许可证、构建来源和 SHA256 校验摘要。Wine 与编译依赖从锁定归档开始，在独立工作目录构建；MoltenVK 使用已校验的官方 macOS 二进制归档。两套 Wine 核心启用 Vulkan，运行包包含 x86_64 MoltenVK。完整远端构建与目标设备播放验收状态以实际结果为准。

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
Portable-package-only releases keep the current Whisky runtime channel in place.

The build/release workflow refreshes the channel after publishing. Release publication
or edits also trigger the channel workflow. After adding runtime assets to an existing
release, run **Publish Wine runtime channel** from Actions; leave the release tag empty
for automatic selection or provide a specific tag. Its authenticated GitHub API access
runs only in CI; client downloads use public HTTPS endpoints.
