# geoffcloud: Onidel VM, Melbourne. 8 vCPU (EPYC 7513, nested KVM), 31 GiB RAM.
# vda: root (disko.nix). vdb: imp's ZFS pool, imported, never formatted here.
{ config, modulesPath, pkgs, ... }:
let
  # atc's daemon listens on the host's tailnet address; the gateway pod dials it there
  atcDaemonAddress = "100.69.47.33";
  atcDaemonPort = 8415;
  # k3s's default cluster CIDR (no --cluster-cidr override below); services.imp.forwardDeny
  # names the same range
  k3sPodCIDR = "10.42.0.0/16";
  # 1Password Connect for imps (GEO-120). The imp broker in imp-host forwards granted requests
  # for op-connect.imp.internal to the relay below, on docker0's host address. imp-forward
  # drops imp-host's traffic to the k3s ranges, so the container cannot reach the Service
  # itself: the host dials its ClusterIP instead. The Service pins that ClusterIP
  # (infra/onepassword-connect.ts).
  connectRelayAddress = "172.17.0.1";
  connectRelayPort = 18081;
  connectServiceAddress = "10.43.82.198:8000";
  # docker0's subnet. imp's module does not fix imp-host's address on it, so the rule below
  # admits the whole subnet: every container on docker0, imp's docker proxy and image builds
  # included, can reach the relay. Connect's read-only token still gates every request.
  dockerSubnet = "172.17.0.0/16";
  atc = pkgs.callPackage ../../packages/atc.nix { };
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = "26.05";

  # impd local health as a node-exporter textfile metric (#29): loopback only, not HTTPS
  services.impd-local-health.enable = true;
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
          address = "104.250.100.18";
          prefixLength = 24;
        }
      ];
      ipv6.addresses = [
        {
          address = "2401:a4a0:4:17f::1";
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
    # public: nothing but Tailscale. Everything else is reached over the tailnet.
    allowedUDPPorts = [ 41641 ];
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

  # atc's daemon port, k3s pods only. tailscale0 is trusted above, so nixos-fw alone would
  # accept 8415 from every tailnet device the policy lets reach geoffcloud (today every
  # member, through autogroup:member -> *). This table narrows it to the gateway's path: the
  # pod dials the host's tailnet address, so the packet enters on cni0 from a pod address,
  # and local delivery skips flannel's masquerade in postrouting. Every other source, the
  # tailnet and the host's own loopback included, is dropped. A drop in any input chain is
  # final, and the accept here only passes the packet on to nixos-fw, which trusts cni0.
  # Any pod on the host can still reach 8415; the daemon's bearer token gates the rest.
  networking.nftables.tables.cloud_host = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority filter - 10; policy accept;
        tcp dport ${toString atcDaemonPort} iifname "cni0" ip saddr ${k3sPodCIDR} ip daddr ${atcDaemonAddress} accept
        tcp dport ${toString atcDaemonPort} drop
        tcp dport ${toString connectRelayPort} iifname "docker0" ip saddr ${dockerSubnet} ip daddr ${connectRelayAddress} accept
        tcp dport ${toString connectRelayPort} drop
      }
    '';
  };

  # The Connect relay's port, from docker0 only: nixos-fw does not trust docker0, and imp-host
  # reaches the host there. The cloud_host rules above admit only docker0's subnet to it and
  # drop the rest; as with 8415, a drop in any input chain is final and the accept only passes
  # the packet on to nixos-fw, which opens the port on docker0 alone.
  networking.firewall.interfaces.docker0.allowedTCPPorts = [ connectRelayPort ];

  # The relay: systemd holds the socket and starts the proxy on the first connection, so the
  # socket can wait for docker0 (FreeBind) and the proxy dials the ClusterIP from the host.
  # imp-host reaches the relay on docker0 only while imp's IPv6 mode is off: that mode moves
  # imp-host to its own bridge, which neither nixos-fw nor cloud_host opens for the relay
  assertions = [
    {
      assertion = !(config.services.imp.ipv6.enable or false);
      message = "the Connect relay assumes imp-host on docker0; services.imp.ipv6.enable moves it to br-imphost";
    }
  ];
  systemd.sockets.onepassword-connect-relay = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${connectRelayAddress}:${toString connectRelayPort}" ];
    socketConfig.FreeBind = true;
  };
  systemd.services.onepassword-connect-relay = {
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${connectServiceAddress}";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      CapabilityBoundingSet = "";
    };
  };

  services.openssh = {
    enable = true;
    # reachable on the tailnet only once Onidel's cloud firewall closes 22 (#4)
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ ../../keys/geoff.pub ];

  # Host's own tailnet node: tag:cloud. The auth key is placed at install time
  # by nixos-anywhere --extra-files, minted by Pulumi as a TailnetKey (#5).
  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
    extraUpFlags = [
      "--advertise-tags=tag:cloud"
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
    # pinned: the module's default is imp-host:latest, which moves on every imp release
    # and is not tied to the flake's pin of the module
    image = "ghcr.io/zgeoff/imp-host:0.40.0@sha256:7add8234e6acd9fcc9db402a486ae7671606a0c55b46987b17eb097fa01178b7";
    # the module's default ("imp") is taken in the tailnet
    settings.IMP_TAILSCALE_HOSTNAME = "imp-geoffcloud";
    # HTTPS on the tailnet only (imp#16): imps at <name>.imps.geoff.cloud, impd's API at
    # imps.geoff.cloud, a wildcard certificate by DNS-01. impd writes DNS-only A records
    # for both names at the host's tailnet IP. imp.geoff.cloud stays free for imp's
    # public MCP route. The token lives in dnsApiTokenFile (root-only, re-read on change, so
    # a rotation needs no restart) and the ACME email in environmentFile, both installed by
    # scripts/install-imp-dns-token.sh. environmentFile must not also set IMP_DNS_API_TOKEN.
    settings.IMP_DOMAIN = "imps.geoff.cloud";
    dnsApiTokenFile = "/var/lib/imp-host/secrets/dns-api-token";
    settings.IMP_DNS_PROVIDER = "cloudflare";
    # imps are agent sandboxes: they must not reach the k3s pod and service ranges
    forwardDeny = [
      "10.42.0.0/16"
      "10.43.0.0/16"
    ];
  };

  # atc's daemon for the atc gateway (docs/plans/atc-gateway.md section 7). The token files
  # are root-only and staged by hand (operator checklist C1); systemd passes them in as
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
      # impd on the host's loopback
      url = "http://127.0.0.1:7070";
      tokenFile = "/run/credentials/atc-daemon.service/imp-token";
      impPrefix = "harness-";
    };
    defaultTarget = "geoffcloud";
    principals = {
      # ChatGPT's connector, added 2026-10-04
      "0hpE6styFKfCcbWrvigzCp9HbZU5nVgY".targets = [ "geoffcloud" ];
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
      # NodePorts (Grafana on 30300) bind to the tailnet address only. kube-proxy
      # DNATs them through FORWARD, which the input firewall does not cover.
      "--kube-proxy-arg=nodeport-addresses=100.64.0.0/10"
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
