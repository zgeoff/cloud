# Compares the imp release that the flake input pins with geoffcloud's imp-host image tag through
# lib/collect-imp-pin-mismatches.nix, and fails with every mismatch, so a bump of the module
# without the image, or of the image without the module, fails here instead of reaching the host.
# The release is the version in the pinned imp source's package.json. The cases first test the
# comparison, each on its own pair, in a fresh directory, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos imp-pin
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  collectImpPinMismatches = import ../lib/collect-imp-pin-mismatches.nix { inherit lib; };

  hostMismatches = collectImpPinMismatches {
    releaseVersion = (lib.importJSON "${imp}/package.json").version;
    inherit (geoffcloud.config.services.imp) image;
  };

  renderMismatches = pins: lib.escapeShellArg (builtins.toJSON (collectImpPinMismatches pins));

  cases = [
    {
      title = "it finds no mismatch when the image tag is the release of the flake input";
      script = ''
        assert_equals '[]' ${
          renderMismatches {
            releaseVersion = "3.1.4";
            image = "ghcr.io/zgeoff/imp-host:3.1.4@sha256:${lib.strings.replicate 64 "a"}";
          }
        } "mismatches"
      '';
    }
    {
      title = "it reports an image tag of another release than the flake input";
      script = ''
        assert_equals ${
          lib.escapeShellArg (
            builtins.toJSON [
              "services.imp.image pins imp-host 3.1.3, but the imp flake input is release 3.1.4: pin both with scripts/pin-imp.sh"
            ]
          )
        } ${
          renderMismatches {
            releaseVersion = "3.1.4";
            image = "ghcr.io/zgeoff/imp-host:3.1.3@sha256:${lib.strings.replicate 64 "a"}";
          }
        } "mismatches"
      '';
    }
    {
      title = "it reports an image without a digest";
      script = ''
        assert_equals ${
          lib.escapeShellArg (
            builtins.toJSON [
              "services.imp.image 'ghcr.io/zgeoff/imp-host:3.1.4' names no ghcr.io/zgeoff/imp-host tag and digest"
            ]
          )
        } ${
          renderMismatches {
            releaseVersion = "3.1.4";
            image = "ghcr.io/zgeoff/imp-host:3.1.4";
          }
        } "mismatches"
      '';
    }
    {
      title = "it reports an image from another repository";
      script = ''
        assert_equals ${
          lib.escapeShellArg (
            builtins.toJSON [
              "services.imp.image 'ghcr.io/example/imp-host:3.1.4@sha256:${lib.strings.replicate 64 "a"}' names no ghcr.io/zgeoff/imp-host tag and digest"
            ]
          )
        } ${
          renderMismatches {
            releaseVersion = "3.1.4";
            image = "ghcr.io/example/imp-host:3.1.4@sha256:${lib.strings.replicate 64 "a"}";
          }
        } "mismatches"
      '';
    }
  ];
in
pkgs.runCommand "imp-pin-check"
  {
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${pkgs.writeText "imp-pin-cases.sh" (renderCases cases)}
    run_cases

    mismatches=${lib.escapeShellArg (lib.concatLines hostMismatches)}
    if [ -n "$mismatches" ]; then
      echo "geoffcloud's imp-host image and the imp flake input disagree:" >&2
      printf '%s' "$mismatches" >&2
      exit 1
    fi
    echo "geoffcloud's imp-host image is the imp flake input's release"
    touch $out
  ''
