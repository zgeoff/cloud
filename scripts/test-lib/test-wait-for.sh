#!/usr/bin/env bash
# Test for wait-for.sh: wait_for polls a command until it succeeds, and fails with a
# named message once its deadline passes.
#
#   bash scripts/test-lib/test-wait-for.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh"

it_returns_once_the_command_succeeds_on_a_later_poll() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  # shellcheck disable=SC2016 # expanded by the poll script
  printf '#!/usr/bin/env bash\necho poll >> "%s/polls"\n[ "$(wc -l < "%s/polls")" -ge 3 ]\n' "$tree" "$tree" > "$tree/third-poll"
  chmod +x "$tree/third-poll"

  wait_for 5 "the third poll" "$tree/third-poll" > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  diff - <(wc -l < "$tree/polls") <<< 3
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_returns_without_polling_again_when_the_command_succeeds_at_once() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT

  wait_for 5 "a true command" true > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_fails_with_a_named_message_once_the_deadline_passes() {
  local started elapsed status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  started="$SECONDS"

  wait_for 1 "a condition that never holds" false > "$tree/out" 2> "$tree/err" || status=$?

  elapsed=$((SECONDS - started))
  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'timed out after 1s waiting for a condition that never holds'
  [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 3 ] || { echo "returned after ${elapsed}s, want 1 to 3" >&2; exit 1; }
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_passes_the_command_arguments_through_unchanged() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  touch "$tree/a file with spaces"

  wait_for 5 "the file" test -f "$tree/a file with spaces" > "$tree/out" 2>&1 || status=$?

  diff /dev/null "$tree/out"
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

run_cases
