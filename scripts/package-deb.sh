#!/usr/bin/env bash
# Build a Debian package from the binary produced by
#   pnpm tauri build --bundles rpm,appimage
# or plain `cargo build --release --features custom-protocol`.
#
#   scripts/package-deb.sh                          # auto-detects the target dir
#   scripts/package-deb.sh --target aarch64-unknown-linux-gnu
#   BIN=path/to/pot scripts/package-deb.sh
#
# Why not let the Tauri 1 bundler make the .deb? Its dependency table is written
# around WebKitGTK 4.0 (`libwebkit2gtk-4.0-37`), which no longer exists on the
# distributions this fork targets. Here the dependencies are read back from the
# binary's own NEEDED entries and resolved with dpkg -S, so the control file
# always names the packages that actually provide those sonames
# (libwebkit2gtk-4.1-0, libsoup-3.0-0, libgtk-3-0t64, ...).
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
root=$PWD

target=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) target=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ $(uname -s) == Linux ]] || { echo 'Build this package on Linux.' >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo 'Install dpkg-dev (or run on Debian/Ubuntu).' >&2; exit 1; }

version=$(python3 -c "import json;print(json.load(open('src-tauri/tauri.conf.json'))['package']['version'])")
arch=$(dpkg --print-architecture)
outdir=$root/target/deb
mkdir -p "$outdir"

if [[ -n ${BIN:-} ]]; then
  binary=$BIN
else
  candidates=()
  [[ -n $target ]] && candidates+=("src-tauri/target/$target/release/pot")
  candidates+=("src-tauri/target/release/pot")
  for c in "${candidates[@]}"; do
    [[ -x $c ]] && { binary=$c; break; }
  done
fi
[[ -n ${binary:-} && -x ${binary:-} ]] || { echo "missing pot binary; build first" >&2; exit 1; }
echo "packaging $binary ($version, $arch)"

stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
chmod 755 "$stage"
install -d "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/applications" \
          "$stage/usr/share/icons/hicolor/512x512/apps" "$stage/usr/share/doc/pot" "$stage/usr/share/metainfo"

install -m755 "$binary" "$stage/usr/bin/pot"
strip --strip-all "$stage/usr/bin/pot" 2>/dev/null || true
install -m644 src-tauri/icons/icon.png "$stage/usr/share/icons/hicolor/512x512/apps/pot.png"
install -m644 LICENSE "$stage/usr/share/doc/pot/copyright"
[[ -f com.pot_app.pot.metainfo.xml ]] && install -m644 com.pot_app.pot.metainfo.xml "$stage/usr/share/metainfo/"

cat > "$stage/usr/share/applications/pot.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Pot
Comment=A cross-platform text translation and OCR app
Comment[zh_CN]=跨平台划词翻译和 OCR 软件
Exec=pot
Icon=pot
Terminal=false
Categories=Utility;Translation;
Keywords=translate;ocr;dictionary;
StartupWMClass=pot
DESK

declare -A deps=()
deps['libc6 (>= 2.35)']=1
while read -r soname; do
  path=$(/sbin/ldconfig -p | awk -v s="$soname" '$1 == s {print $NF; exit}')
  [[ -n $path ]] || { echo "warning: $soname is not installed here" >&2; continue; }
  owner=$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -1 | cut -d: -f1 || true)
  if [[ -z $owner ]]; then
    echo "warning: no package owns $path" >&2
  elif [[ $owner != libc6 ]]; then
    deps[$owner]=1
  fi
done < <(readelf -d "$binary" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
# pot shells out to tesseract for OCR; the tray needs appindicator even when the
# linker did not pull it in directly on every arch.
for extra in tesseract-ocr libayatana-appindicator3-1; do deps[$extra]=1; done
depends=$(printf '%s\n' "${!deps[@]}" | sort | paste -sd, - | sed 's/,/, /g')
size=$(du -sk "$stage" | cut -f1)

cat > "$stage/DEBIAN/control" <<EOF
Package: pot
Version: $version
Section: utils
Priority: optional
Architecture: $arch
Installed-Size: $size
Depends: $depends
Recommends: tesseract-ocr-eng, tesseract-ocr-chi-sim, fonts-noto-cjk
Maintainer: pot-app <pot-app@users.noreply.github.com>
Homepage: https://pot-app.com
Description: cross-platform text translation and OCR app
 Pot is a translation and OCR tool built on Tauri. This build links WebKitGTK
 4.1 (libsoup3), so it installs on Debian 13, Ubuntu 24.04 and newer.
EOF

(cd "$stage" && find . -path ./DEBIAN -prune -o -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
chmod 644 "$stage/DEBIAN/md5sums" "$stage/DEBIAN/control"

deb="$outdir/pot_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
(cd "$outdir" && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256")
dpkg-deb --info "$deb" | sed -n '1,8p'
echo "$deb"
