{
  description = "scalals";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    sbt-derivation.url = "github:zaninime/sbt-derivation";
  };

  outputs = { nixpkgs, flake-utils, pre-commit-hooks, sbt-derivation, ... }:
    flake-utils.lib.eachSystem [ "aarch64-linux" "x86_64-darwin" "x86_64-linux" ]
      (system:
        let
          sbtHeadlessOverlay = _: prev: {
            sbt = prev.sbt.override { jre = prev.openjdk11_headless; };
          };

          pkgs = import nixpkgs { inherit system; overlays = [ sbtHeadlessOverlay sbt-derivation.overlay ]; };
          pkgsStatic = pkgs.pkgsStatic;
          stdenvStatic = pkgsStatic.llvmPackages_11.libcxxStdenv;
          mkShell = pkgsStatic.mkShell.override { stdenv = stdenvStatic; };

          nativeBuildInputs = with pkgs; [ git which ];

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
            scalals = pkgs.sbt.mkDerivation.override { stdenv = stdenvStatic; } rec {
              pname = "scalals-native";
              # read the first non-empty string from the VERSION file
              version = builtins.head (builtins.match "[ \n]*([^ \n]+).*" (builtins.readFile ./VERSION));

              depsSha256 = "sha256-XZTF7DFOOTT0JG3+8I+qN5owyKjDFxAQuRcjQHmWUeM=";

              src = ./.;

              inherit nativeBuildInputs;

              # explicitly override version from sbt-dynver which does not work within a nix build
              patchPhase = ''
                echo 'ThisBuild / version := "${version}"' > version.sbt
              '';

              buildPhase = ''
                export CLANG_PATH="$NIX_CC/bin/$CC"
                export CLANGPP_PATH="$NIX_CC/bin/$CXX"
                export NIX_LDFLAGS="$NIX_LDFLAGS -L${empty-gcc-eh}/lib"

                sbt scalalsNative/nativeLink
              '';

              dontPatchELF = true;

              depsWarmupCommand = "sbt scalalsNative/compile";

              passthru = {
                exePath = "/bin/scalals";
              };

              installPhase = ''
                mkdir --parents $out/bin
                cp native/target/scala-*/scalals-out $out/bin/scalals
              '';
            };
            default = scalals;
          };

          apps.default = flake-utils.lib.mkApp { drv = packages.default; };

          checks = {
            pre-commit-check = pre-commit-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                nixpkgs-fmt.enable = true;
                nix-linter.enable = true;
              };
              # generated files / submodules
              excludes = [
                "^modules/"
              ];
            };
          };

          devShells.default = mkShell {
            shellHook = ''
              export CLANG_PATH="$NIX_CC/bin/$CC"
              export CLANGPP_PATH="$NIX_CC/bin/$CXX"
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
