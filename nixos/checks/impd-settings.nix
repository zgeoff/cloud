# Reads the settings file that geoffcloud's imp-host unit hands impd, the file the imp module writes
# from services.imp.settings and its env script exports as IMP_SETTINGS, and checks the settings the
# host sets there. Each case runs in a fresh directory, under test-support/shell/run-cases.sh.
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

  cases = [
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
      title = "it hands impd the public MCP origin https://mcp.geoff.cloud and its listener port 7071";
      script = ''
        assert_equals 1 ${toString (builtins.length envScripts)} "the imp-host-env steps"
        settings=$(sed -n 's|^export IMP_SETTINGS=\(/nix/store/[a-z0-9]\{32\}-imp-host-settings\.env\)$|\1|p' ${lib.head envScripts})
        grep '^IMP_MCP_PUBLIC_' "$settings" | sort > actual

        assert_files_equal - actual <<'EOF'
        IMP_MCP_PUBLIC_PORT=7071
        IMP_MCP_PUBLIC_URL=https://mcp.geoff.cloud
        EOF
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
