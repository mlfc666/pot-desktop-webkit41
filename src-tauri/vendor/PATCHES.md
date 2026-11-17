# Building Pot 3.0.7 on Debian 13 (trixie) with WebKitGTK 4.1

Pot 3.0.7 is Tauri 1.8, and Tauri 1.8 is pinned to **WebKitGTK 4.0 / libsoup2**:

```
pot → tauri 1.8.1 → wry 0.24.11 → webkit2gtk 0.18.2 → webkit2gtk-4.0 + soup2
```

Debian 13 dropped `libwebkit2gtk-4.0*` entirely (only `-4.0-doc` transitional
remains) and ships `libwebkit2gtk-4.1` / libsoup3 instead. Tauri 2 would fix
this at the source, but migrating the app (Rust handlers + `@tauri-apps/api`
v1 → v2 + capabilities) is a rewrite. This tree keeps the application code
untouched and moves only the two GUI crates onto 4.1.

## What the port changes

`src-tauri/Cargo.toml` adds:

```toml
[patch.crates-io]
webkit2gtk = { path = "vendor/webkit2gtk" }
wry = { path = "vendor/wry" }
soup2-sys = { path = "vendor/soup2-sys" }
```

### `vendor/webkit2gtk` (0.18.2)

* `soup2` dependency removed. The crate's own `src/` never calls into it.
* The soup-typed APIs (`CookieManager` cookie calls, `URIRequest/URIResponse/
  URISchemeRequest/URISchemeResponse::http_headers`) are gated behind the
  `dox` feature, so they are not compiled. wry uses none of them except
  `URIRequest::http_headers`.
* New `src/message_headers.rs`: a two-method shim (`append`) standing in for
  `soup::MessageHeaders`. It wraps the pointer WebKitGTK 4.1 returns and calls
  **libsoup3's** `soup_message_headers_append` on it — the object genuinely is
  a libsoup3 `SoupMessageHeaders` in 4.1, and the symbol name is unchanged, so
  the call is type-correct without linking libsoup2.
* `URIRequest::http_headers()` returns that shim.

### `vendor/wry` (0.24.11)

* Adds `use webkit2gtk::SettingsExt as _;` — the 4.0-era bindings reached
  `Settings` setters through the glob import by accident; the newer generated
  bindings need the trait in scope explicitly.
* `soup2` dependency removed (it was declared but unused; `set_persistent_storage`
  takes a path, not a soup type).

### `vendor/soup2-sys` (0.2.0)

* Build script reduced to `fn main() {}` so pkg-config no longer advertises
  `-lsoup-2.4`. `webkit2gtk-sys` still names `soup_sys` types in its bindings,
  and libsoup3 aborts the process if libsoup2 is loaded next to it
  (`libsoup3 symbols detected. Using libsoup2 and libsoup3 in the same process
  is not supported.`), so the library must not be linked at all.

## Build recipe (Debian 13, arm64)

```sh
apt-get install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev \
  libjavascriptcoregtk-4.1-dev libsoup-3.0-dev libsoup2.4-dev \
  libayatana-appindicator3-dev librsvg2-dev libssl-dev nodejs npm

# The dependencies' build scripts still ask pkg-config for the removed 4.0 names.
mkdir -p /opt/gtk41-shim && cat > /opt/gtk41-shim/webkit2gtk-4.0.pc <<'PC'
prefix=/usr
libdir=${prefix}/lib/aarch64-linux-gnu
includedir=${prefix}/include
Name: WebKit2GTK
Description: WebKitGTK 4.1 standing in for the removed 4.0 package
Version: 2.52.6
Requires: webkit2gtk-4.1
Libs: -L${libdir} -lwebkit2gtk-4.1
Cflags: -I${includedir}/webkitgtk-4.1
PC
sed 's/WebKit2GTK/JavaScriptCoreGTK/; s/webkit2gtk-4\.1/javascriptcoregtk-4.1/g; s/-lwebkit2gtk-4.1/-ljavascriptcoregtk-4.1/' \
  /opt/gtk41-shim/webkit2gtk-4.0.pc > /opt/gtk41-shim/javascriptcoregtk-4.0.pc

# `webkit2gtk-sys` hard-codes -lwebkit2gtk-4.0 on the link line as well.
ln -sf libwebkit2gtk-4.1.so.0 /usr/lib/aarch64-linux-gnu/libwebkit2gtk-4.0.so
ln -sf libjavascriptcoregtk-4.1.so.0 /usr/lib/aarch64-linux-gnu/libjavascriptcoregtk-4.0.so

pnpm install --frozen-lockfile --ignore-scripts   # the tauri CLI postinstall is not needed
pnpm build
cd src-tauri
PKG_CONFIG_PATH=/opt/gtk41-shim cargo build --release --features custom-protocol
```

`--locked` no longer applies: the `[patch.crates-io]` entries rewrite the lock.

The resulting binary links **`libwebkit2gtk-4.1.so.0`** and `libsoup-3.0.so.0`,
spawns `/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess`, and only
logs one harmless deprecation notice
(`webkit_settings_set_enable_offline_web_application_cache is deprecated`) from
a setting 4.1 removed.

## Packaging

`pot-pack-local.sh` (outside this tree) derives `Depends` from the binary's
direct `NEEDED` entries via `dpkg -S`, which correctly yields the Debian 13
names (`libgtk-3-0t64`, `libwebkit2gtk-4.1-0`, `libsoup-3.0-0`, …), adds
`tesseract-ocr` for the OCR path, and builds with `dpkg-deb`.
