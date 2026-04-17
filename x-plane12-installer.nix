{ lib
, buildFHSEnv
, stdenv
, fetchurl
, unzip
, at-spi2-core
, cairo
, dbus
, gdk-pixbuf
, glib
, gtk3
, harfbuzz
, libx11
, libxcursor
, libxext
, libxinerama
, libxrandr
, pango
, vulkan-loader
, webkitgtk_4_1
}:

let
  unwrapped = stdenv.mkDerivation {
    pname = "x-plane12-installer-unwrapped";
    version = "12.3.0";

    src = fetchurl {
      url = "https://lookup.x-plane.com/_lookup_12_/download/X-Plane12InstallerLinux.zip";
      hash = "sha256-FBqp1vTibF3q2zo2gQkVeDBTQ6DgSkxozKz+3ijDfoE=";
    };

    nativeBuildInputs = [ unzip ];
    dontBuild = true;

    unpackPhase = ''
      runHook preUnpack
      unzip $src
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp "X-Plane 12 Installer Linux" $out/bin/x-plane12-installer
      runHook postInstall
    '';
  };
in
buildFHSEnv {
  name = "x-plane12-installer";

  # All packages must be listed explicitly — buildFHSEnv does not follow
  # transitive dependencies automatically.
  targetPkgs = _pkgs: [
    at-spi2-core
    cairo
    dbus
    gdk-pixbuf
    glib
    gtk3
    harfbuzz
    libx11
    libxcursor
    libxext
    libxinerama
    libxrandr
    pango
    vulkan-loader
    webkitgtk_4_1
  ];

  runScript = "${unwrapped}/bin/x-plane12-installer";

  meta = {
    description = "Installer for X-Plane 12 flight simulator";
    longDescription = ''
      X-Plane 12 is a professional-grade flight simulator by Laminar Research.
      This package provides the installer, which downloads and installs X-Plane 12
      from Laminar Research's servers. An X-Plane 12 license is required to install
      and run the full simulator.

      Run x-plane12-installer and follow the on-screen instructions.
    '';
    homepage = "https://www.x-plane.com/";
    license = lib.licenses.unfree;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "x-plane12-installer";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
