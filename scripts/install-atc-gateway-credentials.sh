#!/usr/bin/env bash
# Install the three credentials for the atc gateway's first canary on geoffcloud. Run it
# yourself; it never prints a value.
#
#   bash scripts/install-atc-gateway-credentials.sh
#
# 1. impd secret `glm`: the z.ai key from `atc-key zai` on this machine. impd's broker sets
#    `authorization: Bearer <key>` on requests to api.z.ai only.
# 2. The daemon bearer: 48 random bytes, base64url, made here. It goes to the 1Password item
#    cloud/atc-daemon-token (the gateway's copy) and to a root-only file on the host (the
#    daemon's LoadCredential source).
# 3. impd token `atc-cloud`: scope manage, imps harness-*, may grant glm. Minted on the host
#    and written straight to a root-only file there; it never reaches this machine.
#
# Every value travels on stdin (a pipe or SSH's stdin), never in argv, stdout or shell
# history. Each step skips itself when its result already exists, and stops when it finds
# only part of it, so a rerun after a failure finishes the rest and never overwrites.
# The host files live outside /var/lib/atc-daemon: systemd's StateDirectory would hand
# that tree to the atc user.
set -euo pipefail

host="${ATC_CREDENTIALS_HOST:-root@geoffcloud}"
vault="${ATC_CREDENTIALS_VAULT:-cloud}"
item="${ATC_DAEMON_TOKEN_ITEM:-atc-daemon-token}"
dir="${ATC_CREDENTIALS_DIR:-/var/lib/atc-daemon-secrets}"
op_settings="${CLOUD_OP_SETTINGS:-$HOME/projects/cloud/.claude/settings.local.json}"

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(jq -r '.env.OP_SERVICE_ACCOUNT_TOKEN // empty' "$op_settings")"
  export OP_SERVICE_ACCOUNT_TOKEN
fi

on_host() {
  ssh -o BatchMode=yes "$host" "$@"
}

step() {
  printf '\n== %s\n' "$*"
}

step "preflight"
op vault get "$vault" --format json > /dev/null
command -v atc-key > /dev/null
on_host true
on_host docker exec imp-host imp info --json |
  jq -e '.features.grantableTokens == true' > /dev/null ||
  {
    echo "impd lacks grantableTokens; nothing changed" >&2
    exit 1
  }
secrets="$(on_host docker exec imp-host imp secret ls --json)"
tokens="$(on_host docker exec imp-host imp token ls --json)"
has_item="$(op item list --vault "$vault" --format json | jq --arg t "$item" 'any(.[]; .title == $t)')"
on_host "install -d -m 0700 -o root -g root $dir"
host_files="$(on_host "ls $dir")"
echo "ok: 1Password vault $vault, atc-key, ssh $host, impd grantableTokens, $dir"

step "1/3 impd secret glm (api.z.ai, authorization: Bearer)"
glm_rules='[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}]'
if jq -e 'any(.[]; .name == "glm")' <<< "$secrets" > /dev/null; then
  if ! jq -e --argjson r "$glm_rules" 'any(.[]; .name == "glm" and .kind == "custom" and .rules == $r)' \
    <<< "$secrets" > /dev/null; then
    echo "glm exists with other rules; fix it by hand, then rerun" >&2
    exit 1
  fi
  echo "skip: glm exists with the expected rules"
else
  key="$(atc-key zai)"
  if [ -z "$key" ]; then
    echo "atc-key zai printed nothing; nothing changed" >&2
    exit 1
  fi
  printf '%s\n' "$key" |
    on_host docker exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai \
      --header authorization --scheme bearer --json |
    jq -c '{name, kind, rules}'
  unset key
fi

step "2/3 daemon bearer: 1Password $vault/$item and $host:$dir/gateway-token"
has_file=false
grep -qx gateway-token <<< "$host_files" && has_file=true
if [ "$has_item" = true ] && [ "$has_file" = true ]; then
  item_sum="$(op read "op://$vault/$item/credential" | sha256sum | cut -d' ' -f1)"
  host_sum="$(on_host "sha256sum $dir/gateway-token" | cut -d' ' -f1)"
  if [ "$item_sum" != "$host_sum" ]; then
    echo "the 1Password item and the host file differ; fix by hand, then rerun" >&2
    exit 1
  fi
  echo "skip: both exist and match"
elif [ "$has_item" = true ] || [ "$has_file" = true ]; then
  echo "only one copy exists (item: $has_item, host file: $has_file); fix by hand, then rerun" >&2
  exit 1
else
  bearer="$(openssl rand 48 | basenc --base64url -w0 | tr -d '=')"
  # the bearer reaches jq on stdin (printf is a builtin), never in jq's argv
  printf '%s\n' "$bearer" | jq -R --arg t "$item" \
    '{title: $t, category: "API_CREDENTIAL",
      fields: [{id: "credential", type: "CONCEALED", label: "credential", value: .}]}' |
    op item create --vault "$vault" - --format json | jq -r '"1Password: \(.title) (\(.id))"'
  # shellcheck disable=SC2016 # expanded on the host
  printf '%s\n' "$bearer" | on_host "umask 077; t=\$(mktemp $dir/.gateway-token.XXXXXX);
    IFS= read -r v; printf '%s\n' \"\$v\" > \"\$t\"; unset v;
    chmod 0400 \"\$t\"; mv \"\$t\" $dir/gateway-token"
  local_sum="$(printf '%s\n' "$bearer" | sha256sum | cut -d' ' -f1)"
  unset bearer
  item_sum="$(op read "op://$vault/$item/credential" | sha256sum | cut -d' ' -f1)"
  host_sum="$(on_host "sha256sum $dir/gateway-token" | cut -d' ' -f1)"
  if [ "$local_sum" != "$item_sum" ] || [ "$local_sum" != "$host_sum" ]; then
    echo "the copies differ; fix by hand before the gateway uses them" >&2
    exit 1
  fi
  echo "ok: the 1Password item and the host file match"
fi

step "3/3 impd token atc-cloud (manage, harness-*, grantable glm) to $host:$dir/imp-token"
has_token="$(jq 'any(.[]; .name == "atc-cloud")' <<< "$tokens")"
has_file=false
grep -qx imp-token <<< "$host_files" && has_file=true
if [ "$has_token" = true ] && [ "$has_file" = true ]; then
  if ! jq -e 'any(.[]; .name == "atc-cloud" and .scope == "manage"
      and .imps == ["harness-*"] and .grantable == ["glm"])' <<< "$tokens" > /dev/null; then
    echo "atc-cloud exists with another scope, imps or grantable list; fix it by hand, then rerun" >&2
    exit 1
  fi
  # the metadata cannot show the file is right, so ask impd who the saved token is: impd's
  # tokens.whoami on loopback. The token goes from the file to curl's stdin on the host,
  # never into argv or back here; only impd's answer and its HTTP status return. Only an
  # empty file (exit 3), impd's 401 for an unknown token, or a clear answer naming another
  # caller means the file is bad; anything else leaves it unchecked and changes nothing.
  whoami_status=0
  # shellcheck disable=SC2016 # expanded on the host
  answer="$(on_host "set -euo pipefail; v=''
    IFS= read -r v < $dir/imp-token || true
    test -n \"\$v\" || exit 3
    printf 'Authorization: Bearer %s\n' \"\$v\" |
      curl -sS --max-time 10 -H @- -H 'content-type: application/json' \
        --data '{\"json\":{}}' -w '\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami")" ||
    whoami_status=$?
  http_status="${answer##*$'\n'}"
  identity="${answer%$'\n'*}"
  unset answer
  bad_file=false
  unchecked=""
  if [ "$whoami_status" -eq 3 ]; then
    bad_file=true
  elif [ "$whoami_status" -ne 0 ]; then
    unchecked="the check on the host exited $whoami_status (curl's exit code, or 255 from ssh)"
  elif [ "$http_status" = 401 ]; then
    bad_file=true
  elif [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    unchecked="impd answered HTTP $http_status"
  elif ! jq -e '.json | type == "object" and (.kind | type) == "string" and (.name | type) == "string"' \
    <<< "$identity" > /dev/null 2>&1; then
    unchecked="impd answered HTTP $http_status without an identity"
  elif ! jq -e '.json.kind == "token" and .json.name == "atc-cloud"' <<< "$identity" > /dev/null; then
    bad_file=true
  fi
  if [ -n "$unchecked" ]; then
    echo "$unchecked, so $dir/imp-token is unchecked; nothing changed." >&2
    echo "Check impd on the host's 127.0.0.1:7070, then rerun" >&2
    exit 1
  fi
  if [ "$bad_file" = true ]; then
    echo "$dir/imp-token does not authenticate to impd as the token atc-cloud (empty, stale" >&2
    echo "or another token). impd shows a token once, so remove $dir/imp-token and run" >&2
    echo "'imp token rm atc-cloud' in imp-host, then rerun to mint a new one" >&2
    exit 1
  fi
  echo "skip: both exist, atc-cloud has the expected limits, and the file authenticates as it"
elif [ "$has_token" = true ] || [ "$has_file" = true ]; then
  echo "only one exists (token: $has_token, host file: $has_file). impd shows a token once," >&2
  echo "so run 'imp token rm atc-cloud' in imp-host and remove $dir/imp-token, then rerun" >&2
  exit 1
else
  on_host "set -euo pipefail; umask 077; t=\$(mktemp $dir/.imp-token.XXXXXX)
    trap 'rm -f \"\$t\"' EXIT
    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*' \
      --grantable glm > \"\$t\"
    test \$(wc -l < \"\$t\") -eq 1
    chmod 0400 \"\$t\"; mv \"\$t\" $dir/imp-token; trap - EXIT"
fi

step "check"
on_host docker exec imp-host imp secret ls --json |
  jq -c '.[] | select(.name == "glm") | {name, kind, rules, imps}'
on_host docker exec imp-host imp token ls --json |
  jq -c '.[] | select(.name == "atc-cloud") | {name, scope, imps, grantable}'
on_host "stat -c '%n %U %a %s bytes' $dir $dir/gateway-token $dir/imp-token"
