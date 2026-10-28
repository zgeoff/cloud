# services.host-cgroup-cpu on a booted VM, beside node-exporter with its textfile collector on the
# directory the service writes, as the cluster's node-exporter reads it on the host: the series
# come from the kernel's own cgroup v2 tree, which checks/host-cgroup-cpu.nix only writes by hand.
# It prints the service's memory peak, the reading the module's MemoryMax bounds.
# It needs KVM: run `bun run test:nixos host-cgroup-cpu-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  textfileDir = "/var/lib/node-exporter/textfile";
in
pkgs.testers.runNixOSTest {
  name = "host-cgroup-cpu-vm";
  nodes.machine = {
    imports = [ ../modules/host-cgroup-cpu.nix ];
    services.host-cgroup-cpu.enable = true;
    # on the host, services.impd-local-health makes the directory
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it serves the root, system.slice and a unit in it through node-exporter"):
        machine.wait_for_unit("host-cgroup-cpu.service")
        machine.wait_for_open_port(9100)
        query = "curl -sf http://127.0.0.1:9100/metrics | grep '^host_cgroup_cpu_seconds_total{cgroup=\"%s\",mode=\"%s\"} '"

        for cgroup in ["/", "/system.slice", "/system.slice/host-cgroup-cpu.service"]:
            for mode in ["user", "system"]:
                machine.wait_until_succeeds(query % (cgroup, mode), timeout=60)
        scrape_error = machine.succeed("curl -sf http://127.0.0.1:9100/metrics | sed -n 's/^node_textfile_scrape_error //p'").strip()
        assert scrape_error == "0", f"the textfile collector's scrape error is {scrape_error!r}"


    with subtest("it advances system.slice's time between two writes"):
        read = "sed -n 's/^host_cgroup_cpu_seconds_total{cgroup=\"\\/system.slice\",mode=\"user\"} //p' ${textfileDir}/host_cgroup_cpu.prom"
        first = float(machine.succeed(read))

        machine.wait_until_succeeds(f"[ \"$({read})\" != '{first:.6f}' ]", timeout=60)
        second = float(machine.succeed(read))
        assert second > first, f"system.slice's user time went from {first} to {second}"


    with subtest("it stays active, within its memory bound"):
        state = machine.succeed("systemctl show -p ActiveState --value host-cgroup-cpu.service").strip()
        peak = int(machine.succeed("systemctl show -p MemoryPeak --value host-cgroup-cpu.service"))
        print(f"host-cgroup-cpu.service MemoryPeak: {peak} bytes")

        assert state == "active", f"the service is {state!r}"
        assert peak < 64 * 1024 * 1024, f"the service's memory peak is {peak} bytes"
  '';
}
