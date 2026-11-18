# shellcheck shell=bash
# The case runner the shell test suites source. A suite defines each case as a function
# named it_<words>, whose title is that name with spaces for underscores, then calls
# run_cases with the arguments every case takes.
#
# run_cases runs each case (or each case whose title holds $CASE) in its own subshell
# with errexit, nounset and pipefail, so a failing command ends the case; the subshell is
# a plain statement, never the operand of `||` or `if`, where bash would ignore errexit.
# It prints `ok <title>`, or `FAIL <title> (exit <n>)` and the case's output indented,
# keeps going after a failure, then prints the totals. It exits 1 when a case failed or
# when no case ran. It lists the cases with `declare -F`, not `compgen`, so it also runs
# under a bash built without programmable completion, such as the Nix build sandbox's.
run_cases() {
  local fn title output status failures=0 ran=0
  for fn in $(declare -F | sed -n 's/^declare -f[a-z]* \(it_.*\)$/\1/p'); do
    title="${fn//_/ }"
    [[ "$title" == *"${CASE:-}"* ]] || continue
    ran=$((ran + 1))
    set +e
    output="$(
      (
        set -euo pipefail
        "$fn" "$@"
      ) 2>&1
    )"
    status=$?
    set -e
    if [ "$status" = 0 ]; then
      echo "ok $title"
    else
      echo "FAIL $title (exit $status)"
      if [ -n "$output" ]; then printf '%s\n' "$output" | sed 's/^/    /'; fi
      failures=$((failures + 1))
    fi
  done
  echo "$ran cases, $failures failed"
  if [ "$ran" = 0 ] || [ "$failures" != 0 ]; then exit 1; fi
}
