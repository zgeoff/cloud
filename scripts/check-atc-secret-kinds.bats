#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-atc-secret-kinds.sh: it passes an impd whose stored secret kinds the atc pin
# accepts, and refuses an impd that stores a kind atc lacks, naming each such kind. It refuses a
# pin without a release version, a missing pin file, a source file without its kind list, and
# stops on a failed source read with gh's exit code. gh is the stand-in from scripts/src/test-utils/shell,
# which replays the answer each case records to the read of impd's secret-schema.ts and atc's
# credential-broker.ts. Each case writes its own configuration.nix and atc.nix in the case tree,
# runs the script under `env -i`, and compares its stdout, stderr and gh call log.
#
# The recordings in scripts/src/test-utils/shell/gh-recordings hold zgeoff/impz's
# packages/api/src/schemas/secret-schema.ts at v4.2.4 (five kinds) and v5.0.0 (`static` and
# `oauth`), and zgeoff/atc's credential-broker.ts at @zgeoff/atc@7.3.0
# (without `static`) and @zgeoff/atc@7.3.1 (with it), read 2026-10-26.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-atc-secret-kinds.sh"
  recordings="$(cd "$BATS_TEST_DIRNAME/../scripts/src/test-utils/shell/gh-recordings" && pwd)"
  digest=sha256:3b8e1f0c6a4d2e9f7b5c3a1d0e8f6b4c2a0d9e7f5b3c1a8d6e4f2b0c9a7d5e3f
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

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
  printf '["gh","api","-H","Accept: application/vnd.github.raw","repos/zgeoff/atc/contents/packages/plugin-api/src/credentials/credential-broker.ts?ref=%%40zgeoff/atc%%40%s"]\n' "$1"
}

@test "it passes an impd whose secret kinds the atc pin accepts" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.1.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  assert_output '== impd 5.0.0 stores the secret kinds static, oauth, which atc 7.3.1 accepts'
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.1)
EOF
}

@test "it passes impd 4 2 4 whose every kind atc 7 3 0 accepts" {
  setup_test "$tree"
  write_pins "$tree" 4.2.4 7.3.0
  jq -cn --argjson schema "$(schema_call 4.2.4)" --argjson broker "$(broker_call 7.3.0)" \
    --arg schema_file "$recordings/impz-secret-schema-4.2.4.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.0.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  assert_output '== impd 4.2.4 stores the secret kinds github, anthropic, npm, custom, oauth, which atc 7.3.0 accepts'
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$(schema_call 4.2.4)
$(broker_call 7.3.0)
EOF
}

@test "it refuses an impd that stores a kind the atc pin lacks and names the kind" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.0
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.0)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    --arg broker_file "$recordings/atc-credential-broker-7.3.0.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr 'the switch would run impd 5.0.0, which stores the secret kind static, but atc 7.3.0 on the host accepts anthropic, custom, github, npm, oauth only; pin an atc that accepts static first (nixos/packages/atc.nix)'

  run -0 diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.0)
EOF
}

@test "it names every kind the atc pin lacks" {
  setup_test "$tree"
  write_pins "$tree" 6.0.0 7.3.1
  echo "export const SecretKindSchema = z.enum(['static', 'oauth', 'vault', 'ssh']);" > "$tree/schema.ts"
  jq -cn --argjson schema "$(schema_call 6.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$tree/schema.ts" --arg broker_file "$recordings/atc-credential-broker-7.3.1.txt" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr 'the switch would run impd 6.0.0, which stores the secret kinds vault, ssh, but atc 7.3.1 on the host accepts anthropic, custom, github, npm, oauth, static only; pin an atc that accepts vault, ssh first (nixos/packages/atc.nix)'

  run -0 diff - "$tree/calls" << EOF
$(schema_call 6.0.0)
$(broker_call 7.3.1)
EOF
}

@test "it refuses an impd source without the kind enum" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo "export const SecretNameSchema = z.string();" > "$tree/schema.ts"
  jq -cn --argjson schema "$(schema_call 5.0.0)" --arg schema_file "$tree/schema.ts" \
    '{argv: $schema, stdout_file: $schema_file}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr "impd 5.0.0's secret-schema.ts names no one SecretKindSchema enum"

  run -0 diff - "$tree/calls" <<< "$(schema_call 5.0.0)"
}

@test "it refuses an atc source without the kind union" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo "export interface BrokerSecret {}" > "$tree/broker.ts"
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 7.3.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" --arg broker_file "$tree/broker.ts" \
    '{argv: $schema, stdout_file: $schema_file}, {argv: $broker, stdout_file: $broker_file}' \
    > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr "atc 7.3.1's credential-broker.ts names no one BrokerSecretKind union"

  run -0 diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 7.3.1)
EOF
}

@test "it stops with gh exit code when a source cannot be read" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 6.0.1
  # gh's manual (`gh help exit-codes`, gh 2.102.0, read 2026-10-12) gives exit 1 for a failed
  # command, such as an API error; atc 6.0.1 has no plugin-api package
  jq -cn --argjson schema "$(schema_call 5.0.0)" --argjson broker "$(broker_call 6.0.1)" \
    --arg schema_file "$recordings/impz-secret-schema-5.0.0.txt" \
    '{argv: $schema, stdout_file: $schema_file},
    {argv: $broker, stderr: "gh: Not Found (HTTP 404)\n", exit: 1}' > "$tree/gh-responses"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr 'gh: Not Found (HTTP 404)'

  run -0 diff - "$tree/calls" << EOF
$(schema_call 5.0.0)
$(broker_call 6.0.1)
EOF
}

@test "it refuses a configuration without the imp host pin" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo '  services.imp.enable = true;' > "$tree/configuration.nix"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr "$tree/configuration.nix pins no imp-host release image"

  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses an atc nix without the version pin" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  echo '  pname = "atc";' > "$tree/atc.nix"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr "$tree/atc.nix pins no atc release version"

  run -0 diff /dev/null "$tree/calls"
}

@test "it refuses a missing pin file" {
  setup_test "$tree"
  write_pins "$tree" 5.0.0 7.3.1
  rm "$tree/atc.nix"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix" "$tree/atc.nix"

  refute_output
  assert_stderr "$tree/atc.nix is missing, so the switch has no pin to compare secret kinds by"

  run -0 diff /dev/null "$tree/calls"
}

@test "it prints its usage without both arguments" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    bash "$script" "$tree/configuration.nix"

  refute_output
  assert_stderr 'usage: check-atc-secret-kinds.sh <configuration.nix> <atc.nix>'
}
