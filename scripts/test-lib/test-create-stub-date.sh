#!/usr/bin/env bash
# Test for create-stub-date.sh: the date stand-in reads STUB_NOW instead of the clock and
# otherwise is the real date, whose output and errors it passes through; it fails closed on
# a call that names its own instant, and without STUB_NOW.
#
#   bash scripts/test-lib/test-create-stub-date.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-date.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_formats_the_fixed_instant_in_UTC() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z date -u +%Y-%m-%dT%H:%M:%SZ > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 2026-10-08T12:34:56Z
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["date","-u","+%Y-%m-%dT%H:%M:%SZ"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_the_real_date_error_and_exit_code_through() {
  local status=0 real_status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin LC_ALL=C date --bogus > "$tree/real-out" 2> "$tree/real-err" || real_status=$?

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" LC_ALL=C \
    STUB_NOW=2026-10-08T12:34:56Z date --bogus > "$tree/out" 2> "$tree/err" || status=$?

  diff "$tree/real-out" "$tree/out"
  diff "$tree/real-err" "$tree/err"
  diff - "$tree/calls" <<< '["date","--bogus"]'
  [ "$status" = "$real_status" ] || { echo "exit $status, want $real_status" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_that_names_its_own_instant() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z date -u -d @0 +%s > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -u -d @0 +%s'
  diff - "$tree/calls" <<< '["date","-u","-d","@0","+%s"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_without_a_fixed_instant() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    date -u +%s > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -u +%s'
  diff - "$tree/calls" <<< '["date","-u","+%s"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_runs_the_system_date_not_one_on_the_callers_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/fake"
  : > "$tree/calls"
  printf '#!/usr/bin/env bash\necho fake date\n' > "$tree/fake/date"
  chmod +x "$tree/fake/date"
  PATH="$tree/fake:$PATH" create_stub_date "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_NOW=2026-10-08T12:34:56Z date -u +%F > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 2026-10-08
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["date","-u","+%F"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, with fail-closed stand-ins for every
# remote tool, checked so no call can reach a real remote tool, the empty call log, and the
# HOME and TMPDIR the stand-in runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_date "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

run_cases
