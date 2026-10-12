# Wine 多媒体便携包

适用于 Apple Silicon Mac＋Rosetta 2，Wine 宿主核心为 x86_64，支持 32/64 位 Windows 程序。最低 macOS 版本见包内 `portability.json` 的 `minimum_macos_actual`。

在解压目录中运行：

```bash
./run.sh media "/absolute/path/to/game.exe"
./probe.sh media x86 play wmv2 default
./probe.sh media x64 play wmv2 default
```

`media` 为 GE 多媒体修复版，`baseline` 为上游 Wine 对照版。游戏运行目录自动设置为 EXE 所在目录。

Prefix、缓存与日志默认保存在 `~/Library/Application Support/GE-Proton macOS Wine PoC`。使用独立数据目录测试：

```bash
WINE_POC_DATA="$HOME/wine-media-test" ./run.sh media "/absolute/path/to/game.exe"
```

发布包采用 ad-hoc 签名。构建静态检查覆盖文件架构、依赖、签名和部署目标；游戏播放验收需要在目标设备进行。

本项目代码采用 LGPL-2.1-or-later；第三方源码沿用原许可证。见包内 `LICENSE`、`COPYING.LIB`、`UPSTREAMS.md` 和 `licenses/`。对应源码与构建配方随同版本的 sources 归档提供。
