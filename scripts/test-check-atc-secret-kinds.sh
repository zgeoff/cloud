#!/usr/bin/env bash
# Test for check-atc-secret-kinds.sh: it passes an impd whose stored secret kinds the atc pin
# accepts, and refuses an impd that stores a kind atc lacks, naming each such kind. It refuses a
# pin without a release version, a missing pin file, a source file without its kind list, and
# stops on a failed source read with gh's exit code. gh is the stand-in from test-support/shell,
# which replays the answer each case records to the read of impd's secret-schema.ts and atc's
# credential-broker.ts. Each case writes its own configuration.nix and atc.nix in the case tree,
# runs the script under `env -i`, and compares its stdout, stderr and gh call log.
#
# The recordings in test-support/shell/gh-recordings hold zgeoff/impz's
# packages/api/src/schemas/secret-schema.ts at v4.2.4 (five kinds) and v5.0.0 (`static` and
# `oauth`), and zgeoff/atc's packages/plugin-api/src/credential-broker.ts at @zgeoff/atc@7.3.0
# (without `static`) and @zgeoff/atc@7.3.1 (with it), read 2026-10-26.
#
#   bash scripts/test-check-atc-secret-kinds.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-stub-gh.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-atc-secret-kinds.sh"
recordings="$(cd "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/gh-recordings" && pwd)"
digest=sha256:3b8e1f0c6a4d2e9f7b5c3a1d0e8f6b4c2a0d9e7f5b3c1a8d6e4f2b0c9a7d5e3f

# setup_test <tree>: the home and temp folders the cases run with, and the gh stand-in, which
# answers from <tree>/gh-responses
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/gh-responses"
}

# write_pins <tree> <imp-host version> <atc version>: a configuration.nix that pins that imp-host
# release, and an atc.nix that pins that atc release
write_pins() {
  cat > "$1/configuration.nix" << EOF
  services.imp = {
    enable = true;
    image = "ghcr.io/zgeoff/imp-host:$2@$digest";
  };
EOF
  cat > "$1/atc.nix" << EOF
let
  version = "$3";
in
EOF
}

schema_call() {
  printf '["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/impz/contents/packages/api/src/schemas/secret-schema.ts?ref=v%s"]\n' "$1"
}

broker_call() {
  printf '["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/atc/contents/packages/plugin-api/src/credential-broker.ts?ref=%%40zgeoff/atc%%40%s"]\n' "$1"
}

it_passes_an_impd_whose_secret_kinds_the_atc_pin_accepts() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.1.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== impd 5.0.0 stores the secret kinds static, oauth, which atc 7.3.1 accepts'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.1)
EOF
  assert_status 0 "$status"
}

it_passes_impd_4_2_4_whose_every_kind_atc_7_3_0_accepts() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 4.2.4 7.3.0
  jq -cn --argjson schema "$(schema_call 4.2.4)" --argjson broker "$(broker_call 7.3.0)" \
    --arg schema_file "$recordings/impz-secret-schema-4.2.4.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.0.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '== impd 4.2.4 stores the secret kinds github, anthropic, npm, custom, oauth, which atc 7.3.0 accepts'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
$(schema_call 4.2.4)
$(broker_call 7.3.0)
EOF
  assert_status 0 "$status"
}

it_refuses_an_impd_that_stores_a_kind_the_atc_pin_lacks_and_names_the_kind() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.0
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.0)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.0.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run impd 5.0.0, which stores the secret kind static, but atc 7.3.0 on the host accepts anthropic, custom, github, npm, oauth only; pin an atc that accepts static first (nixos/packages/atc.nix)'
  diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.0)
EOF
  assert_status 1 "$status"
}

it_names_every_kind_the_atc_pin_lacks() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 6.0.0 7.3.1
  echo "export const SecretKindSchema = z.enum(['static', 'oauth', 'vault', 'ssh']);" > "$tree/schema.ts"
  jq -cn --argjson schema "$(schema_call 6.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$tree/schema.ts" --arg broker_file "$recordings/atc-credential-broker-7.3.1.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the switch would run impd 6.0.0, which stores the secret kinds vault, ssh, but atc 7.3.1 on the host accepts anthropic, custom, github, npm, oauth, static only; pin an atc that accepts vault, ssh first (nixos/packages/atc.nix)'
  diff - "$tree/calls" << EOF
$(schema_call 6.0.0)
$(broker_call 7.3.1)
EOF
  assert_status 1 "$status"
}

it_refuses_an_impd_source_without_the_kind_enum() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo "export const SecretNameSchema = z.string();" > "$tree/schema.ts"
  jq -cn --argjson schema "$(schema_call 5.0.0)" --arg schema_file "$tree/schema.ts" \
    '{argv: $schema, stdout_file: $schema_file}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "impd 5.0.0's secret-schema.ts names no one SecretKindSchema enum"
  diff - "$tree/calls" <<< "$(schema_call 5.0.0)"
  assert_status 1 "$status"
}

it_refuses_an_atc_source_without_the_kind_union() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo "export interface BrokerSecret {}" > "$tree/broker.ts"
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" --arg broker_file "$tree/broker.ts" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "atc 7.3.1's credential-broker.ts names no one BrokerSecretKind union"
  diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.1)
EOF
  assert_status 1 "$status"
}

it_stops_with_gh_exit_code_when_a_source_cannot_be_read() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 6.0.1
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error; atc 6.0.1 has no plugin-api package
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 6.0.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    '{argv: $schema, stdout_file: $schema_file},
    {argv: $broker, stderr: "gh: Not Found (HTTP 404)\n", exit: 1}' > "$tree/gh-responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh: Not Found (HTTP 404)'
  diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 6.0.1)
EOF
  assert_status 1 "$status"
}

it_refuses_a_configuration_without_the_imp_host_pin() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo '  services.imp.enable = true;' > "$tree/configuration.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/configuration.nix pins no imp-host release image"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_an_atc_nix_without_the_version_pin() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo '  pname = "atc";' > "$tree/atc.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/atc.nix pins no atc release version"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_refuses_a_missing_pin_file() {
  local status=0
  create_case_tree
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  rm "$tree/atc.nix"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "$tree/atc.nix is missing, so the switch has no pin to compare secret kinds by"
  diff /dev/null "$tree/calls"
  assert_status 1 "$status"
}

it_prints_its_usage_without_both_arguments() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: check-atc-secret-kinds.sh <configuration.nix> <atc.nix>'
  assert_status 2 "$status"
}

run_cases
