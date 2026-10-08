# The restore rehearsal's VM, for the checks of scripts/restore-impd-db.sh, so each runs its
# subtests on the identical machine and reset: imp's own NixOS module (the flake's pinned imp
# input) runs imp-host and imp-docker-proxy, on a real ZFS pool with the module's legacy dataset
# tank/imp, real generations in the system profile and a real switch-to-configuration. The images
# are pinned by tag and digest, as geoffcloud pins them, and pulled from a registry inside the VM
# that answers for ghcr.io: an imp-host image of busybox that only sleeps, with a proxy that only
# opens its socket (build-stub-imp-host-image.nix). Beside them, generations that are this VM's
# own specialisations.
#
# Given a name and a function from the two images ({ image28, image29 }, each { layout, ref }) to
# the subtests' script, it returns the NixOS test. One VM boots once. Its script runs the two
# boot subtests first, then defines setup_test(), which returns the VM to the same boot state
# before each subtest: the 0.29.0 system running, its image pulled fresh, an empty tank/imp
# mounted nowhere, generations 1 to 3, and nothing an earlier subtest left. The given subtests
# follow, each calling setup_test() first. It needs KVM, and the checks it builds read scripts/
# beside nixos/, so they build only from the repo root. The test utilities pass their own check
# (test-utils-check.nix) before the VM runs, and every check that uses this runs it on every
# build: its boot subtests are its tests, and impd-restore-reset.nix checks its reset.
{ nixpkgs, imp }:
{ name, subtests }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # the two releases a restore moves between; each carries a digest read at build time, so the
  # subtests share them instead of writing the reference out
  image28 = import ./build-stub-imp-host-image.nix { inherit pkgs; } "0.28.0";
  image29 = import ./build-stub-imp-host-image.nix { inherit pkgs; } "0.29.0";
  testUtilsCheck = import ../test-utils-check.nix { inherit pkgs imp; };
in
pkgs.testers.runNixOSTest {
  inherit name;
  nodes.machine =
    { config, ... }:
    {
      imports = [ imp.nixosModules.imp ];
      networking.hostId = "5ca71846";
      # the rehearsal reaches only loopback, and dhcpcd crashing at times would start
      # systemd-coredump's slice in the middle of a switch
      networking.useDHCP = false;
      # imp-host's docker run passes --device /dev/kvm
      boot.kernelModules = [
        "kvm-amd"
        "kvm-intel"
      ];
      boot.zfs.forceImportRoot = false;
      virtualisation.emptyDiskImages = [ 1024 ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.sqlite ];

      # the registry that answers for ghcr.io: plain HTTP on port 80, which Docker falls back to
      # for a registry it lists as insecure
      networking.hosts."127.0.0.1" = [ "ghcr.io" ];
      virtualisation.docker.daemon.settings."insecure-registries" = [ "ghcr.io" ];
      services.dockerRegistry = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 80;
      };
      systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      # both images in it before the module first pulls one
      systemd.services.rehearsal-registry-images = {
        requiredBy = [ "imp-host-image.service" ];
        before = [ "imp-host-image.service" ];
        requires = [ "docker-registry.service" ];
        after = [ "docker-registry.service" ];
        path = [
          pkgs.curl
          pkgs.skopeo
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # docker-registry is Type=simple, so "after" orders on its start, not on its port: wait
        # until it answers before the first copy
        script = ''
          source ${../../../scripts/test-lib/wait-for.sh}
          wait_for 30 "the registry" curl -sf -o /dev/null http://ghcr.io/v2/
          skopeo --insecure-policy copy --preserve-digests --dest-tls-verify=false \
            oci:${image28.layout}:0.28.0 docker://ghcr.io/zgeoff/imp-host:0.28.0
          skopeo --insecure-policy copy --preserve-digests --dest-tls-verify=false \
            oci:${image29.layout}:0.29.0 docker://ghcr.io/zgeoff/imp-host:0.29.0
        '';
      };

      # the operator's pool, which imp's module expects and never creates: made once on the
      # empty disk, before the module makes its dataset
      systemd.services.rehearsal-pool = {
        requiredBy = [ "imp-zfs-dataset.service" ];
        before = [ "imp-zfs-dataset.service" ];
        path = [ config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "zpool list tank >/dev/null 2>&1 || zpool create -f tank /dev/vdb";
      };
      services.imp = {
        enable = true;
        image = image29.ref;
        # rehearsal-pool makes and imports the pool
        zfs.importPool = false;
        zfs.arcMaxMiB = 64;
        ramBudgetMiB = 512;
      };
      specialisation.old.configuration.services.imp.image = lib.mkForce image28.ref;
      # a switch that fails: a new unit fails to start during activation
      specialisation.broken.configuration = {
        services.imp.image = lib.mkForce image28.ref;
        systemd.services.fail-on-switch = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "exit 1";
        };
      };
    };

  testScript = ''
    # the shared test utilities pass their own tests before any subtest relies on them:
    # ${testUtilsCheck}
    machine.wait_for_unit("multi-user.target")


    # these two run before any setup_test(), which resets failed units
    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it boots with no unit failed"):
        failed = machine.succeed("systemctl list-units --failed --plain --no-legend")

        assert failed == "", f"units failed at boot: {failed}"


    def setup_test():
        """Returns the VM to its boot state, with nothing of an earlier subtest left: the 0.29.0
        system running with imp-host up on its freshly pulled image, an empty tank/imp mounted
        nowhere, and the generations 1 (0.28.0), 2 (0.28.0, a switch that fails) and 3 (0.29.0,
        running). Returns the three systems' store paths as handles, as a temporary directory's
        path would be; which generation a restore goes to stays in each subtest's body."""
        base_path = machine.succeed("readlink -f /run/booted-system").strip()
        # what a subtest can leave: a holder keeping a mount busy, tank/imp or a copy mounted,
        # the seccomp profile covered, docker stopped
        # tail returns once the holder has exited, so its mount is no longer busy
        machine.succeed("if [ -f /tmp/holder.pid ]; then holder=$(cat /tmp/holder.pid); kill \"$holder\" || true; tail --pid=\"$holder\" -s 0.1 -f /dev/null; rm /tmp/holder.pid; fi")
        # findmnt and grep exit 1 when they find nothing
        machine.succeed("{ findmnt -rn -S tank/imp -o TARGET || true; } | xargs -r -n1 umount")
        machine.succeed("{ findmnt -rn -o TARGET | grep '^/root/imp-db-backups/' || true; } | sort -r | xargs -r -n1 umount")
        machine.succeed(f"for seccomp in $(grep -o 'seccomp=/nix/store/[^ ]*' {base_path}/etc/systemd/system/imp-host.service | cut -d= -f2 | tr -d \"'\"); do if mountpoint -q \"$seccomp\"; then umount \"$seccomp\"; fi; done")
        machine.succeed("rm -f /tmp/broken-seccomp.json")
        machine.succeed("find /run -maxdepth 1 -name 'impd-restore.*' -exec rmdir {} +")
        machine.succeed("systemctl start docker.socket docker.service")
        machine.succeed("systemctl reset-failed")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base_path}")
        machine.succeed(f"{base_path}/bin/switch-to-configuration test")
        machine.succeed("systemctl stop imp-host imp-docker-proxy")
        machine.succeed("systemctl reset-failed")
        machine.succeed("docker ps -aq | xargs -r docker rm -f")
        machine.succeed("docker images -q ghcr.io/zgeoff/imp-host | sort -u | xargs -r docker rmi -f")
        images = machine.succeed("docker images -q ghcr.io/zgeoff/imp-host")
        assert images == "", f"images are left: {images}"
        machine.succeed("rm -rf /root/imp-db-backups /tmp/restore.err /tmp/sleep.log")

        # an earlier reset that stopped after this destroy left no tank/imp
        machine.succeed("if zfs list -H -o name tank/imp >/dev/null 2>&1; then zfs destroy -r tank/imp; fi")
        # imp's module makes the dataset again
        machine.succeed("systemctl restart imp-zfs-dataset")
        mountpoint = machine.succeed("zfs get -H -o value mountpoint tank/imp").strip()
        assert mountpoint == "legacy", f"tank/imp has mountpoint {mountpoint!r}"

        machine.succeed("rm -f /nix/var/nix/profiles/system /nix/var/nix/profiles/system-*-link")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set $(readlink -f {base_path}/specialisation/old)")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set $(readlink -f {base_path}/specialisation/broken)")
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base_path}")
        links = machine.succeed("ls -1 /nix/var/nix/profiles | grep -E '^system-[0-9]+-link$'").split()
        assert links == ["system-1-link", "system-2-link", "system-3-link"], f"the generations are {links}"

        machine.succeed("systemctl start imp-host")
        machine.wait_until_succeeds(
            "test \"$(docker inspect imp-host --format '{{.Config.Image}}')\" = ${image29.ref}"
        )
        machine.wait_for_unit("imp-docker-proxy.service")
        return {
            "base_path": base_path,
            "old_path": machine.succeed("readlink -f /nix/var/nix/profiles/system-1-link").strip(),
            "broken_path": machine.succeed("readlink -f /nix/var/nix/profiles/system-2-link").strip(),
        }


  ''
  + subtests { inherit image28 image29; };
}
