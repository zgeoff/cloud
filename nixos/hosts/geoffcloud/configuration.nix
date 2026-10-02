# geoffcloud: Onidel VM, Melbourne. 8 vCPU (EPYC 7513, nested KVM), 31 GiB RAM.
# vda: root (disko.nix). vdb: imp's ZFS pool, imported, never formatted here.
{ modulesPath, pkgs, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = "26.05";
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
    # imp's pool on vdb, created by imp's bootstrap (impd's root is tank/imp)
    zfs.extraPools = [ "tank" ];
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
  # imp owns inet imp_host and inet imp_egress, and k3s and Docker add their own.
  networking.nftables = {
    enable = true;
    flushRuleset = false;
  };
  networking.firewall = {
    enable = true;
    # public: nothing but Tailscale. Everything else is reached over the tailnet.
    allowedUDPPorts = [ 41641 ];
    # trusted as a source, in input and forward: the tailnet, k3s pods, and Docker's
    # bridge, which carries the imp-host container and its microVMs' egress
    trustedInterfaces = [
      "tailscale0"
      "cni0"
      "flannel.1"
      "docker0"
    ];
    # filter forwarded traffic too, so nothing public reaches a pod or a NodePort
    # unless a rule allows it
    filterForward = true;
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

  # imp-host runs on Docker, outside k3s
  virtualisation.docker.enable = true;

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
    ];
  };

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
