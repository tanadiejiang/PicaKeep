#!/bin/bash
# 打包 PicaKeep Linux .deb：同一个 Flutter 二进制,有屏启 GUI、无屏经 xvfb 启
# headless 服务端(picakeep --server),CLI 与桌面版能力完全一致。
# 用法: package_linux_deb.sh <amd64|arm64>
set -euo pipefail

ARCH="${1:?需要架构参数: amd64 或 arm64}"
VER="$(sed -n 's/^version: //p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
PKG="picakeep_${VER}_${ARCH}"
APPDIR="${PKG}/opt/PicaKeep"

BUNDLE_DIR="$(find build/linux -maxdepth 3 -type d -name bundle | head -n 1)"
if [ -z "${BUNDLE_DIR}" ]; then
  echo "找不到 flutter build linux 产物 bundle 目录" >&2
  exit 1
fi

rm -rf "${PKG}"
mkdir -p "${APPDIR}" "${PKG}/DEBIAN" "${PKG}/usr/share/applications" "${PKG}/usr/local/bin" \
  "${PKG}/usr/share/icons/hicolor/scalable/apps" "${PKG}/usr/share/icons/hicolor/512x512/apps"

# GUI bundle(内含 picakeep 可执行 + data/flutter_assets,含 web_console 资源)
cp -r "${BUNDLE_DIR}"/* "${APPDIR}/"
chmod +x "${APPDIR}/picakeep"

# 版本标记文件,供 `picakeep version` 读取(heredoc 内为单引号不展开,故在此写入)。
echo "版本=${VER}" > "${APPDIR}/picakeep.version"

# 安装图标到 hicolor 主题(桌面环境按 Icon=picakeep 主题名查找,最可靠)。
if [ -f "${APPDIR}/data/flutter_assets/assets/web_console/pica-icon.svg" ]; then
  cp "${APPDIR}/data/flutter_assets/assets/web_console/pica-icon.svg" \
    "${PKG}/usr/share/icons/hicolor/scalable/apps/picakeep.svg"
fi
if [ -f "${APPDIR}/data/app_icon.png" ]; then
  cp "${APPDIR}/data/app_icon.png" \
    "${PKG}/usr/share/icons/hicolor/512x512/apps/picakeep.png"
fi

# 智能启动器 / 服务管理器:
#   picakeep            有显示器 -> GUI;无显示器(NAS/SSH) -> 后台服务端
#   picakeep server     后台启动服务端(查重、不刷屏、立即归还终端,日志写文件)
#   picakeep stop       停止后台服务端
#   picakeep status     查看服务端是否在运行
#   picakeep logs       跟踪服务端日志(Ctrl+C 仅退出查看,不停服务)
#   picakeep --server   前台启动服务端(透传给二进制,日志直接打屏、Ctrl+C 停)
cat > "${PKG}/usr/local/bin/picakeep" << 'WRAPPER'
#!/bin/sh
APP=/opt/PicaKeep/picakeep
export PICAKEEP_WEB_CONSOLE_ROOT=/opt/PicaKeep/data/flutter_assets/assets/web_console
PORT=9527
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/picakeep"
PID_FILE="$STATE_DIR/server.pid"
LOG_FILE="$STATE_DIR/server.log"

_server_pid() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  return 1
}

# 按监听端口反查占用进程的 PID(用于 PID 文件丢失时的孤儿服务兜底)。
_port_pid() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1
  fi
}

# 打印本机所有局域网 IP 的完整后台网址(终端可 Ctrl/Cmd+点击直接打开)。
_print_urls() {
  echo "  本机:     http://127.0.0.1:$PORT/admin-view"
  ips=$(
    { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1; } \
      || { hostname -I 2>/dev/null | tr ' ' '\n'; }
  )
  for ipaddr in $ips; do
    [ -n "$ipaddr" ] && echo "  局域网:   http://$ipaddr:$PORT/admin-view"
  done
}

case "${1:-}" in
  server|s|up|start)
    shift
    if pid=$(_server_pid); then
      echo "PicaKeep 服务端已在运行 (PID $pid)。"
      _print_urls
      exit 0
    fi
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$PORT "; then
      echo "端口 $PORT 已被占用(可能服务端已在运行)。如需停止: picakeep stop"
      exit 0
    fi
    mkdir -p "$STATE_DIR"
    # 完全脱离终端的后台进程:setsid 新建会话,不挂当前 shell 作业,
    # 关闭终端也不影响;输出写日志文件,不刷屏。无需手动加 &。
    if command -v setsid >/dev/null 2>&1; then
      setsid xvfb-run -a "$APP" --server "$@" >"$LOG_FILE" 2>&1 < /dev/null &
    else
      nohup xvfb-run -a "$APP" --server "$@" >"$LOG_FILE" 2>&1 < /dev/null &
    fi
    svpid=$!
    echo "$svpid" > "$PID_FILE"
    sleep 1
    echo "PicaKeep 服务端已在后台启动 (PID $svpid)。"
    _print_urls
    echo "  日志: picakeep logs    停止: picakeep stop"
    exit 0
    ;;
  stop|x|down)
    # 优先用 PID 文件;丢失时(如重装/清理后的孤儿服务)按端口反查兜底。
    pid=$(_server_pid) || pid=$(_port_pid)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      # 等待优雅退出;超时则强制结束,确保端口释放。
      i=0
      while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      rm -f "$PID_FILE"
      echo "已停止 PicaKeep 服务端 (PID $pid)。"
    else
      echo "PicaKeep 服务端未在运行。"
    fi
    exit 0
    ;;
  status|st)
    if pid=$(_server_pid); then
      echo "运行中 (PID $pid),端口 $PORT。"
      _print_urls
    else
      pid=$(_port_pid)
      if [ -n "$pid" ]; then
        echo "运行中 (PID $pid,端口 $PORT;PID 文件缺失,可 picakeep stop 停止)。"
        _print_urls
      else
        echo "未运行。"
      fi
    fi
    exit 0
    ;;
  logs|l|log)
    [ -f "$LOG_FILE" ] && tail -n 50 -f "$LOG_FILE" || echo "暂无日志($LOG_FILE)。"
    exit 0
    ;;
  version|-v|--version)
    ver="$(grep -m1 '^版本=' /opt/PicaKeep/picakeep.version 2>/dev/null | cut -d= -f2)"
    [ -z "$ver" ] && ver="unknown"
    osname="$( ( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" ) || uname -s )"
    echo "PicaKeep v$ver"
    echo "  系统:     $osname"
    echo "  内核:     $(uname -srm)"
    echo "  可执行:   $APP"
    exit 0
    ;;
  --server)
    # 前台模式(透传):日志打屏、Ctrl+C 停。
    exec xvfb-run -a "$APP" "$@"
    ;;
esac

# 无子命令:有显示器启 GUI,无显示器自动后台起服务端。
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  exec "$APP" "$@"
fi
exec "$0" server "$@"
WRAPPER
chmod +x "${PKG}/usr/local/bin/picakeep"

# 桌面入口(有显示器时由桌面环境启动 GUI)。Icon 用 hicolor 主题名,最可靠。
cat > "${PKG}/usr/share/applications/picakeep.desktop" << DESKTOP
[Desktop Entry]
Type=Application
Name=PicaKeep
Exec=/opt/PicaKeep/picakeep
Icon=picakeep
Terminal=false
Categories=Graphics;
DESKTOP

# 包元信息。xvfb 用于无显示器环境启动服务端;libgtk-3-0 为 Flutter Linux 引擎运行库;
# libayatana-appindicator3-1 是 tray_manager 插件 Linux 原生依赖(编译期 + 运行期都需要)。
cat > "${PKG}/DEBIAN/control" << CONTROL
Package: picakeep
Version: ${VER}
Section: graphics
Priority: optional
Architecture: ${ARCH}
Maintainer: PicaComic
Depends: libgtk-3-0, xvfb, libayatana-appindicator3-1
Description: 本地漫画阅读器 / 收藏管理器
 有显示器时启动图形界面;无显示器(如 NAS)时终端运行 picakeep
 自动转为后台服务端,网页端管理能力与桌面版完全一致。
CONTROL

# 安装后安全提示:headless 服务端对外暴露 HTTP,默认无密码。
cat > "${PKG}/DEBIAN/postinst" << 'POSTINST'
#!/bin/sh
set -e
# 刷新图标缓存与桌面数据库,使图标和启动项立即生效。
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
fi
echo "PicaKeep 安装完成。"
echo "  有屏:菜单/桌面图标或终端 picakeep 启动图形界面。"
echo "  无屏(NAS/SSH):终端 picakeep 自动后台启动服务端。"
echo "  服务端管理: picakeep server(后台启动) / stop / status / logs"
echo "  安全提示:服务端默认监听且后台密码为空,公网/局域网暴露前请在网页后台设置访问密码,"
echo "           并确认监听地址(host)是否需要绑定 0.0.0.0。"
exit 0
POSTINST
chmod +x "${PKG}/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "${PKG}"
mkdir -p artifacts
mv "${PKG}.deb" artifacts/
echo "已生成 artifacts/${PKG}.deb"

