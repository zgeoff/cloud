# geoffcloud: Onidel VM, Melbourne. 8 vCPU (EPYC 7513, nested KVM), 31 GiB RAM.
# vda: root (disko.nix). vdb: imp's ZFS pool, imported, never formatted here.
{
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
  previewLinkExposure = getHostPort "preview-link";
  previewWebhookExposure = getHostPort "preview-webhook";
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
          prefixLength = 24;
        }
      ];
      ipv6.addresses = [
        {
          address = topology.vm.publicIPv6;
          prefixLength = 64;
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
  # imp's module adds inet imp-forward, and k3s and Docker add their own.
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
    # reach the API server and kubelet on the host)
    trustedInterfaces = [
      "tailscale0"
      "cni0"
      "flannel.1"
    ];
    # filter forwarded traffic too, so nothing public reaches a pod or a NodePort
    # unless a rule allows it
    filterForward = true;
    # Pods (cni0, flannel.1) need forward too: trustedInterfaces covers input only.
    # imp's module accepts imp-host's own bridge, and drops its traffic to the k3s
    # ranges (services.imp.forwardDeny below).
    extraForwardRules = ''
      iifname { "cni0", "flannel.1" } accept
    '';
  };

  # atc's daemon port, k3s pods only, in inet cloud_host (modules/cloud-host-firewall.nix).
  # tailscale0 is trusted above, so nixos-fw alone would accept the port from every tailnet
  # device the policy lets reach geoffcloud (today every member, through autogroup:member -> *).
  # The admission narrows it to the gateway's path: the pod dials the host's tailnet address, so
  # the packet enters on cni0 from a pod address, and local delivery skips flannel's masquerade
  # in postrouting. Every other source, the tailnet and the host's own loopback included, is
  # dropped; nixos-fw, which trusts cni0, accepts what the admission passes on. Any pod on the
  # host can still reach the port; the daemon's bearer token gates the rest.
  networking.cloudHost.admissions = [
    {
      inherit (atcDaemonExposure) port interface;
      sourceCIDR = k3sPodCIDR;
      destinationAddress = atcDaemonAddress;
    }
    # the preview service's webhook listener, on the same path for cloudflared's pod
    {
      inherit (previewWebhookExposure) port interface;
      sourceCIDR = k3sPodCIDR;
      destinationAddress = topology.tailnet.nodes.geoffcloud.address;
    }
  ];

  # 1Password Connect for imps, relayed from docker0 to the Service's pinned ClusterIP; the
  # module admits docker0's subnet to the relay in cloud_host and opens its port on docker0
  services.onepassword-connect-relay = {
    enable = true;
    address = topology.docker.bridgeAddress;
    inherit (getHostPort "onepassword-connect-relay") port;
    allowedSubnet = topology.docker.subnet;
    target = "${topology.onePasswordConnect.clusterIP}:${toString topology.onePasswordConnect.port}";
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
  # runs Docker and imports tank (vdb); the secrets are staged at install (runbook).
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
    image = "ghcr.io/zgeoff/imp-host:2.0.3@sha256:6622fe097cefdaabfb2b1d18bed3947c512d6a67ed1ae750c2b277d4ae777210";
    # the module's default ("imp") is taken in the tailnet
    settings.IMP_TAILSCALE_HOSTNAME = topology.tailnet.nodes.imp.hostname;
    # HTTPS on the tailnet only (imp#16): imps at <name>.imps.geoff.cloud, impd's API at
    # imps.geoff.cloud, a wildcard certificate by DNS-01. impd writes DNS-only A records
    # for both names at the tailnet IP of imp's own node. imp.geoff.cloud stays free for imp's
    # public MCP route. The token lives in dnsApiTokenFile (root-only, re-read on change, so
    # a rotation needs no restart) and the ACME email in environmentFile, both installed by
    # scripts/install-imp-dns-token.sh. environmentFile must not also set IMP_DNS_API_TOKEN.
    settings.IMP_DOMAIN = topology.imp.domain;
    dnsApiTokenFile = "/var/lib/imp-host/secrets/dns-api-token";
    settings.IMP_DNS_PROVIDER = "cloudflare";
    # imps are agent sandboxes: they must not reach the k3s pod and service ranges
    forwardDeny = [
      k3sPodCIDR
      k3sServiceCIDR
    ];
  };

  # tank/cloud, the encrypted datasets on tank (modules/tank-cloud.nix, docs/runbooks/tank-cloud.md):
  # unlocked at boot from /var/lib/zfs-keys/tank.key. Each service here refuses to start while
  # its datasets are not mounted, instead of starting on the empty mount points on vda.
  services.tank-cloud = {
    enable = true;
    requiredBy = {
      k3s = [ "rancher" ];
      imp-host = [ "host-secrets" ];
      atc-daemon = [ "host-secrets" ];
      preview = [ "host-secrets" ];
    };
  };

  # atc's daemon for the atc gateway (docs/architecture/workloads/atc-gateway.md). The token
  # files are root-only and staged by scripts/install-atc-gateway-credentials.ts; systemd passes them in as
  # credentials. principals lists each gateway client ID (`atc-gateway clients list`) with
  # the targets it may reach; a client not listed here is refused every request.
  services.atc-daemon = {
    enable = true;
    package = atc;
    listen = "${atcDaemonAddress}:${toString atcDaemonPort}";
    tokenFile = "/var/lib/atc-daemon-secrets/gateway-token";
    impTokenFile = "/var/lib/atc-daemon-secrets/imp-token";
    targets.geoffcloud = {
      provider = "imp";
      url = impdLoopbackURL;
      tokenFile = "/run/credentials/atc-daemon.service/imp-token";
      impPrefix = "harness-";
    };
    defaultTarget = "geoffcloud";
    principals = {
      # ChatGPT's connector, added 2026-10-04
      "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY".targets = [ "geoffcloud" ];
    };
  };

  # The preview service (docs/architecture/workloads/preview.md, docs/runbooks/preview.md). Its
  # secrets sit on host-secrets, staged by the runbook; until they exist, the unit is skipped.
  # A repository opts in with preview/compose.yaml and a webhook to the public route.
  services.preview = {
    enable = true;
    linkListen = "${topology.tailnet.nodes.geoffcloud.address}:${toString previewLinkExposure.port}";
    webhookListen = "${topology.tailnet.nodes.geoffcloud.address}:${toString previewWebhookExposure.port}";
    baseURL = "http://geoffcloud:${toString previewLinkExposure.port}";
    repos = [ "zgeoff/nixie" ];
    impdURL = impdLoopbackURL;
    impDomain = topology.imp.domain;
    impGitHubSecret = "gh";
    webhookSecretFile = "/var/lib/tank-cloud/host-secrets/preview/webhook-secret";
    githubTokenFile = "/var/lib/tank-cloud/host-secrets/preview/github-token";
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
