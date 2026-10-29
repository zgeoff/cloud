#!/usr/bin/env bash
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
#   bash scripts/test-run-nixos-checks.sh
#   CASE='kvm' bash scripts/test-run-nixos-checks.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-checks-git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-checks-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-with-file-modes.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-nixos-checks.sh"

it_builds_every_check_the_flake_declares_from_a_snapshot_of_the_tracked_and_unignored_files() {
  local status=0
  create_case_tree
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

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\nimpd-restore-boundaries\n' KVM_DEVICE="$tree/kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore-boundaries"]
["docker","run","--rm","--network","host","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*","/nix/store/00000000000000000000000000000000-impd-restore-boundaries.drv^*"]
EOF
  # the deleted nixos/gone.nix and the untracked, ignored notes.txt stay out
  find "$tree/source-saw" -type f -printf '%P\n' | sort > "$tree/source-saw-files"
  diff - "$tree/source-saw-files" << 'EOF'
nixos/flake.nix
scripts/untracked.sh
EOF
  diff - "$tree/source-saw/nixos/flake.nix" <<< 'tracked'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_caps_every_nix_container_at_the_cpus_and_memory_the_environment_names() {
  local status=0
  create_case_tree
  setup_test "$tree"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\n' KVM_DEVICE="$tree/kvm" \
    NIXOS_CHECKS_CPUS=0-1 NIXOS_CHECKS_MEMORY=7g \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*"]
EOF
  assert_status 0 "$status"
}

it_builds_only_the_checks_named_without_listing_the_flake() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon test-utils > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.test-utils"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-test-utils.drv^*"]
EOF
  assert_status 0 "$status"
}

it_builds_the_other_checks_then_fails_naming_impd_restore_when_the_kvm_device_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  assert_status 1 "$status"
}

it_builds_the_other_checks_then_fails_naming_impd_restore_when_the_kvm_device_is_not_readable_and_writable() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # QEMU cannot open such a device, and would fall back to emulation
  touch "$tree/kvm"
  chmod 0400 "$tree/kvm"

  run_with_file_modes env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/kvm" \
    bash "$script" impd-restore atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/kvm is missing or not readable and writable; impd-restore needs KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  assert_status 1 "$status"
}

it_builds_the_other_checks_then_fails_naming_every_restore_check_when_the_kvm_device_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore atc-daemon impd-restore-boundaries > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore, impd-restore-boundaries need KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_every_restore_check_and_leaves_no_temp_file_when_it_lists_the_checks_without_kvm() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\nimpd-restore-boundaries\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore, impd-restore-boundaries need KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_fails_naming_impd_restore_and_builds_nothing_when_it_is_the_only_check_and_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_tank_cloud_unlock_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-unlock > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-unlock needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_tank_cloud_host_secrets_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-host-secrets > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-host-secrets needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_tank_cloud_rancher_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" tank-cloud-rancher > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; tank-cloud-rancher needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_imp_dataset_key_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" imp-dataset-key > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; imp-dataset-key needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_geoffcloud_no_pool_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" geoffcloud-no-pool > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; geoffcloud-no-pool needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_network_policy_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" network-policy > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; network-policy needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_imp_cpu_weight_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" imp-cpu-weight > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; imp-cpu-weight needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_host_cgroup_cpu_vm_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" host-cgroup-cpu-vm > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; host-cgroup-cpu-vm needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_public_front_vm_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" public-front-vm > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; public-front-vm needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_fails_naming_atc_daemon_vm_and_builds_nothing_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon-vm > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; atc-daemon-vm needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  assert_status 1 "$status"
}

it_stops_without_building_when_the_flake_fails_to_evaluate() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_EVAL_ERROR="error: syntax error, unexpected end of file" KVM_DEVICE="$tree/no-kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: syntax error, unexpected end of file"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_fails_when_the_flake_declares_no_checks() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: the flake declares no checks.x86_64-linux"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
  assert_status 1 "$status"
}

it_fails_with_the_build_when_a_check_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_BUILD_ERROR="error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'." \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'."
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_stops_without_building_when_a_check_fails_to_evaluate() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_DERIVATION_ERROR="error: attribute 'atc-daemon' missing" KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: attribute 'atc-daemon' missing"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_writes_every_check_s_derivation_sorted_and_builds_nothing_without_kvm() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    STUB_CHECKS=$'impd-restore\natc-daemon\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --derivations "$tree/derivations" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/derivations" << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_fails_with_its_usage_when_derivations_names_no_file() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --derivations > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-nixos-checks.sh [--derivations <file>] [check…] | --from-derivations <file>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_builds_the_listed_derivations_with_kvm_without_evaluating_the_flake() {
  local status=0
  create_case_tree
  setup_test "$tree"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"
  cat > "$tree/derivations" << 'EOF'
/nix/store/00000000000000000000000000000000-atc-daemon.drv
/nix/store/00000000000000000000000000000000-impd-restore.drv
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/kvm" NIXOS_CHECKS_CPUS=0-1 NIXOS_CHECKS_MEMORY=7g \
    bash "$script" --from-derivations "$tree/derivations" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["docker","run","--rm","--network","host","--cpuset-cpus","0-1","--memory","7g","--memory-swap","7g","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*","/nix/store/00000000000000000000000000000000-impd-restore.drv^*"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_fails_and_builds_nothing_from_derivations_when_kvm_is_missing() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '/nix/store/00000000000000000000000000000000-atc-daemon.drv\n' > "$tree/derivations"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --from-derivations "$tree/derivations" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "run-nixos-checks: $tree/no-kvm is missing or not readable and writable; --from-derivations needs KVM"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_fails_with_its_usage_when_from_derivations_names_an_empty_file() {
  local status=0
  create_case_tree
  setup_test "$tree"
  : > "$tree/derivations"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" --from-derivations "$tree/derivations" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-nixos-checks.sh [--derivations <file>] [check…] | --from-derivations <file>'
  diff /dev/null "$tree/calls"
  assert_status 2 "$status"
}

it_substitutes_from_the_cache_the_environment_names_when_it_holds_a_nix_cache_info() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/cache"
  printf 'StoreDir: /nix/store\n' > "$tree/cache/nix-cache-info"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" NIXOS_CHECKS_CACHE="$tree/cache" \
    bash "$script" atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","$tree/cache:/cache:ro","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","extra-substituters","file:///cache?trusted=true","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  assert_status 0 "$status"
}

it_builds_without_a_substituter_when_the_cache_holds_no_nix_cache_info() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # a cache restore that missed leaves the folder empty
  mkdir "$tree/cache"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_SOURCE_SAW="$tree/source-saw" \
    KVM_DEVICE="$tree/no-kvm" NIXOS_CHECKS_CACHE="$tree/cache" \
    bash "$script" atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","path-info","--derivation","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","--max-jobs","2","build","--no-link","-L","/nix/store/00000000000000000000000000000000-atc-daemon.drv^*"]
EOF
  assert_status 0 "$status"
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

run_cases
