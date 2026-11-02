#!/usr/bin/env bash
# Test for the agent image's build step sbin/download-with-resume, run with the real curl against
# the stand-ins from test-support/shell: a download whose every connection stays under the speed
# floor finishes, because each attempt resumes where the one before ended, and a download that
# adds no bytes fails after 5 attempts with curl's status. The cases pass the Dockerfile's speed
# floor with a --speed-time of 1, so an attempt ends in about 1 s, and put create_stub_clock's
# pause first on PATH as sleep, so a pause is recorded and returns at once. Each case runs the
# step under `timeout 30`, so a step that never ends fails the case with exit 124.
#
#   bash images/agent/test-download-with-resume.sh
# shellcheck source-path=SCRIPTDIR/../..
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
umask 022
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-support/shell/run-cases.sh
source "$here/../../test-support/shell/run-cases.sh"
# shellcheck source=test-support/shell/create-case-tree.sh
source "$here/../../test-support/shell/create-case-tree.sh"
# shellcheck source=test-support/shell/assert-equals.sh
source "$here/../../test-support/shell/assert-equals.sh"
# shellcheck source=test-support/shell/assert-status.sh
source "$here/../../test-support/shell/assert-status.sh"
# shellcheck source=test-support/shell/create-stub-clock.sh
source "$here/../../test-support/shell/create-stub-clock.sh"
# shellcheck source=test-support/shell/start-stub-slow-download.sh
source "$here/../../test-support/shell/start-stub-slow-download.sh"

step="$here/sbin/download-with-resume"

# setup_test <tree>: the pause in <tree>/bin, and the home and temp folders the step runs with
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_clock "$tree/bin"
}

it_finishes_a_download_whose_every_connection_stays_under_the_speed_floor() {
  local status=0
  create_case_tree 'kill "$(cat "$tree/download/pid" 2> /dev/null)" 2> /dev/null || true'
  setup_test "$tree"
  # 384 KiB at 128 KiB/s takes 3 s, and the floor ends each attempt after about 1 s
  start_stub_slow_download "$tree/download" 393216 131072

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout 30 "$step" "$tree/chrome.zip" "http://127.0.0.1:$(cat "$tree/download/port")/chrome.zip" \
    -q --noproxy '*' --speed-limit 1048576 --speed-time 1 > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 0 "$status"
  cmp "$tree/download/body" "$tree/chrome.zip"
  diff /dev/null "$tree/out"
  # how many bytes each attempt fetched depends on timing, so the counts are masked
  sed -E 's/with [0-9]+ bytes/with <n> bytes/' "$tree/err" | sort -u > "$tree/err-lines"
  diff - "$tree/err-lines" << 'EOF'
curl: (28) Operation too slow. Less than 1048576 bytes/sec transferred the last 1 seconds
download-with-resume: curl exited 28 with <n> bytes, resuming in 2s
EOF
  # the first GET asks for the whole file, and each later one for the bytes after the last
  awk '
    NR == 1 { if ($3 != "-") exit 1; next }
    { split($3, range, /[=-]/); if (range[2] + 0 <= last) exit 1; last = range[2] + 0 }
    END { if (NR < 2) exit 1 }
  ' "$tree/download/requests"
  assert_equals "$(($(wc -l < "$tree/download/requests") - 1))" "$(grep -c '^2$' "$tree/bin/pauses")" \
    "the 2 s pauses, one before each resumed attempt"
}

it_fails_with_curls_status_after_5_attempts_in_a_row_that_add_no_bytes() {
  local status=0
  create_case_tree
  setup_test "$tree"

  # nothing listens on port 1, so each attempt fails at once and adds no bytes
  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    timeout 30 "$step" "$tree/chrome.zip" "http://127.0.0.1:1/chrome.zip" -q --noproxy '*' \
    > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 7 "$status"
  diff /dev/null "$tree/out"
  # the milliseconds each connect took are a measurement, so they are masked
  sed -E 's/after [0-9]+ ms/after <ms> ms/' "$tree/err" > "$tree/err-masked"
  diff - "$tree/err-masked" << 'EOF'
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
download-with-resume: curl exited 7 with 0 bytes, resuming in 2s
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
download-with-resume: curl exited 7 with 0 bytes, resuming in 2s
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
download-with-resume: curl exited 7 with 0 bytes, resuming in 2s
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
download-with-resume: curl exited 7 with 0 bytes, resuming in 2s
curl: (7) Failed to connect to 127.0.0.1 port 1 after <ms> ms: Couldn't connect to server
download-with-resume: curl exited 7 with 0 bytes, after 5 attempts that added none
EOF
  diff - "$tree/bin/pauses" << 'EOF'
2
2
2
2
EOF
}

it_refuses_a_call_without_a_url() {
  local status=0
  create_case_tree
  setup_test "$tree"

  env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" \
    "$step" "$tree/chrome.zip" > "$tree/out" 2> "$tree/err" || status=$?

  assert_status 2 "$status"
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: download-with-resume <file> <url> [<curl option>...]'
}

run_cases
