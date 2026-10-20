#!/usr/bin/env bash
# Test for the agent image's bun and bunx shim, bin/bun: it runs the Bun version that the nearest
# .bun-version pins, and the image's default Bun when there is none, when the image lacks the pin,
# or when the pin is no version. setup_test lays out a fake /opt/bun in the case tree, as the image
# lays out the real one, with a scripted command for each version's bun and bunx that logs to that
# version's own log, and points the shim at it with AGENT_BUN_ROOT. Each case runs the shim with `sh`
# under `env -i`, so CI runs it with dash, the guest's /bin/sh. check-agent-image.ts runs the real
# binaries through the shim in the image.
#
#   bash images/agent/test-bun-shim.sh
# shellcheck source-path=SCRIPTDIR/../..
set -euo pipefail
umask 022
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-support/shell/run-cases.sh
source "$here/../../test-support/shell/run-cases.sh"
# shellcheck source=test-support/shell/create-case-tree.sh
source "$here/../../test-support/shell/create-case-tree.sh"
# shellcheck source=test-support/shell/assert-status.sh
source "$here/../../test-support/shell/assert-status.sh"
# shellcheck source=test-support/shell/assert-missing.sh
source "$here/../../test-support/shell/assert-missing.sh"
# shellcheck source=test-support/shell/create-stub-scripted-command.sh
source "$here/../../test-support/shell/create-stub-scripted-command.sh"

script="$here/bin/bun"

# a fake /opt/bun with Bun 1.4.2 and 1.4.3, whose calls log to $tree/<version>.log and answer from
# $tree/<version>-answers, the default linked to 1.4.3, and $tree/bin/bun and bunx linked to the
# shim, as /usr/local/bin/bun and bunx are in the image; the cases run from $tree/repo/sub
setup_test() {
  create_case_tree
  local version
  for version in 1.4.2 1.4.3; do
    mkdir -p "$tree/opt/$version" "$tree/$version-answers"
    create_stub_scripted_command "$tree/opt/$version" bun "$tree/$version.log" "$tree/$version-answers"
    create_stub_scripted_command "$tree/opt/$version" bunx "$tree/$version.log" "$tree/$version-answers"
  done
  ln -s "$tree/opt/1.4.3" "$tree/opt/default"
  mkdir -p "$tree/bin" "$tree/repo/sub"
  ln -s "$script" "$tree/bin/bun"
  ln -s "$script" "$tree/bin/bunx"
}

it_runs_the_version_that_the_folder_s_bun_version_pins() {
  local status=0
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 1.4.2 > "$tree/1.4.2-answers/1.out"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 1.4.2
  diff /dev/null "$tree/err"
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  assert_missing "$tree/1.4.3.log" '1.4.3 log'
  assert_status 0 "$status"
}

it_runs_the_version_that_the_nearest_bun_version_above_the_folder_pins() {
  local status=0
  setup_test
  echo 1.4.3 > "$tree/.bun-version"
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  (cd "$tree/repo/sub" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" test a.test.ts) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo/sub\",\"argv\":[\"bun\",\"test\",\"a.test.ts\"]}"
  assert_missing "$tree/1.4.3.log" '1.4.3 log'
  assert_status 0 "$status"
}

it_runs_the_pinned_version_s_bunx_when_called_as_bunx() {
  local status=0
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bunx" oxlint --fix) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bunx\",\"oxlint\",\"--fix\"]}"
  assert_missing "$tree/1.4.3.log" '1.4.3 log'
  assert_status 0 "$status"
}

it_reads_a_pin_with_a_leading_v_and_a_crlf_line_end() {
  local status=0
  setup_test
  printf 'v1.4.2\r\n' > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.2-answers/1.status"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/1.4.2.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  assert_missing "$tree/1.4.3.log" '1.4.3 log'
  assert_status 0 "$status"
}

it_runs_the_default_without_a_bun_version() {
  local status=0
  setup_test
  echo 0 > "$tree/1.4.3-answers/1.status"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  assert_missing "$tree/1.4.2.log" '1.4.2 log'
  assert_status 0 "$status"
}

it_runs_the_default_and_names_both_versions_for_a_pin_the_image_lacks() {
  local status=0
  setup_test
  echo 1.4.4 > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.3-answers/1.status"

  (cd "$tree/repo/sub" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "bun: $tree/repo/.bun-version pins Bun 1.4.4, which this image lacks; running 1.4.3"
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo/sub\",\"argv\":[\"bun\",\"--version\"]}"
  assert_missing "$tree/1.4.2.log" '1.4.2 log'
  assert_status 0 "$status"
}

it_runs_the_default_for_a_pin_that_names_a_folder_outside_the_root() {
  local status=0
  setup_test
  mkdir -p "$tree/outside" "$tree/outside-answers"
  create_stub_scripted_command "$tree/outside" bun "$tree/outside.log" "$tree/outside-answers"
  echo ../outside > "$tree/repo/.bun-version"
  echo 0 > "$tree/1.4.3-answers/1.status"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" --version) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "bun: $tree/repo/.bun-version pins '../outside', which is no version; running the image's default Bun"
  diff - "$tree/1.4.3.log" <<< "{\"cwd\":\"$tree/repo\",\"argv\":[\"bun\",\"--version\"]}"
  assert_missing "$tree/outside.log" 'outside log'
  assert_status 0 "$status"
}

it_passes_on_the_exit_status_and_output_of_the_bun_it_runs() {
  local status=0
  setup_test
  echo 1.4.2 > "$tree/repo/.bun-version"
  echo '1 fail' > "$tree/1.4.2-answers/1.err"
  echo 1 > "$tree/1.4.2-answers/1.status"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" AGENT_BUN_ROOT="$tree/opt" \
    sh "$tree/bin/bun" test) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< '1 fail'
  assert_status 1 "$status"
}

run_cases
