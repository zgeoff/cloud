# geoffcloud: Onidel VM, Melbourne. 8 vCPU (EPYC 7513, nested KVM), 31 GiB RAM.
# vda: root (disko.nix). vdb: imp's ZFS pool, imported, never formatted here.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  topology = import ../../topology.nix;
  # the exposure registry (packages/topology/exposure.json): the firewall's public ports and the
  # cloud_host admissions come from it, and checks/exposure.nix compares it with this config
  exposure = (import ../../exposure.nix).entries;
  hostPorts = builtins.filter (entry: entry.kind == "host-port") exposure;
  getHostPort = name: builtins.head (builtins.filter (entry: entry.name == name) hostPorts);
  publicPorts =
    protocol:
    map (entry: entry.port) (
      builtins.filter (entry: entry.scope == "public" && entry.protocol == protocol) hostPorts
    );
  atcDaemonExposure = getHostPort "atc-daemon";
  atcDaemonHomePCExposure = getHostPort "atc-daemon-home-pc";
  previewLinkExposure = getHostPort "preview-link";
  previewWebhookExposure = getHostPort "preview-webhook";
  previewModelRouteExposure = getHostPort "preview-model-route";
  impdMCPListenerExposure = getHostPort "impd-mcp-listener";
  impdMCPRouteExposure = builtins.head (builtins.filter (entry: entry.name == "impd-mcp") exposure);
  impdMCPListenerPort = toString impdMCPListenerExposure.port;
  filesExposure = builtins.head (builtins.filter (entry: entry.name == "files") exposure);
  # atc's daemon listens on the host's tailnet address; the gateway pod dials it there
  atcDaemonAddress = topology.tailnet.nodes.geoffcloud.address;
  atcDaemonPort = topology.atc.daemonPort;
  # k3s's default cluster and service CIDRs (no --cluster-cidr or --service-cidr override
  # below); services.imp.forwardDeny names both
  k3sPodCIDR = topology.k3s.podCIDR;
  k3sServiceCIDR = topology.k3s.serviceCIDR;
  # impd's API on the host's loopback, for the atc daemon's imp target and the health probe
  impdLoopbackURL = "http://127.0.0.1:${toString topology.imp.apiPort}";
  atc = pkgs.callPackage ../../packages/atc.nix { };
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = "26.05";

  # impd local health as a node-exporter textfile metric (#29): loopback only, not HTTPS
  services.impd-local-health = {
    enable = true;
    url = "${impdLoopbackURL}/health";
  };
  # how long the host has run an older system or imp than the latest green main build
  services.host-build-lag.enable = true;
  # builds and checks the agent image of each commit on main that changes images/agent
  # (docs/runbooks/agent-image.md). Its impd token sits on host-secrets, staged by the runbook;
  # until it exists, the unit is skipped.
  services.agent-image-build = {
    enable = true;
    impdURL = impdLoopbackURL;
    impTokenFile = "/var/lib/tank-cloud/host-secrets/agent-image-build/imp-token";
  };
  # each slice's and unit's CPU time, the root cgroup's, and the kernel's, as node-exporter
  # textfile metrics
  services.host-cgroup-cpu.enable = true;
  # the daily drift check of prod (docs/runbooks/drift-check.md). Its credentials file sits on
  # host-secrets, installed by scripts/install-drift-check-credentials.sh; until it exists, the
  # unit is skipped.
  services.drift-check = {
    enable = true;
    credentialsFile = "/var/lib/tank-cloud/host-secrets/drift-check/credentials";
  };
  networking.hostName = "geoffcloud";
  # ZFS host ID: the one imp's pool was created under on Ubuntu (/etc/hostid),
  # so NixOS imports tank without -f
  networking.hostId = "5ca71846";
  time.timeZone = "Australia/Melbourne";

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    kernelModules = [ "kvm-amd" ];
    supportedFilesystems = [ "zfs" ];
    # root is ext4; never force-import a pool another host may own
    zfs.forceImportRoot = false;
    # virtio disks have no serial, so /dev/disk/by-id (the default) has no vdb link
    zfs.devNodes = "/dev/disk/by-partuuid";
  };

  # Onidel gives a static address; no DHCP on this network
  networking = {
    useDHCP = false;
    interfaces.eth0 = {
      ipv4.addresses = [
        {
          address = topology.vm.publicIPv4;
          prefixLength = topology.vm.publicIPv4PrefixLength;
        }
      ];
      ipv6.addresses = [
        {
          address = topology.vm.publicIPv6;
          prefixLength = topology.vm.publicIPv6PrefixLength;
        }
      ];
    };
    defaultGateway = {
      address = "104.250.100.1";
      interface = "eth0";
    };
    defaultGateway6 = {
      address = "fe80::1";
      interface = "eth0";
    };
    nameservers = [
      "1.1.1.1"
      "2606:4700:4700::1111"
    ];
  };
  # the NIC is eth0 on Onidel; keep the kernel name rather than a predictable one
  networking.usePredictableInterfaceNames = false;

  # Firewall: NixOS's own table (inet nixos-fw). flushRuleset must stay off:
  # imp's module adds inet imp-forward, and k3s and netavark, Podman's network backend, add their
  # own.
  networking.nftables = {
    enable = true;
    flushRuleset = false;
  };
  networking.firewall = {
    enable = true;
    # public: the registry's public host ports, Tailscale's direct-connection port alone.
    # Everything else is reached over the tailnet.
    allowedTCPPorts = publicPorts "tcp";
    allowedUDPPorts = publicPorts "udp";
    # ICMP stays open (the registry's icmp entry): path MTU discovery needs fragmentation-needed
    # and ICMPv6 packet-too-big, and ping checks that the host is reachable
    allowPing = true;
    # trusted as a source, in input and forward: the tailnet and k3s pods (pods
    # reach the API server and kubelet on the host). inet cloud_host closes the host's SSH to the
    # pods (cloudHost.inputDrops below)
    trustedInterfaces = [
      "tailscale0"
      "cni0"
      "flannel.1"
    ];
    # filter forwarded traffic too, so nothing public reaches a pod or a NodePort
    # unless a rule allows it
    filterForward = true;
    # Pods (cni0, flannel.1) need forward too: trustedInterfaces covers input only.
    # inet cloud_host drops their traffic to Podman's subnet first (cloudHost.forwardDrops
    # below). imp's module accepts imp-host's own bridge, and drops its traffic to the k3s
    # ranges (services.imp.forwardDeny below).
    extraForwardRules = ''
      iifname { "cni0", "flannel.1" } accept
    '';
  };

  # atc's daemon port, k3s pods and home-pc only, in inet cloud_host
  # (modules/cloud-host-firewall.nix). tailscale0 is trusted above, so nixos-fw alone would accept
  # the port from every tailnet device the policy lets reach geoffcloud (today every member,
  # through autogroup:member -> *). The first admission narrows it to the gateway's path: the pod
  # dials the host's tailnet address, so the packet enters on cni0 from a pod address, and local
  # delivery skips flannel's masquerade in postrouting. The second admits home-pc's tailnet
  # address on tailscale0. Every other source, the rest of the tailnet and the host's own
  # loopback included, is dropped; nixos-fw, which trusts cni0 and tailscale0, accepts what the
  # admissions pass on. Any pod on the host can still reach the port; the daemon's bearer token
  # gates the rest.
  networking.cloudHost.admissions = [
    {
      inherit (atcDaemonExposure) port interface;
      sourceCIDR = k3sPodCIDR;
      destinationAddress = atcDaemonAddress;
    }
    # home-pc's atc client, over the tailnet
    {
      inherit (atcDaemonHomePCExposure) port interface;
      sourceCIDR = "${topology.tailnet.nodes.homePC.address}/32";
      destinationAddress = atcDaemonAddress;
    }
    # the preview service's webhook listener, on the same path for cloudflared's pod
    {
      inherit (previewWebhookExposure) port interface;
      sourceCIDR = k3sPodCIDR;
      destinationAddress = topology.tailnet.nodes.geoffcloud.address;
    }
  ];

  # No pod reaches the host's SSH: nixos-fw trusts cni0 and flannel.1, so it accepts every port
  # that listens on all addresses from them, and no pod needs OpenSSH. A drop in inet cloud_host's
  # input chain is final whatever nixos-fw accepts. The drops name only the pod interfaces, so
  # OpenSSH and Tailscale SSH answer on tailscale0.
  networking.cloudHost.inputDrops =
    lib.concatMap (interface: map (port: { inherit port interface; }) config.services.openssh.ports)
      [
        "cni0"
        "flannel.1"
      ];

  # No pod reaches Podman's subnet, imp-host's every port included: inside imp-host only its imps'
  # taps are filtered, so from podman0's side impd's plain-HTTP API, sshd and the broker all
  # answer. In iptables' FORWARD, kube-router's network-policy accept mark would let a pod's flow
  # past a drop there. In nixos-fw, forward-allow accepts a DNAT'd flow before extraForwardRules,
  # and only a new flow reaches it. A drop in inet cloud_host's forward chain is final whatever the
  # other chains accept, and it is static, so it holds before kube-router programs a new pod.
  # Every pod reaches impd at its tailnet name instead, which this drop does not match.
  networking.cloudHost.forwardDrops =
    map
      (interface: {
        inherit interface;
        destinationCIDR = topology.podman.subnet;
      })
      [
        "cni0"
        "flannel.1"
      ];

  # Services for imps, relayed from podman0 to each Service's pinned ClusterIP: 1Password Connect,
  # pepys ingest for the sessions' telemetry, and the boxxy worker Service. The module admits
  # podman0's subnet to each relay in cloud_host and opens its port on podman0. kube-router admits
  # the node's own addresses before any network policy, so a relay needs no policy of its own.
  services.bridge-relays =
    let
      relay = name: target: {
        inherit (getHostPort name) port;
        interface = topology.podman.bridge;
        address = topology.podman.bridgeAddress;
        allowedSubnet = topology.podman.subnet;
        inherit target;
      };
    in
    {
      onepassword-connect-relay =
        relay "onepassword-connect-relay" "${topology.onePasswordConnect.clusterIP}:${toString topology.onePasswordConnect.port}"
        // {
          label = "the Connect relay";
        };
      pepys-ingest-relay = relay "pepys-ingest-relay" "${topology.pepysIngest.clusterIP}:${toString topology.pepysIngest.port}";
      boxxy-worker-relay = relay "boxxy-worker-relay" "${topology.boxxy.workerClusterIP}:${toString topology.boxxy.workerPort}";
    };

  services.openssh = {
    enable = true;
    # tailnet only (the registry's ssh entry): the module's default opens 22 on every interface,
    # the public one included. tailscale0 is trusted, so OpenSSH still answers on the tailnet, and
    # Tailscale SSH stays the access path.
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ ../../keys/owner.pub ];

  # Host's own tailnet node: tag:cloud. The auth key is placed at install time
  # by nixos-anywhere --extra-files, minted by Pulumi as a TailnetKey (#5).
  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
    extraUpFlags = [
      "--advertise-tags=${topology.tailnet.tags.cloud}"
      "--ssh"
    ];
    useRoutingFeatures = "client";
  };

  # imp: impd and Firecracker in the imp-host container, outside k3s. The module
  # runs imp-host under rootful Podman and imports tank (vdb); the secrets are staged at install
  # (runbook) and live on tank/cloud (services.tank-cloud.binds).
  services.imp = {
    enable = true;
    zfs = {
      pool = "tank";
      arcMaxMiB = 3206;
    };
    ramBudgetMiB = 20480;
    hostFirewall = "none";
    tailscaleAuthKeyFile = "/var/lib/imp-host/secrets/tailscale-authkey";
    environmentFile = "/var/lib/imp-host/secrets/imp-host.env";
    backupPasswordFile = "/var/lib/imp-host/secrets/backup-password";
    # pinned by digest: the module's default names only its release's tag, which a later push
    # could move
    image = "ghcr.io/zgeoff/imp-host:6.12.0@sha256:3237353cd5f2cf49ec751495489515dffaea3a7723d20414240ec99c9dcc05b1";
    # the module's default ("imp") is taken in the tailnet
    settings.IMP_TAILSCALE_HOSTNAME = topology.tailnet.nodes.imp.hostname;
    # HTTPS on the tailnet only (imp#16): imps at <name>.imps.geoff.cloud, impd's API at
    # imps.geoff.cloud, a wildcard certificate by DNS-01. impd writes DNS-only A records
    # for both names at the tailnet IP of imp's own node. The token lives in dnsApiTokenFile (root-only, re-read on change, so
    # a rotation needs no restart) and the ACME email in environmentFile, both installed by
    # scripts/install-imp-dns-token.sh. environmentFile must not also set IMP_DNS_API_TOKEN.
    settings.IMP_DOMAIN = topology.imp.domain;
    dnsApiTokenFile = "/var/lib/imp-host/secrets/dns-api-token";
    settings.IMP_DNS_PROVIDER = "cloudflare";
    # image eviction, in percent of tank/imp (docs/architecture/host/imp.md). tank/imp sees the
    # 200 GB pool less ZFS's slop and the rancher zvol's reservation, about 160 GiB, and impd's disk
    # reserve is 5 % of that, about 8 GiB. At 80 % a 20 GiB builder disk still fits above the
    # reserve (85 % would refuse it), and eviction starts before impd's low-disk warning at twice
    # the reserve. The 15-point gap frees about 24 GiB, so one eviction serves many adds.
    settings.IMP_IMAGE_EVICT_HIGH_PERCENT = 80;
    settings.IMP_IMAGE_EVICT_LOW_PERCENT = 65;
    # imps are agent sandboxes: they must not reach the k3s pod and service ranges
    forwardDeny = [
      k3sPodCIDR
      k3sServiceCIDR
    ];
    # impd's public MCP route (the registry's impd-mcp entry): impd opens its public listener only
    # with this origin set, and imp-host publishes the listener on the host's loopback alone, where
    # the TLS front below proxies the route's paths to it
    settings.IMP_MCP_PUBLIC_URL = "https://${impdMCPRouteExposure.hostname}";
    settings.IMP_MCP_PUBLIC_PORT = impdMCPListenerExposure.port;
    publicPorts = [ "127.0.0.1:${impdMCPListenerPort}:${impdMCPListenerPort}" ];
    # every imp of fixed memory runs on the host's pool of 2 MiB pages, restored and woken through
    # a page handler (docs/architecture/host/imp.md)
    settings.IMP_HUGE_PAGES = "2M";
    # the most data a slept imp's memory file may hold for impd to warm it into the page cache after
    # the sleep. A warm of an agent imp's file, about 1.8 GiB, would push most of the ZFS ARC out
    settings.IMP_WARM_CAP_MIB = "256";
    # the budget kept for nixie's sandboxes, which serve people waiting on a turn: its conversation
    # imp (2048 MiB), two system tasks (1024 MiB each) and four web fetches (512 MiB each). The
    # other 14336 MiB hold 7 agent imps of 2048 MiB, as 5120 MiB would, so the last 1024 MiB costs
    # no agent slot
    settings.IMP_PRIORITY_RAM_MIB = 6144;
    settings.IMP_PRIORITY_IMPS = "nixie-*";
    # the name of this impd in each imp identity token that its broker signs. A service stores the
    # name beside the imp it names, so a change orphans those rows, and no other impd may use it.
    # An impd older than 6.12.0 does not read the setting
    settings.IMP_IDENTITY_ISSUER = "geoffcloud";
  };

  # the pool of 2 MiB pages that impd's huge pages run on: the whole imp RAM budget, since no imp
  # here is elastic and only an elastic imp runs on ordinary pages. systemd-sysctl reserves it early
  # in boot, before memory fragments; no page is made on demand past it, because Firecracker maps
  # the pool without a reservation and a page the kernel cannot make kills the guest
  boot.kernel.sysctl."vm.nr_hugepages" = config.services.imp.ramBudgetMiB / 2;

  # the root disk's read-ahead at the kernel's default, in place of the 8 MiB the kernel derives
  # from what vda reports, at which Alloy's journal reads thrash its memory cgroup
  # (docs/architecture/host/host.md#read-ahead-on-the-root-disk). vdb keeps its own: ZFS prefetches
  services.disk-read-ahead = {
    enable = true;
    device = "vda";
  };

  # the TLS front on 443 for the registry's front routes (modules/public-front.nix). A hosted MCP
  # client signs in and calls imp's tools through it, so each address gets a limit of its own:
  # impd counts its limits per client and grant, never per address
  services.public-front = {
    enable = true;
    routes = [ { inherit (impdMCPRouteExposure) hostname upstream paths; } ];
    rateLimit = {
      events = 120;
      window = "1m";
    };
  };

  # Podman's default network, which imp-host runs on, pinned to the topology's bridge and subnet:
  # the relays, the model route listener and the pod drops above name them
  virtualisation.podman.defaultNetwork.settings = {
    network_interface = topology.podman.bridge;
    subnets = [
      {
        gateway = topology.podman.bridgeAddress;
        inherit (topology.podman) subnet;
      }
    ];
  };

  # imps yield CPU to k3s and its pods rather than hold a cap (docs/architecture/host/imp.md).
  # Rootful Podman puts each container's scope in machine.slice, and imp-host is the host's only
  # container.
  systemd.slices.machine.sliceConfig.CPUWeight = 10;

  # tank/cloud, the encrypted datasets on tank (modules/tank-cloud.nix, docs/runbooks/tank-cloud.md):
  # unlocked at boot from /var/lib/zfs-keys/tank.key. Each service here refuses to start while
  # its datasets are not mounted, instead of starting on the empty mount points on vda. The
  # secret files of imp-host and the atc daemon and impd's database copies keep their paths, but
  # live on tank/cloud: each path is a bind mount of a directory of a dataset. k3s's data
  # directory is the rancher zvol itself, and /etc/rancher, with the admin kubeconfig and the node
  # password, a directory on it.
  services.tank-cloud = {
    enable = true;
    binds = {
      imp-host-secrets = {
        dataset = "host-secrets";
        subdirectory = "imp-host";
        path = "/var/lib/imp-host/secrets";
      };
      atc-daemon-secrets = {
        dataset = "host-secrets";
        subdirectory = "atc-daemon";
        path = "/var/lib/atc-daemon-secrets";
      };
      root-imp-db-backups = {
        dataset = "imp-db-backups";
        path = "/root/imp-db-backups";
      };
      etc-rancher = {
        dataset = "rancher";
        subdirectory = "etc-rancher";
        path = "/etc/rancher";
      };
    };
    requiredBy = {
      k3s = [
        "rancher"
        "etc-rancher"
      ];
      imp-host = [
        "host-secrets"
        "imp-host-secrets"
      ];
      imp-host-dns-token = [ "imp-host-secrets" ];
      atc-daemon = [ "atc-daemon-secrets" ];
      preview = [ "host-secrets" ];
      drift-check = [ "host-secrets" ];
    };
  };

  # a path unit that survives the switch keeps its inotify watch on the directory the bind
  # shadows, so a token rotation would wait for the 5-minute timer; this restarts it with the bind.
  # A path unit's default dependencies order it before paths.target, so before basic.target, and
  # the bind waits for tank-cloud-key, which starts after basic.target: an ordering cycle, which
  # systemd breaks at boot by dropping a job, at times the bind's, and imp-host then never starts.
  # So the unit keeps only the default dependencies that order it against boot and shutdown.
  systemd.paths.imp-host-dns-token = {
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/var/lib/imp-host/secrets" ];
    };
    requires = [ "sysinit.target" ];
    after = [ "sysinit.target" ];
    conflicts = [ "shutdown.target" ];
    before = [ "shutdown.target" ];
  };

  # tank/imp, an encryption root keyed by the same file (modules/imp-dataset-key.nix,
  # docs/runbooks/tank-cloud.md): its key loads at boot, and imp-host stays stopped
  # while it is missing, plain or locked
  services.imp-dataset-key.enable = true;

  # atc's daemon for the atc gateway (docs/architecture/workloads/atc-gateway.md). The token
  # files are root-only and staged by scripts/install-atc-gateway-credentials.ts; systemd passes them in as
  # credentials. principals lists each gateway client ID (`atc-gateway clients list`) with
  # the targets it may reach; a client not listed here is refused every request. The target,
  # the claude and codex agents and the auth profiles match the home-pc daemon's `cloud` target;
  # the boxxy agents run on this daemon alone. The profiles name
  # the same impd secrets as home-pc's, so a renamed or added profile changes both daemons'
  # configs, and the daemon's impd token must list each secret as grantable.
  services.atc-daemon =
    let
      # the made-up host that the broker serves pepys ingest as: the stack config's
      # pepys.impIdentityAudience names it, and the imp identity tokens name it as their audience
      pepysTelemetryHost = "pepys.imp.internal";
      # the profiles a Claude session signs in through. A boxxy session takes the same ones, the
      # github profile included: it clones, fetches pinned skills, pushes its branch and opens the
      # pull request.
      claudeProfiles = [
        "claude"
        "github"
        "linear"
        "op-connect"
        "pepys-telemetry"
      ];
      # the Linear MCP server and the variables of a Claude session, shared by the claude and boxxy
      # entries so a boxxy session behaves like a Claude session.
      #
      # The pr-evidence skill uploads to the files service with PR_EVIDENCE_*: its API address, and
      # the vault/item/field path of its agent token, which the skill reads with `op read` through
      # the op-connect profile. The path has no op:// prefix, because `op run` resolves every op://
      # value in its environment and fails on one its token can't read. They sit on the entry
      # because atc takes only the profile's own host as a profile URL.
      #
      # The telemetry variables switch on Claude Code's OpenTelemetry export. A profile's variable
      # may hold only the broker placeholder or an https origin of the profile's host, so the
      # endpoint sits on the pepys-telemetry profile and the other three, plain values, sit in the
      # entry's env (which may not repeat a variable that a selected profile sets). atc appends
      # atc.session.id to OTEL_RESOURCE_ATTRIBUTES in every session it starts, so the entries set
      # no resource attributes.
      claudeAuth = {
        mcpServers.linear = {
          url = "https://mcp.linear.app/mcp";
          profile = "linear";
        };
      };
      telemetryEnv = {
        CLAUDE_CODE_ENABLE_TELEMETRY = "1";
        OTEL_LOGS_EXPORTER = "otlp";
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/json";
      };
      claudeEnv = telemetryEnv // {
        PR_EVIDENCE_URL = "https://${filesExposure.hostname}/api/files";
        PR_EVIDENCE_TOKEN_PATH = "imp/files-agent-token/credential";
      };
      # the plug-in folder in the agent image that a boxxy session's hooks run from
      boxxyPluginArgs = [
        "--plugin-dir"
        "/opt/boxxy/hook-plugin"
      ];
    in
    {
      enable = true;
      package = atc;
      listen = "${atcDaemonAddress}:${toString atcDaemonPort}";
      tokenFile = "/var/lib/atc-daemon-secrets/gateway-token";
      impTokenFile = "/var/lib/atc-daemon-secrets/imp-token";
      # atc clones a session's git workspace on this host before the session exists, so the
      # session's GitHub broker profile does not apply. A private repo's clone and ref lookup use
      # this token, which is read-only: contents and pull requests read on the boxxy repos.
      environmentCredentials.ATC_GIT_CLONE_TOKEN = "/var/lib/atc-daemon-secrets/git-clone-token";
      targets.geoffcloud = {
        provider = "imp";
        url = impdLoopbackURL;
        tokenFile = "/run/credentials/atc-daemon.service/imp-token";
        impPrefix = "harness-";
        # the agent image (docs/runbooks/agent-image.md) built from the commit that pins this
        # daemon's atc release, so hooks run the image's atc and no spawn copies the daemon's in
        image = "agent-923a556";
        guestATC = "/usr/local/bin/atc";
      };
      defaultTarget = "geoffcloud";
      authProfiles = {
        claude = {
          secret = "claude-setup-token";
          host = "api.anthropic.com";
          header = "authorization";
          scheme = "bearer";
        };
        github = {
          secret = "github-imp-agents";
          kind = "github";
        };
        # the read-only clone token, with Contents: read and Pull requests: read on the boxxy repos:
        # the boxxy-review agent alone selects it
        github-review = {
          secret = "boxxy-github-token";
          kind = "github";
        };
        linear = {
          secret = "linear-imp-agents";
          host = "mcp.linear.app";
          header = "authorization";
          scheme = "bearer";
        };
        op-connect = {
          secret = "op-connect";
          host = "op-connect.imp.internal";
          header = "authorization";
          scheme = "bearer";
          env = {
            OP_CONNECT_HOST = "https://op-connect.imp.internal";
            OP_CONNECT_TOKEN = "broker-placeholder";
          };
        };
        # Claude Code's telemetry to pepys ingest. The broker adds the bearer token and the imp
        # identity token itself, so the session holds neither and sends no placeholder.
        pepys-telemetry = {
          secret = "pepys-telemetry";
          host = pepysTelemetryHost;
          header = "authorization";
          scheme = "bearer";
          env.OTEL_EXPORTER_OTLP_ENDPOINT = "https://${pepysTelemetryHost}";
        };
        # the boxxy server's worker listener, through the host's relay. The broker adds the worker
        # token and the imp identity token; the boxxy CLI in the session reads BOXXY_URL.
        boxxy = {
          secret = "boxxy";
          host = topology.boxxy.brokerHost;
          header = "authorization";
          scheme = "bearer";
          env.BOXXY_URL = "https://${topology.boxxy.brokerHost}";
        };
      };
      agents = {
        claude = {
          auth = claudeAuth // {
            profiles = claudeProfiles;
          };
          env = claudeEnv;
        };
        # a worker session of the boxxy server (docs/architecture/workloads/boxxy.md): a Claude
        # session with the boxxy profile beside the claude entry's, and the boxxy CLI's hook
        # plug-in, which the agent image holds. A stock entry's auth takes no args (only a gateway
        # entry's does), so the plug-in goes in the entry's args, which apply on an imp.
        boxxy = {
          kind = "claude";
          args = boxxyPluginArgs;
          auth = claudeAuth // {
            profiles = claudeProfiles ++ [ "boxxy" ];
          };
          # a worker image has no git config, so a build session's commit fails without these:
          # the session commits as the owner's GitHub login
          env = claudeEnv // {
            GIT_AUTHOR_NAME = "zgeoff";
            GIT_AUTHOR_EMAIL = "3013783+zgeoff@users.noreply.github.com";
            GIT_COMMITTER_NAME = "zgeoff";
            GIT_COMMITTER_EMAIL = "3013783+zgeoff@users.noreply.github.com";
          };
        };
        # a review session of the boxxy server: it runs noslop's command on the pull request and
        # sends the result as its close-out. It alone takes github-review, the read-only clone
        # token, which noslop reads as GH_TOKEN, and no other GitHub profile; the server lists it
        # in spawn.reviewAgents, so the rules load only when review recipes alone name it.
        boxxy-review = {
          kind = "claude";
          args = boxxyPluginArgs;
          auth.profiles = [
            "claude"
            "github-review"
            "pepys-telemetry"
            "boxxy"
          ];
          env = telemetryEnv;
        };
        # atc refuses a Codex auth without an oauth profile for chatgpt.com, which this daemon
        # does not have, so Codex runs with no brokered sign-in
        codex = { };
      };
      principals = {
        # ChatGPT's connector, added 2026-10-04
        "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY".targets = [ "geoffcloud" ];
        # the boxxy server's service token at the atc gateway
        # (docs/architecture/workloads/atc-gateway.md#service-tokens)
        "service:boxxy".targets = [ "geoffcloud" ];
      };
    };

  # The preview service (docs/architecture/workloads/preview.md, docs/runbooks/preview.md). Its
  # secrets sit on host-secrets, staged by the runbook; until they exist, the unit is skipped.
  # A repository opts in with preview/compose.yaml and the preview GitHub App's installation,
  # which only the owner's account can install, so every repository of the owner is listed.
  services.preview = {
    enable = true;
    linkListen = "${topology.tailnet.nodes.geoffcloud.address}:${toString previewLinkExposure.port}";
    webhookListen = "${topology.tailnet.nodes.geoffcloud.address}:${toString previewWebhookExposure.port}";
    baseURL = "http://geoffcloud:${toString previewLinkExposure.port}";
    repos = [ "zgeoff/*" ];
    impdURL = impdLoopbackURL;
    impDomain = topology.imp.domain;
    impGitHubSecret = "gh";
    # nixie's preview stack sends its model calls through the broker with this grant, whose
    # upstream is the spend cap's model route listener (docs/runbooks/preview.md)
    impModelSecret = "preview-model-counted";
    # each preview's model calls pass a counting proxy of their own, which refuses them past the
    # module's default limit
    spendCap = {
      enable = true;
      package = pkgs.callPackage ../../packages/counting-proxy.nix { };
      interface = topology.podman.bridge;
      address = topology.podman.bridgeAddress;
      inherit (previewModelRouteExposure) port;
      allowedSubnet = topology.podman.subnet;
      # nixie's preview/config.yaml model profile
      model = "claude-haiku-5-5";
      # Haiku 5.5's list prices on Anthropic's pricing page: the base prices for a prompt up to
      # 100,000 tokens, cache reads and writes included, and the long-prompt prices for a longer one
      prices = {
        input = 0.1;
        cache_write = 0.125;
        cache_write_1h = 0.2;
        cached_input = 0.01;
        output = 0.5;
        long_prompt = {
          over_tokens = 100000;
          input = 0.5;
          cache_write = 0.625;
          cache_write_1h = 1;
          cached_input = 0.05;
          output = 2.5;
        };
      };
    };
    # nixie's pull requests that change the Agent SDK's pin run its SDK contract suite
    contractRepos = [ "zgeoff/nixie" ];
    contractModelSecret = "preview-model";
    # the imp-base release that images/agent/Dockerfile builds on; the imp release pin moves both
    impRegistryImage = "ghcr.io/zgeoff/imp-base:6.12.0@sha256:629d044ed189cd58ec69f66a0a0b36161724da56c90dc48d01f39fa221158d8e";
    webhookSecretFile = "/var/lib/tank-cloud/host-secrets/preview/webhook-secret";
    githubAppClientIDFile = "/var/lib/tank-cloud/host-secrets/preview/github-app-client-id";
    githubAppKeyFile = "/var/lib/tank-cloud/host-secrets/preview/github-app-key";
    impTokenFile = "/var/lib/tank-cloud/host-secrets/preview/imp-token";
  };

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      # ingress is cloudflared; no Traefik or ServiceLB
      "--disable=traefik"
      "--disable=servicelb"
      "--write-kubeconfig-mode=0600"
      "--tls-san=geoffcloud"
      # NodePorts (Grafana's, topology.k3s.grafanaNodePort) bind to the tailnet range only.
      # kube-proxy DNATs them through FORWARD, which the input firewall does not cover.
      "--kube-proxy-arg=nodeport-addresses=${topology.tailnet.cidr}"
      # the host resolves through MagicDNS (100.100.100.100), which pods cannot reach
      "--resolv-conf=/etc/k3s-resolv.conf"
    ];
  };

  # k3s on a zvol without its cluster's server data would make a new cluster, so the start fails
  # instead (checks/tank-cloud-rancher.nix). The guard names the two files that k3s makes again
  # when they are missing: the cluster CA, without which it makes a new CA, and the sqlite
  # datastore, without which it makes an empty cluster. /var/lib/rancher/k3s is no guard, nor is its server directory:
  # any k3s command, kubectl among them, unpacks k3s's binaries into /var/lib/rancher/k3s/data, and
  # a directory does not show that the files in it exist. A move to another datastore, such as
  # embedded etcd, changes the second path. The bind of /etc/rancher is no guard either: systemd
  # makes a bind's missing source directory.
  systemd.services.k3s.unitConfig.AssertPathExists = [
    "/var/lib/rancher/k3s/server/tls/server-ca.crt"
    "/var/lib/rancher/k3s/server/db/state.db"
  ];

  environment.etc."k3s-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 9.9.9.9
  '';

  environment.systemPackages = with pkgs; [
    # a patched copy for `atc daemon id`; the service runs the unpatched release
    (callPackage ../../packages/atc-interactive.nix { inherit atc; })
    # copy-impd-db-host and restore-impd-db, for scripts/copy-impd-db.sh and the restore runbook
    (callPackage ../../packages/impd-db-tools { })
    git
    htop
    k9s
    kubectl
    zfs
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "root" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
