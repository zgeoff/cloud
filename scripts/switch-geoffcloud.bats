#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Hermetic test for switch-geoffcloud.sh: a switch never builds a commit that no green NixOS
# checks run covers, nor one whose atc daemon pin differs in atc major from a running atc gateway
# pod's image, nor one whose impd the running nixie's imp client refuses, before the build or
# before the activation, nor one whose impd stores a secret kind its atc daemon pin lacks, never
# follows a failed build, activates the exact store path the build printed, built from the checked
# commit, records that commit beside the path on the host before the activation, never activates a
# build whose dry-activate would stop or restart k3s unless --allow-k3s-restart names a planned k3s
# window, and fails when nixie is not ready after it, when an impd image record's build folder is
# gone, or when the host reserved fewer hugetlb pages than its system configures, and in the pool's
# window (--stop-ordinary-page-imps) stops each imp on 4 KiB pages in its stop order. Only a
# switch that passes every check moves origin's deployed/host tag to the switched commit, and one
# whose push origin refuses fails with the command that moves the tag. Each case
# that switches commits its own nixos/packages/atc.nix and imp-host pin. gh also serves the nixie
# release's bun.lock and the impd and atc sources that hold their secret kinds, and the fake clock
# stands in for the readiness check's pause. It touches no host and runs no Nix: gh replays
# recorded answers (create-stub-gh.sh), the bun.lock and the kind sources from setup_test and the
# green runs each case that reaches the gate records, and docker
# and ssh are stand-ins from scripts/src/test-utils/shell that log their argv as JSON lines (two cases hand them to the real docker and ssh, to fail on a
# missing daemon socket and a refused loopback port), and each case runs the script in
# its own temporary clone with its own origin, under `env -i` with only the variables it
# sets. Each case compares the script's whole stdout, stderr and call log, masking only
# the snapshot's temporary path.
#
#   bash scripts/run-bats.sh
#   CASE='unknown argument' bash scripts/run-bats.sh   # the cases whose title holds it

# shellcheck disable=SC2030,SC2031 # the docker socket case moves its own tree under /tmp

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-clock.sh'
  load 'src/test-utils/shell/create-stub-nix-docker.sh'
  load 'src/test-utils/shell/create-stub-nixos-ssh.sh'
  load 'src/test-utils/shell/create-stub-racing-git.sh'
  load 'src/test-utils/shell/create-stub-gh.sh'
  load 'src/test-utils/shell/gh-nixos-pr-calls.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  load 'nix-image.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  recordings="$(cd "$BATS_TEST_DIRNAME/../scripts/src/test-utils/shell/gh-recordings" && pwd)"
  # The suite's own git calls (the arrange steps, outside `env -i`) read no repository,
  # user or system setting from the caller's environment, and commit as a fixed identity.
  while read -r name; do unset "$name"; done < <(compgen -e GIT_)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_COMMITTER_NAME=test \
    GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
  # the call find-nixos-check-run.sh makes to list the green runs, which every switch makes first
  gh_runs_call='["gh","api","-X","GET","repos/{owner}/{repo}/actions/workflows/nixos-checks.yml/runs","-f","branch=main","-f","per_page=100","--jq",".workflow_runs[] | select(.conclusion == \"success\" and (.event == \"schedule\" or .event == \"workflow_dispatch\")) | \"\\(.head_sha) \\(.html_url)\""]'
  # the imp-host pin each case that switches commits, the impd that the nixie stand-in's client speaks
  imp_host_pin='    image = "ghcr.io/zgeoff/imp-host:3.4.0@sha256:7f3e9c1a5b2d4e6f8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f";'
  # the call check-nixie-impd-major.sh makes for the running nixie's lock, and nixie's ready report
  nixie_lock_call='["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/nixie/contents/bun.lock?ref=v0.31.4"]'
  nixie_ready_call='["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie health"]'
  nixie_ready='{"status":"ready","parts":{"store":{"isReady":true},"imp_host":{"isReady":true}}}'
  # the calls check-atc-secret-kinds.sh makes for impd 3.4.0's stored kinds and atc 2.26.2's accepted
  # kinds, and the line it prints, from the recordings setup_test serves for them
  kinds_calls='["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/impz/contents/packages/api/src/schemas/secret-schema.ts?ref=v3.4.0"]
["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/atc/contents/packages/plugin-api/src/credentials/credential-broker.ts?ref=%40zgeoff/atc%402.26.2"]'
  kinds_line='== impd 3.4.0 stores the secret kinds github, anthropic, npm, custom, oauth, which atc 2.26.2 accepts'
  # the image listing check-impd-image-dirs.sh runs after nixie reports ready
  images_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz image ls --json"]'
  # the imp listing and the page-size loop stop-ordinary-page-imps.sh runs in the pool's window
  imps_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz ls --json --builders"]'
  # shellcheck disable=SC2016 # $d, $s and $v are the remote shell's variables, as the call log records them
  pages_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c '"'"'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/snapshot/meta.json\" && s=2M; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/vm.json\" && v=2M; echo \"$d $s $v\"; done'"'"'"]'
  # the pool query check-hugetlb-pool.sh runs after the image check
  pool_call='["ssh","-o","BatchMode=yes","root@geoffcloud","sysctl -n vm.nr_hugepages; sed -n '"'"'s/^vm\\.nr_hugepages=//p'"'"' /etc/sysctl.d/60-nixos.conf"]'
  # the dry-activate of the built system on root@geoffcloud, which every switch that copies runs
  dry_activate_call='["ssh","-o","BatchMode=yes","root@geoffcloud","NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE     -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud-dry-activate '"'"'/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration'"'"'     dry-activate"]'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
  if [ -n "${socket_tree:-}" ]; then rm -rf "$socket_tree" || true; fi
}

# Boot data every case needs: a clone of a bare origin whose main holds one empty commit,
# the script under test and the pin it reads copied into the clone untracked (they run from
# there, and the check and the build ignore untracked files), and the docker, ssh and gh stand-ins
# (scripts/src/test-utils/shell/create-stub-nix-docker.sh, scripts/src/test-utils/shell/create-stub-nixos-ssh.sh,
# scripts/src/test-utils/shell/create-stub-gh.sh), which log each call's argv as a JSON line to the one
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
  # boot data: the running nixie's bun.lock holds imp-client 3.2.1, and impd 3.4.0's secret schema
  # and atc 2.26.2's broker kinds are impd 4.2.4's and atc 7.3.0's, which accept each other; each
  # case that reaches the NixOS checks gate appends its answer to the runs call
  jq -cn --argjson argv "$nixie_lock_call" --arg lock "$recordings/nixie-bun-lock-imp-client-3.2.1.lock" \
    '{argv: $argv, stdout_file: $lock}' > "$tree/gh-responses"
  jq -c --arg schema "$recordings/impz-secret-schema-4.2.4.txt" \
    --arg broker "$recordings/atc-credential-broker-7.3.0.txt" \
    '[{argv: .[0], stdout_file: $schema}, {argv: .[1], stdout_file: $broker}][]' \
    <<< "[$(paste -sd, - <<< "$kinds_calls")]" >> "$tree/gh-responses"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  git init -q --bare -b main "$tree/origin.git"
  git clone -q "$tree/origin.git" "$tree/clone" 2> /dev/null
  # no auto maintenance: a commit's, a fetch's or a push's detached repack could still write into
  # a repository while bats removes the case tree
  git -C "$tree/origin.git" config maintenance.auto false
  git -C "$tree/clone" config maintenance.auto false
  git -C "$tree/clone" commit -q --allow-empty -m init
  git -C "$tree/clone" push -q origin main
  mkdir "$tree/clone/scripts" "$tree/clone/.github"
  cp "$BATS_TEST_DIRNAME/switch-geoffcloud.sh" "$BATS_TEST_DIRNAME/nix-image.sh" \
    "$BATS_TEST_DIRNAME/find-nixos-check-run.sh" \
    "$BATS_TEST_DIRNAME/check-atc-gateway-skew.sh" "$BATS_TEST_DIRNAME/check-nixie-impd-major.sh" \
    "$BATS_TEST_DIRNAME/check-nixie-ready.sh" "$BATS_TEST_DIRNAME/check-k3s-restart.sh" \
    "$BATS_TEST_DIRNAME/check-atc-secret-kinds.sh" "$BATS_TEST_DIRNAME/check-impd-image-dirs.sh" \
    "$BATS_TEST_DIRNAME/check-hugetlb-pool.sh" "$BATS_TEST_DIRNAME/stop-ordinary-page-imps.sh" \
    "$tree/clone/scripts/"
  # the gate filter that find-nixos-check-run.sh runs with the real bun, its modules and its manifest
  cp "$BATS_TEST_DIRNAME"/{run-decide-gates,load-gate-manifest,is-gate-needed,exit-error,run-or-exit,run-process,with-exit-code}.ts \
    "$tree/clone/scripts/"
  cp "$BATS_TEST_DIRNAME/../.github/gates.yml" "$tree/clone/.github/"
  ln -s "$(command -v bun)" "$tree/bin/bun"
}

@test "it activates the store path its build printed" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
  find "$tree/build-saw" -type f -printf '%P\n' > "$tree/build-saw-found"
  sort "$tree/build-saw-found" > "$tree/build-saw-files"
  run -0 diff - "$tree/build-saw-files" << 'EOF'
nixos/hosts/geoffcloud/configuration.nix
nixos/marker
nixos/packages/atc.nix
EOF
  run -0 diff - "$tree/build-saw/nixos/marker" <<< committed
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$commit"
}

@test "it moves deployed host from an earlier commit to the switched one" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$commit"
}

@test "it fails naming the command that moves deployed host when origin refuses the tag" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  # a pre-receive hook that refuses every tag, as a ruleset on tags would
  mkdir -p "$tree/origin.git/hooks"
  cat > "$tree/origin.git/hooks/pre-receive" << 'EOF'
#!/bin/sh
while read -r _ _ ref; do case "$ref" in refs/tags/*) exit 1 ;; esac; done
EOF
  chmod +x "$tree/origin.git/hooks/pre-receive"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin atc'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
To $tree/origin.git
 ! [remote rejected] $commit -> deployed/host (pre-receive hook declined)
error: failed to push some refs to '$tree/origin.git'
root@geoffcloud runs ${commit:0:7}, but deployed/host did not move; move it with \`git push --force origin $commit:refs/tags/deployed/host\`
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
EOF

  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it prints the failed units the host reports after the switch" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_UNITS='alloy.service loaded failed failed Alloy' \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
alloy.service loaded failed failed Alloy
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
}

@test "it switches as before when the activation restarts other units but not k3s" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would stop the following units: alloy.service\nwould activate the configuration...\nwould restart the following units: atc-daemon.service, tailscaled.service\nwould start the following units: alloy.service, k3s-images.service' \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
}

@test "it never activates a build whose activation would stop k3s" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would stop the following units: alloy.service, k3s.service\nwould activate the configuration...\nwould start the following units: alloy.service, k3s.service' \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << 'EOF'
the switch would interrupt k3s.service, and nixie can stay down for minutes after it:
would stop the following units: alloy.service, k3s.service
switch in a planned k3s window with --allow-k3s-restart
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
EOF
}

@test "it activates a build that restarts k3s in a planned k3s window" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE=$'would activate the configuration...\nwould restart the following units: k3s.service' \
    bash scripts/switch-geoffcloud.sh --allow-k3s-restart

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
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
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
}

@test "it never activates when the dry activate fails" {
  local commit
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

  run -11 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_DRY_ACTIVATE_LOCKED=1 \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'Could not acquire lock'
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
EOF
}

@test "it builds the checked commit when the checkout is edited during the build" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_EDIT_DURING_BUILD="$tree/clone/nixos/marker" \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
  run -0 diff - "$tree/clone/nixos/marker" <<< edited
  run -0 diff - "$tree/build-saw/nixos/marker" <<< committed
}

@test "it never builds an untracked file" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
  find "$tree/build-saw" -type f -printf '%P\n' > "$tree/build-saw-found"
  sort "$tree/build-saw-found" > "$tree/build-saw-files"
  run -0 diff - "$tree/build-saw-files" << 'EOF'
nixos/hosts/geoffcloud/configuration.nix
nixos/marker
nixos/packages/atc.nix
EOF
}

# The script reads HEAD once, while it checks; a commit landing after that check must not
# reach the build. Nothing but an interception lands it at that moment, so a git stand-in
# (scripts/src/test-utils/shell/create-stub-racing-git.sh) commits right after the check's last read
# (rev-parse origin/main) and logs that it did.
@test "it builds the checked commit when a commit lands after the check" {
  local checked
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${checked:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud configures no hugetlb pool
== deployed/host moved to $checked
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["git-moved-head"]
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
$images_call
$pool_call
EOF
  git -C "$tree/clone" log --format=%s -2 > "$tree/log"
  run -0 diff - "$tree/log" << 'EOF'
moved
marker
EOF
  git -C "$tree/clone" rev-parse HEAD~1 > "$tree/parent"
  run -0 diff - "$tree/parent" <<< "$checked"
  run -0 diff - "$tree/build-saw/nixos/marker" <<< committed
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$checked"
}

@test "it builds and never copies with build only" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --build-only

  refute_stderr
  assert_output - << EOF
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never builds or switches a commit that no green nixos run covers" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  # no green run: the --jq filter prints nothing
  jq -c '{argv: .}' <<< "$gh_runs_call" >> "$tree/gh-responses"
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
no green NixOS checks run covers ${commit:0:7}; start one with \`gh workflow run nixos-checks.yml --ref main\` and switch once it passes
EOF
  refute_output

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
$(gh_pulls_call "$commit")
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never builds or switches a commit that changed nixos after the last green run" {
  local checked commit
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
  gh_pulls_call "$commit" | jq -c '{argv: .}' >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
no green NixOS checks run covers ${commit:0:7}; start one with \`gh workflow run nixos-checks.yml --ref main\` and switch once it passes
EOF
  refute_output

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
$(gh_pulls_call "$commit")
EOF
}

@test "it never builds or switches when gh cannot list the runs" {
  setup_test "$tree"
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 4 when gh needs
  # authentication
  jq -c '{argv: ., stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exit: 4}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -4 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'To get started with GitHub CLI, please run:  gh auth login'
  refute_output

  run -0 diff - "$tree/calls" <<< "$gh_runs_call"
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

# cloud#207's skew: the bump pins daemon 4.5.0 while the cluster still runs gateway 2.27.0,
# whose atc_report_get sends report.get, which atc 4.0.0 renamed note.get
@test "it never builds or switches a daemon pin a major release ahead of the deployed gateway" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0@sha256:b53896a326e7c407167a5973736526b68ca6f30500d00558f1a7350869d91867 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'the switch would run atc 4.5.0 on the host, but an atc gateway pod runs atc 2.27.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 4.x image first (docs/runbooks/workflows.md, Switch the host)'
  assert_output '== checked by https://github.com/zgeoff/cloud/actions/runs/1'

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

# a gateway rollout recreates its one pod, so for a while no gateway pod runs
@test "it never builds or switches while no gateway pod runs" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES= \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'no atc gateway pod runs, so the switch cannot tell which atc it speaks; wait for its rollout (kubectl -n atc rollout status deployment atc-gateway)'
  assert_output '== checked by https://github.com/zgeoff/cloud/actions/runs/1'

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

# The check runs again after the copy, so a gateway rollout that lands during the build or the
# copy stops the switch before the activation (STUB_GATEWAY_LATER_IMAGES answers that check).
@test "it never activates when the gateway moves to another major during the build" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_GATEWAY_LATER_IMAGES=ghcr.io/zgeoff/atc-gateway:4.5.0 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'the switch would run atc 2.26.2 on the host, but an atc gateway pod runs atc 4.5.0, and atc changes its daemon protocol in a major release; deploy an atc-gateway 2.x image first (docs/runbooks/workflows.md, Switch the host)'
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never builds or switches an impd major that the running nixie does not accept" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'the switch would run impd 4.0.0, but a nixie pod runs nixie 0.31.4 (imp-client 3.2.1), which accepts impd 3 only; deploy a nixie that speaks impd 4 first (docs/runbooks/workflows.md, Switch the host)'
  assert_output - << 'EOF'
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
EOF

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
EOF
  refute [ -e "$tree/build-saw" ]
  refute [ -L "$tree/build-saw" ]
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never builds or switches an impd that stores a secret kind the atc pin lacks" {
  local commit
  setup_test "$tree"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  # impd 3.4.0's schema answers as impd 5.0.0's, which stores `static`; the first line that
  # matches answers, so it goes before setup_test's answer
  jq -cn --argjson argv "$(head -n 1 <<< "$kinds_calls")" \
    --arg schema "$recordings/impz-secret-schema-5.0.0.txt" \
    '{argv: $argv, stdout_file: $schema}' > "$tree/gh-responses-first"
  cat "$tree/gh-responses-first" "$tree/gh-responses" > "$tree/gh-responses-both"
  mv "$tree/gh-responses-both" "$tree/gh-responses"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'the switch would run impd 3.4.0, which stores the secret kind static, but atc 2.26.2 on the host accepts anthropic, custom, github, npm, oauth only; pin an atc that accepts static first (nixos/packages/atc.nix)'
  assert_output - << 'EOF'
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
EOF

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
EOF
  refute [ -e "$tree/build-saw" ]
  refute [ -L "$tree/build-saw" ]
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it fails the switch naming the image record whose build folder is gone" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_IMPD_IMAGES='[{"id":"img_1","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:3.4.0","digest":"imp-build-5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592","source":"oci","createdAt":"2026-10-20T08:00:00.000Z","sizeBytes":1048576,"pinned":true}]' \
    STUB_IMPD_IMAGE_DIRS=imp-build-9e107d9d372bb6826bd81d3542a419d69e107d9d372bb6826bd81d3542a419d6 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << 'EOF'
impd's image pv-base points at /var/lib/imp/images/imp-build-5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592, which holds no rootfs.ext4
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
EOF

  tail -n 2 "$tree/calls" > "$tree/calls-last"
  run -0 diff - "$tree/calls-last" << EOF
$images_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c 'cd /var/lib/imp/images && for d in *; do if [ -f \"\$d/rootfs.ext4\" ]; then echo \"\$d\"; fi; done'"]
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it fails the switch naming both counts when the host reserved a short hugetlb pool" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_HUGETLB_RESERVED=7000 STUB_HUGETLB_CONFIGURED=10240 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr "root@geoffcloud reserved 7000 of its 10240 hugetlb pages, so impd refuses each boot and wake past them; reboot the host, which reserves the whole pool early in boot, then switch again"
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
EOF

  tail -n 2 "$tree/calls" > "$tree/calls-last"
  run -0 diff - "$tree/calls-last" << EOF
$images_call
$pool_call
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it stops each imp on 4 kib pages in its stop order before the activation in the pool window" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_HUGETLB_RESERVED=10240 STUB_HUGETLB_CONFIGURED=10240 \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"sleeping"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K' IMP_STOP_ORDER=teapot \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --stop-ordinary-page-imps

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== stop order on root@geoffcloud: teapot, anvil
== stop teapot: its sleeping guest is on 4 KiB pages
== stop anvil: its sleeping guest is on 4 KiB pages
== stopped 2 imps; each keeps its disk and boots cold on the pool at its next use
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@geoffcloud reserved its whole hugetlb pool: 10240 pages
== deployed/host moved to $commit
EOF

  # the stop step's calls, the activation and the pool query, in the order the switch made them
  grep -E 'impz (ls|stop)|/var/lib/imp/imps|switch-to-configuration'"'"' switch|vm\.nr_hugepages' "$tree/calls" \
    > "$tree/calls-order"
  run -0 diff - "$tree/calls-order" << EOF
$imps_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
$pool_call
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$commit"
}

@test "it never activates and stops no imp while an image builder runs on 4 kib pages in the pool window" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping","kind":"user"},{"id":"imp_2","name":"imp-build-k7m2q9xw","state":"running","kind":"builder"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K' \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --stop-ordinary-page-imps

  assert_stderr - << 'EOF'
image builder imp-build-k7m2q9xw: its running guest is on 4 KiB pages, and impz stop does not take a builder
wait for each build to end, then run this again
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
EOF

  # the stop step's calls, the activation and the pool query, in the order the switch made them
  grep -E 'impz (ls|stop)|/var/lib/imp/imps|switch-to-configuration'"'"' switch|vm\.nr_hugepages' "$tree/calls" \
    > "$tree/calls-order"
  run -0 diff - "$tree/calls-order" << EOF
$imps_call
$pages_call
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it stops each imp on 4 kib pages before the activation and fails with a reboot when the pool is short" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
  mkdir -p "$tree/clone/nixos/packages" "$tree/clone/nixos/hosts/geoffcloud"
  echo '  version = "2.26.2";' > "$tree/clone/nixos/packages/atc.nix"
  echo "$imp_host_pin" > "$tree/clone/nixos/hosts/geoffcloud/configuration.nix"
  git -C "$tree/clone" add nixos/packages/atc.nix nixos/hosts/geoffcloud/configuration.nix
  git -C "$tree/clone" commit -qm 'pin imp 3.4.0'
  git -C "$tree/clone" push -q origin main
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_HUGETLB_RESERVED=7000 STUB_HUGETLB_CONFIGURED=10240 \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K' \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh --stop-ordinary-page-imps

  assert_stderr "root@geoffcloud reserved 7000 of its 10240 hugetlb pages, so impd refuses each boot and wake past them; reboot the host, which reserves the whole pool early in boot, then switch again"
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== stop order on root@geoffcloud: anvil, teapot
== stop anvil: its running guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stopped 2 imps; each keeps its disk and boots cold on the pool at its next use
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
EOF

  # the stop step's calls, the activation and the pool query, in the order the switch made them
  grep -E 'impz (ls|stop)|/var/lib/imp/imps|switch-to-configuration'"'"' switch|vm\.nr_hugepages' "$tree/calls" \
    > "$tree/calls-order"
  run -0 diff - "$tree/calls-order" << EOF
$imps_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
$pool_call
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it fails the switch naming each part when nixie is not ready after it" {
  local commit earlier unready
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/clock:$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$unready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_stderr 'nixie is not ready after 30 tries: imp_host: impd 3.4.0 refuses imp client 3.2.1'
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
  run -0 diff - "$tree/clock/pauses" <<< "$(for _ in $(seq 1 29); do echo 10; done)"
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it never builds or switches a commit without the atc daemon pin" {
  local commit
  setup_test "$tree"
  commit="$(git -C "$tree/clone" rev-parse HEAD)"
  jq -c --arg runs "$commit https://github.com/zgeoff/cloud/actions/runs/1" '{argv: ., stdout: "\($runs)\n"}' \
    <<< "$gh_runs_call" >> "$tree/gh-responses"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    bash scripts/switch-geoffcloud.sh

  assert_output '== checked by https://github.com/zgeoff/cloud/actions/runs/1'

  # shellcheck disable=SC2001 # a regex mask, which ${variable//search/replace} cannot express

  stderr="$(sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" <<< "$stderr")"
  assert_stderr 'SNAPSHOT/nixos/packages/atc.nix is missing, so the switch has no atc daemon pin to compare'
  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it switches the host that the environment names" {
  local commit
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

  run -0 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    GEOFFCLOUD_HOST=root@other.test \
    bash scripts/switch-geoffcloud.sh

  refute_stderr
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@other.test
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@other.test
== root@other.test runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== nixie ready: store, imp_host
== impd holds no image
== root@other.test configures no hugetlb pool
== deployed/host moved to $commit
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@other.test","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
${images_call/root@geoffcloud/root@other.test}
${pool_call/root@geoffcloud/root@other.test}
EOF
}

@test "it rejects an unknown argument with its usage" {
  setup_test "$tree"

  run -2 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh --switch

  assert_stderr - << EOF
usage: switch-geoffcloud.sh [--build-only | --allow-k3s-restart | --stop-ordinary-page-imps]
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds from a branch other than main" {
  setup_test "$tree"
  git -C "$tree/clone" checkout -q -b topic

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
switch from main, not topic
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never builds with uncommitted changes" {
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  echo edited > "$tree/clone/nixos/marker"

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
the checkout has uncommitted changes
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds when git status fails" {
  setup_test "$tree"
  head -c 64 /dev/zero | tr "\0" x > "$tree/clone/.git/index"

  run -128 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
error: bad signature 0x78787878
fatal: index file corrupt
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds when the fetch fails" {
  setup_test "$tree"
  mv "$tree/origin.git" "$tree/origin-gone.git"

  run -128 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
fatal: '$tree/origin.git' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds when origin main has moved on" {
  setup_test "$tree"
  git clone -q "$tree/origin.git" "$tree/other"
  git -C "$tree/other" config maintenance.auto false
  git -C "$tree/other" commit -q --allow-empty -m elsewhere
  git -C "$tree/other" push -q origin main

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
main is not origin/main; pull first
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds main with an unpushed commit" {
  setup_test "$tree"
  git -C "$tree/clone" commit -q --allow-empty -m unpushed

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
main is not origin/main; pull first
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never builds when the commit cannot be archived" {
  local blob
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  blob="$(git -C "$tree/clone" rev-parse HEAD:nixos/marker)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  run -255 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
error: invalid object 100644 $blob for 'nixos/marker'
error: cannot read '$blob'
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it leaves no snapshot archive behind when the commit cannot be archived" {
  local blob
  setup_test "$tree"
  mkdir "$tree/clone/nixos"
  echo committed > "$tree/clone/nixos/marker"
  git -C "$tree/clone" add nixos/marker
  git -C "$tree/clone" commit -qm marker
  git -C "$tree/clone" push -q origin main
  blob="$(git -C "$tree/clone" rev-parse HEAD:nixos/marker)"
  rm -f "$tree/clone/.git/objects/${blob:0:2}/${blob:2}"

  run -255 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
error: invalid object 100644 $blob for 'nixos/marker'
error: cannot read '$blob'
EOF
  refute_output

  ls -A "$tree/tmp" > "$tree/tmp-files"
  run -0 diff /dev/null "$tree/tmp-files"
  run -0 diff /dev/null "$tree/calls"
}

@test "it never builds outside a git checkout" {
  setup_test "$tree"
  mkdir "$tree/loose"
  cp "$tree/clone/scripts/switch-geoffcloud.sh" "$tree/clone/scripts/nix-image.sh" "$tree/loose/"

  run -128 --separate-stderr env -C "$tree/loose" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" GIT_CEILING_DIRECTORIES="$tree" \
    bash switch-geoffcloud.sh

  assert_stderr - << EOF
fatal: not a git repository (or any of the parent directories): .git
EOF
  refute_output

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff /dev/null "$tree/calls-masked"
}

@test "it never switches after a failed build" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_ERROR="error: builder for '/nix/store/x.drv' failed with exit code 1" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
error: builder for '/nix/store/x.drv' failed with exit code 1
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

# The real docker CLI, behind the logging stand-in, with no daemon at its socket: docker
# 28.0.4 (CI's ubuntu-24.04 runner image 20261004) and 29.7.2 word that error differently,
# and 28 adds a help line and exits 125, so the case accepts either stderr with its status.
@test "it never switches when docker cannot reach its daemon" {
  local commit
  # under /tmp, not $TMPDIR: the real docker meets a socket in this tree, and a socket path
  # past 107 bytes, the most sun_path holds, makes docker 29.7.2 panic or print another error
  tree="$(mktemp -d -p /tmp)"
  socket_tree="$tree"
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

  run --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_DOCKER_PASS=1 STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    DOCKER_HOST="unix://$tree/docker.sock" \
    bash scripts/switch-geoffcloud.sh

  assert_output "$(printf '== checked by https://github.com/zgeoff/cloud/actions/runs/1\n== atc 2.26.2 on the host, 2.27.0 in the gateway\n== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster\n%s\n== build %s' "$kinds_line" "${commit:0:7}")"
  # set -e passes docker's status through: 125 from docker 28.0.4, 1 from docker 29.7.2
  case "$status" in
    125) assert_stderr "$(printf 'docker: Cannot connect to the Docker daemon at unix://%s/docker.sock. Is the docker daemon running?\n\nRun '"'"'docker run --help'"'"' for more information' "$tree")" ;;
    1) assert_stderr "$(printf 'failed to connect to the docker API at unix://%s/docker.sock; check if the path is correct and if the daemon is running: dial unix %s/docker.sock: connect: no such file or directory' "$tree" "$tree")" ;;
    *) fail "exit $status, want 125 (docker 28.0.4) or 1 (docker 29.7.2)" ;;
  esac
  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it never switches when the build prints no system path" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_BUILD_OUT='warning: x' STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
the build printed no system path: warning: x
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
EOF
}

# The copy runs nix inside the pinned Nix image, which no hermetic case can start, so
# the docker stand-in fails it (STUB_COPY_ERROR).
@test "it never activates when the copy fails" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_COPY_ERROR="error: cannot connect to 'root@geoffcloud'" \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
error: cannot connect to 'root@geoffcloud'
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
EOF
}

# The real ssh, behind the logging stand-in, refused by a loopback port where nothing
# listens. The gateway query is the switch's first call to the host, so an unreachable host
# stops the switch before the build.
@test "it never builds and stops with ssh exit 255 when the host is unreachable" {
  local commit
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

  run -255 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_PASS=1 GEOFFCLOUD_HOST=ssh://root@127.0.0.1:1 \
    bash scripts/switch-geoffcloud.sh

  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  assert_output '== checked by https://github.com/zgeoff/cloud/actions/runs/1'

  run -0 diff - "$tree/calls" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
EOF
  ls -A "$tree/tmp" > "$tree/tmp-left"
  run -0 diff /dev/null "$tree/tmp-left"
}

@test "it stops with the activation exit code when switch to configuration fails" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
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

  run -4 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_ACTIVATE_FAILED_UNITS=atc-daemon.service \
    STUB_ACTIVATE_STATUS=$'× atc-daemon.service - atc daemon\n     Active: failed (Result: exit-code)' \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
warning: the following units failed: atc-daemon.service
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
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
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

# Only an interception drops an open session at the readlink check, so the ssh stand-in
# does it (STUB_SSH_DROP_AT_READLINK).
@test "it stops with ssh exit 255 when the connection drops before the check" {
  local commit
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

  run -255 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_SSH_DROP_AT_READLINK=1 \
    bash scripts/switch-geoffcloud.sh

  assert_stderr $'Connection to geoffcloud closed by remote host.\r'
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
}

@test "it fails when the host runs another system after the switch" {
  local commit earlier
  setup_test "$tree"
  earlier="$(git -C "$tree/clone" rev-parse HEAD)"
  git -C "$tree/clone" push -q origin "$earlier:refs/tags/deployed/host"
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
the host runs /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-geoffcloud-old, not the built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","SNAPSHOT:/src:ro","-w","/src","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","build","--no-link","--print-out-paths","path:.?dir=nixos#nixosConfigurations.geoffcloud.config.system.build.toplevel"]
["docker","run","--rm","--network","host","-v","geoffcloud-nix-store:/nix","-v","$tree/home/.ssh/known_hosts:/root/.ssh/known_hosts:ro","-e","NIX_SSHOPTS=-o BatchMode=yes","$NIX_IMAGE","nix","--extra-experimental-features","nix-command flakes","shell","nixpkgs#openssh","-c","nix","--extra-experimental-features","nix-command","copy","--to","ssh://root@geoffcloud","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test"]
$dry_activate_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
["ssh","-o","BatchMode=yes","root@geoffcloud","nix-env -p /nix/var/nix/profiles/system --set '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test'   && mkdir -p /var/lib/host-build-lag && echo '$commit /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test' >> /var/lib/host-build-lag/switches   && NIXOS_INSTALL_BOOTLOADER=0 systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER     -E NIXOS_NO_CHECK --collect --no-ask-password --wait --pipe --quiet     --service-type=exec --unit=switch-geoffcloud '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test/bin/switch-to-configuration' switch"]
["ssh","-o","BatchMode=yes","root@geoffcloud","readlink","/run/current-system"]
EOF
  git -C "$tree/origin.git" rev-parse refs/tags/deployed/host > "$tree/deployed-host"
  run -0 diff - "$tree/deployed-host" <<< "$earlier"
}

@test "it fails with systemctls exit code when listing failed units fails" {
  local commit
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

  run -1 --separate-stderr env -C "$tree/clone" -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" \
    TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$tree/calls" \
    STUB_BUILD_SAW="$tree/build-saw" STUB_GATEWAY_IMAGES=ghcr.io/zgeoff/atc-gateway:2.27.0 \
    STUB_NIXIE_IMAGES=ghcr.io/zgeoff/nixie:0.31.4 STUB_NIXIE_REPORTS="$nixie_ready" \
    STUB_BUILD_OUT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_CURRENT=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test \
    STUB_FAILED_EXIT=1 \
    bash scripts/switch-geoffcloud.sh

  assert_stderr - << EOF
Failed to list units: Connection timed out
EOF
  assert_output - << EOF
== checked by https://github.com/zgeoff/cloud/actions/runs/1
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
$kinds_line
== build ${commit:0:7}
built /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
== copy to root@geoffcloud
== atc 2.26.2 on the host, 2.27.0 in the gateway
== impd 3.4.0 on the host, nixie 0.31.4 (imp-client 3.2.1) in the cluster
== switch root@geoffcloud
== root@geoffcloud runs /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-geoffcloud-26.05.test
EOF

  sed -E "s|$tree/tmp/tmp\.[A-Za-z0-9]+|SNAPSHOT|" "$tree/calls" > "$tree/calls-masked"
  run -0 diff - "$tree/calls-masked" << EOF
$gh_runs_call
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n atc get pods -l app=atc-gateway -o 'jsonpath={.items[*].spec.containers[0].image}'"]
["ssh","-o","BatchMode=yes","root@geoffcloud","k3s kubectl -n nixie get pods -l app=nixie -o 'jsonpath={.items[*].spec.containers[?(@.name==\"nixie\")].image}'"]
$nixie_lock_call
$kinds_calls
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
}
