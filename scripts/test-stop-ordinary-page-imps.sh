#!/usr/bin/env bash
# Test for stop-ordinary-page-imps.sh: it stops each running or sleeping imp whose guest is on 4 KiB
# pages, in its names' sorted order between the names IMP_STOP_ORDER puts first and those
# IMP_STOP_LAST puts last, and only through
# `impz stop`, so each disk stays. It leaves an imp on 2 MiB pages and an imp with no guest alone,
# and counts an imp as on 2 MiB pages when either its snapshot's file or its VM's file says so.
# --plan prints the order and stops nothing, and --check fails naming each imp on 4 KiB pages, or
# passes when none is left. It stops with ssh's exit code when the host refuses the connection. The
# imps take the id, name and state fields of impd's ImpSchema (zgeoff/impz
# packages/api/src/schemas/imp-schema.ts at v6.1.0), with invented values. ssh is the NixOS host
# stand-in from test-support/shell, which answers the imp listing and the page-size loop from the
# case's STUB_IMPD_IMPS and STUB_IMPD_IMP_PAGES. Each case runs the script under `env -i` and
# compares its stdout, stderr and ssh call log.
#
#   bash scripts/test-stop-ordinary-page-imps.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-nixos-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/require-remote-tool-stubs.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop-ordinary-page-imps.sh"
# the two remote commands every mode runs, as the call log records them
list_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz ls --json"]'
# shellcheck disable=SC2016 # $d, $s and $v are the remote shell's variables, as the call log records them
pages_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c '"'"'cd /var/lib/imp/imps && for d in *; do s=4K; v=4K; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/snapshot/meta.json\" && s=2M; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"$d/vm.json\" && v=2M; echo \"$d $s $v\"; done'"'"'"]'

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

it_stops_each_imp_on_4_kib_pages_in_sorted_order_and_leaves_the_rest() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"running"},{"id":"imp_5","name":"barrow","state":"stopped"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 2M\nimp_4 2M 2M\nimp_5 4K 4K' \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== stop order on root@geoffcloud: anvil, teapot
== stop anvil: its running guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stopped 2 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
EOF
  assert_status 0 "$status"
}

it_leaves_a_sleeping_imp_whose_snapshot_file_a_wake_removed_when_its_vm_file_says_2_mib() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 2M\nimp_2 2M 4K' \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "== no imp on root@geoffcloud is on 4 KiB pages"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
  assert_status 0 "$status"
}

it_stops_the_imps_imp_stop_order_names_first_in_that_order() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"sleeping"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 4K\nimp_4 4K 4K' \
    IMP_STOP_ORDER='quill,lantern ghost teapot,quill' \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== stop order on root@geoffcloud: quill, teapot, anvil
== stop quill: its sleeping guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stop anvil: its running guest is on 4 KiB pages
== stopped 3 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop quill"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
EOF
  assert_status 0 "$status"
}

it_stops_the_imps_imp_stop_last_names_last_in_that_order() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"lantern","state":"sleeping"},{"id":"imp_4","name":"quill","state":"sleeping"},{"id":"imp_5","name":"barrow","state":"sleeping"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K\nimp_3 2M 4K\nimp_4 4K 4K\nimp_5 4K 4K' \
    IMP_STOP_ORDER=barrow IMP_STOP_LAST='teapot,lantern ghost anvil barrow,teapot' \
    bash "$script" root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== stop order on root@geoffcloud: barrow, quill, teapot, anvil
== stop barrow: its sleeping guest is on 4 KiB pages
== stop quill: its sleeping guest is on 4 KiB pages
== stop teapot: its sleeping guest is on 4 KiB pages
== stop anvil: its running guest is on 4 KiB pages
== stopped 4 imps; each keeps its disk and boots cold on the pool at its next use
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop barrow"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop quill"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop teapot"]
["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz stop anvil"]
EOF
  assert_status 0 "$status"
}

it_prints_the_stop_order_and_stops_nothing_with_plan() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 4K 4K' IMP_STOP_LAST=anvil \
    bash "$script" --plan root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== stop order on root@geoffcloud: teapot, anvil
== would stop teapot: its sleeping guest is on 4 KiB pages
== would stop anvil: its running guest is on 4 KiB pages
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
  assert_status 0 "$status"
}

it_fails_naming_each_imp_on_4_kib_pages_with_check() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 4K 4K\nimp_2 2M 2M' \
    bash "$script" --check root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "== stop order on root@geoffcloud: teapot"
  diff - "$tree/err" << 'EOF'
imp teapot: its sleeping guest is on 4 KiB pages
stop each with `bash scripts/stop-ordinary-page-imps.sh <host>`, so it boots cold on the pool
EOF
  diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
  assert_status 1 "$status"
}

it_passes_check_when_every_guest_is_on_2_mib_pages() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMPS='[{"id":"imp_1","name":"teapot","state":"sleeping"},{"id":"imp_2","name":"anvil","state":"running"},{"id":"imp_3","name":"quill","state":"stopped"}]' \
    STUB_IMPD_IMP_PAGES=$'imp_1 2M 2M\nimp_2 4K 2M\nimp_3 4K 4K' \
    bash "$script" --check root@geoffcloud > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< "== no imp on root@geoffcloud is on 4 KiB pages"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$list_call
$pages_call
EOF
  assert_status 0 "$status"
}

it_stops_with_ssh_s_exit_code_when_the_host_refuses_the_connection() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_SSH_PASS=1 bash "$script" ssh://root@127.0.0.1:1 > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< "${list_call/root@geoffcloud/ssh://root@127.0.0.1:1}"
  assert_status 255 "$status"
}

run_cases
