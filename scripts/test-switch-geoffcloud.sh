#!/usr/bin/env bash
# Hermetic test for switch-geoffcloud.sh: a switch never follows a failed build, and it
# activates the exact store path the build printed, built from the checked commit. It
# touches no host and runs no Nix: docker and ssh are stubs that log their argv as JSON
# lines, and each case runs the script in its own temporary clone with its own origin,
# under `env -i` with only the variables it sets.
#
#   bash scripts/test-switch-geoffcloud.sh
#   CASE='unknown argument' bash scripts/test-switch-geoffcloud.sh   # the cases whose title holds it
set -euo pipefail

# the suite's own git calls read no user or system config and commit as a fixed identity
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

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
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
  diff - <(sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls") << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","nixos/nix","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","nixos/nix","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  diff - <(cd "$tree/build-saw" && find . -type f | sort) << 'EOF'
./nixos/marker
./scripts/switch-geoffcloud.sh
EOF
  diff - "$tree/build-saw/nixos/marker" <<< committed
  diff /dev/null <(ls -A "$tree/tmp")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_the_failed_units_the_host_reports_after_the_switch() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - <(tail -n 2 "$tree/out") << 'EOF'
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
alloy.service loaded failed failed Alloy
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

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_EDIT_DURING_BUILD="$tree/clone/nixos/marker" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/clone/nixos/marker" <<< edited
  diff - "$tree/build-saw/nixos/marker" <<< committed
  diff - <(head -n 1 "$tree/out") <<< "== build ${commit:0:7}"
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
docker /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
ssh nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch
ssh /run/current-system
ssh --plain
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_never_builds_an_untracked_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  echo '{ }' > "$tree/clone/nixos/untracked.nix"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - <(cd "$tree/build-saw" && find . -type f | sort) << 'EOF'
./nixos/marker
./scripts/switch-geoffcloud.sh
EOF
  diff - <(jq -r '.[0]' "$tree/calls") << 'EOF'
docker
docker
ssh
ssh
ssh
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

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - <(jq -r '.[0]' "$tree/calls") << 'EOF'
git-moved-head
docker
docker
ssh
ssh
ssh
EOF
  diff - <(git -C "$tree/clone" log --format=%s -2) << 'EOF'
moved
marker
EOF
  diff - <(git -C "$tree/clone" rev-parse HEAD~1) <<< "$checked"
  diff - <(head -n 1 "$tree/out") <<< "== build ${checked:0:7}"
  diff - "$tree/build-saw/nixos/marker" <<< committed
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_builds_and_never_copies_with_build_only() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --build-only) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
EOF
  diff /dev/null <(ls -A "$tree/tmp")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_switches_the_host_that_the_environment_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" GEOFFCLOUD_HOST=root@other.test \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - <(jq -r 'if .[0] == "ssh" then .[0] + " " + .[3] else .[0] + " " + .[-2] end' "$tree/calls") << 'EOF'
docker --print-out-paths
docker ssh://root@other.test
ssh root@other.test
ssh root@other.test
ssh root@other.test
EOF
  diff - <(sed -n '3,4p;5s/ runs .*//p' "$tree/out") << 'EOF'
== copy to root@other.test
== switch root@other.test
== root@other.test
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_an_unknown_argument_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh --switch) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'usage: switch-geoffcloud.sh [--build-only]'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_never_builds_from_a_branch_other_than_main() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  git -C "$tree/clone" checkout -q -b topic

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'switch from main, not topic'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  diff /dev/null <(ls -A "$tree/tmp")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_with_uncommitted_changes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '# local edit' >> "$tree/clone/scripts/switch-geoffcloud.sh"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the checkout has uncommitted changes'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_when_git_status_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  head -c 64 /dev/zero | tr "\\0" x > "$tree/clone/.git/index"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
error: bad signature 0x78787878
fatal: index file corrupt
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 128 ] || { echo "exit $status, want 128" >&2; exit 1; }
}

it_never_builds_when_the_fetch_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  mv "$tree/origin.git" "$tree/origin-gone.git"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
fatal: '$tree/origin.git' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
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

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'main is not origin/main; pull first'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_main_with_an_unpushed_commit() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  git -C "$tree/clone" commit -q --allow-empty -m unpushed

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'main is not origin/main; pull first'
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_builds_when_the_commit_cannot_be_archived() {
  local blob status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  blob="$(git -C "$tree/clone" rev-parse HEAD:scripts/switch-geoffcloud.sh)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: invalid object 100644 $blob for 'scripts/switch-geoffcloud.sh'
error: cannot read '$blob'
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_never_switches_after_a_failed_build() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "error: builder for '/nix/store/x.drv' failed with exit code 1"
  diff - "$tree/out" <<< "== build ${commit:0:7}"
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
EOF
  diff /dev/null <(ls -A "$tree/tmp")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_switches_when_docker_cannot_reach_its_daemon() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" STUB_DOCKER_DOWN=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
docker: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
EOF
  diff - "$tree/out" <<< "== build ${commit:0:7}"
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
EOF
  [ "$status" = 125 ] || { echo "exit $status, want 125" >&2; exit 1; }
}

it_never_switches_when_the_build_prints_no_system_path() {
  local commit status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_BUILD_OUT='warning: x' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the build printed no system path: warning: x'
  diff - "$tree/out" <<< "== build ${commit:0:7}"
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_never_activates_when_the_copy_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "error: cannot connect to 'root@geoffcloud'"
  diff - <(tail -n 1 "$tree/out") <<< '== copy to root@geoffcloud'
  diff - <(jq -r '.[0] + " " + .[-1]' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
docker /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_ssh_exit_255_when_the_host_is_unreachable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_SSH_DOWN=1 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'ssh: connect to host geoffcloud port 22: Connection refused'
  diff - <(tail -n 1 "$tree/out") <<< '== switch root@geoffcloud'
  diff - <(jq -r '.[0]' "$tree/calls") << 'EOF'
docker
docker
ssh
EOF
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_fails_when_the_host_runs_another_system_after_the_switch() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
the host runs /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old, not the built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  diff - <(jq -r '.[0] + " " + if .[0] == "ssh" then .[4] | split(" ")[0] else .[-1] end' "$tree/calls") << 'EOF'
docker path:./nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel
docker /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
ssh nix-env
ssh readlink
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Boot data every case needs: a clone of a bare origin whose main holds the script under
# test, and docker and ssh stand-ins that log each call's argv as a JSON line to STUB_LOG.
setup_case() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  # docker: a build copies its /src mount to STUB_BUILD_SAW (after the optional edit of
  # STUB_EDIT_DURING_BUILD, so a build of the working tree would see the edit), then fails
  # with STUB_BUILD_ERROR (nix's exit 1) or prints STUB_BUILD_OUT; a copy fails with
  # STUB_COPY_ERROR; STUB_DOCKER_DOWN fails every call as docker does with no daemon (125)
  cat > "$tree/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ -n "${STUB_DOCKER_DOWN:-}" ]; then
  echo "docker: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
  exit 125
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
EOF
  # ssh: answers the three remote commands the switch runs; STUB_CURRENT is the host's
  # current system, STUB_FAILED_UNITS its failed units; STUB_SSH_DOWN refuses every
  # connection with ssh's own exit code, 255
  cat > "$tree/bin/ssh" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ -n "${STUB_SSH_DOWN:-}" ]; then
  echo "ssh: connect to host ${3#*@} port 22: Connection refused" >&2
  exit 255
fi
case "${*:4}" in
  "nix-env -p /nix/var/nix/profiles/system --set "*"/bin/switch-to-configuration' switch") ;;
  "readlink /run/current-system") printf '%s\n' "$STUB_CURRENT" ;;
  "systemctl --failed --no-legend --plain") [ -z "${STUB_FAILED_UNITS:-}" ] || printf '%s\n' "$STUB_FAILED_UNITS" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
EOF
  chmod +x "$tree/bin/docker" "$tree/bin/ssh"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  mkdir "$tree/clone/scripts"
  cp "$(dirname "${BASH_SOURCE[0]}")/switch-geoffcloud.sh" "$tree/clone/scripts/"
  git -C "$tree/clone" add scripts
  git -C "$tree/clone" commit -qm init
  git -C "$tree/clone" push -q origin main
}

# Runs each it_* function (or those whose title holds $CASE) in its own background
# subshell, so errexit holds inside it, and prints ok or FAIL with the case's output. A
# case leaves its tree variable out of `local`, so its EXIT trap still sees it.
run_cases() {
  local fn title log status failures=0 ran=0
  log="$(mktemp)"
  for fn in $(compgen -A function it_); do
    title="${fn//_/ }"
    [[ "$title" == *"${CASE:-}"* ]] || continue
    ran=$((ran + 1))
    (
      set -euo pipefail
      "$fn"
    ) > "$log" 2>&1 &
    status=0
    wait "$!" || status=$?
    if [ "$status" = 0 ]; then
      echo "ok $title"
    else
      echo "FAIL $title (exit $status)"
      sed 's/^/    /' "$log"
      failures=$((failures + 1))
    fi
  done
  rm -f "$log"
  echo "$ran cases, $failures failed"
  [ "$ran" -gt 0 ] && [ "$failures" = 0 ] || exit 1
}

run_cases
