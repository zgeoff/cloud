#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-nixos-ssh.sh: the ssh stand-in logs every call, answers the thirteen
# remote commands of a switch, fails closed on anything else, and hands a loopback call to
# the real ssh when asked. The pass-through case pins what the switch suite assumes about
# the real ssh: a refused connection exits 255 with "ssh: connect to host … port …:
# Connection refused" and the CR LF that its log ends a line with on stderr, as OpenSSH
# 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and 10.5p1 print it. A session that
# drops after it opens has no real transport here, so the stand-in's drop reuses that exit
# 255 with OpenSSH's "Connection to <host> closed by remote host." line, whose source and
# check create-stub-nixos-ssh.sh records with those of the other texts it prints.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-nixos-ssh.sh'
  load 'create-stub-remote-tools.sh'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for the other
# remote tools, checked so no call can reach a real remote tool, and the HOME and TMPDIR the
# stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it answers the switch with nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"

  refute_output
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
}

@test "it prints the named unit lists on stderr for the dry activate" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_DRY_ACTIVATE=$'would stop the following units: k3s.service\nwould activate the configuration...' \
    ssh -o BatchMode=yes root@geoffcloud "NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"

  refute_output
  assert_stderr - << 'ERR'
would stop the following units: k3s.service
would activate the configuration...
ERR
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"]
CALLS
}

@test "it prints only the activation line for a dry activate with no unit to change" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud "NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"

  refute_output
  assert_stderr 'would activate the configuration...'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"]
CALLS
}

@test "it fails the dry activate with exit 11 while another switch holds the lock" {
  setup_test "$tree"

  run -11 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_DRY_ACTIVATE_LOCKED=1 ssh -o BatchMode=yes root@geoffcloud "NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"

  refute_output
  assert_stderr 'Could not acquire lock'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","NIXOS_INSTALL_BOOTLOADER=0 systemd-run --wait --pipe '/nix/store/x/bin/switch-to-configuration' dry-activate"]
CALLS
}

# switch-to-configuration-ng sorts the failed units by their lower-case names, so
# Atc-daemon.service comes between alloy.service and zram.service, not first as a byte
# order would put it.
@test "it fails the switch as switch to configuration ng reports failed units" {
  setup_test "$tree"

  run -4 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_ACTIVATE_FAILED_UNITS="zram.service Atc-daemon.service alloy.service" \
    STUB_ACTIVATE_STATUS=$'× alloy.service - Alloy\n     Active: failed (Result: exit-code)' \
    ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"

  assert_output - << 'OUT'
× alloy.service - Alloy
     Active: failed (Result: exit-code)
OUT
  assert_stderr 'warning: the following units failed: alloy.service, Atc-daemon.service, zram.service'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
}

@test "it prints no status text for failed units when none is given" {
  setup_test "$tree"

  run -4 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_ACTIVATE_FAILED_UNITS="alloy.service" \
    ssh -o BatchMode=yes root@geoffcloud \
    "nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"

  refute_output
  assert_stderr 'warning: the following units failed: alloy.service'
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/x' && systemd-run '/nix/store/x/bin/switch-to-configuration' switch"]
CALLS
}

@test "it prints the named gateway images without a newline for the kubectl query" {
  setup_test "$tree"

  # to a file, so the missing newline reaches the comparison
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_GATEWAY_IMAGES='ghcr.io/zgeoff/atc-gateway:2.27.0 ghcr.io/zgeoff/atc-gateway:4.5.0' \
    ssh -o BatchMode=yes root@geoffcloud \
    "k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'" \
    > "$tree/out" 2> "$tree/err"

  printf '%s' 'ghcr.io/zgeoff/atc-gateway:2.27.0 ghcr.io/zgeoff/atc-gateway:4.5.0' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
CALLS
}

@test "it prints nothing for the kubectl query when no gateway pod is named" {
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud \
    "k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'" \
    > "$tree/out" 2> "$tree/err"

  cmp /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
CALLS
}

@test "it prints the later gateway images from the second kubectl query on" {
  setup_test "$tree"

  for query in first second third; do
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
      STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 STUB_GATEWAY_LATER_IMAGES=ghcr.io/zgeoff/atc-gateway:4.5.0 \
      ssh -o BatchMode=yes root@geoffcloud \
      "k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'" \
      > "$tree/out-$query" 2>> "$tree/err"
  done

  printf '%s' ghcr.io/zgeoff/atc-gateway:2.27.0 | cmp - "$tree/out-first"
  printf '%s' ghcr.io/zgeoff/atc-gateway:4.5.0 | cmp - "$tree/out-second"
  printf '%s' ghcr.io/zgeoff/atc-gateway:4.5.0 | cmp - "$tree/out-third"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
CALLS
}

@test "it prints the named nixie images then the later ones for the nixie query" {
  setup_test "$tree"

  for query in first second; do
    env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
      STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_LATER_IMAGES=ghcr.io/zgeoff/nixie:0.32.0 \
      ssh -o BatchMode=yes root@geoffcloud \
      "k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'" \
      > "$tree/out-$query" 2>> "$tree/err"
  done

  printf '%s' ghcr.io/zgeoff/nixie:0.31.4 | cmp - "$tree/out-first"
  printf '%s' ghcr.io/zgeoff/nixie:0.32.0 | cmp - "$tree/out-second"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
CALLS
}

@test "it prints nothing for the nixie query when no nixie pod is named" {
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud \
    "k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'" \
    > "$tree/out" 2> "$tree/err"

  cmp /dev/null "$tree/out"
  diff /dev/null "$tree/err"
}

@test "it prints one nixie report per readiness call and repeats the last" {
  setup_test "$tree"
  local health=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls"
    STUB_NIXIE_REPORTS=$'{"status":"unready"}\n{"status":"ready"}'
    ssh -o BatchMode=yes root@geoffcloud "k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health")

  run -1 --separate-stderr "${health[@]}"
  assert_output '{"status":"unready"}'
  assert_stderr 'command terminated with exit code 1'
  run -0 --separate-stderr "${health[@]}"
  assert_output '{"status":"ready"}'
  refute_stderr
  run -0 --separate-stderr "${health[@]}"
  assert_output '{"status":"ready"}'
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
CALLS
}

@test "it fails the readiness call as kubectl does when no report is named" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud \
    "k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"

  refute_output
  assert_stderr 'Error from server (NotFound): pods "nixie-0" not found'
}

@test "it prints the named current system for readlink" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    ssh -o BatchMode=yes root@geoffcloud readlink /run/current-system

  assert_output /nix/store/current
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]'
}

@test "it drops the connection at readlink with exit 255" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    STUB_SSH_DROP_AT_READLINK=1 ssh -o BatchMode=yes root@geoffcloud readlink /run/current-system

  refute_output
  assert_stderr $'Connection to geoffcloud closed by remote host.\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]'
}

@test "it prints the named failed units" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    ssh -o BatchMode=yes root@geoffcloud systemctl --failed --no-legend --plain

  assert_output 'alloy.service loaded failed failed Alloy'
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]'
}

@test "it fails the failed unit listing with the named exit code" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_FAILED_EXIT=1 \
    ssh -o BatchMode=yes root@geoffcloud systemctl --failed --no-legend --plain

  refute_output
  assert_stderr 'Failed to list units: Connection timed out'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]'
}

@test "it prints the named impd image records" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"name":"pv-base","digest":"sha256:0a"}]' \
    ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz image ls --json"

  assert_output '[{"name":"pv-base","digest":"sha256:0a"}]'
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz image ls --json"]'
}

@test "it prints an empty image list when no record is named" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz image ls --json"

  assert_output '[]'
  refute_stderr
}

@test "it prints the reserved then the configured hugetlb pages" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_HUGETLB_RESERVED=300 STUB_HUGETLB_CONFIGURED=512 ssh -o BatchMode=yes root@geoffcloud \
    "sysctl -n vm.nr_hugepages; sed -n 's/^vm\\.nr_hugepages=//p' /etc/sysctl.d/60-nixos.conf"

  assert_output - << 'EOF'
300
512
EOF
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","sysctl -n vm.nr_hugepages; sed -n 's/^vm\\.nr_hugepages=//p' /etc/sysctl.d/60-nixos.conf"]
CALLS
}

@test "it prints no reserved and no configured hugetlb pages when none are named" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud \
    "sysctl -n vm.nr_hugepages; sed -n 's/^vm\\.nr_hugepages=//p' /etc/sysctl.d/60-nixos.conf"

  assert_output '0'
  refute_stderr
}

@test "it prints the named imps" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"kettle","state":"sleeping"}]' \
    ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz ls --json --builders"

  assert_output '[{"id":"imp_1","name":"kettle","state":"sleeping"}]'
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz ls --json --builders"]'
}

@test "it prints an empty imp list when no imp is named" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz ls --json --builders"

  assert_output '[]'
  refute_stderr
}

@test "it prints the named page sizes for the page size loop" {
  setup_test "$tree"

  # shellcheck disable=SC2016 # $d, $s and $v belong to the remote shell
  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 2M 2M' ssh -o BatchMode=yes root@geoffcloud \
    'podman exec imp-host sh -c '"'"'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs "\"hugePages\": \"2M\"" "$d/snapshot/meta.json" && s=2M; grep -qs "\"hugePages\": \"2M\"" "$d/vm.json" && v=2M; echo "$d $s $v"; done'"'"''

  assert_output - << 'EOF'
imp_1 4K 4K
imp_2 2M 2M
EOF
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c 'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/snapshot/meta.json\" && s=2M; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/vm.json\" && v=2M; echo \"$d $s $v\"; done'"]
CALLS
}

@test "it prints nothing for the page size loop when no size is named" {
  setup_test "$tree"

  # shellcheck disable=SC2016 # $d, $s and $v belong to the remote shell
  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud \
    'podman exec imp-host sh -c '"'"'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs "\"hugePages\": \"2M\"" "$d/snapshot/meta.json" && s=2M; grep -qs "\"hugePages\": \"2M\"" "$d/vm.json" && v=2M; echo "$d $s $v"; done'"'"''

  refute_output
  refute_stderr
}

@test "it takes an imp stop and prints nothing" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz stop kettle"

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop kettle"]'
}

@test "it prints one named image folder per line" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGE_DIRS='0a 1b' ssh -o BatchMode=yes root@geoffcloud \
    "podman exec imp-host sh -c 'cd /var/lib/imp/images && for d in *; do if [ -f \"\$d/rootfs.ext4\" ]; then echo \"\$d\"; fi; done'"

  assert_output - << 'EOF'
0a
1b
EOF
  refute_stderr
  diff - "$tree/calls" << 'CALLS'
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c 'cd /var/lib/imp/images && for d in *; do if [ -f \"$d/rootfs.ext4\" ]; then echo \"$d\"; fi; done'"]
CALLS
}

@test "it fails both podman commands as podman does without imp host" {
  setup_test "$tree"

  run -125 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMP_HOST_GONE=1 ssh -o BatchMode=yes root@geoffcloud "podman exec imp-host impz image ls --json"
  refute_output
  assert_stderr 'Error: no container with name or ID "imp-host" found: no such container'
  run -125 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMP_HOST_GONE=1 STUB_IMPD_IMAGE_DIRS=0a ssh -o BatchMode=yes root@geoffcloud \
    "podman exec imp-host sh -c 'cd /var/lib/imp/images && for d in *; do if [ -f \"\$d/rootfs.ext4\" ]; then echo \"\$d\"; fi; done'"
  refute_output
  assert_stderr 'Error: no container with name or ID "imp-host" found: no such container'
}

@test "it fails closed with exit 97 on an unknown remote command" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    ssh -o BatchMode=yes root@geoffcloud reboot

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes root@geoffcloud reboot'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","reboot"]'
}

@test "it fails closed with exit 97 on a call without batch mode" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" STUB_CURRENT=/nix/store/current \
    ssh root@geoffcloud readlink /run/current-system

  refute_output
  assert_stderr 'unexpected: root@geoffcloud readlink /run/current-system'
  diff - "$tree/calls" <<< '["ssh","root@geoffcloud","readlink","/run/current-system"]'
}

@test "it hands a loopback call to the real ssh which refuses a dead port with exit 255" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]'
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
@test "it never hands a call to another destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 true

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.2:1","true"]'
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
@test "it never hands a call with an option after the destination to the real ssh" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true

  refute_output
  assert_stderr 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","true"]'
}

@test "it hands a call to the system ssh not one on the callers PATH" {
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  run -255 --separate-stderr env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]'
}
