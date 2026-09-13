{ lib
, buildFHSEnv
, writeShellScript
, writeShellScriptBin
, alsa-lib
, at-spi2-core
, cacert
, cairo
, cups
, dbus
, expat
, gdk-pixbuf
, glib
, glib-networking
, gtk3
, harfbuzz
, libdrm
, libx11
, libxcb
, libxcomposite
, libxcursor
, libxdamage
, libxext
, libxfixes
, libxinerama
, libxkbcommon
, libxrandr
, libxshmfence
, libxxf86vm
, curl
, libGL
, libGLU
, libgbm
, lm_sensors
, nss
, zlib
, zstd
, nspr
, openal
, pango
, vulkan-loader
, webkitgtk_4_1
, wl-clipboard
, xclip
, openssl
, runCommand
}:

let
  # The ToLiss AirbusFBW + MangoStudios plugins shell out to `xclip` to read the
  # clipboard (SimBrief ID, Hoppie logon code) and to write it back. Real xclip
  # is X11-only: on a Wayland session it can only reach X-Plane's XWayland
  # server, whose compositor<->XWayland clipboard bridge is unreliable and does
  # not export the PRIMARY selection that `xclip -o` reads, so paste returns
  # nothing. This shim maps the xclip flags those plugins use onto wl-clipboard,
  # which talks to the Wayland compositor directly. It shadows the real xclip
  # only on Wayland (see PATH in runScript); X11 sessions keep the real xclip.
  waylandXclip = writeShellScriptBin "xclip" ''
    sel=primary
    mode=in
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|-out) mode=out ;;
        -i|-in) mode=in ;;
        -sel|-select|-selection)
          shift
          case "''${1:-}" in c*|C*) sel=clipboard ;; *) sel=primary ;; esac ;;
        -sel=*|-select=*|-selection=*)
          case "''${1#*=}" in c*|C*) sel=clipboard ;; *) sel=primary ;; esac ;;
        -d|-display|-t|-target|-l|-loops) shift ;;
        *) ;;
      esac
      shift
    done
    prim=()
    [ "$sel" = primary ] && prim=(--primary)
    if [ "$mode" = out ]; then
      exec wl-paste --no-newline "''${prim[@]}"
    else
      exec wl-copy "''${prim[@]}"
    fi
  '';

  runScript = writeShellScript "x-plane12" ''
    dir="''${XPLANE12_DIR:-$HOME/flightsim/X-Plane 12}"
    if [ ! -x "$dir/X-Plane-x86_64" ]; then
      echo "X-Plane 12 not found at: $dir"
      echo "Install it with x-plane12-installer, or set XPLANE12_DIR."
      exit 1
    fi
    cd "$dir"
    export LD_LIBRARY_PATH="$dir/Resources/dlls/64:$dir/Resources/dlls/64/cef/lin:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
    # Expose the NixOS driver Vulkan ICD files to the Vulkan loader.
    export XDG_DATA_DIRS="/run/opengl-driver/share:''${XDG_DATA_DIRS:-/usr/share}"
    # On Wayland, shadow the X11-only xclip the ToLiss plugins call with the
    # wl-clipboard shim so SimBrief/Hoppie clipboard paste works without relying
    # on the flaky XWayland clipboard bridge.
    if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
      export PATH="${waylandXclip}/bin:$PATH"
    fi
    exec "$dir/X-Plane-x86_64" "$@"
  '';

  # ToLiss's AirbusFBW plugin statically links a Debian-built curl whose
  # compiled-in CApath (/etc/ssl/certs) is passed explicitly to OpenSSL via
  # SSL_CTX_load_verify_locations(). That is a *hashed-directory* trust store: it
  # only reads per-CA subject-hash symlinks (<hash>.0). Debian ships those; NixOS
  # /etc/ssl/certs holds just the ca-certificates.crt bundle and no hash links,
  # so the plugin's trust store is effectively empty -> "Unknown CA" TLS alert ->
  # the SimBrief/Hoppie downloads return 0 bytes ("Copied 0 bytes ..." in
  # Log.txt). Because the CApath is set explicitly, SSL_CERT_FILE/SSL_CERT_DIR
  # and the OPENSSLDIR defaults are all bypassed -- only real hash entries in
  # /etc/ssl/certs fix it. Build a dir with both the hash symlinks (for the
  # plugin) and the flat bundle (for CAfile consumers such as the base game's own
  # HTTP stack), then bind it over /etc/ssl/certs in the sandbox (extraBwrapArgs).
  sslCerts = runCommand "x-plane12-ssl-certs" { nativeBuildInputs = [ openssl ]; } ''
    mkdir -p $out
    cd $out
    # One certificate per file (drop the NSS label lines the bundle interleaves),
    # then generate the OpenSSL subject-hash symlinks a hashed CApath lookup needs.
    awk '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("cert-%04d.pem", n); inb=1} inb{print > f} /-----END CERTIFICATE-----/{inb=0; close(f)}' ${cacert}/etc/ssl/certs/ca-bundle.crt
    openssl rehash $out
    # Keep the flat bundle too (CAfile consumers, e.g. the base game reads
    # /etc/ssl/certs/ca-certificates.crt).
    cp ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ca-certificates.crt
    ln -s ca-certificates.crt $out/ca-bundle.crt
  '';
in
buildFHSEnv {
  name = "x-plane12";

  targetPkgs = _pkgs: [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    # GIO's TLS backend (libgiognutls.so); see the profile below.
    glib-networking
    gtk3
    harfbuzz
    libdrm
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxinerama
    libxkbcommon
    libxrandr
    libGL
    # Addon-only: ToLiss MangoStudios and Rotate MD-11F plugins link it.
    libGLU
    libgbm
    curl
    nss
    nspr
    # Addon-only: ToLiss MangoStudios plugin links libopenal.so.1.
    openal
    zlib
    # Mesa's DRI/Gallium driver (libgallium_dri.so from /run/opengl-driver/lib)
    # dlopens these; without them GL context creation fails with "Failed to load
    # libgallium_dri.so ... <lib>: cannot open shared object file" and X-Plane
    # crashes at startup (the only visible symptom is SDL's benign "Couldn't load
    # font" message box fallback).
    zstd            # libzstd.so.1
    libxshmfence    # libxshmfence.so.1
    # X-Plane's own bundled Zink stack (Resources/dlls/64/zink/{libgallium_dri.so,
    # libGL.so}), used with `--zink` to run plugin OpenGL on top of Vulkan, needs
    # these two. Both bundled libs have no /nix/store RUNPATH, so every DT_NEEDED
    # must resolve from the FHS tree. Without them the Zink dlopen fails: missing
    # libsensors.so.5 makes libgallium_dri.so unloadable (silent fallback to
    # native GL -- "Supports Zink: Yes" but the bridge device reports radeonsi,
    # not zink); with that fixed, libGL.so then needs libXxf86vm.so.1 or `--zink`
    # crashes at startup (gfx_ogl_bridge_context_x11.cpp -> "xplm not running").
    # lm_sensors: .out because it installs only bin+man by default; the .so is in out.
    lm_sensors.out    # libsensors.so.5
    libxxf86vm        # libXxf86vm.so.1
    pango
    vulkan-loader
    webkitgtk_4_1
    # Wayland clipboard tools (wl-copy/wl-paste). Backs the xclip shim in
    # runScript that ToLiss's SimBrief/Hoppie clipboard reads use on Wayland.
    wl-clipboard
    # Addon-only: ToLiss AirbusFBW + MangoStudios plugins shell out to xclip to
    # read/write the clipboard. Used directly on X11; on Wayland it is shadowed
    # by the wl-clipboard shim (see waylandXclip / PATH in runScript).
    xclip
  ];

  # GIO's module directory is compiled into libgio as a /nix/store path, so it
  # never sees the FHS tree. Without this the GnuTLS module is not loaded and
  # WebKit reports "TLS support is not available".
  profile = ''
    export GIO_EXTRA_MODULES=/usr/lib/gio/modules
  '';

  # Replace the sandbox's /etc/ssl/certs (which buildFHSEnv binds from the host,
  # and on NixOS holds only the bundle file) with a dir that also carries the
  # OpenSSL hash symlinks the ToLiss plugin's hashed CApath lookup requires. The
  # symlink buildFHSEnv sets up for /etc/ssl/certs runs earlier in the bwrap
  # command; --tmpfs /etc/ssl drops it so the following --ro-bind takes effect.
  extraBwrapArgs = [
    "--tmpfs /etc/ssl"
    "--ro-bind ${sslCerts} /etc/ssl/certs"
  ];

  inherit runScript;

  meta = {
    description = "X-Plane 12 flight simulator";
    homepage = "https://www.x-plane.com/";
    license = lib.licenses.unfree;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "x-plane12";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
