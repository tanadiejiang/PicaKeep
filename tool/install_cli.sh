#!/usr/bin/env bash
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
build_root="${PICAKEEP_BUILD_DIR:-$repo_root/build/cli}"
bin_dir="${PICAKEEP_BIN_DIR:-$HOME/.local/bin}"
install_root="${PICAKEEP_INSTALL_ROOT:-$HOME/.local/share/picakeep-cli}"
launcher_path="$bin_dir/picakeep"
meta_path="$build_root/build.meta"
version_path="$build_root/picakeep.version"

if [ "${PICAKEEP_ALLOW_ROOT_INSTALL:-}" != "1" ] && [ "$(id -u)" -eq 0 ]; then
  echo "[install_cli] refusing to run as root for the default user-level install" >&2
  echo "[install_cli] switch back to your normal user and run: bash tool/install_cli.sh" >&2
  echo "[install_cli] if root-owned build files were created, fix them from your normal user with:" >&2
  echo "  sudo chown -R \"<your-user>:<your-user>\" \"$repo_root/build/cli\"" >&2
  echo "  sudo chown -R \"<your-user>:<your-user>\" \"/home/<your-user>/.local/bin\" \"/home/<your-user>/.local/share/picakeep-cli\" 2>/dev/null || true" >&2
  echo "[install_cli] set PICAKEEP_ALLOW_ROOT_INSTALL=1 only if you intentionally want a root-owned install" >&2
  exit 1
fi

bash "$repo_root/tool/build_cli.sh"

mkdir -p "$bin_dir" "$install_root"

copy_web_console_assets() {
  asset_src="$repo_root/assets/web_console"
  asset_dest="$install_root/assets/web_console"
  if [ ! -d "$asset_src" ]; then
    echo "[install_cli] warning: web console assets not found: $asset_src" >&2
    return 0
  fi
  rm -rf "$asset_dest"
  mkdir -p "$(dirname -- "$asset_dest")"
  cp -R "$asset_src" "$asset_dest"
}

copy_version_file() {
  if [ -f "$version_path" ]; then
    cp "$version_path" "$install_root/picakeep.version"
  fi
}

mode="dart-run"
target="bin/picakeep.dart"
if [ -f "$meta_path" ]; then
  # shellcheck disable=SC1090
  . "$meta_path"
  mode="${MODE:-$mode}"
  target="${TARGET:-$target}"
fi

case "$mode" in
  native)
    rm -rf "$install_root/native"
    mkdir -p "$install_root"
    if [ -d "$build_root/native" ]; then
      cp -R "$build_root/native" "$install_root/native"
      installed_target="$install_root/native/${target#native/}"
    else
      cp "$build_root/$target" "$install_root/picakeep-native"
      installed_target="$install_root/picakeep-native"
    fi
    cat > "$launcher_path" <<EOF
#!/usr/bin/env bash
set -eu
exec "$installed_target" "\$@"
EOF
    ;;
  *)
    cat > "$launcher_path" <<EOF
#!/usr/bin/env bash
set -eu
REPO_ROOT="$repo_root"
cd "\$REPO_ROOT"
exec dart run bin/picakeep.dart "\$@"
EOF
    ;;
esac

chmod +x "$launcher_path"
copy_web_console_assets
copy_version_file

echo "[install_cli] installed launcher: $launcher_path"
if [ "$mode" = "native" ]; then
  echo "[install_cli] install mode: native"
  echo "[install_cli] runtime root: $install_root"
else
  echo "[install_cli] install mode: dart-run fallback"
  echo "[install_cli] source checkout required: $repo_root"
fi

case ":$PATH:" in
  *":$bin_dir:"*)
    echo "[install_cli] PATH already contains $bin_dir"
    ;;
  *)
    echo "[install_cli] PATH does not contain $bin_dir"
    echo "[install_cli] add with: export PATH=\"$bin_dir:\$PATH\""
    ;;
esac

echo "[install_cli] verify with:"
echo "  command -v picakeep"
echo "  picakeep -h"
echo "  picakeep -v"
