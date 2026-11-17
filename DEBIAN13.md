# Pot on Debian 13 / WebKitGTK 4.1

这个仓库是 [pot-app/pot-desktop](https://github.com/pot-app/pot-desktop) 3.0.7 的
**WebKitGTK 4.1 移植版**，目标是在 **Debian 13 (trixie)** 及同类发行版
（Ubuntu 24.04+、Fedora 40+ 等已经只提供 WebKitGTK 4.1 的系统）上**从源码构建并能正常运行**。

应用自身的业务代码**一行未改**；改动集中在两个 GUI 依赖 crate 上。

> Upstream `pot-app/pot-desktop` 已归档（archived）。本 fork 保留其 GPL-3.0 许可与全部历史，
> 仅做发行版兼容性维护。

---

## 1. 为什么需要这个 fork

Pot 3.0.7 是 Tauri 1.8 应用，而 Tauri 1.8 的 Linux 后端锁死在 WebKitGTK **4.0**：

```
pot → tauri 1.8.1 → wry 0.24.11 → webkit2gtk 0.18.2 → webkit2gtk-4.0 + soup2(libsoup-2.4)
```

Debian 13 移除了整个 `libwebkit2gtk-4.0*`（仓库里只剩 `libwebkit2gtk-4.0-doc` 这个
transitional 空壳），只提供 `libwebkit2gtk-4.1`（基于 libsoup3）。因此：

- 按官方文档 `apt install libwebkit2gtk-4.0-dev` → 包不存在，构建无法开始；
- 即使把 Debian 12 的 4.0 dev 包搬过来，运行时也会直接 abort：

  ```
  libsoup-3 symbols detected. Using libsoup2 and libsoup3 in the same process is not supported.
  ```

  因为 WebKitGTK 4.1 链接 libsoup3，而 Tauri 1.8 的依赖链会把 libsoup2 拖进同一个进程，
  libsoup3 检测到后主动终止进程。

把应用迁移到 Tauri 2（原生支持 4.1）需要同时改写 Rust 端 handler、前端
`@tauri-apps/api` v1 → v2、以及 allowlist → capabilities，属于重写级改动；本 fork 选择
代价更小、行为完全不变的路线：**只把那两个 GUI crate 搬到 4.1**。

## 2. 改了什么

`src-tauri/Cargo.toml` 增加了三个本地补丁：

```toml
[patch.crates-io]
webkit2gtk  = { path = "vendor/webkit2gtk" }
wry         = { path = "vendor/wry" }
soup2-sys   = { path = "vendor/soup2-sys" }
```

| 补丁 | 内容 |
| --- | --- |
| `vendor/webkit2gtk` (0.18.2) | 移除从未被调用的 `soup2` 依赖；把带 soup 类型的 API（`CookieManager` 的 cookie 方法、`URIRequest`/`URIResponse`/`URISchemeRequest`/`URISchemeResponse` 的 `http_headers`）统一关到 `dox` feature 后面，不参与编译；新增 `src/message_headers.rs` 垫片 |
| `vendor/wry` (0.24.11) | 显式 `use webkit2gtk::SettingsExt as _;`（4.0 时代靠 glob import 偶然生效，新 bindings 需要 trait 在作用域内，否则 7 个 `Settings` setter 报 E0599）；移除声明了但未使用的 `soup2` 依赖 |
| `vendor/soup2-sys` (0.2.0) | build script 置空，不再 advertise `-lsoup-2.4`。`webkit2gtk-sys` 的 bindings 里仍出现 `soup_sys` 类型名，但只要不链接 libsoup2，libsoup3 就不会 abort |

### `MessageHeaders` 垫片做了什么

WebKitGTK 4.1 的 `webkit_uri_request_get_http_headers()` 返回的是 **libsoup3** 的
`SoupMessageHeaders*`。wry 只用到其中一个方法（`append`），而 soup3 与 soup2 的该符号同名。
因此垫片直接持有原始指针，调用 **libsoup3 的** `soup_message_headers_append`：

```rust
#[link(name = "soup-3.0")]
extern "C" { fn soup_message_headers_append(h: *mut c_void, n: *const c_char, v: *const c_char); }
```

类型完全正确（对象本来就是 soup3 的），且进程里不会出现 libsoup2。

## 3. 从源码构建

以 Debian 13 arm64 为例（x86_64 同理）：

```sh
# 1) 构建依赖
sudo apt install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev \
  libjavascriptcoregtk-4.1-dev libsoup-3.0-dev libsoup2.4-dev \
  libayatana-appindicator3-dev librsvg2-dev libssl-dev nodejs npm tesseract-ocr

# 2) 依赖的 build script 仍会向 pkg-config 要已被删除的 4.0 名字，做个映射
sudo mkdir -p /opt/gtk41-shim
sudo tee /opt/gtk41-shim/webkit2gtk-4.0.pc >/dev/null <<'PC'
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
sudo sed 's/WebKit2GTK/JavaScriptCoreGTK/; s/webkit2gtk-4\.1/javascriptcoregtk-4.1/g; s/-lwebkit2gtk-4.1/-ljavascriptcoregtk-4.1/' \
  /opt/gtk41-shim/webkit2gtk-4.0.pc | sudo tee /opt/gtk41-shim/javascriptcoregtk-4.0.pc >/dev/null

# 3) webkit2gtk-sys 还会在链接行里硬编码 -lwebkit2gtk-4.0，补同名软链
sudo ln -sf libwebkit2gtk-4.1.so.0 /usr/lib/aarch64-linux-gnu/libwebkit2gtk-4.0.so
sudo ln -sf libjavascriptcoregtk-4.1.so.0 /usr/lib/aarch64-linux-gnu/libjavascriptcoregtk-4.0.so

# 4) 前端（vite 产物与架构无关；--ignore-scripts 可跳过不需要的 tauri CLI 下载）
pnpm install --frozen-lockfile --ignore-scripts
pnpm build

# 5) Rust
cd src-tauri
PKG_CONFIG_PATH=/opt/gtk41-shim cargo build --release --features custom-protocol
```

说明：
- **不要加 `--locked`**，`[patch.crates-io]` 会重写 `Cargo.lock`。
- x86_64 请把上面路径里的 `aarch64-linux-gnu` 换成 `x86_64-linux-gnu`。
- 首次构建在 8 核 arm64 上约 40–60 分钟（含 `lingua` 语言模型），之后增量很快。

## 4. 打包成 .deb

`Depends` 由二进制的**直接 `NEEDED`** 反查（`dpkg -S`）生成，因此拿到的是 Debian 13 的真实包名
（含 t64 改名）：

```
libwebkit2gtk-4.1-0, libjavascriptcoregtk-4.1-0, libsoup-3.0-0, libgtk-3-0t64,
libjavascriptcoregtk-4.1-0, libayatana-appindicator3-1, libssl3t64, libc6 (>= 2.35),
tesseract-ocr, ...
```

Debian 12 的包在该环境下已无法直接使用，建议直接装 Release 里提供的 arm64 包：

```sh
sudo apt install ./pot_3.0.7_arm64.deb
```

## 5. 已验证

在 Debian 13 (trixie) arm64、KDE Wayland、WebKitGTK 4.1 2.54 上实测：

- 二进制 `NEEDED` 为 `libwebkit2gtk-4.1.so.0` + `libsoup-3.0.so.0`，**没有任何 libsoup-2.4 依赖**；
- 启动后正常拉起了 `/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess`
  与 `WebKitNetworkProcess`，窗口与托盘可用；
- 仅有一条无害告警：`webkit_settings_set_enable_offline_web_application_cache is deprecated`，
  该设置 4.1 已移除，wry 仍在设，忽略即可。

## 6. 已知限制

- 只实测了 **arm64**；x86_64 理论上同样适用（同一套补丁），但没有真机验证，也没有 CI。
- 未迁移到 Tauri 2，因此仍继承 Tauri 1 在 Linux 上的既有问题（如个别桌面环境的托盘/快捷键差异）。
- OCR 走的是系统 `tesseract`，需要安装对应语言包（`tesseract-ocr-chi-sim` 等）。
- `vendor/` 里的三个 crate 是从 crates.io 拷出来打的补丁，体积约 2 MB；升级 Tauri/WebKitGTK 时
  需要重新对照 `vendor/PATCHES.md` 复核。

## 7. 许可

原项目为 **GPL-3.0**，本仓库保留原 `LICENSE` 与完整 git 历史，属于 GPL-3.0 的修改版本，
同样以 GPL-3.0 分发。修改点见本文第 2 节及 `src-tauri/vendor/PATCHES.md`。
