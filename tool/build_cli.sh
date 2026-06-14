#!/usr/bin/env bash
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
build_root="${PICAKEEP_BUILD_DIR:-$repo_root/build/cli}"
native_root="$build_root/native"
compiled_binary="$build_root/picakeep-native"
launcher_path="$build_root/picakeep"
meta_path="$build_root/build.meta"
log_path="$build_root/build.log"
version_path="$build_root/picakeep.version"
package_version="$(awk '/^[[:space:]]*version:[[:space:]]*/ { print $2; exit }' "$repo_root/pubspec.yaml")"

mkdir -p "$build_root"
rm -rf "$native_root"
rm -f "$compiled_binary" "$launcher_path" "$meta_path" "$log_path" "$version_path"
: > "$log_path"
printf '%s\n' "$package_version" > "$version_path"

write_meta() {
  mode="$1"
  target="$2"
  cat > "$meta_path" <<EOF
MODE=$mode
TARGET=$target
EOF
}

copy_web_console_assets() {
  target_dir="$1"
  asset_src="$repo_root/assets/web_console"
  asset_dest="$target_dir/assets/web_console"
  if [ ! -d "$asset_src" ]; then
    echo "[build_cli] warning: web console assets not found: $asset_src" >&2
    return 0
  fi
  rm -rf "$asset_dest"
  mkdir -p "$(dirname -- "$asset_dest")"
  cp -R "$asset_src" "$asset_dest"
}

copy_version_file() {
  target_dir="$1"
  target_path="$target_dir/picakeep.version"
  mkdir -p "$target_dir"
  if [ "$version_path" != "$target_path" ]; then
    cp "$version_path" "$target_path"
  fi
}

write_native_launcher() {
  native_target="$1"
  cat > "$launcher_path" <<EOF
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
exec "\$SCRIPT_DIR/$native_target" "\$@"
EOF
  chmod +x "$launcher_path"
  write_meta "native" "$native_target"
}

write_dart_run_launcher() {
  cat > "$launcher_path" <<EOF
#!/usr/bin/env bash
set -eu
REPO_ROOT="$repo_root"
cd "\$REPO_ROOT"
exec dart run bin/picakeep.dart "\$@"
EOF
  chmod +x "$launcher_path"
  write_meta "dart-run" "bin/picakeep.dart"
}

find_native_bundle_binary() {
  find "$native_root" -type f -path '*/bundle/bin/*' | head -n 1
}

echo "[build_cli] repo_root=$repo_root"
echo "[build_cli] build_root=$build_root"

if dart build cli --target bin/picakeep.dart --output "$native_root" >>"$log_path" 2>&1; then
  native_binary="$(find_native_bundle_binary || true)"
  if [ -n "${native_binary:-}" ]; then
    relative_target="${native_binary#"$build_root"/}"
    copy_web_console_assets "$build_root"
    copy_version_file "$build_root"
    write_native_launcher "$relative_target"
    echo "[build_cli] mode=native (dart build cli)"
    echo "[build_cli] launcher=$launcher_path"
    exit 0
  fi
fi

if dart compile exe bin/picakeep.dart -o "$compiled_binary" >>"$log_path" 2>&1; then
  relative_target="${compiled_binary#"$build_root"/}"
  copy_web_console_assets "$build_root"
  copy_version_file "$build_root"
  write_native_launcher "$relative_target"
  echo "[build_cli] mode=native (dart compile exe)"
  echo "[build_cli] launcher=$launcher_path"
  exit 0
fi

if dart run bin/picakeep.dart -h >>"$log_path" 2>&1; then
  write_dart_run_launcher
  echo "[build_cli] mode=dart-run fallback"
  echo "[build_cli] launcher=$launcher_path"
  echo "[build_cli] build log: $log_path"
  exit 0
fi

echo "[build_cli] failed: native build unavailable and source CLI is not runnable" >&2
echo "[build_cli] inspect log: $log_path" >&2
exit 1
