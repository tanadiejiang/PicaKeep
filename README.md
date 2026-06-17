# PicaKeep

本地漫画阅读器 / 收藏管理器。基于 [PicaComic](https://github.com/Pacalini/PicaComic) 二次开发，使用 Flutter 构建，在原有PicaComic客户端基础上重做为以本地漫画管理为主线的工具，完全兼容原项目的下载内容和数据库读取，支持客户端/服务端双模式、加密压缩包直接阅读、局域网远程阅览与浏览器网页后台。

## 功能概览

- **原项目兼容** — 完全兼容 PicaComic 的下载内容和数据库，已有数据无缝迁移
- **本地漫画管理** — 导入文件夹，自动识别封面
- **加密压缩包** — 直接阅读加密 ZIP/CBZ，支持 AES 和 ZipCrypto
- **服务端模式** — 可切换为 headless 服务端，局域网内其他设备远程阅览
- **局域网发现** — mDNS 广播 + 网段扫描，自动发现服务端
- **网页后台** — 内置 Web Console，浏览器管理漫画库和阅读历史
- **CLI 工具** — 独立命令行入口，后台启动服务端

## 快速安装

从 [Releases](https://github.com/tanadiejiang/PicaKeep/releases) 下载对应平台的安装包：

| 平台 | 安装方式 |
|------|---------|
| **Windows** | 运行 `PicaKeep-x.x.x-windows-amd64-setup.exe` |
| **Linux (Debian/Ubuntu)** | `sudo dpkg -i PicaKeep-x.x.x-linux-amd64.deb` |
| **Linux (通用)** | `chmod +x PicaKeep-x.x.x-linux-amd64.AppImage && ./PicaKeep-x.x.x-linux-amd64.AppImage` |
| **Android** | 安装 `PicaKeep-x.x.x-android-arm64-v8a.apk` |

安装后 GUI 和 CLI 均可直接使用，终端输入 `picakeep` 即可。

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

### 构建 CLI

CLI 是独立的纯 Dart 入口，需要单独构建：

```bash
# Linux
dart build cli --target=bin/picakeep.dart --output=build/cli

# Windows
dart build cli --target=bin/picakeep.dart --output=build/cli
```

或使用脚本一键构建 + 安装到 PATH：

```bash
# Linux
bash tool/build_cli.sh && bash tool/install_cli.sh

# Windows
.\tool\build_cli.ps1; .\tool\install_cli.ps1
```

### CI 自动构建

推送 tag 即触发 GitHub Actions 自动构建 Windows + Linux ARM64 安装包：

```bash
git tag v1.0.0
git push origin v1.0.0
```

产物在仓库 Actions 页面下载。

## CLI 命令参考

安装后终端直接使用 `picakeep`：

| 命令 | 说明 |
|------|------|
| `picakeep -h` | 查看帮助 |
| `picakeep -v` | 查看版本和系统信息 |
| `picakeep run` | 后台启动 headless 服务端 |
| `picakeep run --foreground` | 前台启动（调试用） |
| `picakeep stop` | 停止后台服务端 |
| `picakeep status` | 查看目标服务状态 |

启动后会输出：

```
网页应用:   http://127.0.0.1:9527/
管理后台:   http://127.0.0.1:9527/admin-view
状态接口:   http://127.0.0.1:9527/status
```

运行数据目录：

| 平台 | 路径 |
|------|------|
| Linux | `~/.local/share/picakeep-cli/` |
| Windows | `%LOCALAPPDATA%\PicaKeepCLI\` |

## 项目结构

```
├── lib/                    # Flutter 应用主体
│   ├── pages/              # 页面
│   ├── foundation/         # 基础库（加密、网络、存储）
│   └── server/             # 服务端模式
├── bin/                    # CLI 入口（纯 Dart）
├── assets/                 # 静态资源
│   └── web_console/        # 网页后台前端
├── windows/                # Windows 平台配置
├── linux/                  # Linux 平台配置
├── android/                # Android 平台配置
└── tool/                   # 构建脚本
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
