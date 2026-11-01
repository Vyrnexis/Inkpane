{
  description = "Inkpane: draw on your screen through a transparent Wayland overlay";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # The version lives in Inkpane.nimble only.
      version = builtins.head (builtins.match ''.*version *= *"([^"]+)".*''
        (builtins.readFile ./Inkpane.nimble));
    in
    {
      packages = forAllSystems (pkgs: let
        # nixpkgs' SDL3 has everything on (audio, X11, Vulkan, joysticks, and zenity with
        # all of GTK for message boxes): about 1 GiB. Inkpane needs Wayland and OpenGL.
        sdl3 = pkgs.sdl3.override {
          alsaSupport = false;
          drmSupport = false;
          ibusSupport = false;
          jackSupport = false;
          libdecorSupport = false;
          libudevSupport = false;
          libusbSupport = false;
          pipewireSupport = false;
          pulseaudioSupport = false;
          traySupport = false;
          vulkanSupport = false;
          x11Support = false;
          # Only SDL's own message boxes run zenity, and Inkpane never shows one.
          zenity = pkgs.writeShellScriptBin "zenity" "exit 1";
        };
        sdl3-ttf = pkgs.sdl3-ttf.override { inherit sdl3; };
        # wl-copy's xdg-utils wrapper (and perl with it) only guesses the MIME type, and
        # Inkpane always passes --type.
        wl-clipboard = pkgs.wl-clipboard.overrideAttrs { postInstall = ""; };
      in rec {
        default = inkpane;
        inkpane = pkgs.stdenv.mkDerivation {
          pname = "inkpane";
          inherit version;
          src = self;

          # The official SDL3 wrapper is not in nixpkgs; pinned to the commit Inkpane.nimble uses.
          sdl3Nim = pkgs.fetchFromGitHub {
            owner = "nim-lang";
            repo = "sdl3";
            rev = "533d22196dab2ea637ea0131171ed3f8db61fe90";
            hash = "sha256-2pEWhTDsQ4qeRpjJ++dLJTxNc314s+X/QMOOfdd50eU=";
          };

          nativeBuildInputs = [ pkgs.nim pkgs.makeWrapper ];
          buildInputs = [ sdl3 pkgs.wayland ];

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            flags="-d:release --opt:size -d:lto -d:strip --noNimblePath --path:$sdl3Nim/src"
            nim c $flags --nimcache:$TMPDIR/cache --out:inkpane src/inkpane.nim
            nim c $flags --nimcache:$TMPDIR/cache-mcp --out:inkpane-mcp src/inkpane_mcp.nim
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 -t $out/bin inkpane inkpane-mcp
            install -Dm644 -t $out/share/icons/hicolor/scalable/apps data/icons/hicolor/scalable/apps/*.svg
            install -dm755 $out/share/applications
            sed "s|@APP_BIN@|$out/bin/inkpane|g" data/org.vyrnexis.Inkpane.desktop \
              > $out/share/applications/org.vyrnexis.Inkpane.desktop
            runHook postInstall
          '';

          # GLib/GIO and SDL3_ttf are opened at run time, so they go on the rpath after
          # fixup (which would drop them as unused). SDL 3.4 saves PNGs itself, so no
          # SDL3_image. fc-match and wl-clipboard are run as programs; the user's own
          # come first.
          postFixup = ''
            patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.glib sdl3-ttf ]} $out/bin/inkpane
            patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.glib ]} $out/bin/inkpane-mcp
            for bin in $out/bin/inkpane $out/bin/inkpane-mcp; do
              wrapProgram $bin --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.fontconfig wl-clipboard ]}
            done
          '';

          meta = {
            description = "Draw on your screen through a transparent Wayland overlay";
            homepage = "https://github.com/Vyrnexis/Inkpane";
            license = pkgs.lib.licenses.gpl3Plus;
            platforms = systems;
            mainProgram = "inkpane";
          };
        };
      });
    };
}
