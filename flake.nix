{
  description = "Patchbay agent supervisor";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {self, nixpkgs}: let
    systems = ["aarch64-linux" "x86_64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    pkgsFor = system: import nixpkgs {inherit system;};

    # Erlang/Elixir built without wxwidgets (and without systemd/epmd
    # integration), so the package closure stays headless and small.
    beamPackagesFor = pkgs: pkgs.beamMinimalPackages;

    module = {lib, pkgs, ...}: {
      imports = [./nix/module.nix];
      services.patchbay.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
    };
  in {
    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      patchbay = pkgs.callPackage ./nix/package.nix {
        beamMinimalPackages = beamPackagesFor pkgs;
      };
    in {
      default = patchbay;
      inherit patchbay;
    });

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      patchbay = pkgs.callPackage ./nix/package.nix {
        beamMinimalPackages = beamPackagesFor pkgs;
      };
    in {
      patchbay-packaged-smoke = pkgs.runCommand "patchbay-packaged-smoke" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
      } ''
        export HOME="$TMPDIR"
        bin="${patchbay}/bin/patchbay"

        expect_exit() {
          expected="$1"
          shift
          set +e
          "$@" >"$TMPDIR/stdout" 2>"$TMPDIR/stderr"
          actual="$?"
          set -e
          if [ "$actual" -ne "$expected" ]; then
            echo "expected exit $expected but got $actual: $*" >&2
            echo "--- stdout ---" >&2
            cat "$TMPDIR/stdout" >&2
            echo "--- stderr ---" >&2
            cat "$TMPDIR/stderr" >&2
            exit 1
          fi
        }

        unset SECRET_KEY_BASE

        expect_exit 2 "$bin"
        grep -q "Usage: patchbay" "$TMPDIR/stderr"

        expect_exit 2 "$bin" frobnicate
        grep -q "unknown command" "$TMPDIR/stderr"
        grep -q "Usage: patchbay" "$TMPDIR/stderr"

        expect_exit 0 "$bin" help
        grep -q "run-manager" "$TMPDIR/stdout"

        mkdir -p "$out"
        touch "$out/ok"
      '';
    });

    nixosModules = {
      default = module;
      patchbay = module;
    };

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
      beamPackages = beamPackagesFor pkgs;
    in {
      default = pkgs.mkShell {
        packages = [
          beamPackages.elixir
          beamPackages.erlang
          beamPackages.hex
          beamPackages.rebar3
          pkgs.zstd
        ];

        shellHook = ''
          export MIX_HOME="$PWD/.nix/mix"
          export HEX_HOME="$PWD/.nix/hex"
        '';
      };
    });
  };
}
