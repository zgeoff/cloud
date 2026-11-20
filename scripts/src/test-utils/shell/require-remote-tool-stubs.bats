#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for require-remote-tool-stubs.sh: the guard passes only when ssh, scp, sftp, rsync
# and tailscale all resolve to executables inside the case's bin directory, and otherwise
# stops a case under errexit (a child bash -e, as a setup_test runs) before the step
# after it runs. The cases that remove a stand-in pass a system path inside the case tree,
# so what the guard finds there is the case's own placeholder or nothing, never the host's
# tools; the first case keeps the default system path. It checks command resolution alone,
# so no case here runs any remote tool, real or stand-in.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'require-remote-tool-stubs.sh'
  # fixed, so the modes the cases assert do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# Runtime every case needs: <tree>/bin with an executable placeholder for each remote
# tool, an empty <tree>/system for the cases to pass as the system path, and the HOME and
# TMPDIR a child bash runs with. The guard only resolves names, so a placeholder that
# exits 97 serves.
setup_test() {
  local tree="$1" tool
  mkdir "$tree/bin" "$tree/system" "$tree/home" "$tree/tmp"
  for tool in ssh scp sftp rsync tailscale; do
    printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/bin/$tool"
    chmod +x "$tree/bin/$tool"
  done
}

@test "it passes when every remote tool resolves to a stand in on the default system path" {
  setup_test "$tree"

  run -0 --separate-stderr require_remote_tool_stubs "$tree/bin"

  refute_output
  refute_stderr
}

@test "it passes when the system path also holds every remote tool" {
  local tool
  setup_test "$tree"
  for tool in ssh scp sftp rsync tailscale; do
    printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/$tool"
    chmod +x "$tree/system/$tool"
  done

  run -0 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  refute_stderr
}

@test "it stops the case before its next step when ssh is missing" {
  setup_test "$tree"
  rm "$tree/bin/ssh"

  # shellcheck disable=SC2016 # expanded by the child bash
  run -1 --separate-stderr env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash -ec 'source "$1"; require_remote_tool_stubs "$2" "$3"; touch "$4"' _ \
    "$BATS_TEST_DIRNAME/require-remote-tool-stubs.sh" "$tree/bin" "$tree/system" "$tree/script-ran"

  refute_output
  assert_stderr "ssh resolves to nothing, not a stand-in in $tree/bin"
  refute [ -e "$tree/script-ran" ]
  refute [ -L "$tree/script-ran" ]
}

@test "it fails when a stand in is not executable" {
  setup_test "$tree"
  chmod -x "$tree/bin/tailscale"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "tailscale stand-in in $tree/bin is not executable"
}

@test "it fails when ssh is missing and the system path holds one" {
  setup_test "$tree"
  rm "$tree/bin/ssh"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/ssh"
  chmod +x "$tree/system/ssh"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "ssh resolves to $tree/system/ssh, not a stand-in in $tree/bin"
}

@test "it fails when ssh is missing everywhere" {
  setup_test "$tree"
  rm "$tree/bin/ssh"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "ssh resolves to nothing, not a stand-in in $tree/bin"
}

@test "it fails when scp is missing and the system path holds one" {
  setup_test "$tree"
  rm "$tree/bin/scp"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/scp"
  chmod +x "$tree/system/scp"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "scp resolves to $tree/system/scp, not a stand-in in $tree/bin"
}

@test "it fails when scp is missing everywhere" {
  setup_test "$tree"
  rm "$tree/bin/scp"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "scp resolves to nothing, not a stand-in in $tree/bin"
}

@test "it fails when sftp is missing and the system path holds one" {
  setup_test "$tree"
  rm "$tree/bin/sftp"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/sftp"
  chmod +x "$tree/system/sftp"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "sftp resolves to $tree/system/sftp, not a stand-in in $tree/bin"
}

@test "it fails when sftp is missing everywhere" {
  setup_test "$tree"
  rm "$tree/bin/sftp"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "sftp resolves to nothing, not a stand-in in $tree/bin"
}

@test "it fails when rsync is missing and the system path holds one" {
  setup_test "$tree"
  rm "$tree/bin/rsync"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/rsync"
  chmod +x "$tree/system/rsync"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "rsync resolves to $tree/system/rsync, not a stand-in in $tree/bin"
}

@test "it fails when rsync is missing everywhere" {
  setup_test "$tree"
  rm "$tree/bin/rsync"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "rsync resolves to nothing, not a stand-in in $tree/bin"
}

@test "it fails when tailscale is missing and the system path holds one" {
  setup_test "$tree"
  rm "$tree/bin/tailscale"
  printf '#!/usr/bin/env bash\nexit 97\n' > "$tree/system/tailscale"
  chmod +x "$tree/system/tailscale"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "tailscale resolves to $tree/system/tailscale, not a stand-in in $tree/bin"
}

@test "it fails when tailscale is missing everywhere" {
  setup_test "$tree"
  rm "$tree/bin/tailscale"

  run -1 --separate-stderr require_remote_tool_stubs "$tree/bin" "$tree/system"

  refute_output
  assert_stderr "tailscale resolves to nothing, not a stand-in in $tree/bin"
}
