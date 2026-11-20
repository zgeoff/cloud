#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for run-nixos-checks.sh: it evaluates each of the flake's checks to its derivation,
# in a container of its own, from a snapshot of the tracked and unignored files, every check the
# flake declares or only the ones named, then builds those derivations in one more container, two
# builds at a time, each container capped at the CPUs and memory the environment names, and it
# passes KVM to the build only when the device is there for it. With --derivations it writes the
# sorted derivations and builds nothing, and with a cache that holds a nix-cache-info the build
# substitutes from it. It runs no Nix and no container: git and docker
# are stubs that log their argv as JSON lines and exit 97 on a call they do not expect, and each
# case runs the script under `env -i` with only the variables it sets, KVM_DEVICE among them, so
# no case depends on the machine's /dev/kvm; the case with a device it may not write runs the
# script through run_with_file_modes, so the mode binds a run as root too. Each case compares the script's whole stdout, stderr
# and call log, masking only the temporary paths.
#
#   bash scripts/run-bats.sh
#   CASE='kvm' bash scripts/run-bats.sh   # the cases whose title holds it

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-checks-git.sh'
  load 'src/test-utils/shell/create-stub-checks-docker.sh'
  load 'src/test-utils/shell/run-with-file-modes.sh'
  load 'nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/run-nixos-checks.sh"
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

setup_test() {
  local tree="$1"
  # the repository the stub git stands for starts empty, with nothing for ls-files to list
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo"
  : > "$tree/calls"
  : > "$tree/ls-files"
  create_stub_checks_git "$tree/bin"
  create_stub_checks_docker "$tree/bin"
}

@test "it builds every check the flake declares from a snapshot of the tracked and unignored files" {
  setup_test "$tree"
  # a tracked file, an untracked one git lists, and an ignored one it does not; ls-files also
  # names nixos/gone.nix, deleted from the working tree
  mkdir "$tree/repo/nixos" "$tree/repo/scripts"
  echo tracked > "$tree/repo/nixos/flake.nix"
  echo untracked > "$tree/repo/scripts/untracked.sh"
  echo ignored > "$tree/repo/notes.txt"
  printf '%s\0' nixos/flake.nix nixos/gone.nix scripts/untracked.sh > "$tree/ls-files"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\nimpd-restore-boundaries\n' KVM_DEVICE="$tree/kvm" \
    bash "$script"

  refute_output
  refute_stderr

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore-boundaries"]
["docker","run","--rm","--network","host","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*","/nix/store/00000000000000000000000000000000-impd-restore-boundaries.drv^*"]
EOF
  # the deleted nixos/gone.nix and the untracked, ignored notes.txt stay out
  find "$tree/source-saw" -type f -printf '%P\n' > "$tree/source-saw-found"
  sort "$tree/source-saw-found" > "$tree/source-saw-files"
  run -0 diff - "$tree/source-saw-files" << 'EOF'
nixos/flake.nix
scripts/untracked.sh
EOF
  run -0 diff - "$tree/source-saw/nixos/flake.nix" <<< 'tracked'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it caps every nix container at the cpus and memory the environment names" {
  setup_test "$tree"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\n' KVM_DEVICE="$tree/kvm" \
    NIXOS_CHECKS_CPUS=0-1 NIXOS_CHECKS_MEMORY=7g \
    bash "$script"

  refute_output
  refute_stderr

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*"]
EOF
}

@test "it builds only the checks named without listing the flake" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon test-utils

  refute_output
  refute_stderr

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.test-utils"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-test-utils.drv^*"]
EOF
}

@test "it builds the other checks then fails naming impd restore when the kvm device is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore atc-daemon

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
}

@test "it builds the other checks then fails naming impd restore when the kvm device is not readable and writable" {
  setup_test "$tree"
  # QEMU cannot open such a device, and would fall back to emulation
  touch "$tree/kvm"
  chmod 0400 "$tree/kvm"

  run -1 --separate-stderr run_with_file_modes env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/kvm" \
    bash "$script" impd-restore atc-daemon

  refute_output
  assert_stderr "run-nixos-checks: $tree/kvm is missing or not readable and writable; impd-restore needs KVM"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
}

@test "it builds the other checks then fails naming every restore check when the kvm device is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore atc-daemon impd-restore-boundaries

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore, impd-restore-boundaries need KVM"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
}

@test "it fails naming every restore check and leaves no temp file when it lists the checks without kvm" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\nimpd-restore-boundaries\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script"

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore, impd-restore-boundaries need KVM"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails naming impd restore and builds nothing when it is the only check and kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming tank cloud unlock and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-unlock

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-unlock needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming tank cloud host secrets and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-host-secrets

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-host-secrets needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming tank cloud rancher and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-rancher

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-rancher needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming imp dataset key and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" imp-dataset-key

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; imp-dataset-key needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming geoffcloud no pool and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" geoffcloud-no-pool

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; geoffcloud-no-pool needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming network policy and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" network-policy

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; network-policy needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming imp cpu weight and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" imp-cpu-weight

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; imp-cpu-weight needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming host cgroup cpu vm and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" host-cgroup-cpu-vm

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; host-cgroup-cpu-vm needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming disk read ahead vm and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" disk-read-ahead-vm

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; disk-read-ahead-vm needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming public front vm and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" public-front-vm

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; public-front-vm needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it fails naming atc daemon vm and builds nothing when kvm is missing" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon-vm

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; atc-daemon-vm needs KVM"

  run -0 diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
}

@test "it stops without building when the flake fails to evaluate" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_EVAL_ERROR="error: syntax error, unexpected end of file" KVM_DEVICE="$tree/no-kvm" \
    bash "$script"

  refute_output
  assert_stderr "error: syntax error, unexpected end of file"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails when the flake declares no checks" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script"

  refute_output
  assert_stderr "run-nixos-checks: the flake declares no checks.x86_64-linux"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
}

@test "it fails with the build when a check fails" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_BUILD_ERROR="error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'." \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon

  refute_output
  assert_stderr "error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'."

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it stops without building when a check fails to evaluate" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_DERIVATION_ERROR="error: attribute 'atc-daemon' missing" KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon

  refute_output
  assert_stderr "error: attribute 'atc-daemon' missing"

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it writes every check s derivation sorted and builds nothing without kvm" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'impd-restore\natc-daemon\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --derivations "$tree/derivations"

  refute_output
  refute_stderr

  run -0 diff - "$tree/derivations" << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails with its usage when derivations names no file" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --derivations

  refute_output
  assert_stderr 'usage: run-nixos-checks.sh [--derivations <file>] [check…] | --from-derivations <file>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it builds the listed derivations with kvm without evaluating the flake" {
  setup_test "$tree"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"
  cat > "$tree/derivations" << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/kvm" NIXOS_CHECKS_CPUS=0-1 NIXOS_CHECKS_MEMORY=7g \
    bash "$script" --from-derivations "$tree/derivations"

  refute_output
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails and builds nothing from derivations when kvm is missing" {
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --from-derivations "$tree/derivations"

  refute_output
  assert_stderr "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; --from-derivations needs KVM"

  run -0 diff /dev/null "$tree/calls"
}

@test "it fails with its usage when from derivations names an empty file" {
  setup_test "$tree"
  : > "$tree/derivations"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --from-derivations "$tree/derivations"

  refute_output
  assert_stderr 'usage: run-nixos-checks.sh [--derivations <file>] [check…] | --from-derivations <file>'

  run -0 diff /dev/null "$tree/calls"
}

@test "it substitutes from the cache the environment names when it holds a nix cache info" {
  setup_test "$tree"
  mkdir "$tree/cache"
  printf 'StoreDir: /nix/store\n' > "$tree/cache/nix-cache-info"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" NIXOS_CHECKS_CACHE="$tree/cache" \
    bash "$script" atc-daemon

  refute_output
  refute_stderr

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","$tree/cache:/cache:ro","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","extra-substituters","file:///cache?trusted=true","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
}

@test "it builds without a substituter when the cache holds no nix cache info" {
  setup_test "$tree"
  # a cache restore that missed leaves the folder empty
  mkdir "$tree/cache"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" NIXOS_CHECKS_CACHE="$tree/cache" \
    bash "$script" atc-daemon

  refute_output
  refute_stderr

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
}
