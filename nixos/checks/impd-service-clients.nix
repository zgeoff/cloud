# Checks services.impd-service-clients: the two files the module writes under /etc/imp for impd, the
# settings that name them, the restart it asks of imp-host, and each assertion that refuses a client list impd's parser would
# refuse. Each case evaluates its own config, beside imp's module, through
# test-utils/build-module-system.nix, and runs in
# a fresh directory under scripts/src/test-utils/shell/run-cases.sh.
# Run: bun run test:nixos impd-service-clients
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };
  collectFailedAssertions = import ./test-utils/collect-failed-assertions.nix;

  # the module beside imp's, whose settings it reads and sets
  clientsModule = {
    imports = [
      ../modules/impd-service-clients.nix
      imp.nixosModules.imp
    ];
  };

  buildClientsSystem =
    {
      publicURL ? "https://imp.example.com",
      clients,
    }:
    buildModuleSystem clientsModule {
      services.imp.settings.IMP_MCP_PUBLIC_URL = publicURL;
      services.impd-service-clients = {
        enable = true;
        inherit clients;
      };
    };

  # each client list impd's parser refuses, with the assertion messages the module fails on it
  refusals = [
    {
      title = "it fails an assertion on a public MCP URL with a port";
      publicURL = "https://imp.example.com:443";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "*" ];
      };
      messages = [
        "services.impd-service-clients needs services.imp.settings.IMP_MCP_PUBLIC_URL, https:// and a lowercase host name with no port or path, the form impd normalises it to"
      ];
    }
    {
      title = "it fails an assertion on a public MCP URL with a capital letter";
      publicURL = "https://Imp.example.com";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "*" ];
      };
      messages = [
        "services.impd-service-clients needs services.imp.settings.IMP_MCP_PUBLIC_URL, https:// and a lowercase host name with no port or path, the form impd normalises it to"
      ];
    }
    {
      title = "it fails an assertion on a public MCP URL with a path";
      publicURL = "https://imp.example.com/base";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "*" ];
      };
      messages = [
        "services.impd-service-clients needs services.imp.settings.IMP_MCP_PUBLIC_URL, https:// and a lowercase host name with no port or path, the form impd normalises it to"
      ];
    }
    {
      title = "it fails an assertion on an empty client list";
      clients = { };
      messages = [ "services.impd-service-clients.clients must name at least one client" ];
    }
    {
      title = "it fails an assertion on a client name with a capital letter";
      clients.Reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "*" ];
      };
      messages = [ "impd service client Reader: a name must match [a-z][a-z0-9-]{0,31}" ];
    }
    {
      title = "it fails an assertion on a scope impd does not know";
      clients.reader = {
        scopes = [ "admin" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "*" ];
      };
      messages = [
        "impd service client reader: scopes must be one or more of read, exec and manage"
      ];
    }
    {
      title = "it fails an assertion on a client with no secret digest";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ ];
        imps = [ "*" ];
      };
      messages = [
        "impd service client reader: secretDigests must hold 1 or 2 digests of 64 lowercase hex characters"
      ];
    }
    {
      title = "it fails an assertion on a digest in uppercase hex";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "A" "") ];
        imps = [ "*" ];
      };
      messages = [
        "impd service client reader: secretDigests must hold 1 or 2 digests of 64 lowercase hex characters"
      ];
    }
    {
      title = "it fails an assertion on a digest shared by two clients";
      clients = {
        reader = {
          scopes = [ "read" ];
          secretDigests = [ (lib.fixedWidthString 64 "b" "") ];
          imps = [ "*" ];
        };
        runner = {
          scopes = [ "exec" ];
          secretDigests = [ (lib.fixedWidthString 64 "b" "") ];
          imps = [ "dev-*" ];
        };
      };
      messages = [
        "impd service clients must not share a secret digest: ${lib.fixedWidthString 64 "b" ""}"
      ];
    }
    {
      title = "it fails an assertion on an imp pattern with a star in its middle";
      clients.reader = {
        scopes = [ "read" ];
        secretDigests = [ (lib.fixedWidthString 64 "a" "") ];
        imps = [ "dev-*-a" ];
      };
      messages = [
        "impd service client reader: imps must hold 1 to 32 patterns, each *, an imp name, or a name prefix and a trailing *"
      ];
    }
  ];

  cases = [
    {
      title = "it writes each file as a copy that only root changes, names both in the settings of impd, and restarts imp-host when one changes";
      script =
        let
          config =
            (buildClientsSystem {
              clients.reader = {
                scopes = [ "read" ];
                secretDigests = [ (lib.fixedWidthString 64 "c" "") ];
                imps = [ "*" ];
              };
              clients.runner = {
                scopes = [
                  "read"
                  "exec"
                ];
                secretDigests = [
                  (lib.fixedWidthString 64 "d" "")
                  (lib.fixedWidthString 64 "e" "")
                ];
                imps = [
                  "dev-*"
                  "ci"
                ];
              };
            }).config;
          tokens = config.environment.etc."imp/service-tokens.json";
          clients = config.environment.etc."imp/service-clients.json";
        in
        ''
          jq -S . > expected <<'EOF'
          ${builtins.toJSON {
            modes = [
              "0444"
              "0444"
            ];
            tokenFile = {
              resource = "https://imp.example.com/mcp";
              clients = {
                reader = {
                  scopes = [ "read" ];
                  secretDigests = [ (lib.fixedWidthString 64 "c" "") ];
                };
                runner = {
                  scopes = [
                    "read"
                    "exec"
                  ];
                  secretDigests = [
                    (lib.fixedWidthString 64 "d" "")
                    (lib.fixedWidthString 64 "e" "")
                  ];
                };
              };
            };
            clientsFile.clients = {
              reader.imps = [ "*" ];
              runner.imps = [
                "dev-*"
                "ci"
              ];
            };
            restartTriggers = [
              tokens.text
              clients.text
            ];
            settings = {
              IMP_MCP_SERVICE_TOKEN_FILE = "/etc/imp/service-tokens.json";
              IMP_MCP_SERVICE_CLIENTS_FILE = "/etc/imp/service-clients.json";
            };
          }}
          EOF
          jq -S -n \
            --argjson tokenFile ${lib.escapeShellArg tokens.text} \
            --argjson clientsFile ${lib.escapeShellArg clients.text} \
            --argjson modes ${
              lib.escapeShellArg (
                builtins.toJSON [
                  tokens.mode
                  clients.mode
                ]
              )
            } \
            --argjson restartTriggers ${lib.escapeShellArg (builtins.toJSON config.systemd.services.imp-host.restartTriggers)} \
            --argjson settings ${
              lib.escapeShellArg (
                builtins.toJSON {
                  inherit (config.services.imp.settings)
                    IMP_MCP_SERVICE_TOKEN_FILE
                    IMP_MCP_SERVICE_CLIENTS_FILE
                    ;
                }
              )
            } \
            '{$modes, $tokenFile, $clientsFile, $restartTriggers, $settings}' > actual

          assert_files_equal expected actual
          assert_equals '[]' ${
            lib.escapeShellArg (
              builtins.toJSON (
                collectFailedAssertions (buildClientsSystem {
                  clients.reader = {
                    scopes = [ "read" ];
                    secretDigests = [ (lib.fixedWidthString 64 "c" "") ];
                    imps = [ "*" ];
                  };
                })
              )
            )
          } "failed assertions"
        '';
    }
  ]
  ++ map (refusal: {
    inherit (refusal) title;
    script = ''
      assert_equals ${lib.escapeShellArg (builtins.toJSON refusal.messages)} ${
        lib.escapeShellArg (
          builtins.toJSON (
            collectFailedAssertions (
              buildClientsSystem (
                removeAttrs refusal [
                  "title"
                  "messages"
                ]
              )
            )
          )
        )
      } "failed assertions"
    '';
  }) refusals;
in
pkgs.runCommand "impd-service-clients-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "impd-service-clients-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
