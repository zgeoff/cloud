# shellcheck shell=bash
# create_stub_k3s_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the host whose k3s
# kubeconfig connect-k3s.sh reads. "The host" is the case's tree: its
# /etc/rancher/k3s/k3s.yaml is STUB_TREE/host/k3s.yaml. It logs each call's argv as a JSON
# line to STUB_TREE/calls and answers `<STUB_HOST> cat /etc/rancher/k3s/k3s.yaml` with that
# file, or, when it is missing, with cat's "No such file or directory" error and the remote
# exit code 1. With STUB_SSH_UNREACHABLE=1 the call fails as OpenSSH does when the host
# does not answer: "ssh: connect to host <host> port 22: Connection timed out" and the CR
# LF that its log ends a line with on stderr, exit 255. It never runs a command and never
# hands a call to the real ssh: the script names the host as root@<name>, which leaves no
# room for a loopback port. Any other call, including one to a host other than STUB_HOST,
# ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_k3s_ssh() {
  local bin="$1"
  cat > "$bin/ssh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" != 3 ] || [ "$1" != "$STUB_HOST" ] || [ "$2 $3" != "cat /etc/rancher/k3s/k3s.yaml" ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
if [ -n "${STUB_SSH_UNREACHABLE:-}" ]; then
  printf 'ssh: connect to host %s port 22: Connection timed out\r\n' "${1#*@}" >&2
  exit 255
fi
if [ ! -f "$STUB_TREE/host/k3s.yaml" ]; then
  echo "cat: /etc/rancher/k3s/k3s.yaml: No such file or directory" >&2
  exit 1
fi
cat "$STUB_TREE/host/k3s.yaml"
STUB
  chmod +x "$bin/ssh"
}
