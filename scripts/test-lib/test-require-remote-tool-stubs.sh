#!/usr/bin/env bash
# Test for require-remote-tool-stubs.sh: the guard passes only when ssh, scp, sftp, rsync
# and tailscale all resolve to executables inside the case's bin directory, and otherwise
# stops a case under errexit (a child bash -e, as a setup_test runs) before the step
# after it runs. It checks command resolution
# alone, so no case here runs any remote tool, real or stand-in.
#
#   bash scripts/test-lib/test-require-remote-tool-stubs.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_passes_when_every_remote_tool_resolves_to_a_stand_in() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

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

  bash -ec 'source "$1"; require_remote_tool_stubs "$2"; touch "$3"' _ "$lib" "$tree/bin" \
    "$tree/script-ran" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "ssh resolves to $(PATH=/usr/bin:/bin command -v ssh || echo nothing), not a stand-in in $tree/bin"
  [ ! -e "$tree/script-ran" ] || { echo "the step after the guard ran" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_a_stand_in_is_not_executable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  chmod -x "$tree/bin/tailscale"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "tailscale stand-in in $tree/bin is not executable"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_ssh_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/ssh"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "ssh resolves to $(PATH=/usr/bin:/bin command -v ssh || echo nothing), not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_scp_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/scp"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "scp resolves to $(PATH=/usr/bin:/bin command -v scp || echo nothing), not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_sftp_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/sftp"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "sftp resolves to $(PATH=/usr/bin:/bin command -v sftp || echo nothing), not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_rsync_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/rsync"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "rsync resolves to $(PATH=/usr/bin:/bin command -v rsync || echo nothing), not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_when_tailscale_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  rm "$tree/bin/tailscale"

  require_remote_tool_stubs "$tree/bin" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "tailscale resolves to $(PATH=/usr/bin:/bin command -v tailscale || echo nothing), not a stand-in in $tree/bin"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: <tree>/bin with an executable placeholder for each remote
# tool. The guard only resolves names, so a placeholder that exits 97 serves.
setup_test() {
  local tree="$1" tool
  mkdir "$tree/bin"
  for tool in ssh scp sftp rsync tailscale; do
    printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/bin/$tool"
    chmod +x "$tree/bin/$tool"
  done
}

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-remote-tool-stubs.sh"
run_cases
