# shellcheck shell=bash
# create_stub_readiness_ssh <bin>: writes <bin>/ssh, a stand-in for ssh to the host that
# check-atc-gateway-readiness.sh inspects. It never runs a command. It logs each call's
# argv as a JSON line to STUB_TREE/calls and answers, for STUB_HOST only:
#
# - `-o BatchMode=yes -o ConnectTimeout=15 <host> k3s kubectl <args>`, with the cluster's
#   objects as files under STUB_TREE/cluster: namespace/<name>, storageclass/<name> and
#   deploy/<namespace>/<name>, whose content is the Deployment's readyReplicas:
#   - `get nodes --no-headers`: STUB_NODE_LINE;
#   - `get namespace <name>`, `get storageclass <name>`, `get -n <ns> deploy <name>` and
#     `-n <ns> get deploy <name>`: a kubectl table row, or kubectl's NotFound error and
#     exit 1;
#   - `-n <ns> get deploy <name> -o jsonpath={.status.readyReplicas}`: the file's content,
#     printed as jsonpath prints it, with no newline, or the NotFound error and exit 1;
#   - `-n atc run readiness-probe … -- curl … <gateway URL>`: STUB_PROBE_CODE, as the probe
#     pod's curl prints it;
# - `-o BatchMode=yes <host> free -m | awk …`: STUB_MEM_AVAILABLE, the host's available MiB;
# - `-o BatchMode=yes <host> systemctl is-active --quiet atc-daemon`: exit 0 when
#   STUB_DAEMON is active, else systemctl's exit 3 for an inactive unit.
#
# With STUB_SSH_UNREACHABLE=1 every call fails as OpenSSH does when the host does not
# answer: "ssh: connect to host <host> port 22: Connection timed out" and the CR LF that its
# log ends a line with on stderr, exit 255. It never hands a call to the real ssh: the
# script names the host as root@<name>, which leaves no room for a loopback port. Any other
# call, including one to a host other than STUB_HOST, ends with exit 97 and "unexpected:
# <argv>" on stderr.
#
# Not checked against a real cluster: the table rows carry kubectl's columns with fixed
# ages, and the NotFound lines follow kubectl's "Error from server (NotFound): <resource>
# \"<name>\" not found" for each resource's plural API name; the script discards both.
create_stub_readiness_ssh() {
  local bin="$1"
  cat > "$bin/ssh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
unexpected() {
  echo "unexpected: $*" >&2
  exit 97
}
not_found() {
  echo "Error from server (NotFound): $1 \"$2\" not found" >&2
  exit 1
}
cluster="$STUB_TREE/cluster"
if [ "$1 $2" != "-o BatchMode=yes" ]; then unexpected "$@"; fi
if [ "$3 $4" = "-o ConnectTimeout=15" ]; then
  host="$5" command=kubectl
  if [ "$6 $7" != "k3s kubectl" ]; then unexpected "$@"; fi
else
  host="$3" command="${*:4}"
fi
if [ "$host" != "$STUB_HOST" ]; then unexpected "$@"; fi
if [ -n "${STUB_SSH_UNREACHABLE:-}" ]; then
  printf 'ssh: connect to host %s port 22: Connection timed out\r\n' "${host#*@}" >&2
  exit 255
fi
case "$command" in
  "free -m | awk '/^Mem:/ {print \$7}'") printf '%s\n' "$STUB_MEM_AVAILABLE" ;;
  "systemctl is-active --quiet atc-daemon") [ "${STUB_DAEMON:-}" = active ] || exit 3 ;;
  kubectl)
    args="${*:8}"
    case "$args" in
      "get nodes --no-headers") printf '%s\n' "$STUB_NODE_LINE" ;;
      "get namespace "*)
        [ "$#" = 10 ] || unexpected "$@"
        [ -e "$cluster/namespace/${10}" ] || not_found namespaces "${10}"
        printf 'NAME   STATUS   AGE\n%s    Active   2d\n' "${10}"
        ;;
      "get storageclass "*)
        [ "$#" = 10 ] || unexpected "$@"
        [ -e "$cluster/storageclass/${10}" ] || not_found storageclasses.storage.k8s.io "${10}"
        printf 'NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE\n%s   rancher.io/local-path   Retain          WaitForFirstConsumer   false                  2d\n' "${10}"
        ;;
      "-n "*" get deploy "*" -o jsonpath={.status.readyReplicas}")
        [ "$#" = 14 ] || unexpected "$@"
        [ -e "$cluster/deploy/$9/${12}" ] || not_found deployments.apps "${12}"
        cat "$cluster/deploy/$9/${12}"
        ;;
      "get -n "*" deploy "* | "-n "*" get deploy "*)
        [ "$#" = 12 ] || unexpected "$@"
        if [ "$8" = get ]; then ns="${10}"; else ns="$9"; fi
        [ -e "$cluster/deploy/$ns/${12}" ] || not_found deployments.apps "${12}"
        printf 'NAME   READY   UP-TO-DATE   AVAILABLE   AGE\n%s   %s/1     1            %s           2d\n' \
          "${12}" "$(cat "$cluster/deploy/$ns/${12}")" "$(cat "$cluster/deploy/$ns/${12}")"
        ;;
      "-n atc run readiness-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.16.0 -- curl -s -o /dev/null -w %{http_code} -H Host: atc.geoff.cloud http://atc-gateway.atc.svc.cluster.local:8414/.well-known/oauth-protected-resource/mcp")
        printf '%s' "$STUB_PROBE_CODE"
        ;;
      *) unexpected "$@" ;;
    esac
    ;;
  *) unexpected "$@" ;;
esac
STUB
  chmod +x "$bin/ssh"
}
