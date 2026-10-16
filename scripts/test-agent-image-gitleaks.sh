#!/usr/bin/env bash
# Tests scripts/agent-image-gitleaks.toml with the gitleaks that the agent image installs, run as
# the image check runs it: `gitleaks dir /opt` in the image, here against a case tree mounted at
# /opt in place of the image's own. What this proves: the auto-mode entry exempts the short-lived
# Bedrock rule's pattern source in auto-mode's two rule files and nowhere else, and any other
# finding in those files still fails. It needs the image that `bun run test:agent-image` builds,
# which runs this group after its check; one case alone:
#
#   CASE='github token' bash scripts/test-agent-image-gitleaks.sh
# shell-suite: agent-image
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the image reads through the read-only mount do not depend on the caller's
# umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

it_passes_the_bedrock_rule_pattern_in_secret_rules_json() {
  local image="$1" config="$2" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/dist/secret-rules.json"

  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path - \
    > "$tree/out" 2> "$tree/err" || status=$?

  jq -c '.[] | {RuleID, File, StartLine}' "$tree/out" > "$tree/findings"
  diff /dev/null "$tree/findings"
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
INF no leaks found
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_passes_the_bedrock_rule_pattern_in_a_classify_edit_bundle() {
  local image="$1" config="$2" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf 'const rules = [{\n\tid: "aws-amazon-bedrock-api-key-short-lived",\n\tpattern: {\n\t\t"source": "%s",\n\t},\n}];\n' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/dist/classify-edit-B10-ua5i.js"

  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path - \
    > "$tree/out" 2> "$tree/err" || status=$?

  jq -c '.[] | {RuleID, File, StartLine}' "$tree/out" > "$tree/findings"
  diff /dev/null "$tree/findings"
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
INF no leaks found
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_the_bedrock_rule_pattern_in_secret_rules_json_outside_auto_mode_dist() {
  local image="$1" config="$2" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  mkdir -p "$tree/opt/auto-mode/lib" "$tree/opt/other"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/auto-mode/lib/secret-rules.json"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}' \
    "$BEDROCK_PATTERN" > "$tree/opt/other/secret-rules.json"

  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path - \
    > "$tree/out" 2> "$tree/err" || status=$?

  jq -c '.[] | {RuleID, File, StartLine}' "$tree/out" | LC_ALL=C sort > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"aws-amazon-bedrock-api-key-short-lived","File":"/opt/auto-mode/lib/secret-rules.json","StartLine":1}
{"RuleID":"aws-amazon-bedrock-api-key-short-lived","File":"/opt/other/secret-rules.json","StartLine":1}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 2
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_a_github_token_beside_the_bedrock_rule_pattern_in_secret_rules_json() {
  local image="$1" config="$2" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf '{"rules":[{"id":"aws-amazon-bedrock-api-key-short-lived","pattern":{"source":"%s","flags":"","engine":"js"}}]}\n{"token":"%s"}\n' \
    "$BEDROCK_PATTERN" "$GITHUB_TOKEN" > "$tree/opt/auto-mode/dist/secret-rules.json"

  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path - \
    > "$tree/out" 2> "$tree/err" || status=$?

  jq -c '.[] | {RuleID, File, StartLine}' "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"github-pat","File":"/opt/auto-mode/dist/secret-rules.json","StartLine":2}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_fails_a_github_token_beside_the_bedrock_rule_pattern_in_a_classify_edit_bundle() {
  local image="$1" config="$2" status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree" || true' EXIT
  setup_test "$tree"
  printf 'const rules = [{\n\tid: "aws-amazon-bedrock-api-key-short-lived",\n\tpattern: {\n\t\t"source": "%s",\n\t},\n}];\nconst token = "%s";\n' \
    "$BEDROCK_PATTERN" "$GITHUB_TOKEN" > "$tree/opt/auto-mode/dist/classify-edit-B10-ua5i.js"

  docker run --rm --network none --entrypoint gitleaks -v "$tree/opt:/opt:ro" \
    -v "$config:/run/gitleaks.toml:ro" "$image" dir /opt --config /run/gitleaks.toml --no-banner \
    --no-color --redact --report-format json --report-path - \
    > "$tree/out" 2> "$tree/err" || status=$?

  jq -c '.[] | {RuleID, File, StartLine}' "$tree/out" > "$tree/findings"
  diff - "$tree/findings" << 'EOF'
{"RuleID":"github-pat","File":"/opt/auto-mode/dist/classify-edit-B10-ua5i.js","StartLine":7}
EOF
  sed -E 's/^[0-9]+:[0-9]{2}[AP]M //; s/scanned ~[0-9]+ bytes \([^)]*\) in .*$/scanned SIZE in T/' \
    "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
INF scanned SIZE in T
WRN leaks found: 1
EOF
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

# The case tree's /opt with auto-mode's dist directory, where the image keeps auto-mode, and no
# file in it: each case writes its own.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/opt/auto-mode/dist"
}

# Boot data every case needs: the image that test:agent-image builds, the config under test by
# absolute path for the bind mount, the Bedrock rule's pattern source (split here so the repo's
# own scan does not match this file), and a GitHub token that matches gitleaks' github-pat rule,
# derived from SEED.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${AGENT_IMAGE:-cloud/agent-image}"
SEED="${SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"
echo "SEED=$SEED"
BEDROCK_PATTERN="bedrock-api-key-""YmVkcm9jay5hbWF6b25hd3MuY29t"
GITHUB_TOKEN="ghp_$(printf '%s' "$SEED" | sha256sum | cut -c1-36)"
run_cases "$image" "$repo/scripts/agent-image-gitleaks.toml"
