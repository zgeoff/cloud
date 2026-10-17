# The preview service (docs/architecture/workloads/preview.md): a tailnet link per pull request
# to that pull request's code, running in its own imp. It listens twice: the link listener on
# the tailnet, and the webhook listener that cloudflared's pod dials for GitHub's deliveries.
# The unit starts only once its three secret files exist, so a switch before they are staged
# skips it instead of failing. The preview-image unit adds the image each preview imp boots to
# impd, from a reference pinned by digest, so a switch never leaves the service without it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.preview;
  secretFiles = [
    cfg.webhookSecretFile
    cfg.githubTokenFile
    cfg.impTokenFile
  ];

  addImage = pkgs.writeShellApplication {
    name = "preview-image";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.virtualisation.docker.package
    ];
    text = builtins.readFile ./preview-image.sh;
  };
in
{
  options.services.preview = {
    enable = lib.mkEnableOption "the preview service, one imp per pull request";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/preview.nix { };
      description = "The package whose bin/preview-service runs the service.";
    };

    linkListen = lib.mkOption {
      type = lib.types.str;
      example = "100.64.0.10:8417";
      description = "The host:port of the link listener: the host's tailnet address.";
    };

    webhookListen = lib.mkOption {
      type = lib.types.str;
      example = "100.64.0.10:8418";
      description = ''
        The host:port of the webhook listener, which only signed GitHub deliveries pass. The
        host's admission for it lets only pods reach it.
      '';
    };

    baseURL = lib.mkOption {
      type = lib.types.str;
      example = "http://geoffcloud:8417";
      description = "The link's origin, as a tailnet device opens it; each PR comment carries it.";
    };

    repos = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+|\\*)");
      example = [ "acme/greenhouse" ];
      description = ''
        The repositories whose pull requests get previews, as owner/name, or owner/* for every
        repository of an owner. A repository opts in with a preview/compose.yaml and a webhook.
      '';
    };

    slots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "How many previews run at once; opening another sleeps the least recently used.";
    };

    idleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How long a running preview goes unused before the service puts it to sleep.";
    };

    impdURL = lib.mkOption {
      type = lib.types.str;
      example = "http://127.0.0.1:7070";
      description = "impd's API on the host's loopback.";
    };

    impDomain = lib.mkOption {
      type = lib.types.str;
      example = "imps.example.org";
      description = "impd's HTTPS domain, under which each imp answers at https://<name>.<domain>.";
    };

    impImage = lib.mkOption {
      type = lib.types.str;
      default = "pv-base";
      description = ''
        The impd image each preview imp boots, which the preview-image unit adds from
        impRegistryImage. It is a name of the service's own, apart from impd's default image
        (base), which `impz new` boots and an operator may point elsewhere.
      '';
    };

    impRegistryImage = lib.mkOption {
      type = lib.types.strMatching "[^@ ]+@sha256:[0-9a-f]{64}";
      example = "ghcr.io/zgeoff/imp-base:1.2.3@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
      description = ''
        The registry reference, pinned by digest, that the preview-image unit adds to impd as
        impImage. The image must hold dockerd, git and curl, as imp-base does.
      '';
    };

    imageScript = lib.mkOption {
      type = lib.types.package;
      default = addImage;
      readOnly = true;
      description = "The preview-image unit's script, exposed for the flake check.";
    };

    impMemoryMib = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
      description = "Each preview imp's memory.";
    };

    impGitHubSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "gh";
      description = ''
        The impd secret granted to each preview imp, so its clone goes through the broker. Its
        token must list it with --grantable. null clones public repositories only.
      '';
    };

    impModelSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "preview-model";
      description = ''
        The impd secret, for the model API's host, granted to each preview imp, so a stack that
        adds preview/compose.broker.yaml sends its model calls through the broker. Its token must
        list it with --grantable. null leaves the previews without a model route.
      '';
    };

    contractRepos = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+|\\*)");
      default = [ ];
      example = [ "acme/greenhouse" ];
      description = ''
        The repositories whose pull requests run the Agent SDK contract suite, in an imp with the
        model secret's grant, when they change the SDK's pin, as owner/name or owner/*. Each one
        needs the service's webhook. Empty turns the run off.
      '';
    };

    contractModelSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "preview-model";
      description = ''
        The impd secret, for the model API's host, that each contract run's imp is granted. The
        service's impd token must list it with --grantable.
      '';
    };

    contractTimeoutMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "How long one contract run may take before it fails.";
    };

    webhookSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding the GitHub webhook's secret.";
    };

    githubTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding the GitHub token that reads preview/ and comments.";
    };

    impTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding impd's named token for the service (scope manage, imps pv-*).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.contractRepos == [ ] || cfg.contractModelSecret != null;
        message = "services.preview.contractModelSecret must name the model secret when contractRepos lists a repository.";
      }
    ];

    # A oneshot that each switch restarts when the reference changes, so impd holds the pinned
    # image before the service boots a preview from it. A stop of imp-host stops it (requires),
    # and each start of imp-host starts it again (wantedBy), so it runs after every imp-host start.
    systemd.services.preview-image = {
      description = "the preview imps' image in impd";
      wantedBy = [
        "multi-user.target"
        "imp-host.service"
      ];
      after = [ "imp-host.service" ];
      requires = [ "imp-host.service" ];
      environment = {
        PREVIEW_IMAGE_NAME = cfg.impImage;
        PREVIEW_IMAGE_REF = cfg.impRegistryImage;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe addImage;
        # impd's first add pulls its builder image before the add pulls this one
        TimeoutStartSec = "20min";
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    systemd.services.preview = {
      description = "preview service";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
        "preview-image.service"
      ];
      wants = [
        "network-online.target"
        "preview-image.service"
      ];
      unitConfig.ConditionPathExists = secretFiles;
      environment = {
        PREVIEW_LINK_LISTEN = cfg.linkListen;
        PREVIEW_WEBHOOK_LISTEN = cfg.webhookListen;
        PREVIEW_BASE_URL = cfg.baseURL;
        PREVIEW_REPOS = lib.concatStringsSep "," cfg.repos;
        PREVIEW_SLOTS = toString cfg.slots;
        PREVIEW_IDLE_MINUTES = toString cfg.idleMinutes;
        PREVIEW_IMPD_URL = cfg.impdURL;
        PREVIEW_IMP_DOMAIN = cfg.impDomain;
        PREVIEW_IMP_IMAGE = cfg.impImage;
        PREVIEW_IMP_MEMORY_MIB = toString cfg.impMemoryMib;
        PREVIEW_DATABASE = "/var/lib/preview/previews.sqlite";
        HOME = "/var/lib/preview";
        # Bun's transpiler cache would write under HOME on every start; the sources are few
        BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0";
      }
      // lib.optionalAttrs (cfg.impGitHubSecret != null) {
        PREVIEW_IMP_GITHUB_SECRET = cfg.impGitHubSecret;
      }
      // lib.optionalAttrs (cfg.impModelSecret != null) {
        PREVIEW_IMP_MODEL_SECRET = cfg.impModelSecret;
      }
      // lib.optionalAttrs (cfg.contractRepos != [ ]) {
        PREVIEW_CONTRACT_REPOS = lib.concatStringsSep "," cfg.contractRepos;
        PREVIEW_CONTRACT_MODEL_SECRET = toString cfg.contractModelSecret;
        PREVIEW_CONTRACT_TIMEOUT_MINUTES = toString cfg.contractTimeoutMinutes;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/preview-service";
        DynamicUser = true;
        StateDirectory = "preview";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "webhook-secret:${cfg.webhookSecretFile}"
          "github-token:${cfg.githubTokenFile}"
          "imp-token:${cfg.impTokenFile}"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
