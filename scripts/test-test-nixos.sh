#!/usr/bin/env bash
# Hermetic test for test-nixos.sh: it builds the flake's checks from a snapshot of the tracked and
# unignored files, every check the flake declares or only the ones named, and it passes KVM to
# the build only when the device is there for it. It runs no Nix and no container: git and docker
# are stubs that log their argv as JSON lines and exit 97 on a call they do not expect, and each
# case runs the script under `env -i` with only the variables it sets, KVM_DEVICE among them, so
# no case depends on the machine's /dev/kvm. Each case compares the script's whole stdout, stderr
# and call log, masking only the temporary paths.
#
#   bash scripts/test-test-nixos.sh
#   CASE='kvm' bash scripts/test-test-nixos.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-nixos.sh"

it_builds_every_check_the_flake_declares_from_a_snapshot_of_the_tracked_and_unignored_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  touch "$tree/kvm"
  chmod 0600 "$tree/kvm"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    STUB_CHECKS=$'atc-daemon\nimpd-restore\n' KVM_DEVICE="$tree/kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
["docker","run","--rm","--network","host","--device","$tree/kvm:/dev/kvm","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","build","--no-link","-L","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon","path:/src?dir=nixos#checks.x86_64-linux.impd-restore"]
EOF
  # the deleted nixos/gone.nix and the untracked, ignored notes.txt stay out
  find "$tree/build-saw" -type f -printf '%P\n' | sort > "$tree/build-saw-files"
  diff - "$tree/build-saw-files" << 'EOF'
nixos/flake.nix
scripts/untracked.sh
EOF
  diff - "$tree/build-saw/nixos/flake.nix" <<< 'tracked'
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_only_the_checks_named_without_listing_the_flake() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon test-utils > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","build","--no-link","-L","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon","path:/src?dir=nixos#checks.x86_64-linux.test-utils"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_the_other_checks_then_fails_naming_impd_restore_when_the_kvm_device_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "test-nixos: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","build","--no-link","-L","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_builds_the_other_checks_then_fails_naming_impd_restore_when_the_kvm_device_is_not_readable_and_writable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  # QEMU cannot open such a device, and would fall back to emulation
  touch "$tree/kvm"
  chmod 0400 "$tree/kvm"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    KVM_DEVICE="$tree/kvm" \
    bash "$script" impd-restore atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "test-nixos: $tree/kvm is missing or not readable and writable; impd-restore needs KVM"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","--option","system-features","kvm nixos-test benchmark big-parallel uid-range","build","--no-link","-L","path:/src?dir=nixos#checks.x86_64-linux.atc-daemon"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_naming_impd_restore_and_builds_nothing_when_it_is_the_only_check_and_kvm_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" impd-restore > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "test-nixos: $tree/no-kvm is missing or not readable and writable; impd-restore needs KVM"
  diff - "$tree/calls" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_without_building_when_the_flake_fails_to_evaluate() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    STUB_EVAL_ERROR="error: syntax error, unexpected end of file" KVM_DEVICE="$tree/no-kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: syntax error, unexpected end of file"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_the_flake_declares_no_checks() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    STUB_CHECKS=$'\n' KVM_DEVICE="$tree/no-kvm" \
    bash "$script" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "test-nixos: the flake declares no checks.x86_64-linux"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|TMP|g" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git","rev-parse","--show-toplevel"]
["git","-C","$tree/repo","ls-files","-z","--cached","--others","--exclude-standard","--deduplicate"]
["docker","run","--rm","--network","host","-v","cloud-nixos-checks-store:/nix","-v","TMP:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","eval","--raw","path:/src?dir=nixos#checks.x86_64-linux","--apply","checks: builtins.concatStringsSep \"\\\\n\" (builtins.attrNames checks) + \"\\\\n\""]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_the_build_when_a_check_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_TOPLEVEL="$tree/repo" STUB_LS_FILES="$tree/ls-files" STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_ERROR="error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'." \
    KVM_DEVICE="$tree/no-kvm" \
    bash "$script" atc-daemon > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "error: Cannot build '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-atc-daemon-check.drv'."
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

setup_case() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/repo/nixos" "$tree/repo/scripts"
  : > "$tree/calls"
  # the repository the stub git stands for: a tracked file, an untracked one git lists, and an
  # ignored one it does not; ls-files also names nixos/gone.nix, deleted from the working tree
  echo tracked > "$tree/repo/nixos/flake.nix"
  echo untracked > "$tree/repo/scripts/untracked.sh"
  echo ignored > "$tree/repo/notes.txt"
  printf '%s\0' nixos/flake.nix nixos/gone.nix scripts/untracked.sh > "$tree/ls-files"
  # git: answers the toplevel and the file list the snapshot reads
  cat > "$tree/bin/git" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' git "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "$STUB_TOPLEVEL" ;;
  "-C $STUB_TOPLEVEL ls-files -z --cached --others --exclude-standard --deduplicate") cat "$STUB_LS_FILES" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  # docker: an eval prints STUB_CHECKS, or fails with STUB_EVAL_ERROR (nix's exit 1); a build
  # copies its /src mount to STUB_BUILD_SAW, then fails with STUB_BUILD_ERROR (exit 1)
  cat > "$tree/bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "run "*" eval --raw path:/src?dir=nixos#checks.x86_64-linux --apply "*)
    if [ -n "${STUB_EVAL_ERROR:-}" ]; then echo "$STUB_EVAL_ERROR" >&2; exit 1; fi
    printf '%s' "$STUB_CHECKS"
    ;;
  "run "*" build --no-link -L "*)
    src=""
    for arg in "$@"; do
      case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
    done
    cp -R "$src" "$STUB_BUILD_SAW"
    if [ -n "${STUB_BUILD_ERROR:-}" ]; then echo "$STUB_BUILD_ERROR" >&2; exit 1; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$tree/bin/git" "$tree/bin/docker"
}

run_cases
