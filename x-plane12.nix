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
, libgbm
, nss
, zlib
, nspr
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
    libgbm
    curl
    nss
    nspr
    zlib
    pango
    vulkan-loader
    webkitgtk_4_1
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
