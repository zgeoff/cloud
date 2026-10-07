#!/usr/bin/env bash
# Test for create-stub-host-ssh.sh: the ssh stand-in runs each remote command of the
# credentials script on "the host" (the case's tree) with the host's stand-ins first on
# PATH, returns its output and exit code, fails closed on anything else, hands a loopback
# call to the real ssh when asked, and changes the host at the moments its interceptions
# name. It fails closed with exit 97, before any interception, when a remote tool on the
# host's PATH is not a stand-in or a remote command names one or uses `command -p`. The pass-through case pins what the credentials suite assumes about the real
# ssh: a refused connection exits 255 with "ssh: connect to host … port …: Connection
# refused" and a CR LF, as OpenSSH 9.6p1 (CI's ubuntu-24.04 runner image 20261004) and
# 10.5p1 print it.
#
#   bash scripts/test-lib/test-create-stub-host-ssh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-host-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/require-remote-tool-stubs.sh"

it_runs_a_known_remote_command_on_the_host_and_copies_its_output() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  touch "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "ls $tree/host/secrets" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< gateway-token
  diff - "$tree/host-output" <<< gateway-token
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"ls $tree/host/secrets\"]"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_closed_with_exit_97_and_runs_nothing_when_a_remote_tool_on_the_host_path_is_not_a_stand_in() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  touch "$tree/host/secrets/gateway-token"
  rm "$tree/host-bin/tailscale"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "ls $tree/host/secrets" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/host-output"
  diff - "$tree/err" <<< "unexpected: tailscale on the host PATH is not a stand-in in $tree/host-bin"
  diff - "$tree/calls" <<< "[\"ssh\",\"-o\",\"BatchMode=yes\",\"root@geoffcloud\",\"ls $tree/host/secrets\"]"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_before_any_interception_when_a_remote_tool_on_the_host_path_is_not_a_stand_in() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  touch "$tree/host/secrets/imp-token"
  rm "$tree/host-bin/ssh"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_REMOVE_TOKEN_AT_WHOAMI=1 \
    ssh -o BatchMode=yes root@geoffcloud "set -euo pipefail; export LC_ALL=C; curl http://127.0.0.1/rpc/tokens/whoami" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: ssh on the host PATH is not a stand-in in $tree/host-bin"
  ls -A "$tree/host/secrets" > "$tree/secrets-left"
  diff - "$tree/secrets-left" <<< imp-token
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C; curl http://127.0.0.1/rpc/tokens/whoami"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_when_a_known_command_names_a_remote_tool_by_path() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "docker exec -i imp-host imp secret add glm x; /usr/bin/ssh root@geoffcloud true" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/host-output"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@geoffcloud docker exec -i imp-host imp secret add glm x; /usr/bin/ssh root@geoffcloud true"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_when_a_known_command_bypasses_path_with_command_p() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "docker exec -i imp-host imp secret add glm x; command -p true" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/host-output"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@geoffcloud docker exec -i imp-host imp secret add glm x; command -p true"
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_runs_the_remote_command_with_the_host_stand_ins_first_on_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho "host docker: $*"\n' > "$tree/host-bin/docker"
  chmod +x "$tree/host-bin/docker"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud docker exec imp-host imp info --json \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'host docker: exec imp-host imp info --json'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_returns_the_remote_commands_exit_code_and_stderr() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "sha256sum $tree/host/secrets/gateway-token" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "sha256sum: $tree/host/secrets/gateway-token: No such file or directory"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_an_unknown_remote_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@geoffcloud "rm -rf $tree/host" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: -o BatchMode=yes root@geoffcloud rm -rf $tree/host"
  [ -d "$tree/host" ] || { echo "the unknown command ran" >&2; exit 1; }
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_another_host() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh -o BatchMode=yes root@other.test true > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes root@other.test true'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_fails_closed_with_exit_97_on_a_call_without_batch_mode() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    ssh root@geoffcloud true > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'unexpected: root@geoffcloud true'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_loopback_call_to_the_real_ssh_which_refuses_a_dead_port_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

# 127.0.0.2 is loopback too, so a broken guard would only reach a dead local port, never a
# real host; the guard admits 127.0.0.1 alone.
it_never_hands_a_call_to_another_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.2:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.2:1 true'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

# OpenSSH reads an option even after the destination, so the stand-in refuses one there
# before it calls the real ssh.
it_never_hands_a_call_with_an_option_after_the_destination_to_the_real_ssh() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: -o BatchMode=yes ssh://root@127.0.0.1:1 -oProxyCommand=false true'
  diff - "$tree/calls" <<< '["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","-oProxyCommand=false","true"]'
  [ "$status" = 97 ] || { echo "exit $status, want 97" >&2; exit 1; }
}

it_hands_a_call_to_the_system_ssh_not_one_on_the_callers_PATH() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  mkdir "$tree/bin" "$tree/host-bin" "$tree/host" "$tree/fake"
  printf '#!/usr/bin/env bash\necho fake ssh\n' > "$tree/fake/ssh"
  chmod +x "$tree/fake/ssh"
  PATH="$tree/fake:$PATH" create_stub_host_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"

  env -i PATH="$tree/bin:$tree/fake:/usr/bin:/bin" HOME="$tree" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" \
    STUB_SSH_PASS=1 ssh -o BatchMode=yes ssh://root@127.0.0.1:1 true \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_drops_the_connection_at_the_whoami_check_with_exit_255() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_SSH_DROP_AT_WHOAMI=1 \
    ssh -o BatchMode=yes root@geoffcloud "set -euo pipefail; export LC_ALL=C; echo ran http://127.0.0.1:7070/rpc/tokens/whoami" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< $'Connection to geoffcloud closed by remote host.\r'
  diff - <(tail -n 1 "$tree/calls") <<< '["ssh-dropped-at-whoami"]'
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_removes_the_saved_token_just_before_the_whoami_check() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  touch "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_REMOVE_TOKEN_AT_WHOAMI=1 \
    ssh -o BatchMode=yes root@geoffcloud "set -euo pipefail; export LC_ALL=C; ls $tree/host/secrets; echo http://127.0.0.1:7070/rpc/tokens/whoami" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< http://127.0.0.1:7070/rpc/tokens/whoami
  diff - <(tail -n 1 "$tree/calls") <<< '["imp-token-removed-at-whoami"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_makes_the_secrets_directory_read_only_just_before_the_bearer_write() {
  local status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+w "$tree"; rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_READONLY_AT_BEARER_WRITE=1 \
    ssh -o BatchMode=yes root@geoffcloud "umask 077; t=\$(mktemp $tree/host/secrets/.gateway-token.XXXXXX); echo \"\$t\"" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(stat -c %a "$tree/host/secrets") <<< 500
  diff - <(sed -E 's/XXXXXX/X/' "$tree/err") <<< "mktemp: failed to create file via template '$tree/host/secrets/.gateway-token.X': Permission denied"
  diff - <(tail -n 1 "$tree/calls") <<< '["secrets-dir-made-read-only"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_alters_the_written_bearer_just_before_its_checksum() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  chmod 0400 "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_ALTER_BEARER_BEFORE_SUM=1 \
    ssh -o BatchMode=yes root@geoffcloud "sha256sum $tree/host/secrets/gateway-token" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/host/secrets/gateway-token" << 'TOKEN'
fixture-bearer
altered
TOKEN
  diff - <(cut -d' ' -f1 "$tree/out") <<< "$(printf 'fixture-bearer\naltered\n' | sha256sum | cut -d' ' -f1)"
  diff - <(tail -n 1 "$tree/calls") <<< '["gateway-token-altered"]'
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_removes_the_bearer_just_before_the_final_stat() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/host/secrets"
  touch "$tree/host/secrets/gateway-token" "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" STUB_REMOVE_BEARER_BEFORE_STAT=1 \
    ssh -o BatchMode=yes root@geoffcloud "stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< "stat: cannot statx '$tree/host/secrets/gateway-token': No such file or directory"
  diff - <(tail -n 1 "$tree/calls") <<< '["gateway-token-removed-before-stat"]'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Runtime every case needs: the stand-in in <tree>/bin, a <tree>/host-bin for the host's
# stand-ins, fail-closed stand-ins for every other remote tool in both, checked so no call can
# reach a real remote tool, and the host's root.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/host-bin" "$tree/host"
  : > "$tree/host-output"
  create_stub_host_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
}

run_cases
