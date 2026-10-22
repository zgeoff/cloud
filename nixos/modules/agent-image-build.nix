# The agent image's build on the host (docs/runbooks/agent-image.md): a timer polls the public
# main of zgeoff/cloud, and builds and checks the agent image of the newest commit that changes
# images/agent once impd holds no image of its name (agent-image-build.sh). The build needs an
# impd token of manage scope with no imp patterns, which stays on the host: the unit reads it from
# a root-only file that an operator stages, and is skipped until that file exists. Its output goes
# to the journal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.agent-image-build;

  build = pkgs.writeShellApplication {
    name = "agent-image-build";
    runtimeInputs = [
      pkgs.bun
      pkgs.coreutils
      pkgs.git
      pkgs.gnutar
      pkgs.gzip
      pkgs.jq
    ];
    text = builtins.readFile ./agent-image-build.sh;
  };
in
{
  options.services.agent-image-build = {
    enable = lib.mkEnableOption "the agent image's build on the host";

    repoURL = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/zgeoff/cloud.git";
      description = "The public repository whose main the timer builds from, fetched without a credential.";
    };

    impdURL = lib.mkOption {
      type = lib.types.str;
      example = "http://127.0.0.1:7070";
      description = "impd's API on the host's loopback, which imp's CLI calls with the token.";
    };

    impTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding impd's named token for the build (scope manage, no imp patterns).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "How often the timer looks for a commit to build.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = build;
      readOnly = true;
      description = "The build script, exposed for the flake check.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.agent-image-build = {
      description = "agent image build from main";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # a switch leaves a running build alone, and the next run takes the new script
      restartIfChanged = false;
      unitConfig.ConditionPathExists = cfg.impTokenFile;
      environment = {
        REPO_URL = cfg.repoURL;
        STATE_DIR = "/var/lib/agent-image-build";
        HOME = "/var/lib/agent-image-build";
        IMP_URL = cfg.impdURL;
        DOCKER = lib.getExe config.virtualisation.docker.package;
        BUN = lib.getExe pkgs.bun;
        # Bun's transpiler cache would write under HOME at every build
        BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0";
      };
      # root, since docker's socket is root's
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe build;
        LoadCredential = [ "imp-token:${cfg.impTokenFile}" ];
        # the build waits up to 45 min for impd and the check up to 30 min, with room for the rest
        TimeoutStartSec = "2h";
        StateDirectory = "agent-image-build";
        StateDirectoryMode = "0700";
        # imp's CLI, copied from imp-host, is a Bun executable that asks for the FHS loader
        BindReadOnlyPaths = [ "${pkgs.glibc}/lib/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2" ];
        NoNewPrivileges = true;
        ProtectSystem = "full";
        PrivateTmp = true;
      };
    };

    systemd.timers.agent-image-build = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "1min";
      };
    };
  };
}
