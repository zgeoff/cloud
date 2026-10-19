#!/usr/bin/env bash
# Test for create-stub-gh.sh: the gh stand-in logs each call's argv as a JSON line, answers a call
# from the first recorded response whose argv and environment match it, with that response's
# stdout, stderr, stdout file, downloads and exit, and fails closed with exit 97 on a call that no
# response matches. No gh runs here; each suite that replays a recorded response cites where its
# answer comes from.
#
#   bash test-support/shell/test-create-stub-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/assert-status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-gh.sh"

it_answers_a_matching_call_with_its_stdout_stderr_and_exit() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "{\"id\":1}\n", "stderr": "gh: warning\n", "exit": 4}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"id":1}'
  diff - "$tree/err" <<< 'gh: warning'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
  assert_status 4 "$status"
}

it_exits_0_and_prints_nothing_for_a_response_that_names_only_its_argv() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo '{"argv": ["gh", "api", "repos/acme/widgets"]}' > "$tree/responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
  assert_status 0 "$status"
}

it_matches_any_one_argument_at_a_null_element() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "release", "download", "v1.0.0", "-D", null], "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -D "$tree/tmp/work.1a2b" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< matched
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-D\",\"$tree/tmp/work.1a2b\"]"
  assert_status 0 "$status"
}

it_fails_closed_on_a_call_longer_than_the_recorded_argv() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets --paginate > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api repos/acme/widgets --paginate'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets","--paginate"]'
  assert_status 97 "$status"
}

it_fails_closed_on_a_call_shorter_than_the_recorded_argv() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets", null], "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api repos/acme/widgets'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
  assert_status 97 "$status"
}

it_matches_a_response_whose_environment_the_call_runs_with() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0", "DO_NOT_TRACK": "1"}, "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=0 DO_NOT_TRACK=1 \
    gh auth status > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< matched
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","auth","status"]'
  assert_status 0 "$status"
}

it_fails_closed_on_a_call_without_a_variable_the_response_names() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0", "DO_NOT_TRACK": "1"}, "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=0 \
    gh auth status > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
  assert_status 97 "$status"
}

it_fails_closed_on_a_call_with_another_value_of_a_variable_the_response_names() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0"}, "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=1 \
    gh auth status > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
  assert_status 97 "$status"
}

it_copies_each_download_into_the_directory_after_d() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/release" "$tree/out-dir"
  echo binary > "$tree/release/widget-linux-x64"
  echo sums > "$tree/release/SHA256SUMS"
  jq -cn --arg release "$tree/release" '{
    argv: ["gh", "release", "download", "v1.0.0", "-R", "acme/widgets", "-p", "widget-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"widget-linux-x64": "\($release)/widget-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}
  }' > "$tree/responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -R acme/widgets -p widget-linux-x64 -p SHA256SUMS -D "$tree/out-dir" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - <(find "$tree/out-dir" -mindepth 1 -printf '%f\n' | LC_ALL=C sort) << 'EOF'
SHA256SUMS
widget-linux-x64
EOF
  diff - "$tree/out-dir/widget-linux-x64" <<< binary
  diff - "$tree/out-dir/SHA256SUMS" <<< sums
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-R\",\"acme/widgets\",\"-p\",\"widget-linux-x64\",\"-p\",\"SHA256SUMS\",\"-D\",\"$tree/out-dir\"]"
  assert_status 0 "$status"
}

it_copies_nothing_into_the_directory_after_d_on_a_call_no_response_matches() {
  local status=0
  create_case_tree
  setup_test "$tree"
  mkdir "$tree/release" "$tree/out-dir"
  echo binary > "$tree/release/widget-linux-x64"
  jq -cn --arg release "$tree/release" '{
    argv: ["gh", "release", "download", "v1.0.0", "-R", "acme/widgets", "-p", "widget-linux-x64", "-D", null],
    downloads: {"widget-linux-x64": "\($release)/widget-linux-x64"}
  }' > "$tree/responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -R acme/widgets -p widget-darwin-arm64 -D "$tree/out-dir" \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: release download v1.0.0 -R acme/widgets -p widget-darwin-arm64 -D $tree/out-dir"
  diff /dev/null <(ls -A "$tree/out-dir")
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-R\",\"acme/widgets\",\"-p\",\"widget-darwin-arm64\",\"-D\",\"$tree/out-dir\"]"
  assert_status 97 "$status"
}

it_fails_closed_on_a_response_with_downloads_for_a_call_without_d() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo binary > "$tree/widget-linux-x64"
  jq -cn --arg asset "$tree/widget-linux-x64" '{
    argv: ["gh", "release", "download", "v1.0.0"], downloads: {"widget-linux-x64": $asset}
  }' > "$tree/responses"

  (cd "$tree/tmp" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'gh stand-in: the response has downloads but the call has no -D'
  diff /dev/null <(ls -A "$tree/tmp")
  diff - "$tree/calls" <<< '["gh","release","download","v1.0.0"]'
  assert_status 97 "$status"
}

it_prints_the_bytes_of_the_stdout_file_after_stdout() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf 'line one\nline two without a newline' > "$tree/body"
  jq -cn --arg body "$tree/body" '{argv: ["gh", "api", "repos/acme/widgets"], stdout: "head\n", stdout_file: $body}' \
    > "$tree/responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  printf 'head\nline one\nline two without a newline' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
  assert_status 0 "$status"
}

it_answers_with_the_first_response_that_matches() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/other"], "stdout": "other\n"}
{"argv": ["gh", "api", null], "stdout": "first\n"}
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "second\n", "exit": 1}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< first
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
  assert_status 0 "$status"
}

it_fails_closed_with_exit_97_on_a_call_no_response_matches() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/gadgets > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: api repos/acme/gadgets'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/gadgets"]'
  assert_status 97 "$status"
}

it_fails_closed_with_exit_97_when_no_responses_file_exists() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh auth status > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
  assert_status 97 "$status"
}

it_appends_each_calls_argv_as_one_json_line_keeping_spaces_and_quotes() {
  local status=0
  create_case_tree
  setup_test "$tree"
  echo '["gh", "--version"]' > "$tree/calls"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api -H 'Accept: application/vnd.github.raw' --jq '.[] | select(.name == "a b")' "it's" '' \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "unexpected: api -H Accept: application/vnd.github.raw --jq .[] | select(.name == \"a b\") it's "
  diff - "$tree/calls" << 'EOF'
["gh", "--version"]
["gh","api","-H","Accept: application/vnd.github.raw","--jq",".[] | select(.name == \"a b\")","it's",""]
EOF
  assert_status 97 "$status"
}

# The stand-in is written before the case records any response, so the first call reads the
# response file as it stands then and the second reads its replacement.
it_reads_the_responses_file_at_each_call() {
  local status=0
  create_case_tree
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "before\n"}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out-before"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "after\n"}
EOF

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out-before" <<< before
  diff - "$tree/out" <<< after
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","api","repos/acme/widgets"]
["gh","api","repos/acme/widgets"]
EOF
  assert_status 0 "$status"
}

# create_stub_gh takes relative paths here, and the call runs from another directory, so the log
# and the responses are found only through the absolute paths the stand-in was written with.
it_reads_and_logs_through_the_absolute_paths_it_was_written_with() {
  local status=0
  create_case_tree
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/elsewhere"
  (cd "$tree" && create_stub_gh bin shared-calls responses)
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  (cd "$tree/elsewhere" && env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< matched
  diff /dev/null "$tree/err"
  diff - "$tree/shared-calls" <<< '["gh","api","repos/acme/widgets"]'
  diff /dev/null <(ls -A "$tree/elsewhere")
  assert_status 0 "$status"
}

# Runtime every case needs: the stand-in in <tree>/bin, logging to <tree>/calls and answering from
# <tree>/responses, which each case writes, and the HOME and TMPDIR it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/responses"
}

run_cases
