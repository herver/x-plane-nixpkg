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
, curl
, libGL
, libGLU
, libgbm
, nss
, zlib
, nspr
, openal
, pango
, vulkan-loader
, webkitgtk_4_1
, wl-clipboard
, xclip
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
    # The ToLiss AirbusFBW plugin statically links curl + OpenSSL to fetch the
    # SimBrief flight plan (https://www.simbrief.com/...) and drive Hoppie CPDLC
    # (https://www.hoppie.nl/...). Its OpenSSL is built with OPENSSLDIR
    # "/usr/lib/ssl", whose default cert.pem/certs dir does not exist in the FHS
    # tree, so TLS peer verification fails and every request returns 0 bytes
    # ("Copied 0 bytes of data in response to Simbrief request" in Log.txt).
    # OpenSSL honours SSL_CERT_FILE for its default trust store; point it at the
    # cacert bundle (a /nix/store path, visible because the store is bind-mounted
    # inside the FHS env). CURL_CA_BUNDLE covers any addon libcurl that reads it.
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export CURL_CA_BUNDLE=${cacert}/etc/ssl/certs/ca-bundle.crt
  '';

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
