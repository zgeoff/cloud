#!/usr/bin/env bash
# Hermetic test for install-atc-gateway-credentials.sh. It touches no host, no 1Password
# vault and no impd: op, atc-key and ssh are stubs on this machine, and "the host" is a
# directory in the case's tree, where the ssh stub runs each remote command with host
# stubs for docker (impd), install and curl first on PATH. Every stub logs its argv as a
# JSON line. Each case runs the script under `env -i` with only the variables it sets.
#
# Tokens derive from SEED, which the run prints, so a failing run reproduces:
#
#   bash scripts/test-install-atc-gateway-credentials.sh
#   SEED=1234 CASE='stale token' bash scripts/test-install-atc-gateway-credentials.sh
set -euo pipefail

it_skips_every_step_when_all_three_credentials_exist_and_match() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff - <(jq -r 'if .[0] == "ssh" then "ssh " + .[3] + " " + (.[4:] | join(" ") | split("\n")[0]) else join(" ") end' "$tree/calls") << EOF
op vault get cloud --format json
ssh root@geoffcloud true
ssh root@geoffcloud docker exec imp-host imp info --json
docker exec imp-host imp info --json
ssh root@geoffcloud docker exec imp-host imp secret ls --json
docker exec imp-host imp secret ls --json
ssh root@geoffcloud docker exec imp-host imp token ls --json
docker exec imp-host imp token ls --json
op item list --vault cloud --format json
ssh root@geoffcloud install -d -m 0700 -o root -g root $tree/host/secrets
install -d -m 0700 -o root -g root $tree/host/secrets
ssh root@geoffcloud ls $tree/host/secrets
op read op://cloud/atc-daemon-token/credential
ssh root@geoffcloud sha256sum $tree/host/secrets/gateway-token
ssh root@geoffcloud set -euo pipefail; export LC_ALL=C
curl -q --noproxy * -sS --max-time 10 -H @- -H content-type: application/json --data {"json":{}} -w \n%{http_code} http://127.0.0.1:7070/rpc/tokens/whoami
ssh root@geoffcloud docker exec imp-host imp secret ls --json
docker exec imp-host imp secret ls --json
ssh root@geoffcloud docker exec imp-host imp token ls --json
docker exec imp-host imp token ls --json
ssh root@geoffcloud stat -c '%n %U %a %s bytes' $tree/host/secrets $tree/host/secrets/gateway-token $tree/host/secrets/imp-token
EOF
  diff - "$tree/op-token-seen" <<< ops_fixture_env
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_the_1Password_vault_is_missing() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_VAULT=missing \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << 'EOF'
[ERROR] 2026/10/07 12:00:00 "missing" isn't a vault in this account. Specify the vault with its ID or name.
EOF
  diff - "$tree/out" <<< $'\n== preflight'
  diff - <(jq -r 'join(" ")' "$tree/calls") <<< 'op vault get missing --format json'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_atc_key_is_not_installed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  rm "$tree/bin/atc-key"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - "$tree/out" <<< $'\n== preflight'
  diff - <(jq -r 'join(" ")' "$tree/calls") <<< 'op vault get cloud --format json'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_reads_the_1Password_token_from_the_default_settings_file_when_the_environment_has_none() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  rm "$tree/bin/atc-key"
  mkdir -p "$tree/home/projects/cloud/.claude"
  echo '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_settings"}}' \
    > "$tree/home/projects/cloud/.claude/settings.local.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/op-token-seen" <<< ops_fixture_settings
  diff /dev/null "$tree/err"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_reads_the_1Password_token_from_the_settings_file_the_environment_names() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  rm "$tree/bin/atc-key"
  echo '{"env":{"OP_SERVICE_ACCOUNT_TOKEN":"ops_fixture_named"}}' > "$tree/settings.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    CLOUD_OP_SETTINGS="$tree/settings.json" STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/op-token-seen" <<< ops_fixture_named
  diff /dev/null "$tree/err"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_before_1Password_when_the_settings_file_is_missing_and_the_environment_has_no_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    STUB_TREE="$tree" STUB_HOST=root@geoffcloud STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
jq: error: Could not open file $tree/home/projects/cloud/.claude/settings.local.json: No such file or directory
EOF
  diff /dev/null "$tree/out"
  diff /dev/null "$tree/calls"
  [ "$status" = 2 ] || { echo "exit $status, want 2" >&2; exit 1; }
}

it_stops_with_ssh_exit_255_when_the_host_is_unreachable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" ATC_CREDENTIALS_HOST=root@unreachable.invalid \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'ssh: Could not resolve hostname unreachable.invalid: Name or service not known'
  diff - <(jq -r 'join(" ")' "$tree/calls") << 'EOF'
op vault get cloud --format json
ssh -o BatchMode=yes root@unreachable.invalid true
EOF
  [ "$status" = 255 ] || { echo "exit $status, want 255" >&2; exit 1; }
}

it_stops_when_impd_lacks_grantable_tokens() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.26.0","features":{"sessionOffsets":true,"leases":true}}' > "$tree/impd/info.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'impd lacks grantableTokens; nothing changed'
  diff - <(jq -r 'join(" ")' "$tree/calls" | tail -n 1) <<< 'docker exec imp-host imp info --json'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_glm_exists_with_other_rules() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"x-api-key","scheme":"raw"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'glm exists with other rules; fix it by hand, then rerun'
  diff /dev/null <(jq -r 'select(.[0] == "atc-key" or (.[1:] | join(" ") | test("secret add")))' "$tree/calls")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_adds_glm_from_the_z_ai_key_on_stdin_when_glm_is_missing() {
  local seed="$1" good_token zai_key status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  zai_key="$(build_token "$seed" zai)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_ZAI_KEY="$zai_key" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  diff - <(sed -n '/^== 1\/3/,/^$/p' "$tree/out") << 'EOF'
== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}]}

EOF
  diff - "$tree/impd/secret-glm" <<< "$zai_key"
  diff - <(jq -r 'select(.[0] == "atc-key" or .[1] == "exec") | join(" ")' "$tree/calls" | sed -n '4,5p') << 'EOF'
atc-key zai
docker exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai --header authorization --scheme bearer --json
EOF
  diff /dev/null <(grep -F -e "$zai_key" -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_atc_key_prints_no_z_ai_key() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_ZAI_KEY= \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'atc-key zai printed nothing; nothing changed'
  diff - <(jq -r 'join(" ")' "$tree/calls" | tail -n 1) <<< 'atc-key zai'
  [ ! -e "$tree/impd/secret-glm" ] || { echo "impd stored a glm secret" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_the_1Password_item_and_the_host_file_differ() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'other-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the 1Password item and the host file differ; fix by hand, then rerun'
  diff - "$tree/host/secrets/gateway-token" <<< other-bearer
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_1Password_item_holds_the_bearer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'only one copy exists (item: true, host file: false); fix by hand, then rerun'
  diff /dev/null <(ls -A "$tree/host/secrets")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_host_file_holds_the_bearer() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'only one copy exists (item: false, host file: true); fix by hand, then rerun'
  diff /dev/null <(ls -A "$tree/vault/cloud")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_mints_one_bearer_into_1Password_and_a_root_only_host_file_when_neither_exists() {
  local seed="$1" good_token bearer status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  bearer="$(cat "$tree/vault/cloud/atc-daemon-token")"
  [[ "$bearer" =~ ^[A-Za-z0-9_-]{64}$ ]] || { echo "the vault holds no 48-byte base64url bearer" >&2; exit 1; }
  diff - "$tree/host/secrets/gateway-token" <<< "$bearer"
  diff - <(stat -c %a "$tree/host/secrets/gateway-token") <<< 400
  diff /dev/null <(find "$tree/host/secrets" -name '.gateway-token.*')
  diff /dev/null "$tree/err"
  diff - <(sed -n '/^== 2\/3/,/^$/p' "$tree/out") << EOF
== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:$tree/host/secrets/gateway-token
1Password: atc-daemon-token (fixture-item-id)
ok: the 1Password item and the host file match

EOF
  diff /dev/null <(grep -F -e "$bearer" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_stops_when_the_minted_bearer_reads_back_differently() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_OP_READ_VALUE=a-different-value \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" <<< 'the copies differ; fix by hand before the gateway uses them'
  diff - <(jq -r 'join(" ")' "$tree/calls" | tail -n 1) <<< "ssh -o BatchMode=yes root@geoffcloud sha256sum $tree/host/secrets/gateway-token"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_accepts_a_saved_token_without_a_trailing_newline() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  grep -x 'skip: both exist, atc-cloud has the expected limits, and the file authenticates as it' "$tree/out"
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_an_empty_saved_token_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_followed_by_a_second_line_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_followed_by_a_blank_line_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_ending_in_a_carriage_return_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_holding_a_space_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# the host's bash drops a NUL from the value it reads (and warns), so the token's length
# no longer matches the file's size
it_rejects_a_saved_token_holding_a_NUL_byte_without_asking_impd() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(jq -r 'select(.[0] == "curl" or (join(" ") | test("token (new|rm)")))' "$tree/calls")
  diff /dev/null <(grep -aF -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_stale_saved_token_that_impd_answers_with_401() {
  local seed="$1" good_token stale_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff - <(jq -r 'select(.[0] == "curl") | .[0]' "$tree/calls") <<< curl
  diff /dev/null <(grep -F -e "$good_token" -e "$stale_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_token_that_impd_names_as_another_token() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_rejects_a_saved_credential_that_impd_names_as_a_caller_other_than_a_token() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_accepts_an_identity_that_impd_answers_with_a_2xx_other_than_200() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  grep -x 'skip: both exist, atc-cloud has the expected limits, and the file authenticates as it' "$tree/out"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_204_without_a_body() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
    STUB_WHOAMI_BODY= \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 204 without an identity, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_200_with_a_body_that_is_not_JSON() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
    STUB_WHOAMI_BODY='<html>bad gateway</html>' \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
impd answered HTTP 200 without an identity, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_500() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_answers_403() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_refuses_the_connection() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" STUB_GOOD_TOKEN="$good_token" STUB_CURL_EXIT=7 \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
curl: (7) Failed to connect to 127.0.0.1 port 7070 after 0 ms: Couldn't connect to server
the check on the host exited 7 (curl's exit code, or 255 from ssh), so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_impd_resets_the_connection() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The ssh connection drops on the whoami check alone; nothing but an interception drops
# it at that moment, so the ssh stub does it and logs that it did.
it_leaves_the_saved_token_unchecked_when_ssh_drops_during_the_check() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  diff - <(jq -r 'select(length == 1) | .[0]' "$tree/calls") <<< ssh-dropped-at-whoami
  diff - "$tree/err" << EOF
Connection to geoffcloud closed by remote host.
the check on the host exited 255 (curl's exit code, or 255 from ssh), so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check impd on the host's 127.0.0.1:7070, then rerun
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The saved token disappears after preflight listed it and before the check reads it;
# nothing but an interception removes it at that moment, so the ssh stub does it and logs
# that it did.
it_leaves_the_saved_token_unchecked_when_it_disappears_before_the_check() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  diff - <(jq -r 'select(length == 1) | .[0]' "$tree/calls") <<< imp-token-removed-at-whoami
  diff - "$tree/err" << EOF
the saved token is not a readable regular file on the host, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check $tree/host/secrets/imp-token on the host, then rerun
EOF
  diff /dev/null <(jq -r 'select(.[0] == "curl") | .[0]' "$tree/calls")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_a_directory_stands_in_its_place() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  mkdir "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
the saved token is not a readable regular file on the host, so $tree/host/secrets/imp-token is unchecked; nothing changed.
Check $tree/host/secrets/imp-token on the host, then rerun
EOF
  diff /dev/null <(jq -r 'select(.[0] == "curl") | .[0]' "$tree/calls")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_leaves_the_saved_token_unchecked_when_the_file_cannot_be_read() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'chmod -R u+rwX "$tree"; rm -rf "$tree"' EXIT
  setup_case "$tree"
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
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_atc_cloud_exists_with_another_scope() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  diff - "$tree/err" <<< 'atc-cloud exists with another scope, imps or grantable list; fix it by hand, then rerun'
  diff /dev/null <(jq -r 'select(.[0] == "curl") | .[0]' "$tree/calls")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_atc_cloud_token_exists() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one exists (token: true, host file: false). impd shows a token once,
so run 'imp token rm atc-cloud' in imp-host and remove $tree/host/secrets/imp-token, then rerun
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_stops_when_only_the_saved_token_file_exists() {
  local seed="$1" good_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
only one exists (token: false, host file: true). impd shows a token once,
so run 'imp token rm atc-cloud' in imp-host and remove $tree/host/secrets/imp-token, then rerun
EOF
  diff - "$tree/host/secrets/imp-token" <<< "$good_token"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_mints_atc_cloud_into_a_root_only_host_file_when_neither_exists() {
  local seed="$1" minted_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  diff - "$tree/host/secrets/imp-token" <<< "$minted_token"
  diff - <(stat -c %a "$tree/host/secrets/imp-token") <<< 400
  diff /dev/null <(find "$tree/host/secrets" -name '.imp-token.*')
  diff - <(jq -r 'select(.[0] == "docker" and .[3] == "imp" and .[4] == "token" and .[5] == "new") | join(" ")' "$tree/calls") << 'EOF'
docker exec imp-host imp token new atc-cloud --scope manage --imps harness-* --grantable glm
EOF
  diff - "$tree/err" <<< 'imp: token atc-cloud made; impd shows its secret only this once'
  diff - <(tail -n 4 "$tree/out" | head -n 1) <<< '{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}'
  diff /dev/null <(grep -F -e "$minted_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_saves_no_token_when_the_mint_prints_more_than_one_line() {
  local seed="$1" minted_token status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_case "$tree"
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

  diff - <(ls -A "$tree/host/secrets") <<< gateway-token
  diff - "$tree/err" <<< 'imp: token atc-cloud made; impd shows its secret only this once'
  diff - <(tail -n 1 "$tree/out") <<< "== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:$tree/host/secrets/imp-token"
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# The hostile curl config the real-curl cases run under: .curlrc files in HOME, CURL_HOME
# and XDG_CONFIG_HOME that turn on -v and --trace-ascii and set a proxy, and every proxy
# variable pointing at a listener that records what reaches it. These two controls prove
# that config is live, so the isolation cases below are not passing on a dead config.
it_routes_a_plain_curl_through_the_proxy_under_the_hostile_config() {
  local seed="$1" stale_token impd_port proxy_port deadline=$((SECONDS + 10))
  tree="$(mktemp -d)"
  trap 'kill "$listener" 2> /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree"
  stale_token="$(build_token "$seed" stale)"
  STUB_GOOD_TOKEN=unused python3 "$tree/listen.py" "$tree/listener" &
  listener=$!
  until [ -f "$tree/listener/ports" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "the impd and proxy stand-ins did not start within 10s" >&2; exit 1; }
    sleep 0.05
  done
  read -r impd_port proxy_port < "$tree/listener/ports"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"

  printf 'Authorization: Bearer %s\n' "$stale_token" |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" http_proxy="http://127.0.0.1:$proxy_port" \
      curl -sS --max-time 5 -H @- "http://127.0.0.1:$impd_port/rpc/tokens/whoami" \
      > "$tree/out" 2>&1 || true

  diff - <(head -n 1 "$tree/listener/proxy.bytes") <<< connection
}

it_traces_the_token_when_curl_runs_with_noproxy_alone_under_the_hostile_config() {
  local seed="$1" stale_token impd_port proxy_port deadline=$((SECONDS + 10))
  tree="$(mktemp -d)"
  trap 'kill "$listener" 2> /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree"
  stale_token="$(build_token "$seed" stale)"
  STUB_GOOD_TOKEN=unused python3 "$tree/listen.py" "$tree/listener" &
  listener=$!
  until [ -f "$tree/listener/ports" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "the impd and proxy stand-ins did not start within 10s" >&2; exit 1; }
    sleep 0.05
  done
  read -r impd_port proxy_port < "$tree/listener/ports"
  printf -- '-v\nproxy = %s\ntrace-ascii = %s\n' "http://127.0.0.1:$proxy_port" "$tree/trace.txt" \
    > "$tree/curl-home/.curlrc"

  printf 'Authorization: Bearer %s\n' "$stale_token" |
    env -i PATH=/usr/bin:/bin HOME="$tree/home" CURL_HOME="$tree/curl-home" \
      curl --noproxy '*' -sS --max-time 5 -H @- "http://127.0.0.1:$impd_port/rpc/tokens/whoami" \
      > "$tree/out" 2>&1 || true

  sed -E 's/^[0-9a-f]{4}: //' "$tree/trace.txt" | tr -d '\n' | grep -qF -- "$stale_token" ||
    { echo "the trace does not hold the token" >&2; exit 1; }
}

it_sends_the_saved_token_to_impd_alone_under_the_hostile_curl_config() {
  local seed="$1" good_token impd_port proxy_port deadline=$((SECONDS + 10)) status=0
  tree="$(mktemp -d)"
  trap 'kill "$listener" 2> /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  STUB_GOOD_TOKEN="$good_token" python3 "$tree/listen.py" "$tree/listener" &
  listener=$!
  until [ -f "$tree/listener/ports" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "the impd and proxy stand-ins did not start within 10s" >&2; exit 1; }
    sleep 0.05
  done
  read -r impd_port proxy_port < "$tree/listener/ports"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
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
    CURL_HOME="$tree/curl-home" XDG_CONFIG_HOME="$tree/xdg" \
    http_proxy="http://127.0.0.1:$proxy_port" HTTP_PROXY="http://127.0.0.1:$proxy_port" \
    https_proxy="http://127.0.0.1:$proxy_port" HTTPS_PROXY="http://127.0.0.1:$proxy_port" \
    all_proxy="http://127.0.0.1:$proxy_port" ALL_PROXY="http://127.0.0.1:$proxy_port" \
    NO_PROXY= no_proxy= ATC_IMPD_PORT="$impd_port" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  grep -x 'skip: both exist, atc-cloud has the expected limits, and the file authenticates as it' "$tree/out"
  diff - <(ls -A "$tree/listener") <<< ports
  [ ! -e "$tree/trace.txt" ] || { echo "curl wrote a trace" >&2; exit 1; }
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_rejects_a_stale_saved_token_without_leaking_it_under_the_hostile_curl_config() {
  local seed="$1" good_token stale_token impd_port proxy_port deadline=$((SECONDS + 10)) status=0
  tree="$(mktemp -d)"
  trap 'kill "$listener" 2> /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  stale_token="$(build_token "$seed" stale)"
  STUB_GOOD_TOKEN="$good_token" python3 "$tree/listen.py" "$tree/listener" &
  listener=$!
  until [ -f "$tree/listener/ports" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "the impd and proxy stand-ins did not start within 10s" >&2; exit 1; }
    sleep 0.05
  done
  read -r impd_port proxy_port < "$tree/listener/ports"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
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
    CURL_HOME="$tree/curl-home" XDG_CONFIG_HOME="$tree/xdg" \
    http_proxy="http://127.0.0.1:$proxy_port" HTTP_PROXY="http://127.0.0.1:$proxy_port" \
    https_proxy="http://127.0.0.1:$proxy_port" HTTPS_PROXY="http://127.0.0.1:$proxy_port" \
    all_proxy="http://127.0.0.1:$proxy_port" ALL_PROXY="http://127.0.0.1:$proxy_port" \
    NO_PROXY= no_proxy= ATC_IMPD_PORT="$impd_port" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/err" << EOF
$tree/host/secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
$tree/host/secrets/imp-token and run 'imp token rm atc-cloud' in imp-host, then rerun to mint
a new one
EOF
  diff - <(ls -A "$tree/listener") <<< ports
  [ ! -e "$tree/trace.txt" ] || { echo "curl wrote a trace" >&2; exit 1; }
  diff /dev/null <(grep -F -e "$good_token" -e "$stale_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

# HOME's .curlrc alone traces to stdout, which the host command returns here
it_keeps_the_saved_token_out_of_the_output_under_a_curlrc_in_HOME_alone() {
  local seed="$1" good_token impd_port proxy_port deadline=$((SECONDS + 10)) status=0
  tree="$(mktemp -d)"
  trap 'kill "$listener" 2> /dev/null; rm -rf "$tree"' EXIT
  setup_case "$tree"
  good_token="$(build_token "$seed" good)"
  STUB_GOOD_TOKEN="$good_token" python3 "$tree/listen.py" "$tree/listener" &
  listener=$!
  until [ -f "$tree/listener/ports" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "the impd and proxy stand-ins did not start within 10s" >&2; exit 1; }
    sleep 0.05
  done
  read -r impd_port proxy_port < "$tree/listener/ports"
  printf -- '-v\n--trace-ascii -\nproxy = %s\n' "http://127.0.0.1:$proxy_port" > "$tree/home/.curlrc"
  echo '{"version":"0.27.0","features":{"sessionOffsets":true,"leases":true,"grantableTokens":true,"secretRebind":true}}' > "$tree/impd/info.json"
  echo '[{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/secrets.json"
  echo '[{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}]' > "$tree/impd/tokens.json"
  printf fixture-bearer > "$tree/vault/cloud/atc-daemon-token"
  printf 'fixture-bearer\n' > "$tree/host/secrets/gateway-token"
  printf '%s\n' "$good_token" > "$tree/host/secrets/imp-token"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    http_proxy="http://127.0.0.1:$proxy_port" ATC_IMPD_PORT="$impd_port" \
    OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_env STUB_TREE="$tree" STUB_HOST=root@geoffcloud \
    STUB_HOST_BIN="$tree/host-bin-real-curl" \
    ATC_CREDENTIALS_DIR="$tree/host/secrets" bash "$tree/install-atc-gateway-credentials.sh" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/err"
  grep -x 'skip: both exist, atc-cloud has the expected limits, and the file authenticates as it' "$tree/out"
  diff - <(ls -A "$tree/listener") <<< ports
  diff /dev/null <(grep -F -e "$good_token" "$tree/calls" "$tree/host-output" "$tree/out" "$tree/err")
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

# A token in imp's format, imp_<16>.<43>, derived from the run's seed and a label, so a
# rerun with the same SEED repeats every value.
build_token() {
  local seed="$1" label="$2" id secret
  id="$(printf '%s' "$seed-$label-id" | sha256sum)"
  secret="$(printf '%s' "$seed-$label-secret" | sha256sum)"
  printf 'imp_%.16s.%.43s' "$id" "$secret"
}

# Boot data every case needs: the script, the vault `cloud` (empty), the host's secrets
# directory (empty), the stand-ins below, and the impd and proxy listener the real-curl
# cases start. The stand-ins' JSON shapes follow imp's own schemas (SecretSchema,
# TokenSchema, IdentitySchema and the 401 body in imp's packages/api and daemon), and op's
# follow its item JSON; each stand-in ends with exit 97 on a call it does not know.
setup_case() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/host-bin" "$tree/host-bin-real-curl" "$tree/home" "$tree/tmp" \
    "$tree/vault/cloud" "$tree/impd" "$tree/host/secrets" "$tree/curl-home" "$tree/xdg" \
    "$tree/listener"
  : > "$tree/calls"
  : > "$tree/host-output"
  cp "$(dirname "${BASH_SOURCE[0]}")/install-atc-gateway-credentials.sh" "$tree/"
  # op: the vault is a directory under vault/, an item a file holding its credential;
  # records the service-account token it ran with in op-token-seen; STUB_OP_READ_VALUE
  # makes `op read` answer another value
  cat > "$tree/bin/op" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' op "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
printf '%s\n' "${OP_SERVICE_ACCOUNT_TOKEN-unset}" > "$STUB_TREE/op-token-seen"
case "$*" in
  "vault get "*" --format json")
    if [ -d "$STUB_TREE/vault/$3" ]; then
      jq -cn --arg name "$3" '{id: "fixture-vault-id", name: $name}'
    else
      echo "[ERROR] 2026/10/07 12:00:00 \"$3\" isn't a vault in this account. Specify the vault with its ID or name." >&2
      exit 1
    fi
    ;;
  "item list --vault "*" --format json")
    (cd "$STUB_TREE/vault/$4" && ls -A) | jq -R --arg vault "$4" \
      '{id: "fixture-item-id", title: ., version: 1, vault: {id: "fixture-vault-id", name: $vault}, category: "API_CREDENTIAL"}' |
      jq -s .
    ;;
  "item create --vault "*" - --format json")
    item="$(cat)"
    title="$(jq -r .title <<< "$item")"
    jq -j '.fields[] | select(.id == "credential") | .value' <<< "$item" > "$STUB_TREE/vault/$4/$title"
    jq -n --arg title "$title" --arg vault "$4" \
      '{id: "fixture-item-id", title: $title, version: 1, vault: {id: "fixture-vault-id", name: $vault}, category: "API_CREDENTIAL"}'
    ;;
  "read op://"*"/credential")
    ref="${2#op://}"
    if [ -n "${STUB_OP_READ_VALUE:-}" ]; then
      printf '%s\n' "$STUB_OP_READ_VALUE"
    else
      cat "$STUB_TREE/vault/${ref%/credential}"
      echo
    fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
EOF
  # atc-key: prints STUB_ZAI_KEY, the z.ai key
  cat > "$tree/bin/atc-key" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' atc-key "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  zai) printf '%s\n' "$STUB_ZAI_KEY" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
EOF
  # ssh: refuses any host but STUB_HOST as ssh does (255), else runs the remote command
  # here with STUB_HOST_BIN first on PATH and copies its stdout to host-output. Two
  # interceptions, each logged: STUB_SSH_DROP_AT_WHOAMI drops the connection on the
  # whoami check, and STUB_REMOVE_TOKEN_AT_WHOAMI removes the saved token just before it.
  cat > "$tree/bin/ssh" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' ssh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$1 $2" != "-o BatchMode=yes" ]; then echo "unexpected: $*" >&2; exit 97; fi
if [ "$3" != "$STUB_HOST" ]; then
  echo "ssh: Could not resolve hostname ${3#*@}: Name or service not known" >&2
  exit 255
fi
remote="${*:4}"
if [[ "$remote" == *tokens/whoami* && -n "${STUB_SSH_DROP_AT_WHOAMI:-}" ]]; then
  echo '["ssh-dropped-at-whoami"]' >> "$STUB_TREE/calls"
  echo "Connection to ${STUB_HOST#*@} closed by remote host." >&2
  exit 255
fi
if [[ "$remote" == *tokens/whoami* && -n "${STUB_REMOVE_TOKEN_AT_WHOAMI:-}" ]]; then
  rm -f "$ATC_CREDENTIALS_DIR/imp-token"
  echo '["imp-token-removed-at-whoami"]' >> "$STUB_TREE/calls"
fi
PATH="$STUB_HOST_BIN:/usr/bin:/bin" bash -c "$remote" | tee -a "$STUB_TREE/host-output"
exit "${PIPESTATUS[0]}"
EOF
  # host docker: impd in imp-host, its state in impd/ (info.json, secrets.json,
  # tokens.json); `secret add` stores its stdin in impd/secret-<name>; `token new`
  # prints STUB_MINTED as imp prints a new token's secret
  cat > "$tree/host-bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
impd="$STUB_TREE/impd"
case "$*" in
  "exec imp-host imp info --json") jq . "$impd/info.json" ;;
  "exec imp-host imp secret ls --json") jq . "$impd/secrets.json" ;;
  "exec imp-host imp token ls --json") jq . "$impd/tokens.json" ;;
  "exec -i imp-host imp secret add glm --kind custom --hosts api.z.ai --header authorization --scheme bearer --json")
    IFS= read -r value || true
    if [ -z "$value" ]; then echo "imp: no value given; nothing stored" >&2; exit 2; fi
    printf '%s\n' "$value" > "$impd/secret-glm"
    secret='{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[],"createdAt":"2026-10-07T12:00:00.000Z"}'
    jq --argjson s "$secret" '. + [$s]' "$impd/secrets.json" > "$impd/secrets.next"
    mv "$impd/secrets.next" "$impd/secrets.json"
    jq -n --argjson s "$secret" '$s + {droppedGrants: 0}'
    ;;
  "exec imp-host imp token new atc-cloud --scope manage --imps harness-* --grantable glm")
    token='{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"sshKeys":[],"grantable":["glm"],"createdAt":"2026-10-07T12:00:00.000Z"}'
    jq --argjson t "$token" '. + [$t]' "$impd/tokens.json" > "$impd/tokens.next"
    mv "$impd/tokens.next" "$impd/tokens.json"
    echo "imp: token atc-cloud made; impd shows its secret only this once" >&2
    printf '%s\n' "$STUB_MINTED"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
EOF
  # host install: install -d without the chown, which needs root
  cat > "$tree/host-bin/install" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' install "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "-d -m 0700 -o root -g root /"*) mkdir -p "$8" && chmod 0700 "$8" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
EOF
  # host curl: impd's tokens.whoami on 127.0.0.1:7070, answering as curl -w
  # '\n%{http_code}' prints it. The bearer STUB_GOOD_TOKEN gets atc-cloud's identity and
  # any other bearer impd's 401; STUB_WHOAMI_STATUS and STUB_WHOAMI_BODY set a fixed
  # answer; STUB_CURL_EXIT fails as curl does (7 refused, 56 reset).
  cat > "$tree/host-bin/curl" << 'EOF'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
header="$(cat)"
if [ "$*" != '-q --noproxy * -sS --max-time 10 -H @- -H content-type: application/json --data {"json":{}} -w \n%{http_code} http://127.0.0.1:7070/rpc/tokens/whoami' ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
case "${STUB_CURL_EXIT:-}" in
  7) echo "curl: (7) Failed to connect to 127.0.0.1 port 7070 after 0 ms: Couldn't connect to server" >&2; exit 7 ;;
  56) echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56 ;;
esac
if [ -n "${STUB_WHOAMI_STATUS:-}" ]; then
  printf '%s\n%s' "$STUB_WHOAMI_BODY" "$STUB_WHOAMI_STATUS"
elif [ "$header" = "Authorization: Bearer ${STUB_GOOD_TOKEN:-}" ]; then
  printf '%s\n200' '{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
else
  printf '%s\n401' '{"error":"unauthorized"}'
fi
EOF
  cp "$tree/host-bin/docker" "$tree/host-bin/install" "$tree/host-bin-real-curl/"
  chmod +x "$tree"/bin/* "$tree"/host-bin/* "$tree"/host-bin-real-curl/*
  # impd's whoami on an ephemeral port, plus a proxy that records each connection to
  # proxy.bytes; writes "<impd port> <proxy port>" to ports once both listen
  cat > "$tree/listen.py" << 'EOF'
import os, socket, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

out_dir = sys.argv[1]

class Impd(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        good = self.headers.get("authorization") == "Bearer " + os.environ["STUB_GOOD_TOKEN"]
        if self.path == "/rpc/tokens/whoami" and good:
            status = 200
            body = b'{"json":{"kind":"token","name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}}'
        else:
            status, body = 401, b'{"error":"unauthorized"}'
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

def run_proxy(server):
    while True:
        conn, _ = server.accept()
        conn.settimeout(2)
        with open(os.path.join(out_dir, "proxy.bytes"), "ab") as out:
            out.write(b"connection\n")
            try:
                out.write(conn.recv(65536))
            except OSError:
                pass
        conn.close()

proxy = socket.socket()
proxy.bind(("127.0.0.1", 0))
proxy.listen()
threading.Thread(target=run_proxy, args=(proxy,), daemon=True).start()
impd = ThreadingHTTPServer(("127.0.0.1", 0), Impd)
with open(os.path.join(out_dir, "ports.tmp"), "w") as out:
    out.write(f"{impd.server_address[1]} {proxy.getsockname()[1]}\n")
os.rename(os.path.join(out_dir, "ports.tmp"), os.path.join(out_dir, "ports"))
impd.serve_forever()
EOF
}

# Runs each it_* function (or those whose title holds $CASE) in its own background
# subshell, so errexit holds inside it, with the run's seed as its argument; prints ok or
# FAIL with the case's output. A case leaves its tree (and listener) variables out of
# `local`, so its EXIT trap still sees them.
run_cases() {
  local seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}" fn title log status failures=0 ran=0
  log="$(mktemp)"
  echo "seed $seed (rerun with SEED=$seed)"
  for fn in $(compgen -A function it_); do
    title="${fn//_/ }"
    [[ "$title" == *"${CASE:-}"* ]] || continue
    ran=$((ran + 1))
    (
      set -euo pipefail
      "$fn" "$seed"
    ) > "$log" 2>&1 &
    status=0
    wait "$!" || status=$?
    if [ "$status" = 0 ]; then
      echo "ok $title"
    else
      echo "FAIL $title (exit $status)"
      sed 's/^/    /' "$log"
      failures=$((failures + 1))
    fi
  done
  rm -f "$log"
  echo "$ran cases, $failures failed (seed $seed)"
  [ "$ran" -gt 0 ] && [ "$failures" = 0 ] || exit 1
}

run_cases
