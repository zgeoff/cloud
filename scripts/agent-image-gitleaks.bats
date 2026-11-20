#!/usr/bin/env bats
# bats file_tags=suite:agent-image
# Tests scripts/agent-image-gitleaks.toml with the gitleaks that the agent image installs, run as
# the image check runs it: `gitleaks dir /opt` in the image, here against a case tree mounted at
# /opt in place of the image's own. What this proves: the auto-mode entry exempts the short-lived
# Bedrock rule's pattern source in auto-mode's two rule files and nowhere else, the Chrome entry
# exempts the extension key in Chrome's reading-mode manifest and nowhere else, and any other
# finding in those files still fails. It needs the image that `bun run test:agent-image` builds,
# which runs this group after its check; one case alone:
#
#   CASE='github token' bash scripts/run-bats.sh agent-image

# each case starts a container, which a cold host can take longer than 30 seconds over
export BATS_TEST_TIMEOUT=120

# Boot data every case needs: the image that test:agent-image builds, the config under test by
# absolute path for the bind mount, the Bedrock rule's pattern source (split here so the repo's
# own scan does not match this file), a GitHub token that matches gitleaks' github-pat rule, and
# an extension key shaped like Chrome's that matches its generic-api-key rule, both derived from
# SEED.
setup_file() {
  load '../scripts/src/test-utils/bats/setup'
  local seed="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
  echo "SEED=$seed" >&3
  export image="${AGENT_IMAGE:-cloud/agent-image}"
  export config="$BATS_TEST_DIRNAME/agent-image-gitleaks.toml"
  BEDROCK_PATTERN="bedrock-api-key-""YmVkcm9jay5hbWF6b25hd3MuY29t"
  GITHUB_TOKEN="ghp_$(printf '%s' "$seed" | sha256sum | cut -c1-36)"
  CHROME_KEY="MIIEvgIBADANBgkqhkiG9w0BAQEFAASC$(printf '%s' "$seed-key" | sha256sum | cut -c1-40)"
  export BEDROCK_PATTERN GITHUB_TOKEN CHROME_KEY
}

setup() {
  load '../scripts/src/test-utils/bats/setup'
  # fixed, so the files the image reads through the read-only mount do not depend on the caller's
  # umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# The case tree's /opt with auto-mode's dist directory and Chrome's accessibility resources, where
# the image keeps them, and no file in either: each case writes its own.
setup_test() {
  mkdir -p "$tree/opt/auto-mode/dist" "$tree/opt/chrome/resources/accessibility"
}

# scan: the image's gitleaks over the case tree's /opt with the config under test; a case runs it
# redirecting its report to "$tree/out" and its log to "$tree/err"
scan() {
  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path -
}

@test "it passes the bedrock rule pattern in secret rules json" {
  setup_test
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/dist/secret-rules.json"

  scan > "$tree/out" 2> "$tree/err"

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff /dev/null "$tree/findings"
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
INF no leaks found
EOF
}

@test "it passes the bedrock rule pattern in a classify edit bundle" {
  setup_test
  printf 'const rules = [{\n\tid: "aws-amazon-bedrock-api-key-short-lived",\n\tpattern: {\n\t\t"source": "%s",\n\t},\n}];\n' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/dist/classify-edit-B10-ua5i.js"

  scan > "$tree/out" 2> "$tree/err"

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff /dev/null "$tree/findings"
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
INF no leaks found
EOF
}

@test "it fails the bedrock rule pattern in secret rules json outside auto mode dist" {
  local status=0
  setup_test
  mkdir -p "$tree/opt/auto-mode/lib" "$tree/opt/other"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/lib/secret-rules.json"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/other/secret-rules.json"

  scan > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" | LC_ALL=C sort > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"aws-amazon-bedrock-api-key-short-lived","File":"/opt/auto-mode/lib/secret-rules.json","StartLine":1}
{"RuleID":"aws-amazon-bedrock-api-key-short-lived","File":"/opt/other/secret-rules.json","StartLine":1}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 2
EOF
}

@test "it fails a github token beside the bedrock rule pattern in secret rules json" {
  local status=0
  setup_test
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}\n{"token":"%s"}\n' \
    "$BEDROCK_PATTERN" "$GITHUB_TOKEN" > "$tree/opt/auto-mode/dist/secret-rules.json"

  scan > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"github-pat","File":"/opt/auto-mode/dist/secret-rules.json","StartLine":2}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
}

@test "it fails a github token beside the bedrock rule pattern in a classify edit bundle" {
  local status=0
  setup_test
  printf 'const rules = [{\n\tid: "aws-amazon-bedrock-api-key-short-lived",\n\tpattern: {\n\t\t"source": "%s",\n\t},\n}];\nconst token = "%s";\n' \
    "$BEDROCK_PATTERN" "$GITHUB_TOKEN" > "$tree/opt/auto-mode/dist/classify-edit-B10-ua5i.js"

  scan > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"github-pat","File":"/opt/auto-mode/dist/classify-edit-B10-ua5i.js","StartLine":7}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
}

@test "it passes the extension key in chromes reading mode manifest" {
  setup_test
  printf '{\n  "key": "%s",\n  "manifest_version": 3\n}\n' "$CHROME_KEY" \
    > "$tree/opt/chrome/resources/accessibility/reading_mode_gdocs_helper_manifest.json"

  scan > "$tree/out" 2> "$tree/err"

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff /dev/null "$tree/findings"
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
INF no leaks found
EOF
}

@test "it fails the extension key in another chrome manifest" {
  local status=0
  setup_test
  printf '{\n  "key": "%s",\n  "manifest_version": 3\n}\n' "$CHROME_KEY" \
    > "$tree/opt/chrome/resources/accessibility/other_manifest.json"

  scan > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"generic-api-key","File":"/opt/chrome/resources/accessibility/other_manifest.json","StartLine":2}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
}

@test "it fails a github token beside the extension key in chromes reading mode manifest" {
  local status=0
  setup_test
  printf '{\n  "key": "%s",\n  "token": "%s"\n}\n' "$CHROME_KEY" "$GITHUB_TOKEN" \
    > "$tree/opt/chrome/resources/accessibility/reading_mode_gdocs_helper_manifest.json"

  scan > "$tree/out" 2> "$tree/err" || status=$?
  assert_equal "$status" 1

  jq -c '.[] | {RuleID, File, StartLine}' < "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"github-pat","File":"/opt/chrome/resources/accessibility/reading_mode_gdocs_helper_manifest.json","StartLine":3}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    < "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
}
