# shellcheck shell=bash
# create_stub_livez_curl <bin>: writes <bin>/curl, a stand-in for curl as wait-for-k3s-api.sh
# calls it, `curl -sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez`, so no case
# reaches geoffcloud. It logs each call's argv as a JSON line to STUB_TREE/calls. Tries before
# the STUB_LIVEZ_ANSWER_FROM-th one fail as curl -s does when no answer comes within
# --max-time: nothing printed, exit 28. That try and every later one answer, as any HTTP answer
# does for curl without -f: nothing printed (-o /dev/null), exit 0. Without STUB_LIVEZ_ANSWER_FROM
# no try answers. Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Not checked against a k3s API (no test reaches the tailnet). Checked on 2026-10-14 against
# https://curl.se/docs/manpage.html (EXIT CODES), the same for curl 8.5.0 (CI's ubuntu-24.04
# runner image) and 8.22.0: 28 "Operation timeout", and -f is what turns an HTTP error answer
# into a failure, so a 401 or 404 without it exits 0. The docs do not settle whether a node that
# has not yet reached its peer times out (28) or is refused (7); wait-for-k3s-api.sh treats both
# alike, so the stand-in models the timeout only.
create_stub_livez_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "-sk -o /dev/null --max-time 5 https://geoffcloud:6443/livez")
    echo try >> "$STUB_TREE/livez-tries"
    tries="$(wc -l < "$STUB_TREE/livez-tries")"
    if [ -n "${STUB_LIVEZ_ANSWER_FROM:-}" ] && [ "$tries" -ge "$STUB_LIVEZ_ANSWER_FROM" ]; then
      exit 0
    fi
    exit 28
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/curl"
}
