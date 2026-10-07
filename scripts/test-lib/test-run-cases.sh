#!/usr/bin/env bash
# Test for run-cases.sh, the runner the shell suites source. It cannot run itself on the
# runner it tests, so it drives each case with the plain loop at the bottom: every case
# writes a small suite that sources run-cases.sh, runs it under `env -i`, and compares
# the whole output and the exact exit code. It keeps the caller's PATH, so it also runs in
# the Nix build sandbox (nixos/checks/test-utils-check.nix), which has no /usr/bin.
#
#   bash scripts/test-lib/test-run-cases.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022

it_prints_ok_for_each_passing_case_and_exits_0() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_passes_first() { true; }
it_passes_second() { true; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it passes first
ok it passes second
2 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_prints_a_failing_case_with_its_indented_output_keeps_going_and_exits_1() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_fails() { echo "first line"; echo "second line" >&2; return 3; }
it_passes_after() { true; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
FAIL it fails (exit 3)
    first line
    second line
ok it passes after
2 cases, 1 failed
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_ends_a_case_at_its_first_failing_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_stops_early() { false; echo "after the failure"; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
FAIL it stops early (exit 1)
1 cases, 1 failed
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_ends_a_case_that_reads_an_unset_variable() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_reads_unset() { echo "\$never_set"; echo "after the read"; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << EOF
FAIL it reads unset (exit 1)
    $tree/suite.sh: line 2: never_set: unbound variable
1 cases, 1 failed
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_ends_a_case_whose_pipeline_fails_before_its_last_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_pipes() { false | true; echo "after the pipeline"; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
FAIL it pipes (exit 1)
1 cases, 1 failed
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_runs_only_the_cases_whose_title_holds_CASE() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_reads_a_file() { true; }
it_writes_a_file() { false; }
run_cases
EOF

  env -i PATH="$PATH" CASE='reads a' bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it reads a file
1 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_exits_1_when_CASE_matches_no_case() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_passes() { true; }
run_cases
EOF

  env -i PATH="$PATH" CASE='no such title' bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" <<< '0 cases, 0 failed'
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_passes_its_arguments_to_every_case() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_sees_both() { [ "\$1 \$2" = "one two words" ]; }
it_counts_them() { [ "\$#" = 2 ]; }
run_cases one "two words"
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it counts them
ok it sees both
2 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_runs_a_case_exit_trap_when_the_case_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_cleans_up() { trap 'touch "$tree/cleaned"' EXIT; false; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  [ -e "$tree/cleaned" ] || { echo "the case's EXIT trap did not run" >&2; exit 1; }
  diff - "$tree/out" << 'EOF'
FAIL it cleans up (exit 1)
1 cases, 1 failed
EOF
  [ "$status" = 1 ] || { echo "exit $status, want 1" >&2; exit 1; }
}

it_keeps_one_case_state_out_of_the_next() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_a_sets_a_variable() { leaked=yes; cd /; }
it_b_sees_neither() { [ -z "\${leaked:-}" ] && [ "\$PWD" = "$tree" ]; }
run_cases
EOF

  (cd "$tree" && env -i PATH="$PATH" bash "$tree/suite.sh") > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it a sets a variable
ok it b sees neither
2 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_runs_its_cases_in_a_bash_without_programmable_completion() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
enable -n compgen complete
source "$lib"
it_passes() { true; }
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it passes
1 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

it_runs_an_exported_case() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  cat > "$tree/suite.sh" << EOF
source "$lib"
it_is_exported() { true; }
export -f it_is_exported
run_cases
EOF

  env -i PATH="$PATH" bash "$tree/suite.sh" > "$tree/out" 2>&1 || status=$?

  diff - "$tree/out" << 'EOF'
ok it is exported
1 cases, 0 failed
EOF
  [ "$status" = 0 ] || { echo "exit $status, want 0" >&2; exit 1; }
}

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-cases.sh"
failures=0
ran=0
for fn in $(declare -F | sed -n 's/^declare -f[a-z]* \(it_.*\)$/\1/p'); do
  ran=$((ran + 1))
  set +e
  output="$(
    (
      set -euo pipefail
      "$fn"
    ) 2>&1
  )"
  status=$?
  set -e
  if [ "$status" = 0 ]; then
    echo "ok ${fn//_/ }"
  else
    echo "FAIL ${fn//_/ } (exit $status)"
    printf '%s\n' "$output" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
done
echo "$ran cases, $failures failed"
[ "$failures" = 0 ]
