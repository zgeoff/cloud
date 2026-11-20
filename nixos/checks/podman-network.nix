# Reads the default network file that geoffcloud's config writes for Podman and checks its bridge,
# gateway and subnet against packages/topology. Without the host's settings NixOS writes no file,
# and Podman falls back to its built-in network, which no other check sees: the relay, the model
# route listener and the pod drops still name the topology's bridge.
# Run: bun run test:nixos podman-network
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  topology = import ../topology.nix;
  networkFiles = lib.filterAttrs (
    name: file: name == "containers/networks/podman.json" && file.enable
  ) geoffcloud.config.environment.etc;
  networkFile = lib.attrByPath [ "containers/networks/podman.json" "source" ] "" networkFiles;

  cases = [
    {
      title = "it writes the default Podman network with the bridge, gateway and subnet of the topology";
      script = ''
        # the default network files
        assert_equal ${toString (lib.length (lib.attrNames networkFiles))} 1
        jq -cS '{ network_interface, subnets }' ${networkFile} > actual
        # the default network
        assert_equal "$(cat actual)" ${
          lib.escapeShellArg (
            builtins.toJSON {
              network_interface = topology.podman.bridge;
              subnets = [
                {
                  gateway = topology.podman.bridgeAddress;
                  inherit (topology.podman) subnet;
                }
              ];
            }
          )
        }
      '';
    }
  ];
in
pkgs.runCommand "podman-network-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    bats --timing --print-output-on-failure ${pkgs.writeText "podman-network.bats" (renderCases cases)}
    touch $out
  ''
