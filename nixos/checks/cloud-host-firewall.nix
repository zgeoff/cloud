# Evaluates networking.cloudHost apart from any host's config and checks the inet cloud_host table
# it renders and the module's assertions. Each case evaluates its own config through
# test-utils/build-module-system.nix and runs on its own, in a fresh directory, under
# test-support/shell/run-cases.sh, which reports each case and fails the check when any case
# fails.
# Run: bun run test:nixos cloud-host-firewall
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;

  cases = [
    {
      title = "it renders each admission as an accept from its path, then a drop of its port, sorted by port";
      script =
        let
          table =
            (buildModuleSystem ../modules/cloud-host-firewall.nix {
              networking.nftables = {
                enable = true;
                flushRuleset = false;
              };
              networking.cloudHost.admissions = [
                {
                  port = 18081;
                  interface = "docker0";
                  sourceCIDR = "172.17.0.0/16";
                  destinationAddress = "172.17.0.1";
                }
                {
                  port = 8415;
                  interface = "cni0";
                  sourceCIDR = "10.42.0.0/16";
                  destinationAddress = "100.64.0.1";
                }
              ];
            }).config.networking.nftables.tables.cloud_host;
        in
        ''
          printf '%s' ${lib.escapeShellArg table.content} > actual

          assert_equals inet ${lib.escapeShellArg table.family} "the table's family"
          assert_files_equal - actual <<'EOF'
          chain input {
            type filter hook input priority filter - 10; policy accept;
            tcp dport 8415 iifname "cni0" ip saddr 10.42.0.0/16 ip daddr 100.64.0.1 accept
            tcp dport 8415 drop
            tcp dport 18081 iifname "docker0" ip saddr 172.17.0.0/16 ip daddr 172.17.0.1 accept
            tcp dport 18081 drop
          }
          EOF
        '';
    }
    {
      title = "it adds no table without an admission";
      script =
        let
          system = buildModuleSystem ../modules/cloud-host-firewall.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
          };
          hasTable = system.config.networking.nftables.tables ? cloud_host;
        in
        ''
          assert_equals false ${lib.boolToString hasTable} "a cloud_host table"
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails no assertion for a valid config";
      script =
        let
          system = buildModuleSystem ../modules/cloud-host-firewall.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
        in
        ''
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it renders every accept of a port, sorted by interface, before the one drop of that port";
      script =
        let
          system = buildModuleSystem ../modules/cloud-host-firewall.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "tailscale0";
                sourceCIDR = "100.64.0.2/32";
                destinationAddress = "100.64.0.1";
              }
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
          table = system.config.networking.nftables.tables.cloud_host;
        in
        ''
          printf '%s' ${lib.escapeShellArg table.content} > actual

          assert_files_equal - actual <<'EOF'
          chain input {
            type filter hook input priority filter - 10; policy accept;
            tcp dport 8415 iifname "cni0" ip saddr 10.42.0.0/16 ip daddr 100.64.0.1 accept
            tcp dport 8415 iifname "tailscale0" ip saddr 100.64.0.2/32 ip daddr 100.64.0.1 accept
            tcp dport 8415 drop
          }
          EOF
          assert_equals '[]' ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails an assertion when nftables flushes the ruleset";
      script =
        let
          system = buildModuleSystem ../modules/cloud-host-firewall.nix {
            networking.nftables = {
              enable = true;
              flushRuleset = true;
            };
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "networking.cloudHost.admissions needs networking.nftables.flushRuleset off: a flush drops the tables of imp, k3s and Docker"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
    {
      title = "it fails an assertion without nftables";
      script =
        let
          system = buildModuleSystem ../modules/cloud-host-firewall.nix {
            networking.nftables = {
              enable = false;
              flushRuleset = false;
            };
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "networking.cloudHost.admissions needs networking.nftables.enable: inet cloud_host is an nftables table"
              ]
            )
          } ${lib.escapeShellArg (builtins.toJSON (collectFailedAssertions system))} "failed assertions"
        '';
    }
  ];
in
pkgs.runCommand "cloud-host-firewall-check"
  {
    nativeBuildInputs = [ pkgs.diffutils ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "cloud-host-firewall-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
