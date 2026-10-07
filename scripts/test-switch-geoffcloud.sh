#!/usr/bin/env bash
# Hermetic test for switch-geoffcloud.sh: a switch never follows a failed build, and it
# activates the exact store path the build printed, built from the checked commit. It
# touches no host and runs no Nix: docker and ssh are stubs that log their argv as JSON
# lines, and each case runs the script in its own temporary clone with its own origin,
# under `env -i` with only the variables it sets. Each case compares the script's whole
# stdout, stderr and call log, masking only the snapshot's temporary path.
#
#   bash scripts/test-switch-geoffcloud.sh
#   CASE='unknown argument' bash scripts/test-switch-geoffcloud.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository,
# user or system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

it_activates_the_store_path_its_build_printed() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  # scripts/switch-geoffcloud.sh is setup_case's init commit; nixos/marker is this case's
  find "$tree/build-saw" -type f -printf '%P\n' | sort > "$tree/build-saw-files"
  diff - "$tree/build-saw-files" << 'EOF'
nixos/marker
scripts/switch-geoffcloud.sh
EOF
  diff - "$tree/build-saw/nixos/marker" <<< committed
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_the_failed_units_the_host_reports_after_the_switch() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
alloy.service loaded failed failed Alloy
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_the_checked_commit_when_the_checkout_is_edited_during_the_build() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_EDIT_DURING_BUILD="$tree/clone/nixos/marker" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  diff - "$tree/clone/nixos/marker" <<< edited
  diff - "$tree/build-saw/nixos/marker" <<< committed
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_never_builds_an_untracked_file() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  echo '{ }' > "$tree/clone/nixos/untracked.nix"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  # scripts/switch-geoffcloud.sh is setup_case's init commit; nixos/marker is this case's
  find "$tree/build-saw" -type f -printf '%P\n' | sort > "$tree/build-saw-files"
  diff - "$tree/build-saw-files" << 'EOF'
nixos/marker
scripts/switch-geoffcloud.sh
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The script reads HEAD once, while it checks; a commit landing after that check must not
# reach the build. Nothing but an interception lands it at that moment, so a git stand-in
# commits right after the check's last read (rev-parse origin/main) and logs that it did.
it_builds_the_checked_commit_when_a_commit_lands_after_the_check() {
  local checked real_git status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  checked="$(git -C "$tree/clone" rev-parse HEAD)"
  real_git="$(command -v git)"
  cat > "$tree/bin/git" << EOF
#!/usr/bin/env bash
if [[ " \$* " == *" rev-parse origin/main "* ]]; then
  "$real_git" "\$@"
  echo moved > "$tree/clone/nixos/marker"
  "$real_git" -C "$tree/clone" -c user.name=test -c user.email=test@example.invalid commit -qam moved
  echo '["git-moved-head"]' >> "$tree/calls"
  exit 0
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$tree/bin/git"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${checked:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git-moved-head"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  git -C "$tree/clone" log --format=%s -2 > "$tree/log"
  diff - "$tree/log" << 'EOF'
moved
marker
EOF
  git -C "$tree/clone" rev-parse HEAD~1 > "$tree/parent"
  diff - "$tree/parent" <<< "$checked"
  diff - "$tree/build-saw/nixos/marker" <<< committed
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_and_never_copies_with_build_only() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --build-only) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_switches_the_host_that_the_environment_names() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    GEOFFCLOUD_HOST=root@other.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@other.test
== switch root@other.test
== root@other.test runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@other.test","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@other.test","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@other.test","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@other.test","systemctl","--failed","--no-legend","--plain"]
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_an_unknown_argument_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh --switch) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
usage: switch-geoffcloud.sh [--build-only]
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_never_builds_from_a_branch_other_than_main() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  git -C "$tree/clone" checkout -q -b topic

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
switch from main, not topic
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_with_uncommitted_changes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '# local edit' >> "$tree/clone/scripts/switch-geoffcloud.sh"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the checkout has uncommitted changes
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_when_git_status_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  head -c 64 /dev/zero | tr "\0" x > "$tree/clone/.git/index"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: bad signature 0x78787878
fatal: index file corrupt
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_never_builds_when_the_fetch_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mv "$tree/origin.git" "$tree/origin-gone.git"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
fatal: '$tree/origin.git' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_never_builds_when_origin_main_has_moved_on() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  git clone -q "$tree/origin.git" "$tree/other"
  git -C "$tree/other" commit -q --allow-empty -m elsewhere
  git -C "$tree/other" push -q origin main

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
main is not origin/main; pull first
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_main_with_an_unpushed_commit() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  git -C "$tree/clone" commit -q --allow-empty -m unpushed

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
main is not origin/main; pull first
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_when_the_commit_cannot_be_archived() {
  local blob status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  blob="$(git -C "$tree/clone" rev-parse HEAD:scripts/switch-geoffcloud.sh)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: invalid object 100644 $blob for 'scripts/switch-geoffcloud.sh'
error: cannot read '$blob'
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_never_builds_outside_a_git_checkout() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/loose"
  cp "$tree/clone/scripts/switch-geoffcloud.sh" "$tree/loose/"

  (cd "$tree/loose" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" GIT_CEILING_DIRECTORIES="$tree" \
    bash switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
fatal: not a git repository (or any of the parent directories): .git
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_never_switches_after_a_failed_build() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: builder for '/nix/store/x.drv' failed with exit code 1
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_switches_when_docker_cannot_reach_its_daemon() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_DOCKER_DOWN=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_switches_when_the_build_prints_no_system_path() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_BUILD_OUT='warning: x' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the build printed no system path: warning: x
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_activates_when_the_copy_fails() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: cannot connect to 'root@geoffcloud'
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_ssh_exit_255_when_the_host_is_unreachable() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_DOWN=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
ssh: connect to host geoffcloud port 22: Connection refused
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
EOF
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_stops_with_the_activation_exit_code_when_switch_to_configuration_fails() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_ACTIVATE_EXIT=4 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
warning: error(s) occurred while switching to the new configuration
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
EOF
  [ "$status" = 4 ] || { echo "exit $status, want 4" >&2; exit 1; }
}

it_stops_with_ssh_exit_255_when_the_connection_drops_before_the_check() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_DROP_AT_READLINK=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Connection to geoffcloud closed by remote host.
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_fails_when_the_host_runs_another_system_after_the_switch() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the host runs /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old, not the built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_with_systemctls_exit_code_when_listing_failed_units_fails() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_EXIT=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Failed to list units: Connection timed out
EOF
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}


# Boot data every case needs: a clone of a bare origin whose main holds the script under
# test (its init commit), and docker and ssh stand-ins that log each call's argv as a
# JSON line to STUB_LOG and end with exit 97 on a call they do not know.
setup_case() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  # docker: a build copies its /src mount to STUB_BUILD_SAW (after the optional edit of
  # STUB_EDIT_DURING_BUILD, so a build of the working tree would see the edit), then fails
  # with STUB_BUILD_ERROR (nix's exit 1) or prints STUB_BUILD_OUT; a copy fails with
  # STUB_COPY_ERROR; STUB_DOCKER_DOWN fails every call as docker 29 does when its daemon
  # socket is missing (exit 1)
  cat > "$tree/bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ -n "${STUB_DOCKER_DOWN:-}" ]; then
  echo "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory" >&2
  exit 1
fi
case "$1 $*" in
  "run "*" build --no-link --print-out-paths "*)
    src=""
    for arg in "$@"; do
      case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
    done
    if [ -n "${STUB_EDIT_DURING_BUILD:-}" ]; then echo edited > "$STUB_EDIT_DURING_BUILD"; fi
    cp -R "$src" "$STUB_BUILD_SAW"
    if [ -n "${STUB_BUILD_ERROR:-}" ]; then echo "$STUB_BUILD_ERROR" >&2; exit 1; fi
    printf '%s\n' "$STUB_BUILD_OUT"
    ;;
  "run "*" copy --to ssh://"*)
    if [ -n "${STUB_COPY_ERROR:-}" ]; then echo "$STUB_COPY_ERROR" >&2; exit 1; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  # ssh: answers the three remote commands the switch runs. STUB_SSH_DOWN refuses every
  # connection (ssh's 255); STUB_ACTIVATE_EXIT makes switch-to-configuration fail with that
  # code, which systemd-run --wait --pipe passes back; STUB_SSH_DROP_AT_READLINK drops the
  # connection (255) on the readlink check; STUB_CURRENT is the host's current system;
  # STUB_FAILED_UNITS its failed units; STUB_FAILED_EXIT makes systemctl fail
  cat > "$tree/bin/ssh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ -n "${STUB_SSH_DOWN:-}" ]; then
  echo "ssh: connect to host ${3#*@} port 22: Connection refused" >&2
  exit 255
fi
case "${*:4}" in
  "nix-env -p /nix/var/nix/profiles/system --set "*"/bin/switch-to-configuration' switch")
    if [ -n "${STUB_ACTIVATE_EXIT:-}" ]; then
      echo "warning: error(s) occurred while switching to the new configuration" >&2
      exit "$STUB_ACTIVATE_EXIT"
    fi
    ;;
  "readlink /run/current-system")
    if [ -n "${STUB_SSH_DROP_AT_READLINK:-}" ]; then
      echo "Connection to ${3#*@} closed by remote host." >&2
      exit 255
    fi
    printf '%s\n' "$STUB_CURRENT"
    ;;
  "systemctl --failed --no-legend --plain")
    if [ -n "${STUB_FAILED_EXIT:-}" ]; then
      echo "Failed to list units: Connection timed out" >&2
      exit "$STUB_FAILED_EXIT"
    fi
    if [ -n "${STUB_FAILED_UNITS:-}" ]; then printf '%s\n' "$STUB_FAILED_UNITS"; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$tree/bin/docker" "$tree/bin/ssh"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  mkdir "$tree/clone/scripts"
  cp "$(dirname "${BASH_SOURCE[0]}")/switch-geoffcloud.sh" "$tree/clone/scripts/"
  git -C "$tree/clone" add scripts
  git -C "$tree/clone" commit -qm init
  git -C "$tree/clone" push -q origin main
}

run_cases
