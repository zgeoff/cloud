#!/usr/bin/env bash
# Hermetic test for switch-geoffcloud.sh: a switch never builds a commit that no green NixOS
# checks run covers, nor one whose atc daemon pin differs in atc major from a running atc gateway
# pod's image, nor one whose impd the running nixie's imp client refuses, before the build or
# before the activation, never follows a failed build, activates the exact store path the build
# printed, built from the checked commit, records that commit beside the path on the host before
# the activation, never activates a build whose dry-activate would stop or restart k3s unless
# --allow-k3s-restart names a planned k3s window, and fails when nixie is not ready after it. Each case
# that switches commits its own nixos/packages/atc.nix and imp-host pin. gh also serves the nixie
# release's bun.lock, and the fake clock stands in for the readiness check's pause. It touches
# no host and runs no Nix: gh replays recorded answers (create-stub-gh.sh), the bun.lock from
# setup_test and the green runs each case that reaches the gate records, and docker
# and ssh are stand-ins from test-support/shell that log their argv as JSON lines (two cases hand them to the real docker and ssh, to fail on a
# missing daemon socket and a refused loopback port), and each case runs the script in
# its own temporary clone with its own origin, under `env -i` with only the variables it
# sets. Each case compares the script's whole stdout, stderr and call log, masking only
# the snapshot's temporary path.
#
#   bash scripts/test-switch-geoffcloud.sh
#   CASE='unknown argument' bash scripts/test-switch-geoffcloud.sh   # the cases whose title holds it
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-one-of-outputs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-clock.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-nix-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-nixos-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-racing-git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh"

recordings="$(cd "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/gh-recordings" && pwd)"

# The suite's own git calls (the arrange steps, outside `env -i`) read no repository,
# user or system setting from the caller's environment, and commit as a fixed identity.
while read -r name; do unset "$name"; done < <(compgen -e GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
  GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

# the call find-nixos-check-run.sh makes to list the green runs, which every switch makes first
gh_runs_call='["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","status=success","-f","per_page=100","--jq",".workflow_runs[] | select(.event == \"schedule\" or .event == \"workflow_dispatch\") | \"\\(.head_sha) \\(.html_url)\""]'

# the imp-host pin each case that switches commits, the impd that the nixie stand-in's client speaks
imp_host_pin='    image = "ghcr.io/zgeoff/imp-host:3.4.0@sha256:7f3e9c1a5b2d4e6f8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f";'
# the call check-nixie-impd-major.sh makes for the running nixie's lock, and nixie's ready report
nixie_lock_call='["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"]'
nixie_ready_call='["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]'
nixie_ready='{"status":"ready","parts":{"store":{"isReady":true},"imp_host":{"isReady":true}}}'
# the dry-activate of the built system on root@geoffcloud, which every switch that copies runs
dry_activate_call='["ssh","-o","BatchMode=yes","root@geoffcloud","NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE     -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud-dry-activate '"'"'/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration'"'"'     dry-activate"]'

it_activates_the_store_path_its_build_printed() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo committed > "$tree/clone/nixos/marker"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/marker nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  find "$tree/build-saw" -type f -printf '%P\n' | sort > "$tree/build-saw-files"
  diff - "$tree/build-saw-files" << 'EOF'
nixos/hosts/geoffcloud/configuration.nix
nixos/marker
nixos/packages/atc.nix
EOF
  diff - "$tree/build-saw/nixos/marker" <<< committed
  assert_status 0 "$status"
}

it_prints_the_failed_units_the_host_reports_after_the_switch() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
alloy.service loaded failed failed Alloy
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  assert_status 0 "$status"
}

it_switches_as_before_when_the_activation_restarts_other_units_but_not_k3s() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would stop the following units: alloy.service\nwould activate the configuration...\nwould restart the following units: atc-daemon.service, tailscaled.service\nwould start the following units: alloy.service, k3s-images.service' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  assert_status 0 "$status"
}

it_never_activates_a_build_whose_activation_would_stop_k3s() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would stop the following units: alloy.service, k3s.service\nwould activate the configuration...\nwould start the following units: alloy.service, k3s.service' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would stop the following units: alloy.service, k3s.service
switch in a planned k3s window with --allow-k3s-restart
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
EOF
  assert_status 1 "$status"
}

it_activates_a_build_that_restarts_k3s_in_a_planned_k3s_window() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would activate the configuration...\nwould restart the following units: k3s.service' \
    bash scripts/switch-geoffcloud.sh --allow-k3s-restart) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== k3s.service restarts in this planned k3s window (--allow-k3s-restart):
would restart the following units: k3s.service
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  assert_status 0 "$status"
}

it_never_activates_when_the_dry_activate_fails() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE_LOCKED=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'Could not acquire lock'
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
EOF
  assert_status 11 "$status"
}

it_builds_the_checked_commit_when_the_checkout_is_edited_during_the_build() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo committed > "$tree/clone/nixos/marker"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/marker nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_EDIT_DURING_BUILD="$tree/clone/nixos/marker" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  diff - "$tree/clone/nixos/marker" <<< edited
  diff - "$tree/build-saw/nixos/marker" <<< committed
  assert_status 0 "$status"
}

it_never_builds_an_untracked_file() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo committed > "$tree/clone/nixos/marker"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/marker nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  echo '{ }' > "$tree/clone/nixos/untracked.nix"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  find "$tree/build-saw" -type f -printf '%P\n' | sort > "$tree/build-saw-files"
  diff - "$tree/build-saw-files" << 'EOF'
nixos/hosts/geoffcloud/configuration.nix
nixos/marker
nixos/packages/atc.nix
EOF
  assert_status 0 "$status"
}

# The script reads HEAD once, while it checks; a commit landing after that check must not
# reach the build. Nothing but an interception lands it at that moment, so a git stand-in
# (test-support/shell/create-stub-racing-git.sh) commits right after the check's last read
# (rev-parse origin/main) and logs that it did.
it_builds_the_checked_commit_when_a_commit_lands_after_the_check() {
  local checked status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo committed > "$tree/clone/nixos/marker"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/marker nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  checked="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$checked https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"
  create_stub_racing_git "$tree/bin" "$(command -v git)" "$tree/clone" "$tree/calls"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${checked:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
["git-moved-head"]
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$checked /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  git -C "$tree/clone" log --format=%s -2 > "$tree/log"
  diff - "$tree/log" << 'EOF'
moved
marker
EOF
  git -C "$tree/clone" rev-parse HEAD~1 > "$tree/parent"
  diff - "$tree/parent" <<< "$checked"
  diff - "$tree/build-saw/nixos/marker" <<< committed
  assert_status 0 "$status"
}

it_builds_and_never_copies_with_build_only() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
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
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 0 "$status"
}

it_never_builds_or_switches_a_commit_that_no_green_nixos_run_covers() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -c '{argv: .}' <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
no green NixOS checks run covers ${commit:0:7}; start one with \`gh workflow run nixos-checks.yml --ref main\` and switch once it passes
EOF
  diff /dev/null "$tree/out"
  diff - "$tree/calls" <<< "$gh_runs_call"
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_never_builds_or_switches_a_commit_that_changed_nixos_after_the_last_green_run() {
  local checked commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo checked > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm checked
  checked="$(git -C "$tree/clone" rev-parse HEAD)"
  echo unchecked > "$tree/clone/nixos/marker"
  git -C "$tree/clone" commit -qam unchecked
  git -C "$tree/clone" push -q origin main
  # the one green run is on the commit before nixos/ changed
  jq -c --arg runs "$checked https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
no green NixOS checks run covers ${commit:0:7}; start one with \`gh workflow run nixos-checks.yml --ref main\` and switch once it passes
EOF
  diff /dev/null "$tree/out"
  diff - "$tree/calls" <<< "$gh_runs_call"
  assert_status 1 "$status"
}

it_never_builds_or_switches_when_gh_cannot_list_the_runs() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -c '{argv: ., stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'To get started with GitHub CLI, please run:  gh auth login'
  diff /dev/null "$tree/out"
  diff - "$tree/calls" <<< "$gh_runs_call"
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 4 "$status"
}

# cloud#207's skew: the bump pins daemon 4.5.0 while the cluster still runs gateway 2.27.0,
# whose atc_report_get sends report.get, which atc 4.0.0 renamed note.get
it_never_builds_or_switches_a_daemon_pin_a_major_release_ahead_of_the_deployed_gateway() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "4.5.0";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/out" <<< '== checked by https://github.com/zgeoff/cloud/actions/runs/1'
  diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

# a gateway rollout recreates its one pod, so for a while no gateway pod runs
it_never_builds_or_switches_while_no_gateway_pod_runs() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES= \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'no atc gateway pod runs, so the switch cannot tell which atc it speaks; wait for its rollout (kubectl -n atc rollout status deployment atc-gateway)'
  diff - "$tree/out" <<< '== checked by https://github.com/zgeoff/cloud/actions/runs/1'
  diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

# The check runs again after the copy, so a gateway rollout that lands during the build or the
# copy stops the switch before the activation (STUB_GATEWAY_LATER_IMAGES answers that check).
it_never_activates_when_the_gateway_moves_to_another_major_during_the_build() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_GATEWAY_LATER_IMAGES=ghcr.io/zgeoff/atc-gateway:4.5.0 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the switch would run atc 2.26.2 on the host, but an atc gateway pod runs atc 4.5.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 2.x image first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_never_builds_or_switches_an_impd_major_bump_ahead_of_the_running_nixies_imp_client() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "${imp_host_pin/3.4.0/4.0.0}" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 4.0.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the switch would run impd 4.0.0, but a nixie pod runs nixie 0.31.4, whose imp-client 3.2.1 refuses an impd of another major; deploy a nixie that speaks impd 4 first (docs/runbooks/workflows.md, Switch the host)'
  diff - "$tree/out" << 'EOF'
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
EOF
  diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
EOF
  [ ! -e "$tree/build-saw" ] || {
    echo "it built" >&2
    exit 1
  }
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_fails_the_switch_naming_each_part_when_nixie_is_not_ready_after_it() {
  local commit status=0 unready
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"
  unready='{"status":"unready","parts":{"store":{"isReady":true},"imp_host":{"isReady":false,"reason":"impd 3.4.0 refuses imp client 3.2.1"}}}'

  (cd "$tree/clone" && env -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$unready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'nixie is not ready after 30 tries: imp_host: impd 3.4.0 refuses imp client 3.2.1'
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
$(for _ in $(seq 1 30); do printf '%s\n' "$nixie_ready_call"; done)
EOF
  diff - "$tree/clock/pauses" <<< "$(for _ in $(seq 1 29); do echo 10; done)"
  assert_status 1 "$status"
}

it_never_builds_or_switches_a_commit_without_the_atc_daemon_pin() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" <<< 'SNAPSHOT/nixos/packages/atc.nix is missing, so the switch has no atc daemon pin to compare'
  diff - "$tree/out" <<< '== checked by https://github.com/zgeoff/cloud/actions/runs/1'
  diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

it_switches_the_host_that_the_environment_names() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    GEOFFCLOUD_HOST=root@other.test \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@other.test
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@other.test
== root@other.test runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@other.test","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
${dry_activate_call/root@geoffcloud/root@other.test}
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@other.test","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@other.test","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@other.test","systemctl","--failed","--no-legend","--plain"]
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]
EOF
  assert_status 0 "$status"
}

it_rejects_an_unknown_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh --switch) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
usage: switch-geoffcloud.sh [--build-only | --allow-k3s-restart]
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  assert_status 2 "$status"
}

it_never_builds_from_a_branch_other_than_main() {
  local status=0
  create_case_tree
  setup_test "$tree"
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
  assert_status 1 "$status"
}

it_never_builds_with_uncommitted_changes() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  echo edited > "$tree/clone/nixos/marker"

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
  assert_status 1 "$status"
}

it_never_builds_when_git_status_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
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
  assert_status 128 "$status"
}

it_never_builds_when_the_fetch_fails() {
  local status=0
  create_case_tree
  setup_test "$tree"
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
  assert_status 128 "$status"
}

it_never_builds_when_origin_main_has_moved_on() {
  local status=0
  create_case_tree
  setup_test "$tree"
  git clone -q "$tree/origin.git" "$tree/other"
  git -C "$tree/other" config maintenance.auto false
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
  assert_status 1 "$status"
}

it_never_builds_main_with_an_unpushed_commit() {
  local status=0
  create_case_tree
  setup_test "$tree"
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
  assert_status 1 "$status"
}

it_never_builds_when_the_commit_cannot_be_archived() {
  local blob status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  blob="$(git -C "$tree/clone" rev-parse HEAD:nixos/marker)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: invalid object 100644 $blob for 'nixos/marker'
error: cannot read '$blob'
EOF
  diff /dev/null "$tree/out"
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff /dev/null "$tree/calls-masked"
  assert_status 255 "$status"
}

it_leaves_no_snapshot_archive_behind_when_the_commit_cannot_be_archived() {
  local blob status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  blob="$(git -C "$tree/clone" rev-parse HEAD:nixos/marker)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  ls -A "$tree/tmp" > "$tree/tmp-files"
  diff /dev/null "$tree/tmp-files"
  diff - "$tree/err" << EOF
error: invalid object 100644 $blob for 'nixos/marker'
error: cannot read '$blob'
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  assert_status 255 "$status"
}

it_never_builds_outside_a_git_checkout() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/loose"
  cp "$tree/clone/scripts/switch-geoffcloud.sh" "$tree/clone/scripts/nix-image.sh" "$tree/loose/"

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
  assert_status 128 "$status"
}

it_never_switches_after_a_failed_build() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: builder for '/nix/store/x.drv' failed with exit code 1
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 1 "$status"
}

# The real docker CLI, behind the logging stand-in, with no daemon at its socket: docker
# 28.0.4 (CI's ubuntu-24.04 runner image 20261004) and 29.7.2 word that error differently,
# and 28 adds a help line and exits 125, so the case accepts either stderr with its status.
it_never_switches_when_docker_cannot_reach_its_daemon() {
  local commit status=0
  # under /tmp, not $TMPDIR: the real docker meets a socket in this tree, and a socket path
  # past 107 bytes, the most sun_path holds, makes docker 29.7.2 panic or print another error
  tree="$(mktemp -d -p /tmp)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_DOCKER_PASS=1 STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    DOCKER_HOST="unix://$tree/docker.sock" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  printf '== checked by https://github.com/zgeoff/cloud/actions/runs/1\n== atc 2.26.2 on the host, 2.27.0 in the gateway\n== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster\n== build %s\n' "${commit:0:7}" > "$tree/want-out"
  printf 'docker: Cannot connect to the Docker daemon at unix://%s/docker.sock. Is the docker daemon running?\n\nRun '"'"'docker run --help'"'"' for more information\n' "$tree" > "$tree/err-docker-28"
  printf 'failed to connect to the docker API at unix://%s/docker.sock; check if the path is correct and if the daemon is running: dial unix %s/docker.sock: connect: no such file or directory\n' "$tree" "$tree" > "$tree/err-docker-29"
  # set -e passes docker's status through: 125 from docker 28.0.4, 1 from docker 29.7.2
  assert_one_of_outputs "the switch without a docker daemon" "$tree/out" "$tree/err" "$status" \
    "docker 28.0.4" "$tree/want-out" "$tree/err-docker-28" 125 \
    "docker 29.7.2" "$tree/want-out" "$tree/err-docker-29" 1
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
}

it_never_switches_when_the_build_prints_no_system_path() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_BUILD_OUT='warning: x' STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the build printed no system path: warning: x
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  assert_status 1 "$status"
}

# The copy runs nix inside the pinned Nix image, which no hermetic case can start, so
# the docker stand-in fails it (STUB_COPY_ERROR).
it_never_activates_when_the_copy_fails() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
error: cannot connect to 'root@geoffcloud'
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
EOF
  assert_status 1 "$status"
}

# The real ssh, behind the logging stand-in, refused by a loopback port where nothing
# listens. The gateway query is the switch's first call to the host, so an unreachable host
# stops the switch before the build.
it_never_builds_and_stops_with_ssh_exit_255_when_the_host_is_unreachable() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_PASS=1 GEOFFCLOUD_HOST=ssh://root@127.0.0.1:1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/out" <<< '== checked by https://github.com/zgeoff/cloud/actions/runs/1'
  diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  diff /dev/null "$tree/tmp-left"
  assert_status 255 "$status"
}

it_stops_with_the_activation_exit_code_when_switch_to_configuration_fails() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_ACTIVATE_FAILED_UNITS=atc-daemon.service \
    STUB_ACTIVATE_STATUS=$'× atc-daemon.service - atc daemon\n     Active: failed (Result: exit-code)' \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
warning: the following units failed: atc-daemon.service
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
× atc-daemon.service - atc daemon
     Active: failed (Result: exit-code)
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
EOF
  assert_status 4 "$status"
}

# Only an interception drops an open session at the readlink check, so the ssh stand-in
# does it (STUB_SSH_DROP_AT_READLINK).
it_stops_with_ssh_exit_255_when_the_connection_drops_before_the_check() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_DROP_AT_READLINK=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< $'Connection to geoffcloud closed by remote host.\r'
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
  assert_status 255 "$status"
}

it_fails_when_the_host_runs_another_system_after_the_switch() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the host runs /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old, not the built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
  assert_status 1 "$status"
}

it_fails_with_systemctls_exit_code_when_listing_failed_units_fails() {
  local commit status=0
  create_case_tree
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  mkdir -p "$tree/clone/nixos/hosts/geoffcloud"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  (cd "$tree/clone" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_EXIT=1 \
    bash scripts/switch-geoffcloud.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Failed to list units: Connection timed out
EOF
  diff - "$tree/out" << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
["ssh","-o","BatchMode=yes","root@geoffcloud","systemctl","--failed","--no-legend","--plain"]
EOF
  assert_status 1 "$status"
}

# Boot data every case needs: a clone of a bare origin whose main holds one empty commit,
# the script under test and the pin it reads copied into the clone untracked (they run from
# there, and the check and the build ignore untracked files), and the docker, ssh and gh stand-ins
# (test-support/shell/create-stub-nix-docker.sh, test-support/shell/create-stub-nixos-ssh.sh,
# test-support/shell/create-stub-gh.sh), which log each call's argv as a JSON line to the one
# call log, <tree>/calls, and end with exit 97 on a call they do not know;
# fail-closed stand-ins for scp, sftp, rsync and tailscale; and a guard that ends the case
# unless every remote tool resolves to a stand-in, so no call reaches a real host.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/clock" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_clock "$tree/clock"
  create_stub_nix_docker "$tree/bin"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
  # boot data: the running nixie's bun.lock holds imp-client 3.2.1; each case that reaches the
  # NixOS checks gate appends its answer to the runs call
  jq -cn --argjson argv "$nixie_lock_call" --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" \
    '{argv: $argv, stdout_file: $lock}' > "$tree/gh-responses"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  # no auto maintenance: a commit's, a fetch's or a push's detached repack could still write into
  # a repository while the case's trap removes it
  git -C "$tree/origin.git" config maintenance.auto false
  git -C "$tree/clone" config maintenance.auto false
  git -C "$tree/clone" commit -q --allow-empty -m init
  git -C "$tree/clone" push -q origin main
  mkdir "$tree/clone/scripts" "$tree/clone/.github"
  cp "$(dirname "${BASH_SOURCE[0]}")/switch-geoffcloud.sh" "$(dirname "${BASH_SOURCE[0]}")/nix-image.sh" \
    "$(dirname "${BASH_SOURCE[0]}")/find-nixos-check-run.sh" \
    "$(dirname "${BASH_SOURCE[0]}")/check-atc-gateway-skew.sh" "$(dirname "${BASH_SOURCE[0]}")/check-nixie-impd-major.sh" \
    "$(dirname "${BASH_SOURCE[0]}")/check-nixie-ready.sh" "$(dirname "${BASH_SOURCE[0]}")/check-k3s-restart.sh" \
    "$tree/clone/scripts/"
  # the gate filter that find-nixos-check-run.sh runs with the real bun, its modules and its manifest
  cp "$(dirname "${BASH_SOURCE[0]}")"/{run-decide-gates,load-gate-manifest,needs-gate,exit-error,run-or-exit,run-process,with-exit-code}.ts \
    "$tree/clone/scripts/"
  cp "$(dirname "${BASH_SOURCE[0]}")/../.github/gates.yml" "$tree/clone/.github/"
  ln -s "$(command -v bun)" "$tree/bin/bun"
}

run_cases
