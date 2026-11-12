# The egress NetworkPolicies that infra creates, applied to k3s in a NixOS VM with geoffcloud's own
# k3s package, flags and firewall, as one journey whose subtests run in order. The policies come
# from network-policies.json, which infra's builders write (bun run write:network-policies) and a
# test in infra/shared compares with them. Stand-ins answer on every path a pod could take to
# geoffcloud's grants: the atc daemon, the preview links and the preview webhook on the host's
# tailnet address, local delivery as on the host; home-pc's daemon and impd on tailnet peers in a
# network namespace behind tailscale0; and impd's plain API on Podman's subnet in another, both
# forwarded as on the host. A public address on a dummy link stands in for the internet, which of
# pepys's pods only ingest and the backup reach, on 443 only; a private and a link-local address on
# the same link show that the 443 rule excludes them. The VM leaves out inet cloud_host, so
# kube-router alone refuses a path. Each test pod runs the same image and differs only by its
# labels, and pepys's Garage pod by its port. It needs KVM: run `bun run test:nixos network-policy`.
{ nixpkgs, geoffcloud }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  topology = import ../topology.nix;
  hostK3s = geoffcloud.config.services.k3s;
  hostFirewall = geoffcloud.config.networking.firewall;
  nodes = topology.tailnet.nodes;
  getHostPort =
    name: (lib.findFirst (entry: entry.name == name) null (import ../exposure.nix).entries).port;

  policies = builtins.fromJSON (builtins.readFile ./network-policies.json);

  # every test pod serves "pod" on 8080, for the pod-to-pod case, and curls the stand-ins
  podImage = pkgs.dockerTools.buildLayeredImage {
    name = "test.local/network-policy";
    tag = "local";
    contents = [
      pkgs.busybox
      pkgs.curl
    ];
    extraCommands = ''
      mkdir -p www
      echo pod > www/index.html
    '';
    config.Entrypoint = [
      "/bin/httpd"
      "-f"
      "-p"
      "8080"
      "-h"
      "/www"
    ];
  };

  # a documentation address, so no real host answers it
  internetAddress = "203.0.113.10";
  # a private address and a link-local one, which pepys's 443 rule excludes
  privateAddress = "172.16.0.10";
  linkLocalAddress = "169.254.169.254";

  # each stand-in answers its own name, so a reply shows which listener the pod reached
  standIns = [
    {
      name = "host-daemon";
      netns = null;
      address = nodes.geoffcloud.address;
      port = topology.atc.daemonPort;
    }
    {
      name = "preview-link";
      netns = null;
      address = nodes.geoffcloud.address;
      port = getHostPort "preview-link";
    }
    {
      name = "preview-webhook";
      netns = null;
      address = nodes.geoffcloud.address;
      port = getHostPort "preview-webhook";
    }
    {
      name = "home-pc-daemon";
      netns = "tailnet";
      address = nodes.homePC.address;
      port = topology.atc.daemonPort;
    }
    {
      name = "impd";
      netns = "tailnet";
      address = nodes.imp.address;
      port = 443;
    }
    {
      name = "impd-podman-api";
      netns = "podman";
      address = "10.88.0.2";
      port = topology.imp.apiPort;
    }
    {
      name = "internet-https";
      netns = null;
      address = internetAddress;
      port = 443;
    }
    {
      name = "internet-http";
      netns = null;
      address = internetAddress;
      port = 80;
    }
    {
      name = "private-https";
      netns = null;
      address = privateAddress;
      port = 443;
    }
    {
      name = "link-local-https";
      netns = null;
      address = linkLocalAddress;
      port = 443;
    }
  ];

  buildStandInRoot =
    name:
    pkgs.writeTextDir "index.html" ''
      ${name}
    '';

  pods = [
    {
      namespace = "atc";
      name = "gateway";
      labels.app = "atc-gateway";
    }
    {
      namespace = "atc";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "observability";
      name = "daemon-probe";
      labels.app = "atc-daemon-probe";
    }
    {
      namespace = "observability";
      name = "imp-probe";
      labels.app = "imp-health-probe";
    }
    {
      namespace = "observability";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "ingress";
      name = "cloudflared";
      labels.app = "cloudflared";
    }
    {
      namespace = "ingress";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "kube-system";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "default";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "nixie";
      name = "nixie";
      labels.app = "nixie";
    }
    {
      namespace = "nixie";
      name = "web";
      labels.app = "nixie-web";
    }
    {
      namespace = "nixie";
      name = "sandbox-images";
      labels.app = "nixie-sandbox-images";
    }
    # the backup and restore jobs carry no label that an allow selects
    {
      namespace = "nixie";
      name = "stranger";
      labels = { };
    }
    {
      namespace = "nixie-ingress";
      name = "traefik";
      labels."app.kubernetes.io/name" = "traefik";
    }
    # pepys's pods, each on the port of its Service
    {
      namespace = "pepys";
      name = "garage";
      labels.app = "pepys-garage";
      port = 3900;
    }
    {
      namespace = "pepys";
      name = "s2";
      labels.app = "pepys-s2";
    }
    {
      namespace = "pepys";
      name = "ingest";
      labels.app = "pepys-ingest";
    }
    {
      namespace = "pepys";
      name = "host";
      labels.app = "pepys-host";
    }
    {
      namespace = "pepys";
      name = "backup";
      labels.app = "pepys-backup";
    }
    {
      namespace = "pepys";
      name = "stranger";
      labels = { };
    }
  ];

  createdNamespaces = [
    "atc"
    "files"
    "ingress"
    "nixie"
    "nixie-ingress"
    "observability"
    "onepassword"
    "pepys"
  ];

  pepysServices = [
    {
      name = "pepys-garage";
      port = 3900;
    }
    {
      name = "pepys-s2";
      port = 8080;
    }
  ];

  toList = items: {
    apiVersion = "v1";
    kind = "List";
    inherit items;
  };

  workloads = pkgs.writeText "workloads.json" (
    builtins.toJSON (
      toList (
        map (name: {
          apiVersion = "v1";
          kind = "Namespace";
          metadata.name = name;
        }) createdNamespaces
        ++ map (pod: {
          apiVersion = "v1";
          kind = "Pod";
          metadata = { inherit (pod) name namespace labels; };
          spec.containers = [
            (
              {
                name = "test";
                image = "test.local/network-policy:local";
                imagePullPolicy = "Never";
              }
              // lib.optionalAttrs (pod ? port) {
                args = [
                  "-f"
                  "-p"
                  (toString pod.port)
                  "-h"
                  "/www"
                ];
              }
            )
          ];
        }) pods
        ++ [
          {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "web";
              namespace = "nixie";
            };
            spec = {
              selector.app = "nixie-web";
              ports = [ { port = 8080; } ];
            };
          }
        ]
        ++ map (service: {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            inherit (service) name;
            namespace = "pepys";
          };
          spec = {
            selector.app = service.name;
            ports = [ { inherit (service) port; } ];
          };
        }) pepysServices
      )
    )
  );

  policyList = pkgs.writeText "network-policies.json" (builtins.toJSON (toList policies));
in
pkgs.testers.runNixOSTest {
  name = "network-policy";
  nodes.machine =
    { config, ... }:
    {
      networking.useDHCP = false;
      # k3s refuses to start without a default route; nothing answers at the gateway
      networking.defaultGateway = {
        address = "192.168.1.254";
        interface = "eth1";
      };
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.diskSize = 8192;

      networking.nftables = {
        enable = true;
        flushRuleset = false;
      };
      networking.firewall = {
        enable = true;
        inherit (hostFirewall)
          trustedInterfaces
          filterForward
          extraForwardRules
          ;
      };

      services.k3s = {
        enable = true;
        inherit (hostK3s) package role;
        # geoffcloud's flags, without the components the check does not need
        extraFlags = hostK3s.extraFlags ++ [
          "--disable=local-storage"
          "--disable=metrics-server"
        ];
        images = [
          config.services.k3s.package.airgap-images
          podImage
        ];
      };
      environment.etc."k3s-resolv.conf".text = geoffcloud.config.environment.etc."k3s-resolv.conf".text;
      environment.systemPackages = [ pkgs.kubectl ];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

      # the host's tailnet address on tailscale0, with the tailnet's peers behind it, and Podman's
      # bridge address on podman0, with imp-host's container behind it
      systemd.services = {
        stand-in-network = {
          wantedBy = [ "multi-user.target" ];
          before = [ "k3s.service" ];
          path = [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ip netns add tailnet
            ip link add tailscale0 type veth peer name eth0 netns tailnet
            ip addr add ${nodes.geoffcloud.address}/32 dev tailscale0
            ip link set tailscale0 up
            ip route add ${topology.tailnet.cidr} dev tailscale0
            ip -n tailnet link set lo up
            ip -n tailnet addr add ${nodes.homePC.address}/32 dev eth0
            ip -n tailnet addr add ${nodes.imp.address}/32 dev eth0
            ip -n tailnet link set eth0 up
            ip -n tailnet route add ${nodes.geoffcloud.address}/32 dev eth0
            ip -n tailnet route add default via ${nodes.geoffcloud.address} dev eth0 onlink

            ip link add internet0 type dummy
            ip addr add ${internetAddress}/32 dev internet0
            ip addr add ${privateAddress}/32 dev internet0
            ip addr add ${linkLocalAddress}/32 dev internet0
            ip link set internet0 up

            ip netns add podman
            ip link add ${topology.podman.bridge} type veth peer name eth0 netns podman
            ip addr add ${topology.podman.bridgeAddress}/16 dev ${topology.podman.bridge}
            ip link set ${topology.podman.bridge} up
            ip -n podman link set lo up
            ip -n podman addr add 10.88.0.2/16 dev eth0
            ip -n podman link set eth0 up
            ip -n podman route add default via ${topology.podman.bridgeAddress}
          '';
        };
      }
      // lib.listToAttrs (
        map (standIn: {
          name = "stand-in-${standIn.name}";
          value = {
            wantedBy = [ "multi-user.target" ];
            requires = [ "stand-in-network.service" ];
            after = [ "stand-in-network.service" ];
            path = [
              pkgs.iproute2
              pkgs.busybox
            ];
            script =
              let
                serve = "busybox httpd -f -p ${standIn.address}:${toString standIn.port} -h ${buildStandInRoot standIn.name}";
              in
              if standIn.netns == null then "exec ${serve}" else "exec ip netns exec ${standIn.netns} ${serve}";
          };
        }) standIns
      );
    };

  testScript = ''
    import json

    stand_ins = json.loads('${builtins.toJSON standIns}')
    pods = ["atc/gateway", "atc/stranger", "observability/daemon-probe", "observability/imp-probe",
            "observability/stranger", "ingress/cloudflared", "ingress/stranger", "kube-system/stranger",
            "default/stranger", "nixie/nixie", "nixie/web", "nixie/sandbox-images", "nixie/stranger",
            "nixie-ingress/traefik", "pepys/garage", "pepys/s2", "pepys/ingest", "pepys/host",
            "pepys/backup", "pepys/stranger"]


    def dial(pod, url):
        """curl's exit status and body, run in the pod; 7 is curl's 'Failed to connect'"""
        namespace, name = pod.split("/")
        status, body = machine.execute(f"kubectl exec -n {namespace} {name} -- curl -s --max-time 5 {url}")
        return status, body.strip()


    def reach_all():
        return {
            f"{pod} -> {stand_in['name']}": dial(pod, f"http://{stand_in['address']}:{stand_in['port']}/")
            for pod in pods
            for stand_in in stand_ins
        }


    def expect_reach(reached_by):
        return {
            f"{pod} -> {stand_in['name']}": (0, stand_in["name"]) if pod in reached_by.get(stand_in["name"], set()) else (7, "")
            for pod in pods
            for stand_in in stand_ins
        }


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it starts every test pod and CoreDNS"):
        machine.wait_for_unit("k3s.service")
        # a namespace's default service account comes a moment after the namespace, and a pod waits for it
        machine.wait_until_succeeds("kubectl apply -f ${workloads}", timeout=300)
        for pod in pods:
            namespace, name = pod.split("/")
            machine.wait_until_succeeds(f"kubectl wait --for=condition=Ready -n {namespace} pod/{name} --timeout=10s", timeout=600)
        machine.wait_until_succeeds("kubectl wait --for=condition=Ready -n kube-system pod -l k8s-app=kube-dns --timeout=10s", timeout=600)


    with subtest("it reaches every stand-in from every test pod before the policies apply"):
        reached = reach_all()
        everyone = set(pods)

        assert reached == expect_reach({stand_in["name"]: everyone for stand_in in stand_ins}), json.dumps(reached, indent=2)


    with subtest("it lets each allowed pod reach only its own addresses and ports, and refuses every other pod in a namespace with the deny"):
        machine.succeed("kubectl apply -f ${policyList}")
        # the deny leaves the internet open; pepys's deny of all egress leaves its pods only 443
        outside_pepys = {pod for pod in pods if not pod.startswith("pepys/")}
        expected = expect_reach({
            "host-daemon": {"atc/gateway", "observability/daemon-probe"},
            "home-pc-daemon": {"atc/gateway", "observability/daemon-probe"},
            "impd": {"observability/imp-probe", "nixie/nixie", "nixie/sandbox-images"},
            "preview-webhook": {"ingress/cloudflared"},
            "internet-https": outside_pepys | {"pepys/ingest", "pepys/backup"},
            "internet-http": outside_pepys,
            "private-https": outside_pepys,
            "link-local-https": outside_pepys,
        })
        observed = {}

        # kube-router programs a policy's rules a moment after the apply; the last try ends the
        # wait, so the assertion below shows what differs
        def is_enforced(last_try):
            observed["reached"] = reach_all()
            return observed["reached"] == expected or last_try

        retry(is_enforced, timeout_seconds=180)

        assert observed["reached"] == expected, json.dumps(observed["reached"], indent=2)


    with subtest("it keeps pod-to-pod traffic, DNS through CoreDNS and the Kubernetes API for a pod under the deny"):
        web_ip = machine.succeed("kubectl get pod -n nixie web -o jsonpath='{.status.podIP}'").strip()
        by_address = dial("atc/stranger", f"http://{web_ip}:8080/")
        by_name = dial("atc/stranger", "http://web.nixie.svc.cluster.local:8080/")
        token = "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
        ca = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        api_status, api_body = machine.execute(
            f"kubectl exec -n atc stranger -- sh -c 'curl -s --max-time 5 --cacert {ca} -H \"Authorization: Bearer {token}\" https://kubernetes.default.svc/version'"
        )

        assert by_address == (0, "pod"), by_address
        assert by_name == (0, "pod"), by_name
        assert api_status == 0, api_body
        assert json.loads(api_body)["gitVersion"] == "v${hostK3s.package.version}", api_body


    with subtest("it lets each pepys pod reach DNS and only the pepys peers it calls"):
        garage = "http://pepys-garage.pepys.svc.cluster.local:3900/"
        s2 = "http://pepys-s2.pepys.svc.cluster.local:8080/"
        s2_ip = machine.succeed("kubectl get pod -n pepys s2 -o jsonpath='{.status.podIP}'").strip()
        reached = {
            "s2 -> garage": dial("pepys/s2", garage),
            "backup -> garage": dial("pepys/backup", garage),
            "ingest -> s2": dial("pepys/ingest", s2),
            "host -> s2": dial("pepys/host", s2),
            "ingest -> garage": dial("pepys/ingest", garage)[0] == 0,
            "host -> garage": dial("pepys/host", garage)[0] == 0,
            "garage -> s2": dial("pepys/garage", f"http://{s2_ip}:8080/")[0] == 0,
            "stranger -> s2": dial("pepys/stranger", f"http://{s2_ip}:8080/")[0] == 0,
            "stranger -> nixie web": dial("pepys/stranger", "http://web.nixie.svc.cluster.local:8080/")[0] == 0,
            "ingest -> nixie web": dial("pepys/ingest", "http://web.nixie.svc.cluster.local:8080/")[0] == 0,
        }
        api_status, _ = machine.execute(
            "kubectl exec -n pepys stranger -- curl -sk --max-time 5 https://kubernetes.default.svc/version"
        )
        reached["stranger -> kubernetes api"] = api_status == 0

        assert reached == {
            "s2 -> garage": (0, "pod"),
            "backup -> garage": (0, "pod"),
            "ingest -> s2": (0, "pod"),
            "host -> s2": (0, "pod"),
            "ingest -> garage": False,
            "host -> garage": False,
            "garage -> s2": False,
            "stranger -> s2": False,
            "stranger -> nixie web": False,
            "ingest -> nixie web": False,
            "stranger -> kubernetes api": False,
        }, json.dumps(reached, indent=2)
  '';
}
