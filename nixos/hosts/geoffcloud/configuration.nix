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
  modelGatewayModelExposure = getHostPort "model-gateway-model";
  modelGatewayControlRelayExposure = getHostPort "model-gateway-control-relay";
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
    # the pool's 4096 MiB below, plus 16384 MiB on ordinary pages for the elastic agent imps
    ramBudgetMiB = 20480;
    hostFirewall = "none";
    tailscaleAuthKeyFile = "/var/lib/imp-host/secrets/tailscale-authkey";
    environmentFile = "/var/lib/imp-host/secrets/imp-host.env";
    backupPasswordFile = "/var/lib/imp-host/secrets/backup-password";
    # pinned by digest: the module's default names only its release's tag, which a later push
    # could move
    image = "ghcr.io/zgeoff/imp-host:7.11.0@sha256:f2977796205e7cbbc6f01e3a16b76167c9e5bff88ddf876e0a0958df983f0250";
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
    # pool less ZFS's slop and the rancher zvol's reservation: its used and available space add up
    # to about 131.5 GiB, and impd's disk reserve is 5 % of that, about 6.6 GiB. At 79 % the 16
    # points above the reserve hold about 21 GiB, so a 20 GiB builder disk still fits (80 % would
    # leave under 20 GiB), and eviction starts before impd's low-disk warning at twice the reserve.
    # The 15-point gap is the most one eviction frees, about 20 GiB, and it frees less when too few
    # images qualify for removal.
    settings.IMP_IMAGE_EVICT_HIGH_PERCENT = 79;
    settings.IMP_IMAGE_EVICT_LOW_PERCENT = 64;
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
    # the budget kept for nixie's sandboxes, which serve people waiting on a turn: the most nixie
    # has run at once is 6, a conversation (512 MiB) and five of at most 512 MiB each. impd keeps
    # it in the whole budget and in the pool, where the pool's other 1024 MiB hold one more imp of
    # fixed memory up to 1024 MiB; every other kind of imp boots elastic, off the pool
    settings.IMP_PRIORITY_RAM_MIB = 3072;
    settings.IMP_PRIORITY_IMPS = "nixie-*";
    # none of it kept in the ordinary-page budget: nixie's sandboxes run on the pool, and a kept
    # 3072 MiB there would only take room from the elastic agent imps
    settings.IMP_PRIORITY_ORDINARY_RAM_MIB = 0;
    # image builders boot elastic in the ordinary-page budget, off the pool. impd admits a builder
    # at its max, which fits the 16384 MiB of the budget past the pool
    settings.IMP_BUILD_MEMORY_MIB = 1024;
    settings.IMP_BUILD_MAX_MEMORY_MIB = 2048;
    # the name of this impd in each imp identity token that its broker signs. A service stores the
    # name beside the imp it names, so a change orphans those rows, and no other impd may use it.
    # An impd older than 6.12.0 does not read the setting
    settings.IMP_IDENTITY_ISSUER = "geoffcloud";
  };

  # the clients that sign in on impd's public MCP route with a secret (docs/architecture/host/imp.md).
  # Each secret stays in its owner's vault; this file holds only its sha256 digest. The module sets
  # impd's two service-file settings and names IMP_MCP_PUBLIC_URL's /mcp as the resource
  services.impd-service-clients = {
    enable = true;
    # impz's verify run reads the deployed impd as service:wringer-ro, read-only
    clients.wringer-ro = {
      scopes = [ "read" ];
      secretDigests = [ "51f9e0b8220f5f07e9987a396feeb80c9c31b4b104a8e285587c86b7bc463910" ];
      imps = [ "*" ];
    };
  };

  # the pool of 2 MiB pages that impd's huge pages run on: 4096 MiB for the imps of fixed memory,
  # nixie's sandboxes and 1024 MiB more, set apart from ramBudgetMiB. The 16384 MiB of budget past
  # the pool is impd's ordinary-page budget, where the elastic agent imps run: the host has no
  # ordinary memory for a budget past 20480 MiB, so the pool gives up that part. systemd-sysctl
  # reserves the pool early in boot, before memory fragments, and applies a smaller pool at the
  # activation by freeing unused pages; no page is made on demand past it, because Firecracker maps
  # the pool without a reservation and a page the kernel cannot make kills the guest
  boot.kernel.sysctl."vm.nr_hugepages" = 2048;

  # the kernel's default read-ahead on the root disk and on k3s's zvol, in place of the 8 MiB the
  # kernel derives for vda and the 64 MiB it derives for the zvol, at which Alloy's journal reads
  # and Prometheus's TSDB reads thrash their memory cgroups
  # (docs/architecture/host/host.md#disk-read-ahead). vdb keeps its own: ZFS prefetches
  services.disk-read-ahead = {
    enable = true;
    devices = [
      "vda"
      "zvol/tank/cloud/rancher"
    ];
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
      # The pr-evidence skill and `bun verify publish` upload to the files service with
      # CLOUD_FILES_URL, its API address, and CLOUD_FILES_TOKEN_REF, the op:// reference of its
      # agent token in the imp vault, which the skill reads with `op read` through the op-connect
      # profile. Nothing runs `op run`
      # over a session's environment, so the reference stays a plain string. They sit on the entry
      # because atc takes only the profile's own host as a profile URL. Every target of this daemon
      # is an imp, so the entry can carry the imp vault's reference.
      #
      # No entry sets an OpenTelemetry variable: the pepys-telemetry profile's telemetry item sets
      # up the export of each session that selects it, and atc refuses an entry that sets one of
      # those variables beside it. atc appends atc.session.id to OTEL_RESOURCE_ATTRIBUTES in every
      # session it starts, so the entries set no resource attributes.
      claudeAuth = {
        mcpServers.linear = {
          url = "https://mcp.linear.app/mcp";
          profile = "linear";
        };
      };
      # Every Claude entry turns the built-in Artifact tool off, which saves about 14k tokens of
      # context per session. They go on the entry because the daemon host has no ~/.claude to
      # copy, and atc's copy of one drops these keys. An entry's settings and env reach the
      # session's generated --settings file whatever the host holds.
      noArtifactSettings = {
        enableArtifact = false;
        permissions.deny = [ "Artifact" ];
      };
      noArtifactEnv.CLAUDE_CODE_DISABLE_ARTIFACT = "1";
      claudeEnv = noArtifactEnv // {
        CLOUD_FILES_URL = "https://${filesExposure.hostname}/api/files";
        CLOUD_FILES_TOKEN_REF = "op://imp/files-upload-token/credential";
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
      # atc sends a spawn's clone token only to the hosts listed here; every boxxy repo is on GitHub
      workspaces.gitCredentials.ATC_GIT_CLONE_TOKEN.hosts = [ "github.com" ];
      targets.geoffcloud = {
        provider = "imp";
        url = impdLoopbackURL;
        tokenFile = "/run/credentials/atc-daemon.service/imp-token";
        impPrefix = "harness-";
        # sessions follow the `agent` alias (docs/runbooks/agent-image.md), which the host's build
        # moves to each agent image that passes its check, so no edit here moves them. Hooks run the
        # image's atc at guestATC while it prints the daemon's release; when the image ships another
        # release, each new imp takes a copy of the daemon's binary (packages/atc.nix)
        image = "agent";
        guestATC = "/usr/local/bin/atc";
        # harness imps boot elastic, off the huge page pool, so the agents leave the pool to nixie's
        # sandboxes. When the host supports them, impd asks for transparent huge pages at an elastic
        # imp's cold boot, and drops that hint at a wake. An imp keeps the memory it was created with
        memoryMib = 1024;
        maxMemoryMib = 2048;
        # a change to an agent's profiles in this file is the owner's, so a session made before
        # the change moves to the new profiles at its next revive or restore, with no rebind by
        # hand. atc still refuses when the change withdraws a grant the imp holds.
        rebindChangedAuth = true;
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
        # The log records of a session's agents to pepys ingest. For the telemetry item, atc sets
        # Claude Code's four OpenTelemetry variables and writes the log exporter into each Codex
        # config.toml of the session, both with the profile's host. The broker adds the bearer token
        # and the imp identity token itself, so the session holds neither and sends no placeholder.
        pepys-telemetry = {
          secret = "pepys-telemetry";
          host = pepysTelemetryHost;
          header = "authorization";
          scheme = "bearer";
          telemetry.logs = true;
        };
        # the ChatGPT subscription sign-in that impd renews: a Codex session signs in with it, and a
        # boxxy session's `codex review` runs on it, so the build's second review needs no key in the
        # imp (atc docs/guides/configuration/codex-subscription.md)
        codex = {
          secret = "codex-chatgpt";
          kind = "oauth";
          host = "chatgpt.com";
          header = "authorization";
          scheme = "bearer";
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
          settings = noArtifactSettings;
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
            profiles = claudeProfiles ++ [
              "boxxy"
              "codex"
            ];
          };
          # a worker image has no git config, so a build session's commit fails without these:
          # the session commits as the owner's GitHub login
          settings = noArtifactSettings;
          env = claudeEnv // {
            GIT_AUTHOR_NAME = "zgeoff";
            GIT_AUTHOR_EMAIL = "3013783+zgeoff@users.noreply.github.com";
            GIT_COMMITTER_NAME = "zgeoff";
            GIT_COMMITTER_EMAIL = "3013783+zgeoff@users.noreply.github.com";
          };
        };
        # a review session of the boxxy server: it runs noslop's command on the pull request and
        # sends the result as its close-out. It alone takes github-review, the read-only clone
        # token, which noslop reads as GH_TOKEN, and no other GitHub profile; the server's
        # spawn.agents scopes it to the review phase, so the rules load only when review recipes
        # alone name it.
        boxxy-review = {
          kind = "claude";
          args = boxxyPluginArgs;
          auth.profiles = [
            "claude"
            "github-review"
            "pepys-telemetry"
            "boxxy"
          ];
          settings = noArtifactSettings;
          env = noArtifactEnv;
        };
        # a Codex session signs in with the ChatGPT subscription through the codex profile, and
        # sends its log records to pepys through the pepys-telemetry profile
        codex.auth.profiles = [
          "codex"
          "github"
          "pepys-telemetry"
        ];
      };
      principals = {
        # ChatGPT's connector, added 2026-10-04
        "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY".targets = [ "geoffcloud" ];
        # the boxxy server's service token at the atc gateway
        # (docs/architecture/workloads/atc-gateway.md#service-tokens)
        "service:boxxy".targets = [ "geoffcloud" ];
        # atc's verify read client, which holds the read scope alone
        # (docs/architecture/workloads/atc-gateway.md#service-tokens)
        "service:wringer-ro".targets = [ "geoffcloud" ];
        # nixie's coding client at the atc gateway, which starts, joins and messages coding
        # sessions (docs/architecture/workloads/atc-gateway.md#service-tokens)
        "service:nixie".targets = [ "geoffcloud" ];
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
    impRegistryImage = "ghcr.io/zgeoff/imp-base:7.11.0@sha256:da04791b4d6985d08fdb6cbfe7b522267928fa2b3fe75445c7d53897e30d02b4";
    webhookSecretFile = "/var/lib/tank-cloud/host-secrets/preview/webhook-secret";
    githubAppClientIDFile = "/var/lib/tank-cloud/host-secrets/preview/github-app-client-id";
    githubAppKeyFile = "/var/lib/tank-cloud/host-secrets/preview/github-app-key";
    impTokenFile = "/var/lib/tank-cloud/host-secrets/preview/imp-token";
  };

  # nixie's model gateway (docs/runbooks/model-gateway.md): every model request of
  # production nixie passes it, through the impd model secrets' upstream, and it refuses a route's
  # requests past its provider's day and month dollar limits below, or past the route's own where
  # it sets them. The control token sits on host-secrets, staged by the runbook; until it exists,
  # the unit is skipped.
  services.model-gateway =
    let
      # Anthropic's list prices, in dollars per million tokens, from the model pricing table of
      # https://platform.claude.com/docs/en/about-claude/pricing (read 17 Nov 2026). The gateway
      # prices each reply with its route's table, and nixie's profiles hold no prices beside it.
      # Every Anthropic route counts against the provider anthropic, with no limits of its own
      anthropic = model: prices: {
        inherit model prices;
        provider = "anthropic";
      };
      # a model outside Claude through OpenRouter's Messages endpoint, at /api/v1/messages, pinned to
      # one provider: the profile's provider_pin and the route's providerPin name the same endpoint.
      # Each price is the highest of the endpoints the pin matches, from
      # https://openrouter.ai/api/v1/models/<model>/endpoints (read 18 Nov 2026); deploy/nixie/config.yaml
      # gives each profile the same pin, and says why. Each route keeps its own limits of 5 and 50
      # dollars beneath the provider openrouter's
      openrouter = model: providerPin: prices: {
        inherit
          model
          providerPin
          prices
          ;
        provider = "openrouter";
        limits = {
          day = 5;
          month = 50;
        };
        upstream = "https://openrouter.ai/api";
      };
      fable52 = {
        input = 8;
        cache_write = 10;
        cache_write_1h = 16;
        cached_input = 0.2;
        output = 40;
      };
      fable51 = {
        input = 10;
        cache_write = 12.5;
        cache_write_1h = 20;
        cached_input = 0.25;
        output = 50;
      };
      opus55 = {
        input = 4;
        cache_write = 5;
        cache_write_1h = 8;
        cached_input = 0.2;
        output = 20;
      };
      # Opus 4.6 and Opus 4.5 share one price row
      opus4 = {
        input = 5;
        cache_write = 6.25;
        cache_write_1h = 10;
        cached_input = 0.5;
        output = 25;
      };
      sonnet55 = {
        input = 2;
        cache_write = 2.5;
        cache_write_1h = 4;
        cached_input = 0.1;
        output = 10;
      };
      # Haiku 5.5 prices a whole request at the higher row once its prompt, cache reads and writes
      # included, passes 100,000 tokens (the page's "Long context pricing")
      haiku55 = {
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
    in
    {
      enable = true;
      # nixie's time zone: deploy/nixie/config.yaml sets no time section, so nixie's default
      zone = "Australia/Sydney";
      modelListen = {
        interface = topology.podman.bridge;
        address = topology.podman.bridgeAddress;
        inherit (modelGatewayModelExposure) port;
        allowedSubnet = topology.podman.subnet;
      };
      control = {
        port = 8790;
        tokenFile = "/var/lib/tank-cloud/host-secrets/model-gateway/control-token";
      };
      # nixie's pod dials the host's tailnet address, as the atc gateway's pod does for the daemon
      controlRelay = {
        inherit (modelGatewayControlRelayExposure) port interface;
        address = topology.tailnet.nodes.geoffcloud.address;
        allowedSubnet = k3sPodCIDR;
      };
      # the day and month limits, in US dollars, of each place the routes send to; each holds all
      # its routes together. dayCap is left at the gateway's default of twice the day
      providers = {
        anthropic.limits = {
          day = 200;
          month = 3000;
        };
        # the owner's ChatGPT plan, which the route gpt-6-luna spends
        chatgpt-plan.limits = {
          day = 200;
          month = 3000;
        };
        openrouter.limits = {
          day = 10;
          month = 100;
        };
      };
      # one route per profile in deploy/nixie/config.yaml, keyed by the profile's ID, which nixie
      # puts in each request's path
      routes = {
        fable-5-2 = anthropic "claude-fable-5-2" fable52;
        fable-5-1 = anthropic "claude-fable-5-1" fable51;
        opus-5-5 = anthropic "claude-opus-5-5" opus55;
        opus-4-6 = anthropic "claude-opus-4-6" opus4;
        opus-4-5 = anthropic "claude-opus-4-5" opus4;
        sonnet-5-5 = anthropic "claude-sonnet-5-5" sonnet55;
        # the checker's profile, which has no prices in nixie's config
        sonnet-5-5-high = anthropic "claude-sonnet-5-5" sonnet55;
        haiku-5-5 = anthropic "claude-haiku-5-5" haiku55;
        # no role uses it, but nixie's config still lists it, and with no prices there
        haiku-5-5-low = anthropic "claude-haiku-5-5" haiku55;
        gemini-4-carbon = openrouter "google/gemini-4-carbon" "google-ai-studio" {
          input = 2;
          cache_write = 2.1875;
          cache_write_1h = 2.1875;
          cached_input = 0.1;
          output = 10;
        };
        gpt-6-2-sol = openrouter "openai/gpt-6.2-sol" "openai" {
          input = 2;
          cache_write = 2.5;
          cache_write_1h = 2.5;
          cached_input = 0.1;
          output = 10;
          long_prompt = {
            over_tokens = 272000;
            input = 4;
            cache_write = 5;
            cache_write_1h = 5;
            cached_input = 0.2;
            output = 15;
          };
        };
        kimi-k3-1-pro = openrouter "moonshotai/kimi-k3.1-pro" "fireworks" {
          input = 2;
          cache_write = 2;
          cache_write_1h = 2;
          cached_input = 0.2;
          output = 10;
        };
        glm-5-3 = openrouter "z-ai/glm-5.3" "tenstorrent/fp8" {
          input = 0.6;
          cache_write = 0.6;
          cache_write_1h = 0.6;
          cached_input = 0.1;
          output = 2.5;
        };
        grok-4-7 = openrouter "x-ai/grok-4.7" "xai" {
          input = 2.2;
          cache_write = 2.2;
          cache_write_1h = 2.2;
          cached_input = 0.55;
          output = 6.6;
          long_prompt = {
            over_tokens = 200000;
            input = 4.4;
            cache_write = 4.4;
            cache_write_1h = 4.4;
            cached_input = 1.1;
            output = 13.2;
          };
        };
        qwen4-max = openrouter "qwen/qwen4-max" "alibaba" {
          input = 1.425;
          cache_write = 1.78125;
          cache_write_1h = 1.78125;
          cached_input = 0.07125;
          output = 4.275;
        };
        mistral-large-4 = openrouter "mistralai/mistral-large-4-0" "mistral/zdr" {
          input = 0.7;
          cache_write = 0.7;
          cache_write_1h = 0.7;
          cached_input = 0.07;
          output = 2.1;
        };
        inkling-2-small = openrouter "thinkingmachines/inkling-2-small" "together" {
          input = 0.3;
          cache_write = 0.3;
          cache_write_1h = 0.3;
          cached_input = 0.03;
          output = 1;
        };
        deepseek-v4-1-flash = openrouter "deepseek/deepseek-v4.1-flash-1017" "nebius/fp8" {
          input = 0.12;
          cache_write = 0.12;
          cache_write_1h = 0.12;
          cached_input = 0.0024;
          output = 0.48;
        };
        gpt-6-2-astra = openrouter "openai/gpt-6.2-astra" "openai" {
          input = 8;
          cache_write = 10;
          cache_write_1h = 10;
          cached_input = 0.4;
          output = 40;
          long_prompt = {
            over_tokens = 272000;
            input = 16;
            cache_write = 20;
            cache_write_1h = 20;
            cached_input = 0.8;
            output = 60;
          };
        };
        gemini-4-hydrogen = openrouter "google/gemini-4-hydrogen" "google-ai-studio" {
          input = 1.5;
          cache_write = 1.583333;
          cache_write_1h = 1.583333;
          cached_input = 0.075;
          output = 7.5;
        };
        muse-wonder = openrouter "meta/muse-wonder" "meta" {
          input = 4;
          cache_write = 4;
          cache_write_1h = 4;
          cached_input = 0.2;
          output = 20;
        };
        hy4 = openrouter "tencent/hy4" "tencent/fp4" {
          input = 0.417;
          cache_write = 0.417;
          cache_write_1h = 0.417;
          cached_input = 0.021;
          output = 1.2505;
        };
        pareto-26-10 = openrouter "unbiased/pareto-26.10" "unbiased" {
          input = 0.8;
          cache_write = 0.8;
          cache_write_1h = 0.8;
          cached_input = 0.03;
          output = 3.2;
        };
        aion-3-5 = openrouter "aion-labs/aion-3.5" "aion-labs" {
          input = 3;
          cache_write = 3;
          cache_write_1h = 3;
          cached_input = 0.75;
          output = 6;
        };
        # the Codex tasks' plan route (docs/runbooks/model-gateway.md#add-the-chatgpt-plan-route):
        # the gateway holds the owner's ChatGPT plan login and sets its access token on each request,
        # so neither nixie nor a sandbox holds a plan token. The prices and the largest output are
        # OpenAI's API ones for the model, from https://developers.openai.com/api/docs/models/gpt-6-luna
        # (read 19 Nov 2026), so the count and the stop cap the credits that use past the plan spends;
        # OpenAI has no 1-hour cache write, so cache_write_1h is the cache write price
        gpt-6-luna = {
          api = "openai-responses";
          upstream = "https://chatgpt.com/backend-api/codex";
          model = "gpt-6-luna";
          maxOutputTokens = 128000;
          provider = "chatgpt-plan";
          prices = {
            input = 0.1;
            cache_write = 0.125;
            cache_write_1h = 0.125;
            cached_input = 0.01;
            output = 0.5;
            # past 272K input tokens, a whole request costs 2x the input and cache rates, 1.5x output
            long_prompt = {
              over_tokens = 272000;
              input = 0.2;
              cache_write = 0.25;
              cache_write_1h = 0.25;
              cached_input = 0.02;
              output = 0.75;
            };
          };
          login = {
            file = "/var/lib/model-gateway/chatgpt-login-gpt-6-luna.json";
            routeKeyFile = "/var/lib/tank-cloud/host-secrets/model-gateway/gpt-6-luna-route-key";
          };
        };
      };
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
