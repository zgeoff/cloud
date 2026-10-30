# The preview service (docs/architecture/workloads/preview.md): a tailnet link per pull request
# to that pull request's code, running in its own imp. It listens twice: the link listener on
# the tailnet, and the webhook listener that cloudflared's pod dials for GitHub's deliveries.
# The unit starts only once its four secret files exist, so a switch before they are staged
# skips it instead of failing. The preview-image unit adds the image each preview imp boots to
# impd, from a reference pinned by digest, so a switch never leaves the service without it.
# With spendCap on, a third listener on imp-host's bridge takes each preview's model calls from imp-host's
# broker and hands them to that preview's own counting proxy.
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
    cfg.githubAppClientIDFile
    cfg.githubAppKeyFile
    cfg.impTokenFile
  ];
  priceRateOptions = lib.genAttrs [ "input" "cache_write" "cache_write_1h" "cached_input" "output" ] (
    price:
    lib.mkOption {
      type = lib.types.either lib.types.ints.unsigned lib.types.float;
      description = "The model's ${price} price, in dollars per million tokens.";
    }
  );

  addImage = pkgs.writeShellApplication {
    name = "preview-image";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.virtualisation.podman.package
    ];
    # interpolated, so the file joins the script's closure: writeShellApplication turns a bare path
    # into the text of its place in the flake source, which the switch never copies to the host
    runtimeEnv.PREVIEW_IMAGE_TOKEN_FACTS = "${./preview-image-token-facts.sh}";
    text = builtins.readFile ./preview-image.sh;
  };
in
{
  imports = [ ./cloud-host-firewall.nix ];

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
        repository of an owner. A listed repository opts in with a preview/compose.yaml and the
        GitHub App's installation.
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

    spendCap = {
      enable = lib.mkEnableOption ''
        a counting proxy on each preview's model route, which refuses the preview's model calls
        once they cost the limit. impModelSecret must then be a custom secret for the model API's
        host whose upstream is http://<address>:<port>
      '';

      package = lib.mkOption {
        type = lib.types.package;
        description = "The package whose bin/counting-proxy is nixie's counting proxy.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        example = "podman0";
        description = "imp-host's bridge, the interface the model route listener takes calls on.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        example = "10.88.0.1";
        description = "The host's address on the bridge, where the model route listener listens.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        example = 18082;
        description = "The port of the model route listener.";
      };

      allowedSubnet = lib.mkOption {
        type = lib.types.str;
        example = "10.88.0.0/16";
        description = "The bridge's subnet, the only source cloud_host admits to the listener.";
      };

      upstream = lib.mkOption {
        type = lib.types.str;
        default = "https://api.anthropic.com";
        description = "The model API's origin, which each proxy sends a preview's model calls to.";
      };

      model = lib.mkOption {
        type = lib.types.str;
        example = "claude-haiku-5-5";
        description = "The one model a preview may call; each proxy refuses a call for another.";
      };

      prices = lib.mkOption {
        type = lib.types.submodule {
          options = priceRateOptions // {
            long_prompt = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = priceRateOptions // {
                    over_tokens = lib.mkOption {
                      type = lib.types.ints.positive;
                      example = 100000;
                      description = "The prompt length, in tokens, past which a call costs these prices.";
                    };
                  };
                }
              );
              default = null;
              description = ''
                The model's prices for a call whose prompt, cache reads and writes included, passes
                over_tokens. Each proxy charges all of such a call's tokens at them. null charges
                every call at the base prices.
              '';
            };
          };
        };
        description = "The model's prices, which each proxy charges a reply's tokens at.";
      };

      limitDollars = lib.mkOption {
        type = lib.types.either lib.types.ints.positive lib.types.float;
        default = 2;
        description = ''
          The dollars, at the model's prices, that a preview's model calls may cost over its pull
          request's life. A closed pull request's count goes with its imp.
        '';
      };
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

    contractIdleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        How long a running preview goes unused before a contract run that finds every slot taken
        puts it to sleep to take its slot.
      '';
    };

    webhookSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding the webhook secret of the GitHub App.";
    };

    githubAppClientIDFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding the client ID of the GitHub App that reads preview/ and comments.";
    };

    githubAppKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "A root-only file holding that GitHub App's private key, as GitHub's PEM.";
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
      {
        assertion = !cfg.spendCap.enable || cfg.impModelSecret != null;
        message = "services.preview.spendCap needs impModelSecret, whose upstream reaches the model route listener.";
      }
      {
        assertion = !cfg.spendCap.enable || !(config.services.imp.ipv6.enable or false);
        message = "the model route listener assumes imp-host on ${cfg.spendCap.interface}; services.imp.ipv6.enable moves it to br-imphost";
      }
    ];

    networking.cloudHost.admissions = lib.mkIf cfg.spendCap.enable [
      {
        inherit (cfg.spendCap) port interface;
        sourceCIDR = cfg.spendCap.allowedSubnet;
        destinationAddress = cfg.spendCap.address;
      }
    ];
    # optionalAttrs, not mkIf: the module system reads the names of an attrset inside an mkIf even
    # when its condition is false, and with spendCap off the interface option has no value
    networking.firewall.interfaces = lib.optionalAttrs cfg.spendCap.enable {
      ${cfg.spendCap.interface}.allowedTCPPorts = [ cfg.spendCap.port ];
    };

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
      # each start waits up to about 10 min for impd, so restarts after failed waits stay under
      # 10 an hour, and the unit keeps trying while imp-host runs
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        ExecStart = lib.getExe addImage;
        # the wait for impd takes up to about 10 min, and impd's first add pulls its builder image
        # before the add pulls this one
        TimeoutStartSec = "30min";
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
      // lib.optionalAttrs cfg.spendCap.enable {
        PREVIEW_SPEND_LISTEN = "${cfg.spendCap.address}:${toString cfg.spendCap.port}";
        PREVIEW_SPEND_PROXY = "${cfg.spendCap.package}/bin/counting-proxy";
        PREVIEW_SPEND_DIRECTORY = "/var/lib/preview/spend";
        PREVIEW_SPEND_UPSTREAM = cfg.spendCap.upstream;
        PREVIEW_SPEND_MODEL = cfg.spendCap.model;
        # the service's price schema takes no null for an absent long_prompt
        PREVIEW_SPEND_PRICES = builtins.toJSON (
          lib.filterAttrs (_: rates: rates != null) cfg.spendCap.prices
        );
        PREVIEW_SPEND_LIMIT_DOLLARS = toString cfg.spendCap.limitDollars;
      }
      // lib.optionalAttrs (cfg.contractRepos != [ ]) {
        PREVIEW_CONTRACT_REPOS = lib.concatStringsSep "," cfg.contractRepos;
        PREVIEW_CONTRACT_MODEL_SECRET = toString cfg.contractModelSecret;
        PREVIEW_CONTRACT_TIMEOUT_MINUTES = toString cfg.contractTimeoutMinutes;
        PREVIEW_CONTRACT_IDLE_MINUTES = toString cfg.contractIdleMinutes;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/preview-service";
        DynamicUser = true;
        StateDirectory = "preview";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "webhook-secret:${cfg.webhookSecretFile}"
          "github-app-client-id:${cfg.githubAppClientIDFile}"
          "github-app-key:${cfg.githubAppKeyFile}"
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
