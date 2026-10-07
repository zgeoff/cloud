#!/usr/bin/env bash
# Hermetic test for install-atc-gateway-credentials.sh. It touches no host, no 1Password
# vault and no impd: op, atc-key and ssh are stand-ins from test-lib on this machine, and
# "the host" is a directory in the case's tree, where the ssh stand-in runs each remote
# command it knows with stand-ins for docker (impd), install and curl first on PATH.
# Every stand-in logs its argv as a JSON line. A failure that real state can reach runs
# on the real tool: ssh refused by a dead loopback port, install under a parent it may
# not write, curl refused by a closed port, and real curl against the impd and proxy
# stand-ins under a hostile curl config. Each case runs the script under `env -i` with only the variables it
# sets, and compares its whole stdout, stderr and call log, masking only the case's
# temporary path, the user running the suite, and ports the kernel picks.
#
# Tokens derive from SEED, which the run prints, so a failing run reproduces:
#
#   bash scripts/test-install-atc-gateway-credentials.sh
#   SEED=1234 CASE='stale saved token' bash scripts/test-install-atc-gateway-credentials.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/build-token.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-op.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-atc-key.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-host-ssh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-imp-host-docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-host-install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-impd-curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/start-stub-impd.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/start-stub-proxy.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/create-stub-remote-tools.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test-lib/require-remote-tool-stubs.sh"

it_skips_every_step_when_all_three_credentials_exist_and_match() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"
  chmod 0400 "$tree/host/secrets/gateway-token" "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 400 15 bytes
$tree/host/secrets/imp-token $(id -un) 400 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/op-token-seen" <<< ops_fixture_env
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_the_1Password_vault_is_missing() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_VAULT=missing \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
[ERROR] 2026/10/07 12:00:00 "missing" isn't a vault in this account. Specify the vault with its ID or name.
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","missing","--format","json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_atc_key_is_not_installed() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/vault/cloud" "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_reads_the_1Password_token_from_the_default_settings_file_when_the_environment_has_none() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"
  mkdir -p "$tree/home/projects/cloud/.claude"
  echo '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_settings"}}' \
    > "$tree/home/projects/cloud/.claude/settings.local.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/op-token-seen" <<< ops_fixture_settings
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_reads_the_1Password_token_from_the_settings_file_the_environment_names() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"
  echo '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_named"}}' > "$tree/settings.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    CLOUD_OP_SETTINGS="$tree/settings.json" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/op-token-seen" <<< ops_fixture_named
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_before_1Password_when_the_settings_file_is_missing_and_the_environment_has_no_token() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree" \
    STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
jq: error: Could not open file $tree/home/projects/cloud/.claude/settings.local.json: No such file or directory
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

# The real ssh, behind the logging stand-in, refused by a loopback port where nothing
# listens.
it_stops_with_ssh_exit_255_when_the_host_is_unreachable() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_SSH_PASS=1 \
    ATC_CREDENTIALS_HOST=ssh://root@127.0.0.1:1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< $'ssh: connect to host 127.0.0.1 port 1: Connection refused\r'
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","ssh://root@127.0.0.1:1","true"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_stops_when_impd_lacks_grantable_tokens() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"secretRebind":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd lacks grantableTokens; nothing changed
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_impd_turns_grantable_tokens_off() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":false,"secretRebind":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd lacks grantableTokens; nothing changed
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# A failing `imp info` reads as an impd without grantableTokens: the script's one message
# for both, after docker's own.
it_reports_missing_grantable_tokens_when_imp_info_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_IMPD_FAIL_AT=info \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Error response from daemon: container 4f6c0a2e9d1b is not running
impd lacks grantableTokens; nothing changed
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_imp_secret_ls_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_IMPD_FAIL_AT=secret-ls \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Error response from daemon: container 4f6c0a2e9d1b is not running
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_imp_token_ls_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_IMPD_FAIL_AT=token-ls \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
Error response from daemon: container 4f6c0a2e9d1b is not running
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_op_item_list_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_OP_FAIL_AT=item-list \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later.
EOF
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The real install on "the host" (test-lib/create-stub-host-install.sh drops only the
# owner, which needs root), under a parent directory it may not write. coreutils 9.4 (CI's
# ubuntu-24.04 runner image 20261004) and 9.11 word that failure differently, so the case
# accepts either exact line.
it_stops_when_the_host_cannot_create_the_secrets_directory() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud"
  chmod 0500 "$tree/host"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  grep -qxF \
    -e "/usr/bin/install: cannot change permissions of '$tree/host/secrets': No such file or directory" \
    -e "install: cannot create directory '$tree/host/secrets': Permission denied" \
    "$tree/err" || { cat "$tree/err"; echo "not coreutils 9.4's or 9.11's install error" >&2; exit 1; }
  [ "$(wc -l < "$tree/err")" = 1 ] || { cat "$tree/err"; echo "want one line on stderr" >&2; exit 1; }
  diff - "$tree/out" << EOF

== preflight
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_glm_exists_with_other_rules() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"x-api-key","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
glm exists with other rules; fix it by hand, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_adds_glm_from_the_z_ai_key_on_stdin_when_glm_is_missing() {
  local seed="$1" good_token zai_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  zai_token="$(build_token "$seed" zai)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_ZAI_KEY="$zai_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}]}

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["atc-key","zai"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","-i","imp-host","imp","secret","add","glm","--kind","custom","--hosts","api.z.ai","--header","authorization","--scheme","bearer","--json"]
["docker","exec","-i","imp-host","imp","secret","add","glm","--kind","custom","--hosts","api.z.ai","--header","authorization","--scheme","bearer","--json"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" -e "$zai_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/impd/secret-glm" <<< "$zai_token"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_atc_key_prints_no_z_ai_key() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_ZAI_KEY= ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
atc-key zai printed nothing; nothing changed
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["atc-key","zai"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ ! -e "$tree/impd/secret-glm" ] || { echo "impd stored a glm secret" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_with_imps_exit_code_when_impd_rejects_the_glm_secret() {
  local seed="$1" zai_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  zai_token="$(build_token "$seed" zai)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_ZAI_KEY="$zai_token" \
    STUB_SECRET_ADD_ERROR='imp: BAD_REQUEST: rule host api.z.ai is not allowed' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
imp: BAD_REQUEST: rule host api.z.ai is not allowed
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["atc-key","zai"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","-i","imp-host","imp","secret","add","glm","--kind","custom","--hosts","api.z.ai","--header","authorization","--scheme","bearer","--json"]
["docker","exec","-i","imp-host","imp","secret","add","glm","--kind","custom","--hosts","api.z.ai","--header","authorization","--scheme","bearer","--json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$zai_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ ! -e "$tree/impd/secret-glm" ] || { echo "impd stored a glm secret" >&2; exit 1; }
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_stops_when_the_1Password_item_and_the_host_file_differ() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'other-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the 1Password item and the host file differ; fix by hand, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  diff - "$tree/host/secrets/gateway-token" <<< other-bearer
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_1Password_item_holds_the_bearer() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one copy exists (item: true, host file: false); fix by hand, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  ls -A "$tree/host/secrets" > "$tree/host-files"
  diff /dev/null "$tree/host-files"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_host_file_holds_the_bearer() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one copy exists (item: false, host file: true); fix by hand, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  ls -A "$tree/vault/cloud" > "$tree/vault-items"
  diff /dev/null "$tree/vault-items"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_mints_one_bearer_into_1Password_and_a_root_only_host_file_when_neither_exists() {
  local seed="$1" good_token bearer status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
1Password: atc-daemon-token (fixture-item-id)
ok: the 1Password item and the host file match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 400 65 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","item","create","--vault","cloud","-","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","umask 077; t=\$(mktemp $tree/host/secrets/.gateway-token.XXXXXX);\\n    IFS= read -r v; printf '%s\\\\n' \\"\$v\\" > \\"\$t\\"; unset v;\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/gateway-token"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  bearer="$(cat "$tree/vault/cloud/atc-daemon-token")"
  [[ "$bearer" =~ ^[A-Za-z0-9_-]{64}$ ]] || { echo "the vault holds no 48-byte base64url bearer" >&2; exit 1; }
  diff - "$tree/host/secrets/gateway-token" <<< "$bearer"
  stat -c %a "$tree/host/secrets/gateway-token" > "$tree/mode"
  diff - "$tree/mode" <<< 400
  find "$tree/host/secrets" -name '.gateway-token.*' > "$tree/leftover"
  diff /dev/null "$tree/leftover"
  grep -F -e "$bearer" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/bearer-leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/bearer-leaks"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_the_minted_bearer_reads_back_differently_from_1Password() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_OP_READ_VALUE=a-different-value \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the copies differ; fix by hand before the gateway uses them
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
1Password: atc-daemon-token (fixture-item-id)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","item","create","--vault","cloud","-","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","umask 077; t=\$(mktemp $tree/host/secrets/.gateway-token.XXXXXX);\\n    IFS= read -r v; printf '%s\\\\n' \\"\$v\\" > \\"\$t\\"; unset v;\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/gateway-token"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The host file changes between its write and its checksum; nothing but an interception
# changes it at that moment, so the ssh stub appends to it and logs that it did.
it_stops_when_the_minted_bearer_reads_back_differently_from_the_host() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_ALTER_BEARER_BEFORE_SUM=1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the copies differ; fix by hand before the gateway uses them
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
1Password: atc-daemon-token (fixture-item-id)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","item","create","--vault","cloud","-","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","umask 077; t=\$(mktemp $tree/host/secrets/.gateway-token.XXXXXX);\\n    IFS= read -r v; printf '%s\\\\n' \\"\$v\\" > \\"\$t\\"; unset v;\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/gateway-token"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["gateway-token-altered"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_writes_no_host_file_when_creating_the_1Password_item_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_OP_FAIL_AT=item-create \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
[ERROR] 2026/10/07 12:00:00 Too many requests. Please try again later.
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","item","create","--vault","cloud","-","--format","json"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  ls -A "$tree/host/secrets" "$tree/vault/cloud" > "$tree/files"
  diff - "$tree/files" << EOF
$tree/host/secrets:

$tree/vault/cloud:
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The secrets directory turns read-only after preflight; nothing but an interception
# changes it at that moment, so the ssh stub does it and logs that it did. The real
# mktemp then fails on it; the remote write has no errexit, so its later steps fail on
# the empty path too, and the last one's exit ends the script.
it_stops_with_the_item_created_when_the_host_cannot_write_the_bearer() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+rwX "$tree" || true; rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_READONLY_AT_BEARER_WRITE=1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
mktemp: failed to create file via template '$tree/host/secrets/.gateway-token.XXXXXX': Permission denied
bash: line 2: : No such file or directory
chmod: cannot access '': No such file or directory
mv: cannot stat '': No such file or directory
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
1Password: atc-daemon-token (fixture-item-id)
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","item","create","--vault","cloud","-","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","umask 077; t=\$(mktemp $tree/host/secrets/.gateway-token.XXXXXX);\\n    IFS= read -r v; printf '%s\\\\n' \\"\$v\\" > \\"\$t\\"; unset v;\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/gateway-token"]
["secrets-dir-made-read-only"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  ls -A "$tree/host/secrets" > "$tree/host-files"
  diff /dev/null "$tree/host-files"
  ls -A "$tree/vault/cloud" > "$tree/vault-items"
  diff - "$tree/vault-items" <<< atc-daemon-token
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_accepts_a_saved_token_without_a_trailing_newline() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 64 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_an_empty_saved_token_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  : > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_followed_by_a_second_line_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\nextra\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_followed_by_a_blank_line_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_ending_in_a_carriage_return_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\r\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_holding_a_space_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s x\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# the host's bash drops a NUL from the value it reads (and warns), so the token's length
# no longer matches the file's size
it_rejects_a_saved_token_holding_a_NUL_byte_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\0\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
bash: line 4: warning: command substitution: ignored null byte in input
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -aF -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_stale_saved_token_that_impd_answers_with_401() {
  local seed="$1" good_token stale_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  stale_token="$(build_token "$seed" stale)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$stale_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" -e "$stale_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_that_impd_names_as_another_token() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=200 \
    STUB_WHOAMI_BODY='{"json":{"kind":"token","name":"atc-other","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_credential_that_impd_names_as_a_caller_other_than_a_token() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=200 \
    STUB_WHOAMI_BODY='{"json":{"kind":"dashboard","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_accepts_an_identity_that_impd_answers_with_a_2xx_other_than_200() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=201 \
    STUB_WHOAMI_BODY='{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_204_without_a_body() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=204 \
    STUB_WHOAMI_BODY= ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 204 without an identity, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_200_with_a_body_that_is_not_JSON() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=200 \
    STUB_WHOAMI_BODY='<html>bad gateway</html>' ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 200 without an identity, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_500() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=500 \
    STUB_WHOAMI_BODY='{"json":{"defined":false,"code":"INTERNAL_SERVER_ERROR","status":500,"message":"Internal server error"}}' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 500, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_403() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_WHOAMI_STATUS=403 \
    STUB_WHOAMI_BODY='{"json":{"defined":true,"code":"FORBIDDEN","status":403,"message":"forbidden"}}' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 403, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The real curl on "the host", refused by a loopback port where nothing listens. curl
# 8.5.0 (CI's ubuntu-24.04 runner image 20261004) and 8.22.0 word that error differently
# and time it, so the case masks the milliseconds and accepts either exact line.
it_leaves_the_saved_token_unchecked_when_impd_refuses_the_connection() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin-real-curl" STUB_GOOD_TOKEN="$good_token" ATC_IMPD_PORT=1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  sed -E '1s/ after [0-9]+ ms: / after N ms: /' "$tree/err" > "$tree/err-masked"
  head -n 1 "$tree/err-masked" > "$tree/curl-line"
  grep -qxF \
    -e "curl: (7) Failed to connect to 127.0.0.1 port 1 after N ms: Couldn't connect to server" \
    -e "curl: (7) Failed to connect to 127.0.0.1:1 after N ms: Could not connect to server" \
    "$tree/curl-line" || { cat "$tree/curl-line"; echo "not curl 8.5's or 8.22's refused-connection error" >&2; exit 1; }
  diff - <(tail -n +2 "$tree/err-masked") << EOF
the check on the host exited 7 (curl's exit code, or 255 from ssh), so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:1, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:1/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_resets_the_connection() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_CURL_EXIT=56 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
curl: (56) Recv failure: Connection reset by peer
the check on the host exited 56 (curl's exit code, or 255 from ssh), so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The ssh connection drops on the whoami check alone; nothing but an interception drops
# it at that moment, so the ssh stub does it and logs that it did.
it_leaves_the_saved_token_unchecked_when_ssh_drops_during_the_check() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_SSH_DROP_AT_WHOAMI=1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(head -n 1 "$tree/err") <<< $'Connection to geoffcloud closed by remote host.\r'
  diff - <(tail -n +2 "$tree/err") << EOF
the check on the host exited 255 (curl's exit code, or 255 from ssh), so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh-dropped-at-whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The saved token disappears after preflight listed it and before the check reads it;
# nothing but an interception removes it at that moment, so the ssh stub does it and logs
# that it did.
it_leaves_the_saved_token_unchecked_when_it_disappears_before_the_check() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_REMOVE_TOKEN_AT_WHOAMI=1 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the saved token is not a readable regular file on the host, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check $tree/host/secrets/imp-token on the host, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["imp-token-removed-at-whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_a_directory_stands_in_its_place() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  mkdir "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the saved token is not a readable regular file on the host, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check $tree/host/secrets/imp-token on the host, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_the_file_cannot_be_read() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+rwX "$tree" || true; rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"
  chmod 0000 "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the saved token is not a readable regular file on the host, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check $tree/host/secrets/imp-token on the host, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_atc_cloud_exists_with_another_scope() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"exec","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
atc-cloud exists with another scope, imps or grantable list; fix it by hand, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  jq -r 'select(.[0] == "curl")' "$tree/calls" > "$tree/curl-calls"
  diff /dev/null "$tree/curl-calls"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_atc_cloud_token_exists() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one exists (token: true, host file: false). impd shows a token once,
so run 'imp token rm atc-cloud' in imp-host and remove $tree/host/secrets/imp-token, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_saved_token_file_exists() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one exists (token: false, host file: true). impd shows a token once,
so run 'imp token rm atc-cloud' in imp-host and remove $tree/host/secrets/imp-token, then rerun
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/host/secrets/imp-token" <<< "$good_token"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_mints_atc_cloud_into_a_root_only_host_file_when_neither_exists() {
  local seed="$1" minted_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  minted_token="$(build_token "$seed" minted)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_MINTED="$minted_token" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
imp: token atc-cloud made; impd shows its secret only this once
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 400 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; umask 077; t=\$(mktemp $tree/host/secrets/.imp-token.XXXXXX)\\n    trap 'rm -f \\"\$t\\"' EXIT\\n    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*'       --grantable glm > \\"\$t\\"\\n    test \$(wc -l < \\"\$t\\") -eq 1\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/imp-token; trap - EXIT"]
["docker","exec","imp-host","imp","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  grep -F -e "$minted_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  diff - "$tree/host/secrets/imp-token" <<< "$minted_token"
  stat -c %a "$tree/host/secrets/imp-token" > "$tree/mode"
  diff - "$tree/mode" <<< 400
  find "$tree/host/secrets" -name '.imp-token.*' > "$tree/leftover"
  diff /dev/null "$tree/leftover"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_saves_no_token_when_the_mint_prints_more_than_one_line() {
  local seed="$1" minted_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  minted_token="$(build_token "$seed" minted)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_MINTED="$minted_token"$'\nimp: a notice on stdout' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
imp: token atc-cloud made; impd shows its secret only this once
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; umask 077; t=\$(mktemp $tree/host/secrets/.imp-token.XXXXXX)\\n    trap 'rm -f \\"\$t\\"' EXIT\\n    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*'       --grantable glm > \\"\$t\\"\\n    test \$(wc -l < \\"\$t\\") -eq 1\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/imp-token; trap - EXIT"]
["docker","exec","imp-host","imp","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm"]
EOF
  grep -F -e "$minted_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  ls -A "$tree/host/secrets" > "$tree/host-files"
  diff - "$tree/host-files" <<< gateway-token
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_saves_no_token_when_imp_token_new_fails() {
  local seed="$1" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_TOKEN_NEW_ERROR='imp: CONFLICT: token atc-cloud exists' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
imp: CONFLICT: token atc-cloud exists
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; umask 077; t=\$(mktemp $tree/host/secrets/.imp-token.XXXXXX)\\n    trap 'rm -f \\"\$t\\"' EXIT\\n    docker exec imp-host imp token new atc-cloud --scope manage --imps 'harness-*'       --grantable glm > \\"\$t\\"\\n    test \$(wc -l < \\"\$t\\") -eq 1\\n    chmod 0400 \\"\$t\\"; mv \\"\$t\\" $tree/host/secrets/imp-token; trap - EXIT"]
["docker","exec","imp-host","imp","token","new","atc-cloud","--scope","manage","--imps","harness-*","--grantable","glm"]
EOF
  ls -A "$tree/host/secrets" > "$tree/host-files"
  diff - "$tree/host-files" <<< gateway-token
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The bearer file disappears after step 2 checked it; nothing but an interception removes
# it at that moment, so the ssh stub does it before the final stat and logs that it did.
it_fails_the_final_check_when_a_saved_file_is_gone() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" \
    STUB_REMOVE_BEARER_BEFORE_STAT=1 ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
stat: cannot statx '$tree/host/secrets/gateway-token': No such file or directory
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:7070/rpc/tokens/whoami"]
["curl","-q","--noproxy","*","-sS","--max-time","10","-H","@-","-H","content-type: application/json","--data","{\\"json\\":{}}","-w","\\\\n%{http_code}","http://127.0.0.1:7070/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
["gateway-token-removed-before-stat"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# Real curl against the impd and proxy stand-ins (test-lib/start-stub-impd.sh and
# test-lib/start-stub-proxy.sh) under the hostile curl config whose controls are
# test-lib/test-start-stub-proxy.sh's curlrc case and this suite's noproxy-alone case:
# the token must reach impd's stand-in only, with no proxy connection and no trace.
it_sends_the_saved_token_to_impd_alone_under_the_hostile_curl_config() {
  local seed="$1" good_token impd_port proxy_port status=0
  tree="$(mktemp -d)"
  trap 'kill $(cat "$tree/impd-whoami/pid" "$tree/proxy/pid" 2> /dev/null) 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key impd proxy
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  printf '%s' "$good_token" > "$tree/impd-whoami/good-token"
  impd_port="$(cat "$tree/impd-whoami/port")"
  proxy_port="$(cat "$tree/proxy/port")"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
  mkdir "$tree/curl-home" "$tree/xdg"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$proxy_port" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/xdg/curlrc"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_GOOD_TOKEN="$good_token" CURL_HOME="$tree/curl-home" XDG_CONFIG_HOME="$tree/xdg" \
    http_proxy="http://127.0.0.1:$proxy_port" HTTP_PROXY="http://127.0.0.1:$proxy_port" \
    https_proxy="http://127.0.0.1:$proxy_port" HTTPS_PROXY="http://127.0.0.1:$proxy_port" \
    all_proxy="http://127.0.0.1:$proxy_port" ALL_PROXY="http://127.0.0.1:$proxy_port" NO_PROXY= \
    no_proxy= ATC_IMPD_PORT="$impd_port" STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:$impd_port/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  ls -A "$tree/impd-whoami" "$tree/proxy" > "$tree/stand-in-files"
  diff - "$tree/stand-in-files" << EOF
$tree/impd-whoami:
good-token
pid
port

$tree/proxy:
pid
port
EOF
  [ ! -e "$tree/trace.txt" ] || { echo "curl wrote a trace" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_a_stale_saved_token_without_leaking_it_under_the_hostile_curl_config() {
  local seed="$1" good_token stale_token impd_port proxy_port status=0
  tree="$(mktemp -d)"
  trap 'kill $(cat "$tree/impd-whoami/pid" "$tree/proxy/pid" 2> /dev/null) 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key impd proxy
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  stale_token="$(build_token "$seed" stale)"
  printf '%s' "$good_token" > "$tree/impd-whoami/good-token"
  impd_port="$(cat "$tree/impd-whoami/port")"
  proxy_port="$(cat "$tree/proxy/port")"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
  mkdir "$tree/curl-home" "$tree/xdg"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$proxy_port" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/xdg/curlrc"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$stale_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_GOOD_TOKEN="$good_token" CURL_HOME="$tree/curl-home" XDG_CONFIG_HOME="$tree/xdg" \
    http_proxy="http://127.0.0.1:$proxy_port" HTTP_PROXY="http://127.0.0.1:$proxy_port" \
    https_proxy="http://127.0.0.1:$proxy_port" HTTPS_PROXY="http://127.0.0.1:$proxy_port" \
    all_proxy="http://127.0.0.1:$proxy_port" ALL_PROXY="http://127.0.0.1:$proxy_port" NO_PROXY= \
    no_proxy= ATC_IMPD_PORT="$impd_port" STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:$impd_port/rpc/tokens/whoami"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" -e "$stale_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  ls -A "$tree/impd-whoami" "$tree/proxy" > "$tree/stand-in-files"
  diff - "$tree/stand-in-files" << EOF
$tree/impd-whoami:
good-token
pid
port

$tree/proxy:
pid
port
EOF
  [ ! -e "$tree/trace.txt" ] || { echo "curl wrote a trace" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# HOME's .curlrc alone traces to stdout, which the host command returns here
it_keeps_the_saved_token_out_of_the_output_under_a_curlrc_in_HOME_alone() {
  local seed="$1" good_token impd_port proxy_port status=0
  tree="$(mktemp -d)"
  trap 'kill $(cat "$tree/impd-whoami/pid" "$tree/proxy/pid" 2> /dev/null) 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree" atc-key impd proxy
  mkdir "$tree/vault/cloud" "$tree/host/secrets"
  good_token="$(build_token "$seed" good)"
  printf '%s' "$good_token" > "$tree/impd-whoami/good-token"
  impd_port="$(cat "$tree/impd-whoami/port")"
  proxy_port="$(cat "$tree/proxy/port")"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_GOOD_TOKEN="$good_token" http_proxy="http://127.0.0.1:$proxy_port" \
    ATC_IMPD_PORT="$impd_port" STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" << EOF

== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, $tree/host/secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
$tree/host/secrets $(id -un) 700 $(stat -c %s "$tree/host/secrets") bytes
$tree/host/secrets/gateway-token $(id -un) 644 15 bytes
$tree/host/secrets/imp-token $(id -un) 644 65 bytes
EOF
  diff - "$tree/calls" << EOF
["op","vault","get","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","true"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","info","--json"]
["docker","exec","imp-host","imp","info","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["op","item","list","--vault","cloud","--format","json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","install -d -m 0700 -o root -g root $tree/host/secrets"]
["install","-d","-m","0700","-o","root","-g","root","$tree/host/secrets"]
["ssh","-o","BatchMode=yes","root@geoffcloud","ls $tree/host/secrets"]
["op","read","op://cloud/atc-daemon-token/credential"]
["ssh","-o","BatchMode=yes","root@geoffcloud","sha256sum $tree/host/secrets/gateway-token"]
["ssh","-o","BatchMode=yes","root@geoffcloud","set -euo pipefail; export LC_ALL=C\\n    test -f $tree/host/secrets/imp-token && test -r $tree/host/secrets/imp-token || exit 120\\n    size=\$(wc -c < $tree/host/secrets/imp-token) || exit 120\\n    v=\$(cat $tree/host/secrets/imp-token && printf x) || exit 120; v=\${v%x}\\n    test \\"\${#v}\\" = \\"\$size\\" || exit 3\\n    v=\${v%\$'\\\\n'}\\n    [[ \\"\$v\\" =~ ^[[:graph:]]+\$ ]] || exit 3\\n    printf 'Authorization: Bearer %s\\\\n' \\"\$v\\" |\\n      env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy         -u ALL_PROXY -u no_proxy -u NO_PROXY         curl -q --noproxy '*' -sS --max-time 10 -H @- -H 'content-type: application/json'         --data '{\\"json\\":{}}' -w '\\\\n%{http_code}' http://127.0.0.1:$impd_port/rpc/tokens/whoami"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","secret","ls","--json"]
["docker","exec","imp-host","imp","secret","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","docker","exec","imp-host","imp","token","ls","--json"]
["docker","exec","imp-host","imp","token","ls","--json"]
["ssh","-o","BatchMode=yes","root@geoffcloud","stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token"]
EOF
  jq -r 'select(join(" ") | test("token (new|rm)"))' "$tree/calls" > "$tree/mints"
  diff /dev/null "$tree/mints"
  grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err" > "$tree/leaks" || [ "$?" = 1 ]
  diff /dev/null "$tree/leaks"
  ls -A "$tree/impd-whoami" "$tree/proxy" > "$tree/stand-in-files"
  diff - "$tree/stand-in-files" << EOF
$tree/impd-whoami:
good-token
pid
port

$tree/proxy:
pid
port
EOF
  [ ! -e "$tree/trace.txt" ] || { echo "curl wrote a trace" >&2; exit 1; }
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# The control for the hostile-config cases above: curl with --noproxy alone, without the
# script's -q, still reads CURL_HOME's .curlrc and traces the bearer, so a case that finds
# no trace proves the script's isolation, not a dead config. It runs curl itself, not
# the script, because what it pins is real curl's reading of that config.
it_traces_the_bearer_when_curl_runs_with_noproxy_alone_under_the_hostile_config() {
  local seed="$1" stale_token
  tree="$(mktemp -d)"
  trap 'kill $(cat "$tree/impd-whoami/pid" "$tree/proxy/pid" 2> /dev/null) 2> /dev/null || true; rm -rf "$tree"' EXIT
  setup_test "$tree" impd proxy
  stale_token="$(build_token "$seed" stale)"
  mkdir "$tree/curl-home"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$(cat "$tree/proxy/port")" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"

  printf 'Authorization: Bearer %s\n' "$stale_token" |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" CURL_HOME="$tree/curl-home" \
      curl --noproxy '*' -sS --max-time 5 -H @- \
      "http://127.0.0.1:$(cat "$tree/impd-whoami/port")/rpc/tokens/whoami" > /dev/null 2>&1 || true

  [ -f "$tree/trace.txt" ] || { echo "curl wrote no trace" >&2; exit 1; }
  sed -E 's/^[0-9a-f]{4}: //' "$tree/trace.txt" | tr -d '\n' | grep -qF -- "$stale_token" ||
    { echo "the trace does not hold the bearer" >&2; exit 1; }
}

# Boot data every case needs: the script, the roots of the 1Password stand-in's vaults
# (vault/) and of "the host" (host/), impd's state directory (impd/), and the stand-ins
# from test-lib for op, ssh, and the host's docker (impd), install and curl, which log
# each call's argv as a JSON line and end with exit 97 on a call they do not know.
# host-bin-real-curl holds the same host stand-ins without curl, for the cases that run
# the real one. Each of the three bin directories also gets fail-closed stand-ins for the
# remote tools the others do not provide (scp, sftp, rsync, tailscale, and ssh on "the
# host"), and a guard ends the case unless every remote tool resolves to a stand-in. The config names what a case wires on top: atc-key, the stand-in for the
# z.ai key; impd, the stand-in impd whoami server, started in impd-whoami/; and proxy,
# the recording proxy, started in proxy/.
setup_test() {
  local tree="$1" part
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/host-bin-real-curl" "$tree/home" "$tree/tmp" \
    "$tree/vault" "$tree/impd" "$tree/host"
  : > "$tree/calls"
  : > "$tree/host-output"
  cp "$(dirname "${BASH_SOURCE[0]}")/install-atc-gateway-credentials.sh" "$tree/"
  create_stub_op "$tree/bin"
  create_stub_host_ssh "$tree/bin"
  create_stub_imp_host_docker "$tree/host-bin"
  create_stub_host_install "$tree/host-bin"
  create_stub_impd_curl "$tree/host-bin"
  create_stub_imp_host_docker "$tree/host-bin-real-curl"
  create_stub_host_install "$tree/host-bin-real-curl"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin" "$tree/calls" ssh scp sftp rsync tailscale
  create_stub_remote_tools "$tree/host-bin-real-curl" "$tree/calls" ssh scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
  require_remote_tool_stubs "$tree/host-bin"
  require_remote_tool_stubs "$tree/host-bin-real-curl"
  for part in "${@:2}"; do
    case "$part" in
      atc-key) create_stub_atc_key "$tree/bin" ;;
      impd) mkdir "$tree/impd-whoami" && start_stub_impd "$tree/impd-whoami" ;;
      proxy) mkdir "$tree/proxy" && start_stub_proxy "$tree/proxy" ;;
    esac
  done
}

seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
echo "seed $seed (rerun with SEED=$seed)"
run_cases "$seed"
