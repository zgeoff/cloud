# shellcheck shell=bash
# create_stub_imp_host_docker <bin>: writes <bin>/docker, a stand-in for docker on the host
# running imp's CLI in the imp-host container. impd's state is STUB_TREE/impd: info.json,
# secrets.json and tokens.json, whose shapes follow imp's own schemas (SecretSchema and
# TokenSchema in imp's packages/api). It logs each call's argv as a JSON line to
# STUB_TREE/calls and answers:
#
# - `exec imp-host imp info|secret ls|token ls --json`: that state file;
# - `exec -i imp-host imp secret add glm …`: stores its stdin in STUB_TREE/impd/secret-glm,
#   appends glm to secrets.json and prints it with droppedGrants, or fails with
#   STUB_SECRET_ADD_ERROR and imp's exit 2;
# - `exec imp-host imp token new atc-cloud …`: appends atc-cloud to tokens.json and prints
#   STUB_MINTED as imp prints a new token's secret, or fails with STUB_TOKEN_NEW_ERROR and
#   exit 1;
# - STUB_IMPD_FAIL_AT (info, secret-ls, token-ls) fails that call as docker does when
#   imp-host is stopped (exit 1);
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_imp_host_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
impd="$STUB_TREE/impd"
case "$*" in
  "exec imp-host imp info --json") call=info ;;
  "exec imp-host imp secret ls --json") call=secret-ls ;;
  "exec imp-host imp token ls --json") call=token-ls ;;
  "exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai --header authorization --scheme bearer --json") call=secret-add ;;
  "exec imp-host imp token new atc-cloud --scope manage --imps harness-* --grantable glm") call=token-new ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
if [ "${STUB_IMPD_FAIL_AT:-}" = "$call" ]; then
  echo "Error response from daemon: container 4f6c0a2e9d1b is not running" >&2
  exit 1
fi
case "$call" in
  info) jq . "$impd/info.json" ;;
  secret-ls) jq . "$impd/secrets.json" ;;
  token-ls) jq . "$impd/tokens.json" ;;
  secret-add)
    IFS= read -r value || true
    if [ -n "${STUB_SECRET_ADD_ERROR:-}" ]; then echo "$STUB_SECRET_ADD_ERROR" >&2; exit 2; fi
    printf '%s\n' "$value" > "$impd/secret-glm"
    secret='{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}'
    jq --argjson s "$secret" '. + [$s]' "$impd/secrets.json" > "$impd/secrets.next"
    mv "$impd/secrets.next" "$impd/secrets.json"
    jq -n --argjson s "$secret" '$s + {droppedGrants: 0}'
    ;;
  token-new)
    if [ -n "${STUB_TOKEN_NEW_ERROR:-}" ]; then echo "$STUB_TOKEN_NEW_ERROR" >&2; exit 1; fi
    token='{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}'
    jq --argjson t "$token" '. + [$t]' "$impd/tokens.json" > "$impd/tokens.next"
    mv "$impd/tokens.next" "$impd/tokens.json"
    echo "imp: token atc-cloud made; impd shows its secret only this once" >&2
    printf '%s\n' "$STUB_MINTED"
    ;;
esac
STUB
  chmod +x "$bin/docker"
}
