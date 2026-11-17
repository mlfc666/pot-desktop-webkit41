#!/usr/bin/env bash
# Prepare a build host whose only WebKitGTK is 4.1 (Debian 13, Ubuntu 24.04+,
# Fedora 40+, ...) for Tauri 1.8, which still asks pkg-config for the removed
# 4.0 packages.
#
# Two things have to be patched on the build host, both are lookups only:
#   * pkg-config files named webkit2gtk-4.0 / javascriptcoregtk-4.0 that point
#     at the installed 4.1 libraries (the crates ship pre-generated bindings,
#     so only detection and linking matter);
#   * unversioned -lwebkit2gtk-4.0 / -ljavascriptcoregtk-4.0 symlinks, because
#     webkit2gtk-sys hard-codes those names on the link line. The soname of the
#     target file stays libwebkit2gtk-4.1.so.0, so the binary ends up with the
#     correct runtime dependency.
#
# Needs sudo only for the symlinks in /usr/lib; the .pc files go to a directory
# the caller adds to PKG_CONFIG_PATH.
set -euo pipefail

triple=$(gcc -dumpmachine 2>/dev/null || echo "x86_64-linux-gnu")
shim_dir=${SHIM_DIR:-$PWD/.webkit41-shim}
libdir="/usr/lib/$triple"
includedir=/usr/include

webkit=$(pkg-config --modversion webkit2gtk-4.1)
jsc=$(pkg-config --modversion javascriptcoregtk-4.1)

mkdir -p "$shim_dir"
cat > "$shim_dir/webkit2gtk-4.0.pc" <<PC
prefix=/usr
exec_prefix=\${prefix}
libdir=$libdir
includedir=$includedir

Name: WebKit2GTK
Description: WebKitGTK 4.1 standing in for the removed 4.0 package
Version: $webkit
Requires: webkit2gtk-4.1
Libs: -L\${libdir} -lwebkit2gtk-4.1
Cflags: -I\${includedir}/webkitgtk-4.1
PC

cat > "$shim_dir/javascriptcoregtk-4.0.pc" <<PC
prefix=/usr
exec_prefix=\${prefix}
libdir=$libdir
includedir=$includedir

Name: JavaScriptCoreGTK
Description: JavaScriptCore 4.1 standing in for the removed 4.0 package
Version: $jsc
Requires: javascriptcoregtk-4.1
Libs: -L\${libdir} -ljavascriptcoregtk-4.1
Cflags: -I\${includedir}/webkitgtk-4.1
PC

# Only the unversioned dev link names are added; nothing is overwritten.
for pair in "libwebkit2gtk-4.1.so.0 libwebkit2gtk-4.0.so" \
            "libjavascriptcoregtk-4.1.so.0 libjavascriptcoregtk-4.0.so"; do
  set -- $pair
  target=$libdir/$1
  link=$libdir/$2
  [[ -e $target ]] || { echo "missing $target" >&2; exit 1; }
  if [[ -e $link || -L $link ]]; then
    echo "kept existing $link"
  else
    sudo ln -s "$1" "$link"
    echo "linked $link -> $1"
  fi
done

PKG_CONFIG_PATH="$shim_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  pkg-config --modversion webkit2gtk-4.0 javascriptcoregtk-4.0
echo "shim ready in $shim_dir"
