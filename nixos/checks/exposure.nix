# Compares geoffcloud's evaluated firewall with the exposure registry
# (packages/topology/exposure.json) through lib/collect-exposure-mismatches.nix, and fails with
# every mismatch, so a port that opens without a registry entry, or an entry the firewall no
# longer matches, fails here instead of reaching the host. The cases first test the comparison:
# each evaluates its own config through test-utils/build-module-system.nix, with
# inet cloud_host's module and imp's module for their options, or extends geoffcloud's, compares
# it with its own entries, and runs on its own, in a fresh directory, under
# test-support/shell/run-cases.sh.
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
      ../modules/public-front.nix
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
      title = "it reports a port on an addressed interface against a host-scope entry for it";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.interfaces.eth0.ipv4.addresses = [
              {
                address = "203.0.113.10";
                prefixLength = 24;
              }
            ];
            networking.firewall.interfaces.eth0.allowedTCPPorts = [ 8080 ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "tcp 8080 is open on eth0, a public interface, with no public registry entry"
                "the registry's web entry is host scope on eth0, but eth0 is a public interface"
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
                name = "web";
                kind = "host-port";
                protocol = "tcp";
                port = 8080;
                scope = "host";
                interface = "eth0";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it accepts a port on the default route interface with a public entry";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.defaultGateway = {
              address = "203.0.113.1";
              interface = "eth0";
            };
            networking.firewall.interfaces.eth0.allowedTCPPorts = [ 443 ];
          };
        in
        ''
          assert_equals '[]' ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "https";
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
      title = "it passes a port that two admissions narrow when the registry marks each path";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.trustedInterfaces = [
              "cni0"
              "tailscale0"
            ];
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
              {
                port = 8415;
                interface = "tailscale0";
                sourceCIDR = "100.64.0.2/32";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
          icmp = {
            name = "icmp";
            kind = "host-port";
            protocol = "icmp";
            scope = "public";
          };
          podPath = {
            name = "atc-daemon";
            kind = "host-port";
            protocol = "tcp";
            port = 8415;
            scope = "host";
            interface = "cni0";
            admission = true;
          };
          pcPath = {
            name = "atc-daemon-home-pc";
            kind = "host-port";
            protocol = "tcp";
            port = 8415;
            scope = "host";
            interface = "tailscale0";
            admission = true;
          };
        in
        ''
          assert_equals '[]' ${
            renderMismatches system.config [
              icmp
              podPath
              pcPath
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports the second admission of a port when the registry marks only the first path";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.trustedInterfaces = [
              "cni0"
              "tailscale0"
            ];
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
              {
                port = 8415;
                interface = "tailscale0";
                sourceCIDR = "100.64.0.2/32";
                destinationAddress = "100.64.0.1";
              }
            ];
          };
          icmp = {
            name = "icmp";
            kind = "host-port";
            protocol = "icmp";
            scope = "public";
          };
          podPath = {
            name = "atc-daemon";
            kind = "host-port";
            protocol = "tcp";
            port = 8415;
            scope = "host";
            interface = "cni0";
            admission = true;
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "inet cloud_host admits tcp 8415 on tailscale0 with no host-scope registry entry that marks the admission"
              ]
            )
          } ${
            renderMismatches system.config [
              icmp
              podPath
            ]
          } "mismatches"
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
            networking.firewall.trustedInterfaces = [ "cni0" ];
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
      title = "it reports the atc daemon and preview webhook admissions once geoffcloud stops trusting cni0";
      script =
        let
          # geoffcloud's own config, less cni0 in trustedInterfaces: inet cloud_host still admits
          # the pods to tcp 8415 and 8418, but nixos-fw now drops them
          untrusted = geoffcloud.extendModules {
            modules = [
              {
                networking.firewall.trustedInterfaces = lib.mkForce (
                  lib.remove "cni0" geoffcloud.config.networking.firewall.trustedInterfaces
                );
              }
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the registry's atc-daemon entry is host scope on cni0, and inet cloud_host admits tcp 8415 there, but nixos-fw drops it: cni0 is not trusted, and nixos-fw opens tcp 8415 neither there nor on every interface"
                "the registry's preview-webhook entry is host scope on cni0, and inet cloud_host admits tcp 8418 there, but nixos-fw drops it: cni0 is not trusted, and nixos-fw opens tcp 8418 neither there nor on every interface"
              ]
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON (collectExposureMismatches {
                inherit (untrusted) config;
                inherit ((import ../exposure.nix)) entries;
              })
            )
          } "mismatches"
        '';
    }
    {
      title = "it reports an admission on an interface that nixos-fw neither trusts nor opens the port on";
      script =
        let
          system = buildModuleSystem firewallModules {
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
            ];
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the registry's relay entry is host scope on docker0, and inet cloud_host admits tcp 18081 there, but nixos-fw drops it: docker0 is not trusted, and nixos-fw opens tcp 18081 neither there nor on every interface"
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
            ]
          } "mismatches"
        '';
    }
    {
      title = "it accepts an admission that nixos-fw passes through a trusted interface or a port range";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.trustedInterfaces = [ "cni0" ];
            networking.firewall.interfaces.docker0.allowedTCPPortRanges = [
              {
                from = 18000;
                to = 18099;
              }
            ];
            networking.cloudHost.admissions = [
              {
                port = 8415;
                interface = "cni0";
                sourceCIDR = "10.42.0.0/16";
                destinationAddress = "100.64.0.1";
              }
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
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "tcp 18000-18099 is open on docker0 as a range, which no registry entry can match"
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
                admission = true;
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
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports a port that nixos-fw opens on an interface where the cloud host table drops it";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.trustedInterfaces = [ "cni0" ];
            networking.firewall.interfaces.docker0.allowedTCPPorts = [ 8415 ];
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
                "the registry's docker-daemon entry is host scope on docker0, and nixos-fw opens tcp 8415 there, but inet cloud_host drops it: its admissions for tcp 8415 are on cni0"
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
                admission = true;
              }
              {
                name = "docker-daemon";
                kind = "host-port";
                protocol = "tcp";
                port = 8415;
                scope = "host";
                interface = "docker0";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it narrows a port open on every interface to its admission";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.nftables = {
              enable = true;
              flushRuleset = false;
            };
            networking.firewall.allowedTCPPorts = [ 8415 ];
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
                "the registry's atc-public entry is public, but tcp 8415 is not open on every interface"
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
                name = "atc-public";
                kind = "host-port";
                protocol = "tcp";
                port = 8415;
                scope = "public";
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
      title = "it reports each imp publicPorts spec without a public entry, and a loopback one without a host-scope entry for lo";
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
                "imp's publicPorts publishes 127.0.0.1:5353:53/udp (udp 5353) with no host-scope registry entry for lo"
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
      title = "it accepts a port open on every interface whose public entry follows a tailnet entry for the same port";
      script =
        let
          system = buildModuleSystem firewallModules { networking.firewall.allowedTCPPorts = [ 443 ]; };
        in
        ''
          assert_equals '[]' ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "ingress";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "tailnet";
              }
              {
                name = "front";
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
      title = "it reports a host-scope entry for lo that no imp publicPorts spec publishes";
      script =
        let
          system = buildModuleSystem firewallModules { };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the registry's listener entry is host scope on lo, but nothing opens or admits tcp 7071 there"
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
                name = "listener";
                kind = "host-port";
                protocol = "tcp";
                port = 7071;
                scope = "host";
                interface = "lo";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it finds no mismatch when the TLS front serves its registry route from a loopback publish";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedTCPPorts = [ 443 ];
            services.imp.publicPorts = [ "127.0.0.1:7071:7071" ];
            services.public-front = {
              enable = true;
              routes = [
                {
                  hostname = "mcp.example.test";
                  upstream = "127.0.0.1:7071";
                  paths = [
                    "/mcp"
                    "/login"
                  ];
                }
              ];
              rateLimit = {
                events = 10;
                window = "1m";
              };
            };
          };
        in
        ''
          assert_equals '[]' ${
            renderMismatches system.config [
              {
                name = "icmp";
                kind = "host-port";
                protocol = "icmp";
                scope = "public";
              }
              {
                name = "front";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "public";
              }
              {
                name = "listener";
                kind = "host-port";
                protocol = "tcp";
                port = 7071;
                scope = "host";
                interface = "lo";
              }
              {
                name = "mcp";
                kind = "front-route";
                hostname = "mcp.example.test";
                upstream = "127.0.0.1:7071";
                paths = [
                  "/login"
                  "/mcp"
                ];
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports a TLS front route whose upstream and paths differ from those of its registry entry";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedTCPPorts = [ 443 ];
            services.imp.publicPorts = [ "127.0.0.1:7071:7071" ];
            services.public-front = {
              enable = true;
              routes = [
                {
                  hostname = "mcp.example.test";
                  upstream = "127.0.0.1:7070";
                  paths = [
                    "/mcp"
                    "/login"
                    "/rpc"
                  ];
                }
              ];
              rateLimit = {
                events = 10;
                window = "1m";
              };
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the TLS front serves mcp.example.test from 127.0.0.1:7070, with no host-scope registry entry for lo"
                "the TLS front serves mcp.example.test to 127.0.0.1:7070, but the registry's mcp entry names 127.0.0.1:7071"
                "the TLS front serves mcp.example.test for the paths /login /mcp /rpc, but the registry's mcp entry lists /login /mcp"
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
                name = "front";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "public";
              }
              {
                name = "listener";
                kind = "host-port";
                protocol = "tcp";
                port = 7071;
                scope = "host";
                interface = "lo";
              }
              {
                name = "mcp";
                kind = "front-route";
                hostname = "mcp.example.test";
                upstream = "127.0.0.1:7071";
                paths = [
                  "/mcp"
                  "/login"
                ];
                scope = "public";
              }
            ]
          } "mismatches"
        '';
    }
    {
      title = "it reports a TLS front route without a registry entry, and a public front-route entry the front does not serve";
      script =
        let
          system = buildModuleSystem firewallModules {
            networking.firewall.allowedTCPPorts = [ 443 ];
            services.imp.publicPorts = [ "127.0.0.1:7071:7071" ];
            services.public-front = {
              enable = true;
              routes = [
                {
                  hostname = "mcp.example.test";
                  upstream = "127.0.0.1:7071";
                  paths = [ "/mcp" ];
                }
              ];
              rateLimit = {
                events = 10;
                window = "1m";
              };
            };
          };
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON [
                "the TLS front serves mcp.example.test with no public front-route registry entry"
                "the registry's notes entry is a public front route, but the TLS front does not serve notes.example.test"
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
                name = "front";
                kind = "host-port";
                protocol = "tcp";
                port = 443;
                scope = "public";
              }
              {
                name = "listener";
                kind = "host-port";
                protocol = "tcp";
                port = 7071;
                scope = "host";
                interface = "lo";
              }
              {
                name = "notes";
                kind = "front-route";
                hostname = "notes.example.test";
                upstream = "127.0.0.1:7071";
                paths = [ "/mcp" ];
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
