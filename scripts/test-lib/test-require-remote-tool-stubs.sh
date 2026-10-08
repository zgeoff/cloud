#!/usr/bin/env bash
# Test for require-remote-tool-stubs.sh: the guard passes only when ssh, scp, sftp, rsync
# and tailscale all resolve to executables inside the case's bin directory, and otherwise
# stops a case under errexit (a child bash -e, as a setup_test runs) before the step
# after it runs. The cases that remove a stand-in pass a system path inside the case tree,
# so what the guard finds there is the case's own placeholder or nothing, never the host's
# tools; the first case keeps the default system path. It checks command resolution alone,
# so no case here runs any remote tool, real or stand-in.
#
#   bash scripts/test-lib/test-require-remote-tool-stubs.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-missing.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_passes_when_every_remote_tool_resolves_to_a_stand_in_on_the_default_system_path() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_passes_when_the_system_path_also_holds_every_remote_tool() {
  local tool status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  for tool in ssh scp sftp rsync tailscale; do
    printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/$tool"
    chmod +x "$tree/system/$tool"
  done

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_the_case_before_its_next_step_when_ssh_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/ssh"

  bash -ec 'source "$1"; require_remote_tool_stubs "$2" "$3"; touch "$4"' _ "$lib" "$tree/bin" \
    "$tree/system" "$tree/script-ran" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "ssh resolves to nothing, not a stand-in in $tree/bin"
  assert_missing "$tree/script-ran" "the step after the guard ran"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_a_stand_in_is_not_executable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  chmod -x "$tree/bin/tailscale"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "tailscale stand-in in $tree/bin is not executable"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_ssh_is_missing_and_the_system_path_holds_one() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/ssh"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/ssh"
  chmod +x "$tree/system/ssh"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "ssh resolves to $tree/system/ssh, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_ssh_is_missing_everywhere() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/ssh"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "ssh resolves to nothing, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_scp_is_missing_and_the_system_path_holds_one() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/scp"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/scp"
  chmod +x "$tree/system/scp"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "scp resolves to $tree/system/scp, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_scp_is_missing_everywhere() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/scp"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "scp resolves to nothing, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_sftp_is_missing_and_the_system_path_holds_one() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/sftp"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/sftp"
  chmod +x "$tree/system/sftp"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "sftp resolves to $tree/system/sftp, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_sftp_is_missing_everywhere() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/sftp"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "sftp resolves to nothing, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_rsync_is_missing_and_the_system_path_holds_one() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/rsync"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/rsync"
  chmod +x "$tree/system/rsync"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "rsync resolves to $tree/system/rsync, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_rsync_is_missing_everywhere() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/rsync"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "rsync resolves to nothing, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_tailscale_is_missing_and_the_system_path_holds_one() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/tailscale"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/tailscale"
  chmod +x "$tree/system/tailscale"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "tailscale resolves to $tree/system/tailscale, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_tailscale_is_missing_everywhere() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/tailscale"

  require_remote_tool_stubs "$tree/bin" "$tree/system" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "tailscale resolves to nothing, not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: <tree>/bin with an executable placeholder for each remote
# tool, and an empty <tree>/system for the cases to pass as the system path. The guard only
# resolves names, so a placeholder that exits 97 serves.
setup_test() {
  local tree="$1" tool
  mkdir "$tree/bin" "$tree/system"
  for tool in ssh scp sftp rsync tailscale; do
    printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/bin/$tool"
    chmod +x "$tree/bin/$tool"
  done
}

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-remote-tool-stubs.sh"
run_cases
