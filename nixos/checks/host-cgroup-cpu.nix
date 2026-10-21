# Checks services.host-cgroup-cpu: the unit the module generates, each case evaluating its own
# config through test-utils/build-module-system.nix, and the writer script run in the build
# sandbox against a cgroup tree that the case writes, since the sandbox has no /sys. One case
# serves the written file through a real node-exporter's textfile collector on loopback. Each case
# runs on its own, in a fresh directory, with its own tree and textfile directory, and the script
# under env -i with a HOME and TMPDIR of its own, under test-support/shell/run-cases.sh.
# checks/host-cgroup-cpu-vm.nix runs the service against a real cgroup tree.
# Run: bun run test:nixos host-cgroup-cpu
{ nixpkgs, imp }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  buildModuleSystem = import ./test-utils/build-module-system.nix { inherit pkgs; };

  defaultConfig =
    (buildModuleSystem ../modules/host-cgroup-cpu.nix { services.host-cgroup-cpu.enable = true; })
    .config;
  writer = "${defaultConfig.services.host-cgroup-cpu.package}/bin/host-cgroup-cpu";
  loop = defaultConfig.systemd.services.host-cgroup-cpu.serviceConfig.ExecStart;

  # the unit's parts the module sets; NixOS adds PATH to every service's environment
  renderUnit =
    config:
    let
      service = config.systemd.services.host-cgroup-cpu;
    in
    builtins.toJSON {
      inherit (service) description wantedBy serviceConfig;
      environment = removeAttrs service.environment [ "PATH" ];
    };

  # a cgroup tree with the root, two slices, units in one of them, a cgroup a level deeper, a
  # unit name that systemd escapes, a name that needs a quote escaped, and a slice whose cpu.stat
  # has no user and system time; and a /proc of two CPUs, 10 s after a boot at 2000
  writeTree = ''
    mkdir proc
    printf '10.00 15.00\n' > proc/uptime
    printf 'cpu  100 0 100 600 50 0 0 20 0 0\ncpu0 50 0 50 300 25 0 0 10 0 0\ncpu1 50 0 50 300 25 0 0 10 0 0\nintr 0\nbtime 2000\n' > proc/stat
    mkdir -p cg/system.slice/k3s.service/kubepods.slice 'cg/system.slice/system-serial\x2dgetty.slice' \
      'cg/user.slice/odd"name.scope' cg/empty.slice
    printf 'usage_usec 9000000\nuser_usec 4000000\nsystem_usec 5000000\nnr_periods 0\n' > cg/cpu.stat
    printf 'usage_usec 3500250\nuser_usec 1000250\nsystem_usec 2500000\n' > cg/system.slice/cpu.stat
    printf 'usage_usec 3000000\nuser_usec 1000000\nsystem_usec 2000000\n' > cg/system.slice/k3s.service/cpu.stat
    printf 'usage_usec 1\nuser_usec 1\nsystem_usec 0\n' > cg/system.slice/k3s.service/kubepods.slice/cpu.stat
    printf 'usage_usec 250\nuser_usec 250\nsystem_usec 0\n' > 'cg/system.slice/system-serial\x2dgetty.slice/cpu.stat'
    printf 'usage_usec 700000\nuser_usec 600000\nsystem_usec 100000\n' > cg/user.slice/cpu.stat
    printf 'usage_usec 7\nuser_usec 3\nsystem_usec 4\n' > 'cg/user.slice/odd"name.scope/cpu.stat'
    printf 'usage_usec 5\n' > cg/empty.slice/cpu.stat
  '';

  treeMetrics = ''
    # HELP host_cgroup_cpu_seconds_total CPU time of the tasks in a cgroup and its descendants, from cpu.stat. The root cgroup, /, counts the whole host.
    # TYPE host_cgroup_cpu_seconds_total counter
    host_cgroup_cpu_seconds_total{cgroup="/",mode="user"} 4.000000
    host_cgroup_cpu_seconds_total{cgroup="/",mode="system"} 5.000000
    host_cgroup_cpu_seconds_total{cgroup="/system.slice",mode="user"} 1.000250
    host_cgroup_cpu_seconds_total{cgroup="/system.slice",mode="system"} 2.500000
    host_cgroup_cpu_seconds_total{cgroup="/user.slice",mode="user"} 0.600000
    host_cgroup_cpu_seconds_total{cgroup="/user.slice",mode="system"} 0.100000
    host_cgroup_cpu_seconds_total{cgroup="/system.slice/k3s.service",mode="user"} 1.000000
    host_cgroup_cpu_seconds_total{cgroup="/system.slice/k3s.service",mode="system"} 2.000000
    host_cgroup_cpu_seconds_total{cgroup="/system.slice/system-serial\\x2dgetty.slice",mode="user"} 0.000250
    host_cgroup_cpu_seconds_total{cgroup="/system.slice/system-serial\\x2dgetty.slice",mode="system"} 0.000000
    host_cgroup_cpu_seconds_total{cgroup="/user.slice/odd\"name.scope",mode="user"} 0.000003
    host_cgroup_cpu_seconds_total{cgroup="/user.slice/odd\"name.scope",mode="system"} 0.000004
    # HELP host_kernel_cpu_seconds_total CPU time that was neither idle, iowait nor stolen, less the usage of the top-level cgroups: kernel threads in the root cgroup and interrupts.
    # TYPE host_kernel_cpu_seconds_total counter
    host_kernel_cpu_seconds_total 9.099750
    # host_cgroup_cpu_removed_seconds 0.000000
  '';

  cases = [
    {
      title = "it runs the loop as root with only the capability to write the textfile, by default";
      script = ''
        jq -S . > expected <<'EOF'
        ${builtins.toJSON {
          description = "host cgroup CPU textfile metric";
          wantedBy = [ "multi-user.target" ];
          environment = {
            TEXTFILE_DIR = "/var/lib/node-exporter/textfile";
          };
          serviceConfig = {
            ExecStart = loop;
            Restart = "on-failure";
            RestartSec = "1min";
            MemoryMax = "64M";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "CAP_DAC_OVERRIDE";
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            PrivateNetwork = true;
            ReadWritePaths = [ "/var/lib/node-exporter/textfile" ];
          };
        }}
        EOF
        jq -S . > actual <<'EOF'
        ${renderUnit defaultConfig}
        EOF

        assert_files_equal expected actual
      '';
    }
    {
      title = "it writes into the configured directory and waits the configured interval between writes";
      script =
        let
          config =
            (buildModuleSystem ../modules/host-cgroup-cpu.nix {
              services.host-cgroup-cpu = {
                enable = true;
                textfileDir = "/srv/textfile";
                intervalSeconds = 60;
              };
            }).config;
          serviceConfig = config.systemd.services.host-cgroup-cpu.serviceConfig;
        in
        ''
          assert_equals ${
            lib.escapeShellArg (
              builtins.toJSON {
                environment = {
                  TEXTFILE_DIR = "/srv/textfile";
                };
                ReadWritePaths = [ "/srv/textfile" ];
              }
            )
          } ${
            lib.escapeShellArg (
              builtins.toJSON {
                environment = removeAttrs config.systemd.services.host-cgroup-cpu.environment [ "PATH" ];
                inherit (serviceConfig) ReadWritePaths;
              }
            )
          } "the unit's directory"
          assert_equals 1 "$(grep -c '^  sleep 60$' ${serviceConfig.ExecStart})" "the loop's pause"
        '';
    }
    {
      title = "it adds no unit when it is off";
      script =
        let
          config =
            (buildModuleSystem ../modules/host-cgroup-cpu.nix { services.host-cgroup-cpu.enable = false; })
            .config;
        in
        ''
          assert_equals false ${
            lib.boolToString (config.systemd.services ? host-cgroup-cpu)
          } "whether the module adds the unit"
        '';
    }
    {
      title = "it writes the user and system time of the root, its slices and their units, no deeper cgroup, and the kernel time";
      script = ''
        mkdir home tmp out
        ${writeTree}

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 0 "$status" "the writer's exit status"
        assert_files_equal /dev/null stdout
        assert_files_equal /dev/null stderr
        assert_equals host_cgroup_cpu.prom "$(ls -A out)" "the textfile directory"
        assert_equals 644 "$(stat -c %a out/host_cgroup_cpu.prom)" "the file's mode"
        cat > expected <<'EOF'
        ${treeMetrics}EOF
        assert_files_equal expected out/host_cgroup_cpu.prom
      '';
    }
    {
      title = "it keeps the kernel time of the last file from this boot when the new reading is lower";
      script = ''
        mkdir home tmp out
        ${writeTree}
        printf 'host_kernel_cpu_seconds_total 50.000000\n' > out/host_cgroup_cpu.prom
        touch -d @2005 out/host_cgroup_cpu.prom

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 0 "$status" "the writer's exit status"
        assert_files_equal /dev/null stderr
        assert_equals "host_kernel_cpu_seconds_total 50.000000" "$(grep '^host_kernel_cpu_seconds_total ' out/host_cgroup_cpu.prom)" "the kernel time"
      '';
    }
    {
      title = "it ignores the kernel time of a last file written before the boot";
      script = ''
        mkdir home tmp out
        ${writeTree}
        printf 'host_kernel_cpu_seconds_total 50.000000\n' > out/host_cgroup_cpu.prom
        touch -d @1999 out/host_cgroup_cpu.prom

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 0 "$status" "the writer's exit status"
        assert_files_equal /dev/null stderr
        assert_equals "host_kernel_cpu_seconds_total 9.099750" "$(grep '^host_kernel_cpu_seconds_total ' out/host_cgroup_cpu.prom)" "the kernel time"
      '';
    }
    {
      title = "it keeps subtracting the time of a top-level cgroup that is gone since the last write";
      script = ''
        mkdir home tmp out
        ${writeTree}
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer}
        rm -r cg/user.slice
        printf '20.00 30.00\n' > proc/uptime

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 0 "$status" "the writer's exit status"
        assert_files_equal /dev/null stderr
        assert_equals "host_kernel_cpu_seconds_total 29.099750" "$(grep '^host_kernel_cpu_seconds_total ' out/host_cgroup_cpu.prom)" "the kernel time"
        assert_equals "# host_cgroup_cpu_removed_seconds 0.700000" "$(grep '^# host_cgroup_cpu_removed_seconds ' out/host_cgroup_cpu.prom)" "the removed cgroups' time"
      '';
    }
    {
      title = "it fails and leaves the last file when /proc has no btime";
      script = ''
        mkdir home tmp out
        ${writeTree}
        sed -i '/^btime/d' proc/stat
        echo previous > out/host_cgroup_cpu.prom

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the writer's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "host-cgroup-cpu: no uptime, CPUs and btime in $PWD/proc" "$(cat stderr)" "the writer's stderr"
        assert_equals host_cgroup_cpu.prom "$(ls -A out)" "the textfile directory"
        assert_equals previous "$(cat out/host_cgroup_cpu.prom)" "the last file"
      '';
    }
    {
      title = "it fails and leaves the last file when the root cgroup has no cpu.stat";
      script = ''
        mkdir home tmp out cg
        echo previous > out/host_cgroup_cpu.prom

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" TEXTFILE_DIR=out ${writer} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the writer's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "host-cgroup-cpu: no user_usec and system_usec in $PWD/cg/cpu.stat" "$(cat stderr)" "the writer's stderr"
        assert_equals host_cgroup_cpu.prom "$(ls -A out)" "the textfile directory"
        assert_equals previous "$(cat out/host_cgroup_cpu.prom)" "the last file"
      '';
    }
    {
      title = "it stops the loop with the failure of the writer, before its first pause";
      script = ''
        mkdir home tmp out cg

        status=0
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" TEXTFILE_DIR=out ${loop} > stdout 2> stderr || status=$?

        assert_equals 1 "$status" "the loop's exit status"
        assert_files_equal /dev/null stdout
        assert_equals "host-cgroup-cpu: no user_usec and system_usec in $PWD/cg/cpu.stat" "$(cat stderr)" "the loop's stderr"
        assert_equals "" "$(ls -A out)" "the textfile directory"
      '';
    }
    {
      title = "it serves the written series through the textfile collector of node-exporter";
      script = ''
        mkdir home tmp out
        ${writeTree}
        env -i PATH="$PATH" HOME="$PWD/home" TMPDIR="$PWD/tmp" CGROUP_ROOT="$PWD/cg" PROC_ROOT="$PWD/proc" TEXTFILE_DIR=out ${writer}
        # the sandbox has a network namespace of its own, so the fixed port is free
        env -i HOME="$PWD/home" ${pkgs.prometheus-node-exporter}/bin/node_exporter \
          --collector.disable-defaults --collector.textfile --collector.textfile.directory=out \
          --web.listen-address=127.0.0.1:19100 2> exporter.log &
        exporter_pid=$!
        trap 'kill "$exporter_pid"' EXIT
        wait_for 10 "node-exporter's metrics" curl -sf -o metrics http://127.0.0.1:19100/metrics

        grep '^host_cgroup_cpu_seconds_total' metrics > actual
        grep '^host_cgroup_cpu_seconds_total' > expected <<'EOF'
        host_cgroup_cpu_seconds_total{cgroup="/",mode="system"} 5
        host_cgroup_cpu_seconds_total{cgroup="/",mode="user"} 4
        host_cgroup_cpu_seconds_total{cgroup="/system.slice",mode="system"} 2.5
        host_cgroup_cpu_seconds_total{cgroup="/system.slice",mode="user"} 1.00025
        host_cgroup_cpu_seconds_total{cgroup="/system.slice/k3s.service",mode="system"} 2
        host_cgroup_cpu_seconds_total{cgroup="/system.slice/k3s.service",mode="user"} 1
        host_cgroup_cpu_seconds_total{cgroup="/system.slice/system-serial\\x2dgetty.slice",mode="system"} 0
        host_cgroup_cpu_seconds_total{cgroup="/system.slice/system-serial\\x2dgetty.slice",mode="user"} 0.00025
        host_cgroup_cpu_seconds_total{cgroup="/user.slice",mode="system"} 0.1
        host_cgroup_cpu_seconds_total{cgroup="/user.slice",mode="user"} 0.6
        host_cgroup_cpu_seconds_total{cgroup="/user.slice/odd\"name.scope",mode="system"} 4e-06
        host_cgroup_cpu_seconds_total{cgroup="/user.slice/odd\"name.scope",mode="user"} 3e-06
        EOF
        assert_files_equal expected actual
        assert_equals 9.09975 "$(sed -n 's/^host_kernel_cpu_seconds_total //p' metrics)" "the kernel time"
        assert_equals 0 "$(sed -n 's/^node_textfile_scrape_error //p' metrics)" "the collector's scrape error"
      '';
    }
  ];
in
pkgs.runCommand "host-cgroup-cpu-check"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.diffutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.jq
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    # fixed, so the modes the cases assert do not depend on the builder's umask
    umask 022
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${testLib}/wait-for.sh
    source ${pkgs.writeText "host-cgroup-cpu-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
