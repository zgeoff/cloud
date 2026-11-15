# Reads the settings file that geoffcloud's imp-host unit hands impd, the file the imp module writes
# from services.imp.settings and its env script exports as IMP_SETTINGS, and checks the settings the
# host sets there, with the userfaultfd device that its huge pages need. Each case runs in a fresh
# directory, under test-support/shell/run-cases.sh.
# Run: bun run test:nixos impd-settings
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

  # the imp module's env script, the one ExecStartPre step whose store name ends in imp-host-env
  envScripts = lib.filter (step: lib.hasSuffix "-imp-host-env" (toString step)) (
    lib.toList geoffcloud.config.systemd.services.imp-host.serviceConfig.ExecStartPre
  );

  # imp-host's start command, where the imp module passes the container its devices
  execStart = pkgs.writeText "imp-host-exec-start" (
    toString geoffcloud.config.systemd.services.imp-host.serviceConfig.ExecStart
  );

  cases = [
    {
      title = "it turns on huge pages of 2M for impd and passes imp-host the userfaultfd device";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_HUGE_PAGES=' "$settings" > actual
        grep -o -- '--device /dev/userfaultfd' ${execStart} > device

        assert_files_equal - actual <<'EOF'
        IMP_HUGE_PAGES=2M
        EOF
        assert_files_equal - device <<'EOF'
        --device /dev/userfaultfd
        EOF
      '';
    }
    {
      title = "it caps the memory file that impd warms after a sleep at 256 MiB of data";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_WARM_CAP_MIB=' "$settings" > actual

        assert_files_equal - actual <<'EOF'
        IMP_WARM_CAP_MIB=256
        EOF
      '';
    }
    {
      title = "it hands impd both image eviction marks, 80 and 65 percent";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_IMAGE_EVICT_' "$settings" | sort > actual

        assert_files_equal - actual <<'EOF'
        IMP_IMAGE_EVICT_HIGH_PERCENT=80
        IMP_IMAGE_EVICT_LOW_PERCENT=65
        EOF
      '';
    }
    {
      title = "it keeps 6144 MiB of the impd budget for the imps whose names start with nixie-";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_PRIORITY_' "$settings" | sort > actual

        assert_files_equal - actual <<'EOF'
        IMP_PRIORITY_IMPS=nixie-*
        IMP_PRIORITY_RAM_MIB=6144
        EOF
      '';
    }
    {
      title = "it names impd geoffcloud as the issuer of its imp identity tokens";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_IDENTITY_' "$settings" > actual

        assert_files_equal - actual <<'EOF'
        IMP_IDENTITY_ISSUER=geoffcloud
        EOF
      '';
    }
    {
      title = "it hands impd the public MCP origin https://imp.geoff.cloud and its listener port 7071";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_MCP_PUBLIC_' "$settings" | sort > actual

        assert_files_equal - actual <<'EOF'
        IMP_MCP_PUBLIC_PORT=7071
        IMP_MCP_PUBLIC_URL=https://imp.geoff.cloud
        EOF
      '';
    }
    {
      title = "it hands impd the service files of wringer-ro, a client that reads every imp";
      script =
        let
          etc = geoffcloud.config.environment.etc;
        in
        ''
          assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
          settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
          grep '^IMP_MCP_SERVICE_' "$settings" | sort > actual
          jq -S . > expected-files <<'EOF'
          ${builtins.toJSON {
            modes = [
              "0444"
              "0444"
            ];
            tokenFile = {
              resource = "https://imp.geoff.cloud/mcp";
              clients.wringer-ro = {
                scopes = [ "read" ];
                secretDigests = [ "51f9e0b8220f5f07e9987a396feeb80c9c31b4b104a8e285587c86b7bc463910" ];
              };
            };
            clientsFile.clients.wringer-ro.imps = [ "*" ];
          }}
          EOF
          jq -S -n \
            --argjson tokenFile ${lib.escapeShellArg etc."imp/service-tokens.json".text} \
            --argjson clientsFile ${lib.escapeShellArg etc."imp/service-clients.json".text} \
            --argjson modes ${
              lib.escapeShellArg (
                builtins.toJSON [
                  etc."imp/service-tokens.json".mode
                  etc."imp/service-clients.json".mode
                ]
              )
            } \
            '{$modes, $tokenFile, $clientsFile}' > actual-files

          assert_files_equal - actual <<'EOF'
          IMP_MCP_SERVICE_CLIENTS_FILE=/etc/imp/service-clients.json
          IMP_MCP_SERVICE_TOKEN_FILE=/etc/imp/service-tokens.json
          EOF
          assert_files_equal expected-files actual-files
        '';
    }
  ];
in
pkgs.runCommand "impd-settings-check"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "impd-settings-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
