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
NIXPKGS_ALLOW_UNFREE=1 nix-build --no-sandbox -I nixpkgs=channel:nixpkgs-unstable -E \
  '(import <nixpkgs> { config.allowUnfree = true; }).callPackage ./x-plane12.nix {}'
./result/bin/x-plane12
```
The launcher needs a nixpkgs whose glibc is ≥ 2.43 (asserted at eval time): addons built on newer distros (e.g. Falcon 8X's `libXPSV`) import `GLIBC_2.43` libm symbols, and nixos-26.05 ships glibc 2.42.

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

The launcher **replaces** the caller's `LD_LIBRARY_PATH` instead of appending to it. Host `/nix/store` entries are built against a different glibc than the FHS tree; inherited from a shell that sets them, they make `libwebkit2gtk-4.1.so.0` fail to load (`GLIBC_2.xx not found`), which disables Identity login and puts X-Plane in the product-key dialog.

**Vulkan device discovery:** The Vulkan loader finds ICD files via `XDG_DATA_DIRS`. On NixOS the NVIDIA ICD lives at `/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json`. The launcher sets `XDG_DATA_DIRS=/run/opengl-driver/share:...` so the NVIDIA GPU is discovered. Without this, only the Mesa software/iGPU devices are visible.

**Identity login window:** the login window is WebKitGTK running inside the game process, so it inherits the Zink env (`MESA_LOADER_DRIVER_OVERRIDE=zink`, …) X-Plane sets from `Resources/dlls/64/zink/zink_link.json`. With GPU compositing it renders solid black. The launcher exports `WEBKIT_DISABLE_COMPOSITING_MODE=1` and `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` so it renders on the CPU; redraws are slow at 4K, but only the login window uses WebKit.

**Invisible dialogs / no clicks:** CEF's GPU program cache (`Output/caches/cef/_local/GPUCache`, `DawnCache`) can go stale — seen after a reboot. Every Skia shader then fails to link (`Skia shader compilation error` in `debug.log`), CEF draws nothing, and its modal dialogs are invisible while still swallowing every click: the main menu looks dimmed and nothing responds. The launcher deletes both directories on each start; Chromium regenerates them.

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

### Plugin HTTPS / CA certificates (hashed `/etc/ssl/certs`)

The ToLiss `AirbusFBW_XP11` plugin **statically links its own curl + OpenSSL**
(vendored, Debian/Ubuntu-built) to fetch the SimBrief flight plan
(`https://www.simbrief.com/api/xml.fetcher.php`) and to drive Hoppie CPDLC
(`https://www.hoppie.nl/acars/system/connect.html`). On NixOS both requests come
back empty; `Log.txt` shows:

```
ToLiss aircraft systems plugin: Launching http request to URL: https://www.simbrief.com/api/xml.fetcher.php?userid=NNNNNN
ToLiss aircraft systems plugin: http request completed successfully.
ToLiss aircraft systems plugin: Processing data received from http request for request ID 1; buffer Size: 0
ToLiss aircraft systems plugin: Copied 0 bytes of data in response to Simbrief request.
```

("completed successfully" is misleading — the plugin swallows the transfer
error.) A packet capture shows the real failure: the TLS handshake gets the
server's (valid, Let's Encrypt-signed) certificate chain and the client
immediately sends a fatal `Unknown CA` alert. The plugin's TLS client cannot find
a trusted root.

**Root cause.** That vendored curl passes its compiled-in **CApath
`/etc/ssl/certs`** *explicitly* to OpenSSL via `SSL_CTX_load_verify_locations()`.
That is a **hashed-directory** trust store: OpenSSL only reads per-CA
subject-hash symlinks (`<hash>.0`, e.g. `4042bcee.0` = ISRG Root X1). Debian
populates those symlinks, which is why the vendor's build machine never sees the
bug. NixOS `/etc/ssl/certs` contains only the `ca-certificates.crt` bundle file
and **no hash symlinks**, so the hashed lookup finds nothing → empty trust store
→ `Unknown CA` → 0 bytes. (Fedora is affected too: its hash symlinks live in
`/etc/pki/tls/certs`, not `/etc/ssl/certs`.)

Because the CApath is set *explicitly*, none of the usual escape hatches work:
`SSL_CERT_FILE`/`SSL_CERT_DIR` and the compiled-in `OPENSSLDIR` (`/usr/lib/ssl`)
defaults are consulted only on OpenSSL's *default-paths* code path, which an
explicit `SSL_CTX_load_verify_locations()` bypasses. Verified empirically: env
vars and a populated `/usr/lib/ssl/cert.pem` change nothing; **only real hash
entries in `/etc/ssl/certs` fix it.**

**The fix.** Build a directory that carries both the OpenSSL hash symlinks (for
the plugin's hashed CApath lookup) and the flat `ca-certificates.crt` bundle (for
CAfile consumers such as the base game's own HTTP stack, which logs
`I/HTTP: Using built-in certificate path: /etc/ssl/certs/ca-certificates.crt`),
then bind it over `/etc/ssl/certs` inside the sandbox:

```nix
sslCerts = runCommand "x-plane12-ssl-certs" { nativeBuildInputs = [ openssl ]; } ''
  mkdir -p $out; cd $out
  awk '/BEGIN CERTIFICATE/{n++; f=sprintf("cert-%04d.pem", n); inb=1} inb{print > f} /END CERTIFICATE/{inb=0; close(f)}' ${cacert}/etc/ssl/certs/ca-bundle.crt
  openssl rehash $out
  cp ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ca-certificates.crt
  ln -s ca-certificates.crt $out/ca-bundle.crt
'';
# ...
extraBwrapArgs = [ "--tmpfs /etc/ssl" "--ro-bind ${sslCerts} /etc/ssl/certs" ];
```

`buildFHSEnv` binds the host's `/etc/ssl/certs` (via a `--symlink` earlier in the
bwrap command line), so `--tmpfs /etc/ssl` drops that symlink and the following
`--ro-bind` installs our hashed dir. `cacert` and `openssl` are function
arguments; `cacert` is **not** in `targetPkgs` (`/etc/ssl` is host-bound, so a
merged copy would be shadowed — the bwrap bind is what works). The awk step
splits the NSS bundle into one cert per file (dropping its label lines) so
`openssl rehash` can generate one `<hash>.0` per root.

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

### Mesa DRI driver libraries (`zstd`, `libxshmfence`)

On NixOS the GPU driver libs come from `/run/opengl-driver/lib`, which is
bind-mounted into the FHS environment. Mesa's Gallium DRI driver
(`libgallium_dri.so`) `dlopen`s a few libraries that live in the *system* FHS
tree, not under `/run/opengl-driver`, so each must be in `targetPkgs`:

- `zstd` (`libzstd.so.1`) — Mesa compresses its on-disk shader cache with zstd
- `libxshmfence` (`libxshmfence.so.1`) — DRI3 fence shared-memory primitive

If any is missing, GL context creation aborts *before* Vulkan device
enumeration. `Log.txt` shows a single early line:

```
0:00:00.000 E/SYS: MACIBM_alert: Failed to load libgallium_dri.so, error: libzstd.so.1: cannot open shared object file: No such file or directory
```

and X-Plane crashes. The **only** thing printed to the terminal is SDL's
`Couldn't load font ...` message-box fallback (see below), so treat a bare
font error with no other output as a DRI load failure and read `Log.txt` for
the real `MACIBM_alert` line. Rescan the driver's needs with
`ldd /run/opengl-driver/lib/dri/*_dri.so` when chasing a new one.

### Bundled Zink driver libraries (`lm_sensors`, `libXxf86vm`)

X-Plane runs exclusively on Vulkan; plugin OpenGL is translated to Vulkan
through **Zink**. X-Plane ships its *own* Mesa/Zink build for this at
`Resources/dlls/64/zink/` (`libgallium_dri.so` + `libGL.so`, selected via
`MESA_LOADER_DRIVER_OVERRIDE=zink` in `zink/zink_link.json`). It is used when
the game is launched with `--zink` or when Zink is selected in Graphics
settings; otherwise the OpenGL bridge uses the system native GL (`radeonsi`).

Both bundled libs have an **empty RUNPATH**, so every `DT_NEEDED` must resolve
from the FHS tree. Beyond the DRI libs above, two more are required:

- `lm_sensors` (`libsensors.so.5`) — a `DT_NEEDED` of the bundled
  `libgallium_dri.so` (also listed in `zink_link.json`). **Must** be spelled
  `lm_sensors.out` in `targetPkgs`: `lm_sensors` installs only its `bin`+`man`
  outputs by default and the `.so` lives in `out`.
- `libxxf86vm` (`libXxf86vm.so.1`) — a `DT_NEEDED` of the bundled `libGL.so`.

Failure modes are staged: with `libsensors.so.5` missing the Zink `dlopen`
fails silently and X-Plane falls back to native GL — `Log.txt` still shows
`Supports Zink: Yes` but the *OpenGL bridge device* reports `radeonsi`, not
`zink`. With that fixed but `libXxf86vm.so.1` missing, a `--zink` launch
crashes at startup the same way the DRI crash above does (`MACIBM_alert:
Failed to load libGL.so ... libXxf86vm.so.1` → `xplm not running`). When Zink
is active the bridge device reads e.g.
`zink Vulkan 1.4(AMD Radeon RX 7900 XTX (RADV NAVI31) (MESA_RADV))`. Rescan
with `readelf -d Resources/dlls/64/zink/{libgallium_dri.so,libGL.so} | grep
NEEDED` when chasing a new one.

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
- `Couldn't load font -*-*-medium-r-normal--0-120-*-*-p-0-iso8859-1` — SDL trying to load an X11 bitmap font for its fallback message-box renderer; harmless when the main UI initialises successfully. **If it is the only output and the game exits**, it is SDL failing to render a *real* error box: read `Log.txt` for the preceding `MACIBM_alert` line (a DRI/Zink `libgallium_dri.so`/`libGL.so` load failure — see the two driver-library sections above)
- `Resources/dlls/handler` crash handler subprocess fails to start — this is the CEF crash reporter; it does not affect gameplay
- `[ERROR elf_dynamic_array_reader.h:64] tag not found` — benign CEF startup message

## Version history

| Version | Date | Notes |
|---------|------|-------|
| 12.3.0 | Nov 2025 installer / Dec 2025 game | Initial packaging |
| 12.3.0 | Aug 2026 | Added `openal` and `libGLU` for third-party aircraft plugins |
| 12.3.0 | Sep 2026 | Added `wl-clipboard` + Wayland `xclip` shim so ToLiss SimBrief/Hoppie clipboard paste works on Wayland |
| 12.3.0 | Sep 2026 | Added `cacert`+`openssl`-built hashed `/etc/ssl/certs` (bound via `extraBwrapArgs`) so ToLiss's vendored curl finds the CA roots (hashed CApath) — fixes SimBrief/Hoppie downloads returning 0 bytes on NixOS |
| 12.3.0 | Sep 2026 | Added `zstd` + `libxshmfence` (Mesa DRI driver `dlopen` deps) — fixes a startup crash on X-Plane 12.4.x betas whose only terminal symptom is SDL's `Couldn't load font` message |
| 12.3.0 | Sep 2026 | Added `lm_sensors.out` + `libxxf86vm` (bundled `Resources/dlls/64/zink/` driver `DT_NEEDED`s) so the Zink OpenGL-on-Vulkan bridge loads with `--zink` / the Zink graphics setting instead of failing to native GL |
