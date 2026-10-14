# Compares geoffcloud's evaluated firewall with the exposure registry
# (packages/topology/exposure.json) through lib/collect-exposure-mismatches.nix, and fails with
# every mismatch, so a port that opens without a registry entry, or an entry the firewall no
# longer matches, fails here instead of reaching the host. The cases first test the comparison:
# each evaluates its own config through test-utils/build-module-system.nix, with
# inet cloud_host's module and imp's module for their options, compares it with its own entries,
# and runs on its own, in a fresh directory, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos exposure
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
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectExposureMismatches = import ../lib/collect-exposure-mismatches.nix { inherit lib; };

  hostMismatches = collectExposureMismatches {
    inherit (geoffcloud) config;
    inherit ((import ../exposure.nix)) entries;
  };

  # the modules whose options the comparison reads beside networking.firewall
  firewallModules = {
    imports = [
      ../modules/cloud-host-firewall.nix
      imp.nixosModules.imp
    ];
  };
  renderMismatches =
    config: entries:
    lib.escapeShellArg (
      builtins.toJSON (collectExposureMismatches {
        inherit config entries;
      })
    );

  cases = [
    {
      title = "it finds no mismatch when every open port and admission has its entry";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.allowedUDPPorts = [ 41641 ];
            networking.firewall.interfaces.docker0.allowedTCPPorts = [ 18081 ];
            networking.cloudHost.admissions = [
              {
                port = 18081;
                interface = "docker0";
                sourceCIDR = "172.17.0.0/16";
                destinationAddress = "172.17.0.1";
              }
            ];
          };
        in
        ''
          assert_equals '[]' ${
            renderMismatches system.config [
              {
                name = "tailscale";
                kind = "host-port";
                protocol = "udp";
                port = 41641;
                scope = "public";
              }
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "relay";
                kind = "host-port";
                protocol = "tcp";
                port = 18081;
                scope = "host";
                interface = "docker0";
                admission = true;
              }
              {
                name = "ssh";
                kind = "host-port";
                protocol = "tcp";
                port = 22;
                scope = "tailnet";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports a TCP port opened on every interface without an entry";
      script =
        let
          system = buildModuleSystem firewallModules { networking.firewall.allowedTCPPorts = [ 8080 ]; };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [ "tcp 8080 is open on every interface with no registry entry" ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports the openssh default port 22 against a tailnet-scope entry";
      script =
        let
          system = buildModuleSystem firewallModules { services.openssh.enable = true; };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "tcp 22 is open on every interface, but the registry's ssh entry has scope tailnet"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "ssh";
                kind = "host-port";
                protocol = "tcp";
                port = 22;
                scope = "tailnet";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports an sshd port without a tailnet-scope entry";
      script =
        let
          system = buildModuleSystem firewallModules {
            services.openssh = {
              enable = true;
              openFirewall = false;
              ports = [
                22
                2222
              ];
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "sshd listens on tcp 2222 with no tailnet-scope or public registry entry"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "ssh";
                kind = "host-port";
                protocol = "tcp";
                port = 22;
                scope = "tailnet";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports public entries that the firewall does not open";
      script =
        let
          system = buildModuleSystem firewallModules { networking.firewall.allowPing = false; };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the registry's tailscale entry is public, but udp 41641 is not open on every interface"
                "the registry's icmp entry is public, but networking.firewall.allowPing is off"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "tailscale";
                kind = "host-port";
                protocol = "udp";
                port = 41641;
                scope = "public";
              }
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports ping allowed without a public icmp entry";
      script =
        let
          system = buildModuleSystem firewallModules { networking.firewall.allowPing = true; };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [ "ping is allowed on every interface with no public icmp registry entry" ]
            )
          } ${renderMismatches system.config [ ]} "mismatches"
        '';
    }
    {
      title = "it reports a port on an interface and an admission without their entries";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.interfaces.docker0.allowedTCPPorts = [ 18081 ];
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
                "tcp 18081 is open on docker0 with no host-scope registry entry for docker0"
                "inet cloud_host admits tcp 8415 on cni0 with no host-scope registry entry that marks the admission"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "atc-daemon";
                kind = "host-port";
                protocol = "tcp";
                port = 8415;
                scope = "host";
                interface = "cni0";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports host-scope entries that nothing opens or admits";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.interfaces.docker0.allowedTCPPorts = [ 18081 ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the registry's relay entry marks an admission, but inet cloud_host admits no tcp 18081 on docker0"
                "the registry's atc-daemon entry is host scope on cni0, but nothing opens or admits tcp 8415 there"
                "the registry's atc-daemon entry marks an admission, but inet cloud_host admits no tcp 8415 on cni0"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "relay";
                kind = "host-port";
                protocol = "tcp";
                port = 18081;
                scope = "host";
                interface = "docker0";
                admission = true;
              }
              {
                name = "atc-daemon";
                kind = "host-port";
                protocol = "tcp";
                port = 8415;
                scope = "host";
                interface = "cni0";
                admission = true;
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports each imp publicPorts spec without a public entry";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedTCPPorts = [ 443 ];
            services.imp.publicPorts = [
              "443:7443"
              "104.250.100.18:80:7480"
              "127.0.0.1:5353:53/udp"
              "8000-8001:8000-8001"
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "imp's publicPorts publishes 104.250.100.18:80:7480 (tcp 80) with no public registry entry"
                "imp's publicPorts publishes 127.0.0.1:5353:53/udp (udp 5353) with no public registry entry"
                "imp's publicPorts publishes 8000-8001:8000-8001, whose host port the exposure check cannot read"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "imp-https";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports a bare imp publicPorts container port even when a public entry has the same number";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedTCPPorts = [ 443 ];
            services.imp.publicPorts = [ "443" ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "imp's publicPorts publishes 443, whose host port the exposure check cannot read"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "imp-https";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports port ranges and extraInputRules, which no entry can match";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedUDPPortRanges = [
              {
                from = 60000;
                to = 61000;
              }
            ];
            networking.firewall.interfaces.docker0.allowedTCPPortRanges = [
              {
                from = 8000;
                to = 8010;
              }
            ];
            networking.firewall.extraInputRules = "tcp dport 9000 accept";
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "udp 60000-61000 is open on every interface as a range, which no registry entry can match"
                "tcp 8000-8010 is open on docker0 as a range, which no registry entry can match"
                "networking.firewall.extraInputRules is set, and the exposure check cannot read it: open the port through allowedTCPPorts or allowedUDPPorts instead"
              ]
            )
          } ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
  ];
in
pkgs.runCommand "exposure-check"
  {
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${pkgs.writeText "exposure-cases.sh" (renderCases cases)}
    run_cases

    mismatches=${lib.escapeShellArg (lib.concatLines hostMismatches)}
    if [ -n "$mismatches" ]; then
      echo "geoffcloud's firewall and packages/topology/exposure.json disagree:" >&2
      printf '%s' "$mismatches" >&2
      exit 1
    fi
    echo "geoffcloud's firewall matches packages/topology/exposure.json"
    touch $out
  ''
