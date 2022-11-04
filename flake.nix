{
  description = "scalals";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
      url = "github:cachix/pre-commit-hooks.nix";
    };
    sbt = {
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
      url = "github:zaninime/sbt-derivation";
    };
  };

  outputs = { nixpkgs, flake-utils, pre-commit-hooks, sbt, ... }:
    flake-utils.lib.eachSystem [ "aarch64-linux" "x86_64-darwin" "x86_64-linux" ]
      (system:
        let
          jreHeadlessOverlay = _: prev: {
            jre = prev.openjdk11_headless;
          };

          scalafmtOverlay = final: prev: {
            scalafmt =
              let
                version = builtins.head (builtins.match ''[ \n]*version *= *"([^ \n]+)".*'' (builtins.readFile ./.scalafmt.conf));
                deps = final.stdenv.mkDerivation {
                  name = "scalafmt-deps-${version}";
                  buildCommand = ''
                    export COURSIER_CACHE=$(pwd)
                    ${final.coursier}/bin/cs fetch org.scalameta:scalafmt-cli_2.13:${version} > deps
                    mkdir -p $out/share/java
                    cp $(< deps) $out/share/java/
                  '';
                  outputHashMode = "recursive";
                  outputHash = "sha256-o9T/vEG3JL+UYY+KDLUgYmn0GyJR9R85IToUPVlSK60=";
                };
              in
              prev.scalafmt.overrideAttrs (_: {
                inherit version;
                buildInputs = [ deps ];
                # need to repeat the nativeBuildInputs here, otherwise the setJavaClassPath setup hook did not run
                nativeBuildInputs = [ final.makeWrapper final.setJavaClassPath ];
              });
          };

          pkgs = import nixpkgs { inherit system; overlays = [ jreHeadlessOverlay scalafmtOverlay ]; };
          pkgsStatic = pkgs.pkgsStatic;
          stdenvStatic = pkgsStatic.llvmPackages_11.libcxxStdenv;
          lld = pkgs.lld_13;
          mkShell = pkgsStatic.mkShell.override { stdenv = stdenvStatic; };

          nativeBuildInputs = with pkgs; [ git lld ninja which ];

          empty-gcc-eh = pkgs.runCommand "empty-gcc-eh" { } ''
            if $CC -Wno-unused-command-line-argument -x c - -o /dev/null <<< 'int main() {}'; then
              echo "linking succeeded; please remove empty-gcc-eh workaround" >&2
              exit 3
            fi
            mkdir -p $out/lib
            ${pkgs.binutils-unwrapped}/bin/ar r $out/lib/libgcc_eh.a
          '';
        in
        rec {
          packages = rec {
            scalals = sbt.lib.mkSbtDerivation rec {
              inherit pkgs nativeBuildInputs;

              overrides = { stdenv = stdenvStatic; };

              pname = "scalals-native";

              # read the first non-empty string from the VERSION file
              version = builtins.head (builtins.match "[ \n]*([^ \n]+).*" (builtins.readFile ./VERSION));

              depsSha256 = "sha256-gQ1dtAOlAKk7GchE2z03Ycpa+CWcLTfDbMQXfTeOnYU=";

              src = ./.;

              # explicitly override version from sbt-dynver which does not work within a nix build
              patchPhase = ''
                echo 'ThisBuild / version := "${version}"' > version.sbt
              '';

              SCALANATIVE_MODE = "release-full"; # {debug, release-fast, release-full}
              SCALANATIVE_LTO = "thin"; # {none, full, thin}

              buildPhase = ''
                export NIX_LDFLAGS="$NIX_LDFLAGS -L${empty-gcc-eh}/lib"

                sbt 'project scalalsNative' 'show nativeConfig' nativeLink
              '';

              dontPatchELF = true;

              # FIXME: optimizing produces different output hashes on macos and linux due to
              #        different permissions of symlinks
              depsOptimize = false;
              depsWarmupCommand = "sbt scalalsNative/compile";

              installPhase = ''
                mkdir --parents $out/bin
                cp native/target/scala-*/scalals-out $out/bin/scalals
              '';
            };
            default = scalals;
          };

          apps.default = flake-utils.lib.mkApp { drv = packages.default; exePath = "/bin/scalals"; };

          checks = {
            pre-commit-check = pre-commit-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                nixpkgs-fmt.enable = true;
                nix-linter.enable = true;
                scalafmt = {
                  enable = true;
                  name = "scalafmt";
                  entry = "${pkgs.scalafmt}/bin/scalafmt --list --reportError";
                  types = [ "scala" ];
                };
              };
            };
          };

          devShells.default = mkShell {
            shellHook = ''
              export NIX_LDFLAGS="$NIX_LDFLAGS -L${empty-gcc-eh}/lib"

              ${checks.pre-commit-check.shellHook}
            '';
            nativeBuildInputs = nativeBuildInputs ++ [ pkgs.sbt ];
          };

          # compatibility for nix < 2.7.0
          defaultApp = apps.default;
          defaultPackage = packages.default;
          devShell = devShells.default;
        }
      );
}
