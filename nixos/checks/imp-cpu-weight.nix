# geoffcloud's CPU weights in a NixOS VM with geoffcloud's own k3s package and flags and Docker
# settings: a container on Docker, as imp-host runs with its imps' Firecrackers, against a pod, a
# k3s system pod (CoreDNS) and k3s's server, which runs the kubelet. For each pair, the two cgroups
# where their paths part are siblings, and the container's must weigh less, so the kernel gives the
# container the smaller share whenever both want CPU. It needs KVM: run
# `bun run test:nixos imp-cpu-weight`.
{ nixpkgs, geoffcloud }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  hostK3s = geoffcloud.config.services.k3s;
  hostDocker = geoffcloud.config.virtualisation.docker;

  # the pod and the container run the same image, which only sleeps
  sleepImage = pkgs.dockerTools.buildLayeredImage {
    name = "test.local/imp-cpu-weight";
    tag = "local";
    contents = [ pkgs.busybox ];
    config.Cmd = [
      "sleep"
      "infinity"
    ];
  };

  pod = pkgs.writeText "pod.json" (
    builtins.toJSON {
      apiVersion = "v1";
      kind = "Pod";
      metadata = {
        name = "sleeper";
        namespace = "default";
      };
      spec.containers = [
        {
          name = "sleeper";
          image = "test.local/imp-cpu-weight:local";
          imagePullPolicy = "Never";
        }
      ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "imp-cpu-weight";
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
          sleepImage
        ];
      };
      environment.etc."k3s-resolv.conf".text = geoffcloud.config.environment.etc."k3s-resolv.conf".text;
      environment.systemPackages = [ pkgs.kubectl ];
      environment.sessionVariables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

      virtualisation.docker = {
        enable = true;
        inherit (hostDocker) package;
        daemon.settings = hostDocker.daemon.settings;
      };
      systemd.slices = lib.mapAttrs (_: slice: {
        inherit (slice) sliceConfig;
      }) geoffcloud.config.systemd.slices;
    };

  testScript = ''
    import json


    def read_cgroup(pid):
        """the cgroup v2 path of a process, from the host's root"""
        return machine.succeed(f"sed -n 's/^0:://p' /proc/{pid}/cgroup").strip()


    def read_parting_weights(path, other):
        """the cpu.weight of the two sibling cgroups where the two paths part"""
        parts, other_parts = path.strip("/").split("/"), other.strip("/").split("/")
        depth = 0
        while parts[depth] == other_parts[depth]:
            depth += 1
        parent = "/".join(["/sys/fs/cgroup"] + parts[:depth])
        own = f"{parent}/{parts[depth]}"
        sibling = f"{parent}/{other_parts[depth]}"
        return (
            {own: int(machine.succeed(f"cat {own}/cpu.weight")),
             sibling: int(machine.succeed(f"cat {sibling}/cpu.weight"))},
            own,
            sibling,
        )


    def read_pod_pid(name):
        container = machine.succeed(f"k3s crictl ps -q --name {name}").split()[0]
        return json.loads(machine.succeed(f"k3s crictl inspect {container}"))["info"]["pid"]


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it starts the container, the pod and CoreDNS"):
        machine.wait_for_unit("docker.service")
        machine.succeed("docker load -i ${sleepImage}")
        machine.succeed("docker run -d --name imp-host --cgroupns=private test.local/imp-cpu-weight:local")
        machine.wait_for_unit("k3s.service")
        # the default service account comes a moment after the namespace, and a pod waits for it
        machine.wait_until_succeeds("kubectl apply -f ${pod}", timeout=300)
        machine.wait_until_succeeds("kubectl wait --for=condition=Ready pod/sleeper --timeout=10s", timeout=600)
        machine.wait_until_succeeds("kubectl wait --for=condition=Ready -n kube-system pod -l k8s-app=kube-dns --timeout=10s", timeout=600)


    imp_host = read_cgroup(machine.succeed("docker inspect -f '{{.State.Pid}}' imp-host").strip())
    others = {
        "the pod": read_cgroup(read_pod_pid("sleeper")),
        "CoreDNS": read_cgroup(read_pod_pid("coredns")),
        "k3s's server": read_cgroup(machine.succeed("systemctl show -p MainPID --value k3s.service").strip()),
    }
    print(f"imp-host: {imp_host}")
    print(json.dumps(others, indent=2))

    for name, other in others.items():
        with subtest(f"it weighs the container's cgroup below {name}'s where the two part"):
            weights, own, sibling = read_parting_weights(imp_host, other)
            print(json.dumps(weights, indent=2))

            assert weights[own] < weights[sibling], f"imp-host's {own} weighs {weights[own]}, and {name}'s {sibling} {weights[sibling]}"
  '';
}
