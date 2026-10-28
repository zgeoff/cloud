# The egress NetworkPolicies that infra creates, applied to k3s in a NixOS VM with geoffcloud's own
# k3s package, flags and firewall, as one journey whose subtests run in order. The policies come
# from network-policies.json, which infra's builders write (bun run write:network-policies) and a
# test in infra/shared compares with them. Stand-ins answer on every path a pod could take to
# geoffcloud's grants: the atc daemon, the preview links and the preview webhook on the host's
# tailnet address, local delivery as on the host; home-pc's daemon and impd on tailnet peers in a
# network namespace behind tailscale0; and impd's plain API on Docker's subnet in another, both
# forwarded as on the host. The VM leaves out inet cloud_host, so kube-router alone refuses a
# path. Each test pod runs the same image and differs only by its labels. It needs KVM: run
# `bun run test:nixos network-policy`.
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
      name = "impd-docker-api";
      netns = "docker";
      address = "172.17.0.2";
      port = topology.imp.apiPort;
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
  ];

  createdNamespaces = [
    "atc"
    "files"
    "ingress"
    "nixie"
    "nixie-ingress"
    "observability"
    "onepassword"
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
            {
              name = "test";
              image = "test.local/network-policy:local";
              imagePullPolicy = "Never";
            }
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

      # the host's tailnet address on tailscale0, with the tailnet's peers behind it, and Docker's
      # bridge address on docker0, with imp-host's container behind it
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

            ip netns add docker
            ip link add docker0 type veth peer name eth0 netns docker
            ip addr add ${topology.docker.bridgeAddress}/16 dev docker0
            ip link set docker0 up
            ip -n docker link set lo up
            ip -n docker addr add 172.17.0.2/16 dev eth0
            ip -n docker link set eth0 up
            ip -n docker route add default via ${topology.docker.bridgeAddress}
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
            "nixie-ingress/traefik"]


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
        expected = expect_reach({
            "host-daemon": {"atc/gateway", "observability/daemon-probe"},
            "home-pc-daemon": {"atc/gateway", "observability/daemon-probe"},
            "impd": {"observability/imp-probe", "nixie/nixie", "nixie/sandbox-images"},
            "preview-webhook": {"ingress/cloudflared"},
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
  '';
}
