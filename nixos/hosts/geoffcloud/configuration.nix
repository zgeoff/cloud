# geoffcloud: Onidel VM, Melbourne. 8 vCPU (EPYC 7513, nested KVM), 31 GiB RAM.
# vda: root (disko.nix). vdb: imp's ZFS pool, imported, never formatted here.
{ modulesPath, pkgs, ... }:
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
    image = "ghcr.io/zgeoff/imp-host:0.27.0@sha256:81b04266510bcb68ec14573cf8eaad08268f741b7591d3e808819d32711f2d43";
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
