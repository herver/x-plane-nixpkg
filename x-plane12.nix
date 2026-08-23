{ lib
, buildFHSEnv
, writeShellScript
, alsa-lib
, at-spi2-core
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
}:

let
  runScript = writeShellScript "x-plane12" ''
    dir="''${XPLANE12_DIR:-$HOME/X-Plane 12}"
    if [ ! -x "$dir/X-Plane-x86_64" ]; then
      echo "X-Plane 12 not found at: $dir"
      echo "Install it with x-plane12-installer, or set XPLANE12_DIR."
      exit 1
    fi
    cd "$dir"
    export LD_LIBRARY_PATH="$dir/Resources/dlls/64:$dir/Resources/dlls/64/cef/lin:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
    # Expose the NixOS driver Vulkan ICD files to the Vulkan loader.
    export XDG_DATA_DIRS="/run/opengl-driver/share:''${XDG_DATA_DIRS:-/usr/share}"
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
  ];

  # GIO's module directory is compiled into libgio as a /nix/store path, so it
  # never sees the FHS tree. Without this the GnuTLS module is not loaded and
  # WebKit reports "TLS support is not available".
  profile = ''
    export GIO_EXTRA_MODULES=/usr/lib/gio/modules
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
