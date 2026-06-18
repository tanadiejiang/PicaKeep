# PicaKeep

本地漫画阅读器 / 收藏管理器。基于 [PicaComic](https://github.com/Pacalini/PicaComic) 二次开发，使用 Flutter 构建，在原有PicaComic客户端基础上重做为以本地漫画管理为主线的工具，完全兼容原项目的下载内容和数据库读取，支持客户端/服务端双模式、加密压缩包直接阅读、局域网远程阅览与浏览器网页后台。

## 功能概览

- **原项目兼容** — 完全兼容 PicaComic 的下载内容和数据库，已有数据无缝迁移
- **本地漫画管理** — 导入文件夹，自动识别封面
- **加密压缩包** — 直接阅读加密 ZIP/CBZ，支持 AES 和 ZipCrypto
- **服务端模式** — 同一二进制 `--server` 入口起 headless 服务端，局域网内其他设备远程阅览；能力与桌面版完全一致
- **局域网发现** — mDNS 广播 + 网段扫描，自动发现服务端
- **网页后台** — 内置 Web Console，浏览器管理漫画库和阅读历史
- **命令行 / 托盘** — Linux 无屏自动转后台服务端（`picakeep server`）；Windows 可缩系统托盘常驻

## 快速安装

从 [Releases](https://github.com/tanadiejiang/PicaKeep/releases) 下载对应平台的安装包：

<div align=left>
<table>
    <thead align=left>
        <tr>
            <th>OS</th>
            <th>Download</th>
        </tr>
    </thead>
    <tbody align=left>
        <tr>
            <td>Android</td>
            <td>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-android-arm64-v8a.apk"><img src="https://img.shields.io/badge/APK-ARMv8-168039.svg?logo=android"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-android-armeabi-v7a.apk"><img src="https://img.shields.io/badge/APK-ARMv7-45bf55.svg?logo=android"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-android-x86_64.apk"><img src="https://img.shields.io/badge/APK-x64-96ed89.svg?logo=android"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-android.apk"><img src="https://img.shields.io/badge/APK-universal-3DDC84.svg?logo=android"></a>
            </td>
        </tr>
        <tr>
            <td>Windows</td>
            <td>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-windows-amd64-setup.exe"><img src="https://img.shields.io/badge/Setup-x64-2d7d9a.svg?logo=windows"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-windows-arm64-setup.exe"><img src="https://img.shields.io/badge/Setup-ARM64-67b7d1.svg?logo=windows"></a>
            </td>
        </tr>
        <tr>
            <td>Linux</td>
            <td>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-linux-amd64.AppImage"><img src="https://img.shields.io/badge/AppImage-x64-f84e29.svg?logo=linux"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-linux-amd64.deb"><img src="https://img.shields.io/badge/DebPackage-x64-FF9966.svg?logo=debian"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-linux-amd64.tar.gz"><img src="https://img.shields.io/badge/tar.gz-x64-8A8A8A.svg?logo=linux"></a><br>
                <a href="https://github.com/tanadiejiang/PicaKeep/releases/download/v1.9.24/PicaKeep-1.9.24-linux-arm64.deb"><img src="https://img.shields.io/badge/DebPackage-ARM64-F1B42F.svg?logo=debian"></a>
            </td>
        </tr>
    </tbody>
</table>
</div>

<div dir="ltr">

**Note:** Windows ARM64 and Linux ARM64 packages include the `picakeep` CLI.

</div>

| 平台 | 安装方式 |
|------|---------|
| **Windows x64** | 运行 `PicaKeep_Setup_vx.x.x.exe` |
| **Windows ARM64** | 运行 `PicaKeep_ARM64_Setup_vx.x.x.exe` |
| **Linux x64 (Debian/Ubuntu)** | `sudo dpkg -i picakeep_x.x.x_amd64.deb && sudo apt-get install -f` |
| **Linux ARM64** | `sudo dpkg -i picakeep_x.x.x_arm64.deb && sudo apt-get install -f` |
| **Android** | 安装对应 ABI 的 `apk` |

安装后 GUI 与 `picakeep` 命令行均可直接使用。

- **有显示器**：菜单/桌面图标或终端输入 `picakeep` 启动图形界面。
- **无显示器（NAS / SSH）**：Linux 终端输入 `picakeep` 自动后台启动服务端；或显式 `picakeep server`。
- GUI 与命令行起的是**同一套服务端**，能力完全一致，管理在网页后台。

## 构建指引

### 环境要求

- Flutter SDK ≥ 3.3.0
- Android: Android SDK + 签名密钥
- Linux: `libgtk-3-dev`
- Windows: Visual Studio 2022+

### 拉取依赖

```bash
flutter pub get
```

### 构建各平台

```bash
# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android (需要配置 android/key.properties 签名)
flutter build apk --split-per-abi --release
```

### 打包安装包

命令行服务端不再单独编译——它就是 GUI 二进制的 `--server` 入口（能读到全部资源），命令行入口由 wrapper 转调。

```bash
# Linux (.deb，需在 ubuntu-22.04 / Debian 12 上构建以兼容 glibc)
flutter build linux --release
bash .github/scripts/package_linux_deb.sh amd64   # 或 arm64
# 产物：artifacts/picakeep_<ver>_<arch>.deb

# Windows：flutter build windows 产物 + 仓库 windows/cli/ wrapper，再用 Inno Setup 打包
flutter build windows --release
# wrapper 放到 {app}\cli\，把该目录加进 PATH（见 .github/workflows/build.yml 的 Inno 脚本）
```

> 详细打包步骤见 [`Z-plan/后续优化-第二轮/打包说明-Linux与Windows.md`](Z-plan/后续优化-第二轮/打包说明-Linux与Windows.md)。
> 注意：旧的 `dart build cli`（`bin/picakeep.dart`）是读不到资源的空壳服务端，**已弃用**，勿再使用。

### CI 自动构建

推送 `v*` tag 即触发 GitHub Actions，一次产出 4 个安装包（Linux deb amd64/arm64、Windows Inno x64/arm64）：

```bash
git tag v1.0.0
git push origin v1.0.0
```

产物在仓库 Actions 页面下载。

## 命令行参考

安装后终端直接使用 `picakeep`（Linux 经 wrapper + xvfb，Windows 经 wrapper 调用 GUI exe `--server`）：

| 命令 | 简写 | 说明 |
|------|------|------|
| `picakeep` | | 有显示器 → 启动 GUI；无显示器（NAS/SSH）→ 后台启动服务端 |
| `picakeep server` | `s` / `up` / `start` | 后台启动服务端（查重、不刷屏、立即归还终端，日志写文件） |
| `picakeep stop` | `x` / `down` | 停止后台服务端（PID 文件失效时按端口兜底） |
| `picakeep status` | `st` | 查看服务端运行状态与访问网址 |
| `picakeep logs` | `l` / `log` | 跟踪服务端日志（Ctrl+C 仅退出查看，不停服务） |
| `picakeep version` | `-v` / `--version` | 查看 PicaKeep 版本与系统信息 |

启动后会列出可点击的访问网址：

```
本机:     http://127.0.0.1:9527/admin-view
局域网:   http://<本机IP>:9527/admin-view
```

> Windows 下双击桌面图标开 GUI，在界面里启动服务后可缩到**系统托盘**后台常驻（关窗时：有服务→缩托盘，无服务→退出）。命令行 `picakeep server` 与托盘两种方式起的是同一个服务端。

运行数据目录：

| 平台 | 路径 |
|------|------|
| Linux | 应用数据目录（`~/.local/share/...`）；服务端 PID/日志在 `~/.local/state/picakeep/` |
| Windows | 应用数据目录（`%APPDATA%`）；服务端 PID/日志在 `%LOCALAPPDATA%\picakeep\` |

> 安全提示：服务端默认监听且后台密码为空，公网/局域网暴露前请在网页后台设置访问密码。

## 项目结构

```
├── lib/                    # Flutter 应用主体
│   ├── pages/              # 页面
│   ├── foundation/         # 基础库（加密、网络、存储）
│   ├── server/             # 服务端模式（--server 入口起 PicaKeepAdminServer）
│   └── main.dart           # 入口：GUI / --server headless 双路径
├── assets/                 # 静态资源
│   └── web_console/        # 网页后台前端
├── windows/                # Windows 平台配置
│   └── cli/                # Windows 命令行 wrapper（picakeep.cmd / picakeep.ps1）
├── linux/                  # Linux 平台配置
├── android/                # Android 平台配置
└── .github/
    ├── workflows/build.yml         # CI：4 平台安装包
    └── scripts/package_linux_deb.sh # Linux deb 打包脚本
```

## 致谢

### 项目

[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=Pacalini&repo=PicaComic)](https://github.com/Pacalini/PicaComic)

本项目基于 PicaComic 二次开发，感谢原作者的杰出工作。

### 标签翻译

[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=EhTagTranslation&repo=Database)](https://github.com/EhTagTranslation/Database)

漫画标签中文翻译数据来自此项目。

## 许可证

Apache-2.0
