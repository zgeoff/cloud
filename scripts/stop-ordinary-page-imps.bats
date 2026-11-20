#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for stop-ordinary-page-imps.sh: it stops each running or sleeping imp whose guest is on 4 KiB
# pages, in its names' sorted order between the names IMP_STOP_ORDER puts first and those
# IMP_STOP_LAST puts last, and only through
# `impz stop`, so each disk stays. It leaves an imp on 2 MiB pages and an imp with no guest alone,
# and counts an imp as on 2 MiB pages when either its snapshot's file or its VM's file says so.
# --plan prints the order and stops nothing, and --check fails naming each imp on 4 KiB pages, or
# passes when none is left. An image builder on 4 KiB pages fails every mode before any stop, since
# `impz stop` does not take a builder. It stops with ssh's exit code when the host refuses the
# connection. The imps take the id, name, state and kind fields of impd's ImpSchema (zgeoff/impz
# packages/api/src/schemas/imp-schema.ts at v6.3.2), with invented values. ssh is the NixOS host
# stand-in from scripts/src/test-utils/shell, which answers the imp listing and the page-size loop from the
# case's STUB_IMPD_IMPS and STUB_IMPD_IMP_PAGES. Each case runs the script under `env -i` and
# compares its stdout, stderr and ssh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-nixos-ssh.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/stop-ordinary-page-imps.sh"
  # the two remote commands every mode runs, as the call log records them
  list_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz ls --json --builders"]'
  # shellcheck disable=SC2016 # $d, $s and $v are the remote shell's variables, as the call log records them
  pages_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c '"'"'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/snapshot/meta.json\" && s=2M; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/vm.json\" && v=2M; echo \"$d $s $v\"; done'"'"'"]'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the home and temp folders the cases run with, the ssh stand-in, fail-closed
# stand-ins for the other remote tools, and a guard that ends the case unless each resolves to a
# stand-in
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it stops each imp on 4 kib pages in sorted order and leaves the rest" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"running"},{"id":"imp_5","name":"barrow","state":"stopped"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 2M\nimp_4 2M 2M\nimp_5 4K 4K' \
    bash "$script" root@geoffcloud

  assert_output - << 'EOF'
== stop order on root@geoffcloud: anvil, teapot
== stop anvil: its running guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stopped 2 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
EOF
}

@test "it leaves a sleeping imp whose snapshot file a wake removed when its vm file says 2 mib" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 2M\nimp_2 2M 4K' \
    bash "$script" root@geoffcloud

  assert_output "== no imp on root@geoffcloud is on 4 KiB pages"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it stops the imps imp stop order names first in that order" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"sleeping"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 4K\nimp_4 4K 4K' \
    IMP_STOP_ORDER='quill,lantern ghost teapot,quill' \
    bash "$script" root@geoffcloud

  assert_output - << 'EOF'
== stop order on root@geoffcloud: quill, teapot, anvil
== stop quill: its sleeping guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stop anvil: its running guest is on 4 KiB pages
== stopped 3 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop quill"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
EOF
}

@test "it stops the imps imp stop last names last in that order" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"sleeping"},{"id":"imp_5","name":"barrow","state":"sleeping"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 4K\nimp_4 4K 4K\nimp_5 4K 4K' \
    IMP_STOP_ORDER=barrow IMP_STOP_LAST='teapot,lantern ghost anvil barrow,teapot' \
    bash "$script" root@geoffcloud

  assert_output - << 'EOF'
== stop order on root@geoffcloud: barrow, quill, teapot, anvil
== stop barrow: its sleeping guest is on 4 KiB pages
== stop quill: its sleeping guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stop anvil: its running guest is on 4 KiB pages
== stopped 4 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop barrow"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop quill"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
EOF
}

@test "it prints the stop order and stops nothing with plan" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K' IMP_STOP_LAST=anvil \
    bash "$script" --plan root@geoffcloud

  assert_output - << 'EOF'
== stop order on root@geoffcloud: teapot, anvil
== would stop teapot: its sleeping guest is on 4 KiB pages
== would stop anvil: its running guest is on 4 KiB pages
EOF
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it fails naming each imp on 4 kib pages with check" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 2M 2M' \
    bash "$script" --check root@geoffcloud

  assert_output "== stop order on root@geoffcloud: teapot"
  assert_stderr - << 'EOF'
imp teapot: its sleeping guest is on 4 KiB pages
stop each with `bash scripts/stop-ordinary-page-imps.sh <host>`, so it boots cold on the pool
EOF

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it stops nothing and fails naming each image builder on 4 kib pages" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping","kind":"user"},{"id":"imp_2","name":"imp-build-k7m2q9xw","state":"running","kind":"builder"},{"id":"imp_3","name":"imp-build-p4t8r3zn","state":"running","kind":"builder"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 4K 2M' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
image builder imp-build-k7m2q9xw: its running guest is on 4 KiB pages, and impz stop does not take a builder
wait for each build to end, then run this again
EOF

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it fails check naming an image builder on 4 kib pages when no other imp is" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"running","kind":"user"},{"id":"imp_2","name":"imp-build-k7m2q9xw","state":"running","kind":"builder"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 2M 2M\nimp_2 4K 4K' \
    bash "$script" --check root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
image builder imp-build-k7m2q9xw: its running guest is on 4 KiB pages, and impz stop does not take a builder
wait for each build to end, then run this again
EOF

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it passes check when every guest is on 2 mib pages" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"quill","state":"stopped"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 2M 2M\nimp_2 4K 2M\nimp_3 4K 4K' \
    bash "$script" --check root@geoffcloud

  assert_output "== no imp on root@geoffcloud is on 4 KiB pages"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
}

@test "it stops with ssh s exit code when the host refuses the connection" {
  setup_test "$tree"

  run -255 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 bash "$script" ssh://root@127.0.0.1:1

  refute_output
  assert_stderr $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'

  run -0 diff - "$tree/calls" <<< "${list_call/root@geoffcloud/ssh://root@127.0.0.1:1}"
}
