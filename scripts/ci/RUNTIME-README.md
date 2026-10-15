# Wine 多媒体便携包

适用于 Apple Silicon Mac＋Rosetta 2，Wine 宿主核心为 x86_64，支持 32/64 位 Windows 程序。最低 macOS 版本见包内 `portability.json` 的 `minimum_macos_actual`。

在解压目录中运行：

```bash
./run.sh media "/absolute/path/to/game.exe"
./probe.sh media x86 play wmv2 default
./probe.sh media x64 play wmv2 default
```

`media` 为 GE 多媒体修复版，`baseline` 为上游 Wine 对照版。游戏运行目录自动设置为 EXE 所在目录。

当前构建默认启用 FFmpeg 中所有依赖满足的内置软件解码器、解封装器、解析器和码流过滤器，不包含额外第三方解码库或硬件加速组件。FFmpeg 保持 LGPL-2.1-or-later 配置。格式可解码不等于 Wine 已接入对应格式；游戏播放仍需实际确认。

Prefix、缓存与日志默认保存在 `~/Library/Application Support/GE-Proton macOS Wine PoC`。使用独立数据目录测试：

```bash
WINE_POC_DATA="$HOME/wine-media-test" ./run.sh media "/absolute/path/to/game.exe"
```

发布包采用 ad-hoc 签名。构建静态检查覆盖文件架构、依赖、签名和部署目标；游戏播放验收需要在目标设备进行。

本项目代码采用 LGPL-2.1-or-later；第三方源码沿用原许可证。见包内 `LICENSE`、`COPYING.LIB`、`UPSTREAMS.md` 和 `licenses/`。对应源码与构建配方随同版本的 sources 归档提供。

Vulkan diagnostics (x86_64 Wine under Rosetta with bundled MoltenVK):

```sh
./run.sh media "$PWD/vulkan-probe-x64.exe"
./run.sh media "$PWD/vulkan-probe-x86.exe"
./run.sh media "$PWD/vulkan-probe-x64.exe" --surface
```

The surface probe creates a temporary window and checks Win32 surface formats. Game and Steam rendering require separate acceptance.

For a Chromium host that needs application-specific arguments, the media core
supports a `REG_SZ` value named `CommandLineAppend` under
`HKCU\Software\Wine\AppDefaults\<executable-name>`. It appends the value to
child process command lines for that executable. The setting is opt-in.

For Steam CEF compatibility in this isolated prefix:

```sh
./run.sh media "$PWD/media/bin/../lib/wine/x86_64-windows/reg.exe" add 'HKCU\Software\Wine\AppDefaults\steamwebhelper.exe' /v CommandLineAppend /t REG_SZ /d '--no-sandbox --in-process-gpu --disable-gpu' /f
```

This selects CEF software rendering in the browser process and disables its
Windows sandbox, matching the tested compatibility mode. Use it in a dedicated
Steam prefix. Remove the setting with `reg.exe delete` and `/v CommandLineAppend`.
A child-process regression probe checks quoting, Unicode and configuration bounds:

```sh
./run.sh media "$PWD/command-line-probe-x64.exe"
./run.sh media "$PWD/command-line-probe-x86.exe"
```

Device-notification and debug-symbol regression probes:

```sh
./run.sh media "$PWD/device-notify-probe-x64.exe"
./run.sh media "$PWD/device-notify-probe-x86.exe"
./run.sh media "$PWD/dbghelp-probe-x64.exe"
./run.sh media "$PWD/dbghelp-probe-x86.exe"
./run.sh media "$PWD/dwarf-divisor-probe-x64.exe" "Z:$PWD/dwarf-divisor-fixture-x64.dll"
./run.sh media "$PWD/dwarf-divisor-probe-x86.exe" "Z:$PWD/dwarf-divisor-fixture-x86.dll"
```
