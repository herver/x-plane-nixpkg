# X-Plane 12 Nix Packages

Two Nix expressions for running X-Plane 12 on NixOS:

- `x-plane12-installer.nix` — runs the Laminar Research installer to download and install the game
- `x-plane12.nix` — launcher for the installed game

## Usage

**Install:**
```
NIXPKGS_ALLOW_UNFREE=1 nix-build --no-sandbox -E \
  '(import <nixpkgs> { config.allowUnfree = true; }).callPackage ./x-plane12-installer.nix {}'
./result/bin/x-plane12-installer
```
Follow the on-screen instructions. The game installs to `~/X-Plane 12/` by default.

**Run:**
```
NIXPKGS_ALLOW_UNFREE=1 nix-build --no-sandbox -E \
  '(import <nixpkgs> { config.allowUnfree = true; }).callPackage ./x-plane12.nix {}'
./result/bin/x-plane12
```

Set `XPLANE12_DIR` to override the install location:
```
XPLANE12_DIR=/data/X-Plane\ 12 ./result/bin/x-plane12
```

## Architecture

Both packages use `buildFHSEnv` (bubblewrap-based) rather than `autoPatchelfHook`. This was a deliberate choice: X-Plane dlopen's many libraries at runtime (Vulkan, WebKit, OpenGL, CEF, audio), and the game supports user-installed plugins that also expect a standard Linux filesystem. `buildFHSEnv` provides a stable `/lib`, `/lib64`, `/usr/lib` environment that works for all of these without needing to patch every binary.

### Installer (`x-plane12-installer.nix`)

Structure: an inner `unwrapped` derivation extracts the binary from the ZIP (no patching), wrapped in `buildFHSEnv`.

The installer binary (`X-Plane 12 Installer Linux`) is a single ELF built with Conan. Its RPATH contains stale `/root/.conan2/...` entries from the build machine — these are harmless because all of those dependencies (boost, openssl, curl, etc.) are statically linked. The only runtime-dynamic dependencies are the GTK3/X11 libs listed in `targetPkgs`.

The installer also dlopen's:
- `libvulkan.so.1` (for the Vulkan-based UI renderer) — provided via `vulkan-loader`
- `libwebkit2gtk-4.1.so.0` (for the X-Plane Identity login flow) — provided via `webkitgtk_4_1`

Without webkit, the installer still runs but login is disabled and you can't download the full simulator.

The installer downloads game files from `https://tower.x-plane.com/v1/sim-download` at runtime, so it cannot be run in the Nix build sandbox. It is purely a wrapped binary that users run interactively.

**Installer source URL:** `https://lookup.x-plane.com/_lookup_12_/download/X-Plane12InstallerLinux.zip`

This URL is stable and publicly accessible without authentication. The installer enforces the license at runtime (via X-Plane Identity OAuth2 at `https://ident.x-plane.com/`). Version `12.3.0` was current as of April 2026; the `_lookup_12_` segment may change on a major version bump.

### Game launcher (`x-plane12.nix`)

The installed game binary (`X-Plane-x86_64`) has hardcoded references to bundled libraries in `Resources/dlls/64/`. The launcher sets `LD_LIBRARY_PATH` to expose these before exec'ing the binary:

- `Resources/dlls/64/` — FMOD audio (`libfmod.so.13`, `libfmodstudio.so.13`), OpenVR (`libopenvr_api.so`), Discord SDK
- `Resources/dlls/64/cef/lin/` — Chromium Embedded Framework (`libcef.so`) and its helpers

**Do not add `Resources/dlls/64/gl/`** to `LD_LIBRARY_PATH`. That directory contains X-Plane's own `libGL.so` stub, which crashes on NixOS. Instead, `libGL` from nixpkgs (libglvnd) is in `targetPkgs`, and `/run/opengl-driver/lib` is prepended to `LD_LIBRARY_PATH` so both `libGL.so` and the NVIDIA/Mesa driver libraries are found.

**Vulkan device discovery:** The Vulkan loader finds ICD files via `XDG_DATA_DIRS`. On NixOS the NVIDIA ICD lives at `/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json`. The launcher sets `XDG_DATA_DIRS=/run/opengl-driver/share:...` so the NVIDIA GPU is discovered. Without this, only the Mesa software/iGPU devices are visible.

### `targetPkgs` notes

`buildFHSEnv`'s `targetPkgs` does **not** automatically include transitive dependencies — every package whose `.so` files the binary needs at startup must be listed explicitly. The full list was derived by running `patchelf --print-needed` on `X-Plane-x86_64` and all `.so` files in `Resources/dlls/64/` and `Resources/dlls/64/cef/lin/`, filtering out the bundled libs, then mapping to nixpkgs package names.


That derivation covered the **base game only**. Third-party aircraft ship their own plugins under `Aircraft/*/plugins/*/lin_x64/` (and `.../64/lin.xpl`) with dependencies of their own — see below. To rescan an install for libraries the FHS environment does not yet provide:

```
cd ~/X-Plane\ 12
{ find . -path '*lin_x64/*' -name '*.xpl'; find . -path '*/64/lin.xpl'; } \
  | while read -r f; do readelf -d "$f" | grep NEEDED; done | sort -u
```
Use `nix-shell -p nix-index --run "nix-locate <libname>"` to find the correct nixpkgs attribute for any missing library.

### TLS support (`glib-networking`)

Both packages need `glib-networking` in `targetPkgs` **and** `GIO_EXTRA_MODULES=/usr/lib/gio/modules` set in the `profile`. Without both, WebKit/libsoup fails with **"TLS support is not available"** and the X-Plane Identity login cannot proceed — in the installer this blocks the download of the simulator entirely.

GIO discovers its TLS backend by loading a module (`libgiognutls.so`) from a directory that is compiled into `libgio` at build time as a `/nix/store/...-glib-2.x/lib/gio/modules` path. That store path is visible inside the FHS environment but contains no modules, and the merged FHS copy at `/usr/lib/gio/modules` is never searched. Adding the package alone is therefore not enough: `g_tls_backend_get_default()` still returns `GDummyTlsBackend` and `supports_tls()` is false. The `GIO_EXTRA_MODULES` export is what makes the loader pick up `GTlsBackendGnutls`.

Note this is separate from the installer's own HTTPS downloads, which work regardless — curl and OpenSSL are statically linked into the installer binary, so only the WebKit-based login path is affected.

### Plugin HTTPS / CA certificates (`SSL_CERT_FILE`)

The ToLiss `AirbusFBW_XP11` plugin **statically links its own curl + OpenSSL** to
fetch the SimBrief flight plan (`https://www.simbrief.com/api/xml.fetcher.php`)
and to drive Hoppie CPDLC (`https://www.hoppie.nl/acars/system/connect.html`).
That OpenSSL was built with `OPENSSLDIR: "/usr/lib/ssl"`, so its default trust
store is `/usr/lib/ssl/cert.pem` + `/usr/lib/ssl/certs` — paths that **do not
exist** in the FHS tree (`buildFHSEnv` binds the host `/etc/ssl/certs`, not
`/usr/lib/ssl`). With no CA bundle, TLS peer verification fails and every request
returns 0 bytes. The symptom in `Log.txt` is:

```
ToLiss aircraft systems plugin: Launching http request to URL: https://www.simbrief.com/api/xml.fetcher.php?userid=NNNNNN
ToLiss aircraft systems plugin: Copied 0 bytes of data in response to Simbrief request.
```

(and the equivalent `Copied 0 bytes ... CPDLC request` for Hoppie). This is
separate from the base game's own HTTP subsystem, which finds the host bundle on
its own — `Log.txt` logs `I/HTTP: Using built-in certificate path:
/etc/ssl/certs/ca-certificates.crt` — so the sim's built-in downloads work while
the plugin's do not.

The plugin's OpenSSL honours the `SSL_CERT_FILE` environment variable for its
default trust store, so the launcher exports it (plus `CURL_CA_BUNDLE` for any
addon libcurl that reads it) in the `profile`, pointing at the nixpkgs `cacert`
bundle. That is a `/nix/store` path, visible inside the FHS env because the store
is bind-mounted, so the fix is self-contained and does not depend on host cert
configuration. This is why `cacert` is a function argument even though it is not
in `targetPkgs` (`/etc/ssl` is bound from the host, so a `targetPkgs` entry would
be shadowed anyway — the store-path export is what works).

### Addon plugin libraries (`openal`, `libGLU`)

Third-party aircraft plugins need entries in `targetPkgs` too. Two are known:

- `openal` (openal-soft, `libopenal.so.1`) — the ToLiss `MangoStudios` plugin
- `libGLU` (glu, `libGLU.so.1`) — the same ToLiss plugin, and Rotate MD-11F's `MD-11-core` plugin

**The `Log.txt` error is misleading.** X-Plane prints the `dlerror:` line *after* the `Loaded:` line of the previous plugin, so it names the wrong file:

```
Loaded: .../ToLissA339_V1p2p1/plugins/AirbusFBW_XP11/lin_x64/AirbusFBW_XP11.xpl (XP11.ToLiss.Airbus.systems).
dlerror:libopenal.so.1: cannot open shared object file: No such file or directory
```

`AirbusFBW_XP11.xpl` has exactly one `DT_NEEDED` (`libc.so.6`) and no reference to OpenAL. The failure belongs to the *next* plugin in load order — `MangoStudios/64/lin.xpl`. When chasing one of these, check the plugin loaded after the one named.

No `profile` export is needed for either library. `openal-soft` resolves its own backends (ALSA, PulseAudio, PipeWire, D-Bus) through its `RUNPATH`, which stays valid because `/nix/store` is bind-mounted inside the FHS environment.

### Plugin clipboard (`xclip`, `wl-clipboard`)

The ToLiss `AirbusFBW_XP11` and `MangoStudios` plugins shell out to `xclip` to
read and write the X11 selection — used to paste the SimBrief pilot ID and
Hoppie logon code into the MCDU:

- `AirbusFBW_XP11`: `xclip -o` (reads the **PRIMARY** selection)
- `MangoStudios`: `xclip -selection clipboard` (write) and `-o` (read the **CLIPBOARD** selection)

Real `xclip` is X11-only. On a Wayland session X-Plane runs under XWayland, so
`xclip` can only reach the XWayland server; the compositor↔XWayland clipboard
bridge is unreliable and generally does not export PRIMARY, so the paste comes
back empty. The launcher therefore ships a tiny `xclip` shim
(`writeShellScriptBin "xclip"`) that maps those exact invocations onto
`wl-clipboard` (`wl-copy`/`wl-paste`), which talks to the Wayland compositor
directly. `runScript` prepends the shim to `PATH` **only when `WAYLAND_DISPLAY`
is set**, so X11 sessions keep using the real `xclip` from `targetPkgs`
unchanged. The Wayland socket (`$XDG_RUNTIME_DIR/wayland-1`) is reachable
because `buildFHSEnv` auto-binds `/run` into the sandbox.

### Known issues / non-fatal warnings

- `xdg-user-dir: command not found` — from the GTK wrapper script; harmless
- `Couldn't load font -*-*-medium-r-normal--0-120-*-*-p-0-iso8859-1` — SDL trying to load an X11 bitmap font for its fallback message box renderer; harmless when the main UI initialises successfully
- `Resources/dlls/handler` crash handler subprocess fails to start — this is the CEF crash reporter; it does not affect gameplay
- `[ERROR elf_dynamic_array_reader.h:64] tag not found` — benign CEF startup message

## Version history

| Version | Date | Notes |
|---------|------|-------|
| 12.3.0 | Nov 2025 installer / Dec 2025 game | Initial packaging |
| 12.3.0 | Aug 2026 | Added `openal` and `libGLU` for third-party aircraft plugins |
| 12.3.0 | Sep 2026 | Added `wl-clipboard` + Wayland `xclip` shim so ToLiss SimBrief/Hoppie clipboard paste works on Wayland |
| 12.3.0 | Sep 2026 | Added `cacert` + `SSL_CERT_FILE`/`CURL_CA_BUNDLE` exports so ToLiss SimBrief/Hoppie CPDLC HTTPS requests verify TLS and complete |
