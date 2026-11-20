#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-gh.sh: the gh stand-in logs each call's argv as a JSON line, answers a call
# from the first recorded response whose argv and environment match it, with that response's
# stdout, stderr, stdout file, downloads and exit, and fails closed with exit 97 on a call that no
# response matches. No gh runs here; each suite that replays a recorded response cites where its
# answer comes from.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-gh.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# in_dir <dir> <command…>: runs the command from <dir>
in_dir() {
  cd "$1" && shift && "$@"
}

# Runtime every case needs: the stand-in in <tree>/bin, logging to <tree>/calls and answering from
# <tree>/responses, which each case writes, and the HOME and TMPDIR it runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_gh "$tree/bin" "$tree/calls" "$tree/responses"
}

@test "it answers a matching call with its stdout stderr and exit" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "{\"id\":1}\n", "stderr": "gh: warning\n", "exit": 4}
EOF

  run -4 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  assert_output '{"id":1}'
  assert_stderr 'gh: warning'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
}

@test "it exits 0 and prints nothing for a response that names only its argv" {
  setup_test "$tree"
  echo '{"argv": ["gh", "api", "repos/acme/widgets"]}' > "$tree/responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  refute_output
  refute_stderr
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
}

@test "it matches any one argument at a null element" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "release", "download", "v1.0.0", "-D", null], "stdout": "matched\n"}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -D "$tree/tmp/work.1a2b"

  assert_output matched
  refute_stderr
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-D\",\"$tree/tmp/work.1a2b\"]"
}

@test "it fails closed on a call longer than the recorded argv" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets --paginate

  refute_output
  assert_stderr 'unexpected: api repos/acme/widgets --paginate'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets","--paginate"]'
}

@test "it fails closed on a call shorter than the recorded argv" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets", null], "stdout": "matched\n"}
EOF

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  refute_output
  assert_stderr 'unexpected: api repos/acme/widgets'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
}

@test "it matches a response whose environment the call runs with" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0", "DO_NOT_TRACK": "1"}, "stdout": "matched\n"}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=0 DO_NOT_TRACK=1 \
    gh auth status

  assert_output matched
  refute_stderr
  diff - "$tree/calls" <<< '["gh","auth","status"]'
}

@test "it fails closed on a call without a variable the response names" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0", "DO_NOT_TRACK": "1"}, "stdout": "matched\n"}
EOF

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=0 \
    gh auth status

  refute_output
  assert_stderr 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
}

@test "it fails closed on a call with another value of a variable the response names" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "auth", "status"], "env": {"GH_TELEMETRY": "0"}, "stdout": "matched\n"}
EOF

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" GH_TELEMETRY=1 \
    gh auth status

  refute_output
  assert_stderr 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
}

@test "it copies each download into the directory after d" {
  setup_test "$tree"
  mkdir "$tree/release" "$tree/out-dir"
  echo binary > "$tree/release/widget-linux-x64"
  echo sums > "$tree/release/SHA256SUMS"
  jq -cn --arg release "$tree/release" '{
    argv: ["gh", "release", "download", "v1.0.0", "-R", "acme/widgets", "-p", "widget-linux-x64", "-p", "SHA256SUMS", "-D", null],
    downloads: {"widget-linux-x64": "\($release)/widget-linux-x64", "SHA256SUMS": "\($release)/SHA256SUMS"}
  }' > "$tree/responses"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -R acme/widgets -p widget-linux-x64 -p SHA256SUMS -D "$tree/out-dir"

  refute_output
  refute_stderr
  diff - <(find "$tree/out-dir" -mindepth 1 -printf '%f\n' | LC_ALL=C sort) << 'EOF'
SHA256SUMS
widget-linux-x64
EOF
  diff - "$tree/out-dir/widget-linux-x64" <<< binary
  diff - "$tree/out-dir/SHA256SUMS" <<< sums
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-R\",\"acme/widgets\",\"-p\",\"widget-linux-x64\",\"-p\",\"SHA256SUMS\",\"-D\",\"$tree/out-dir\"]"
}

@test "it copies nothing into the directory after d on a call no response matches" {
  setup_test "$tree"
  mkdir "$tree/release" "$tree/out-dir"
  echo binary > "$tree/release/widget-linux-x64"
  jq -cn --arg release "$tree/release" '{
    argv: ["gh", "release", "download", "v1.0.0", "-R", "acme/widgets", "-p", "widget-linux-x64", "-D", null],
    downloads: {"widget-linux-x64": "\($release)/widget-linux-x64"}
  }' > "$tree/responses"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0 -R acme/widgets -p widget-darwin-arm64 -D "$tree/out-dir"

  refute_output
  assert_stderr "unexpected: release download v1.0.0 -R acme/widgets -p widget-darwin-arm64 -D $tree/out-dir"
  diff /dev/null <(ls -A "$tree/out-dir")
  diff - "$tree/calls" <<< "[\"gh\",\"release\",\"download\",\"v1.0.0\",\"-R\",\"acme/widgets\",\"-p\",\"widget-darwin-arm64\",\"-D\",\"$tree/out-dir\"]"
}

@test "it fails closed on a response with downloads for a call without d" {
  setup_test "$tree"
  echo binary > "$tree/widget-linux-x64"
  jq -cn --arg asset "$tree/widget-linux-x64" '{
    argv: ["gh", "release", "download", "v1.0.0"], downloads: {"widget-linux-x64": $asset}
  }' > "$tree/responses"

  run -97 --separate-stderr in_dir "$tree/tmp" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh release download v1.0.0

  refute_output
  assert_stderr 'gh stand-in: the response has downloads but the call has no -D'
  diff /dev/null <(ls -A "$tree/tmp")
  diff - "$tree/calls" <<< '["gh","release","download","v1.0.0"]'
}

@test "it prints the bytes of the stdout file after stdout" {
  setup_test "$tree"
  printf 'line one\nline two without a newline' > "$tree/body"
  jq -cn --arg body "$tree/body" '{argv: ["gh", "api", "repos/acme/widgets"], stdout: "head\n", stdout_file: $body}' \
    > "$tree/responses"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out" 2> "$tree/err"

  printf 'head\nline one\nline two without a newline' | cmp - "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
}

@test "it answers with the first response that matches" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/other"], "stdout": "other\n"}
{"argv": ["gh", "api", null], "stdout": "first\n"}
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "second\n", "exit": 1}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  assert_output first
  refute_stderr
  diff - "$tree/calls" <<< '["gh","api","repos/acme/widgets"]'
}

@test "it fails closed with exit 97 on a call no response matches" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/gadgets

  refute_output
  assert_stderr 'unexpected: api repos/acme/gadgets'
  diff - "$tree/calls" <<< '["gh","api","repos/acme/gadgets"]'
}

@test "it fails closed with exit 97 when no responses file exists" {
  setup_test "$tree"

  run -97 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh auth status

  refute_output
  assert_stderr 'unexpected: auth status'
  diff - "$tree/calls" <<< '["gh","auth","status"]'
}

# err_to <file> <command…>: runs the command with its stderr in <file>
err_to() {
  local file="$1"
  shift
  "$@" 2> "$file"
}

@test "it appends each calls argv as one json line keeping spaces and quotes" {
  setup_test "$tree"
  echo '["gh", "--version"]' > "$tree/calls"

  # stderr to a file, for the space that the empty last argument leaves at the end of its line
  run -97 err_to "$tree/err" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api -H 'Accept: application/vnd.github.raw' --jq '.[] | select(.name == "a b")' "it's" ''

  refute_output
  diff - "$tree/err" <<< "unexpected: api -H Accept: application/vnd.github.raw --jq .[] | select(.name == \"a b\") it's "
  diff - "$tree/calls" << 'EOF'
["gh", "--version"]
["gh","api","-H","Accept: application/vnd.github.raw","--jq",".[] | select(.name == \"a b\")","it's",""]
EOF
}

# The stand-in is written before the case records any response, so the first call reads the
# response file as it stands then and the second reads its replacement.
@test "it reads the responses file at each call" {
  setup_test "$tree"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "before\n"}
EOF
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets > "$tree/out-before"
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "after\n"}
EOF

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  diff - "$tree/out-before" <<< before
  assert_output after
  refute_stderr
  diff - "$tree/calls" << 'EOF'
["gh","api","repos/acme/widgets"]
["gh","api","repos/acme/widgets"]
EOF
}

# create_stub_gh takes relative paths here, and the call runs from another directory, so the log
# and the responses are found only through the absolute paths the stand-in was written with.
@test "it reads and logs through the absolute paths it was written with" {
  mkdir "$tree/bin" "$tree/home" "$tree/tmp" "$tree/elsewhere"
  (cd "$tree" && create_stub_gh bin shared-calls responses)
  cat > "$tree/responses" << 'EOF'
{"argv": ["gh", "api", "repos/acme/widgets"], "stdout": "matched\n"}
EOF

  run -0 --separate-stderr in_dir "$tree/elsewhere" env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    gh api repos/acme/widgets

  assert_output matched
  refute_stderr
  diff - "$tree/shared-calls" <<< '["gh","api","repos/acme/widgets"]'
  diff /dev/null <(ls -A "$tree/elsewhere")
}
