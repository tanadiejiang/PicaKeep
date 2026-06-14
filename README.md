# PicaKeep CLI

PicaKeep 仓库已经包含 CLI 入口 [bin/picakeep.dart](/D:/Flutter_Projucts/PicaComic/PicaKeep/bin/picakeep.dart)，但系统要能直接执行 `picakeep`，还需要额外的构建或安装步骤。

当前仓库的 CLI 依赖链里仍包含部分 Flutter / native-asset 依赖，所以不同 Dart SDK 上可用的构建方式并不完全一致：

- 优先尝试 `dart build cli`
- 旧版环境再尝试 `dart compile exe`
- 只有在 `dart run bin/picakeep.dart` 本身可运行时，才会回退到 `dart run` launcher

如果三条路径都失败，说明当前 CLI 依赖链里还有 Flutter-only 模块需要继续剥离；这时脚本会直接失败，并把详细日志写入 `build/cli/build.log`。

## 1. 开发期运行

直接从源码运行：

```bash
dart run bin/picakeep.dart -h
dart run bin/picakeep.dart -v
dart run bin/picakeep.dart run
```

这条路径最适合开发、调试和排查 CLI 参数问题。

## 2. 构建可执行入口

Linux / Debian：

```bash
bash tool/build_cli.sh
```

Windows PowerShell：

```powershell
.\tool\build_cli.ps1
```

脚本会统一生成 CLI launcher：

```text
Linux:   build/cli/picakeep
Windows: build\cli\picakeep.cmd
```

它的行为如下：

- 如果 `dart build cli` 成功，launcher 会启动原生 CLI bundle
- 如果 `dart compile exe` 成功，launcher 会启动编译出的单文件二进制
- 如果两种原生构建都不可用，但源码运行可用，launcher 会回退到 `dart run bin/picakeep.dart`
- 如果源码运行本身也不可用，脚本会失败，不会生成伪可用 launcher

验证：

```bash
./build/cli/picakeep -h
./build/cli/picakeep -v
```

```powershell
.\build\cli\picakeep.cmd -h
.\build\cli\picakeep.cmd -v
```

构建日志会写到：

```text
build/cli/build.log
```

注意：`build/linux/x64/debug/bundle/` 和 `build/windows/x64/runner/Debug/` 是 Flutter App bundle，不是 CLI 安装目录。即使里面有 `picakeep` / `picakeep.exe`，它也是 App 入口，不是本 CLI launcher。

## 3. 安装到 PATH

Linux / Debian：

```bash
bash tool/install_cli.sh
```

默认安装位置：

```text
~/.local/bin/picakeep
```

Windows PowerShell：

```powershell
.\tool\install_cli.ps1
```

默认安装位置：

```text
%LOCALAPPDATA%\PicaKeepCLI\bin\picakeep.cmd
```

默认运行数据：

- 原生构建成功时：同时安装运行 bundle 到 `~/.local/share/picakeep-cli` 或 `%LOCALAPPDATA%\PicaKeepCLI`
- Web Console 静态资源会安装到运行数据目录下的 `assets/web_console`
- 原生构建失败但源码运行可用时：安装一个 launcher，回到当前仓库执行 `dart run`

安装后验证：

```bash
command -v picakeep
picakeep -h
picakeep -v
```

```powershell
Get-Command picakeep
picakeep -h
picakeep -v
```

如果 Linux 上曾经误用 `root` / `su` 执行安装，仓库里的 `build/cli` 可能会变成 root 所有，普通用户再次安装会出现 `权限不够`。切回普通用户后执行：

```bash
cd /home/azusa/picakeep_linux_build
sudo chown -R "$USER:$USER" build/cli
sudo chown -R "$USER:$USER" "$HOME/.local/bin" "$HOME/.local/share/picakeep-cli" 2>/dev/null || true
bash tool/install_cli.sh
```

如果 Linux 上 `command -v picakeep` 没有输出，说明 `~/.local/bin` 还不在 PATH。可将下面这行加入 `~/.bashrc`、`~/.zshrc` 或当前 shell 配置：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

然后重新打开终端或执行：

```bash
source ~/.bashrc
```

如果 Windows 上 `Get-Command picakeep` 没有输出，先确认安装目录是否可直接运行：

```powershell
& "$env:LOCALAPPDATA\PicaKeepCLI\bin\picakeep.cmd" -v
```

安装脚本会自动把 `%LOCALAPPDATA%\PicaKeepCLI\bin` 写入用户 PATH。已经打开的旧 PowerShell 不一定会立即拿到新的用户 PATH；关闭后重新打开终端即可。当前终端也可以临时执行：

```powershell
$env:Path = "$env:LOCALAPPDATA\PicaKeepCLI\bin;$env:Path"
picakeep -v
```

PowerShell 从当前目录直接运行文件时必须带 `./` 或 `.\` 前缀，例如 `picakeep.exe` 不正确，应该是：

```powershell
.\picakeep.exe -v
```

## 4. 三条运行路径

开发运行：

```bash
dart run bin/picakeep.dart -v
```

构建后运行：

```bash
./build/cli/picakeep -v
```

```powershell
.\build\cli\picakeep.cmd -v
```

安装后运行：

```bash
picakeep -v
picakeep help
picakeep run
picakeep stop
```

```powershell
picakeep -v
picakeep help
picakeep run
picakeep stop
```

默认情况下，`picakeep` / `picakeep run` 会后台启动服务端并立即返回终端，不会占住当前 shell。启动后会输出 PID、日志文件、网页应用、管理后台和状态接口地址。

前台调试时使用：

```bash
picakeep run --foreground
```

停止后台服务：

```bash
picakeep stop
```

默认日志位置：

```text
Linux:   ~/.local/share/picakeep-cli/server.log
Windows: %LOCALAPPDATA%\PicaKeepCLI\server.log
```

当前目录直接运行时必须带路径前缀：

```bash
./picakeep -v
```

```powershell
.\picakeep.exe -v
```

只输入 `picakeep -v` 会走 PATH 搜索；如果还没安装到 PATH，就会显示“未找到命令”。

## 6. 纯 Dart 边界

CLI 入口和 headless 服务端必须保持纯 Dart 依赖边界，不能直接 import Flutter UI、`dart:ui`、`rootBundle`、`MethodChannel` 或 App 全局状态。

当前 CLI 第一版只提供：

- 后台启动 headless 服务端
- 停止后台服务端
- 查看版本、系统和目标服务状态
- 输出网页应用、管理后台 `/admin-view`、`/status` 地址、PID 和日志路径
- 提供网页后台静态资源、状态接口、配置接口和基础空资源视图

完整本地漫画业务仍由 Flutter App 端既有服务端保留。
