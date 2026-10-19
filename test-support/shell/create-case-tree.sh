# shellcheck shell=bash
# create_case_tree [<cleanup>]: sets the global tree to a fresh `mktemp -d` directory, and sets
# the EXIT trap to run <cleanup>, when given, then `rm -rf "$tree" || true`. Call it as a plain
# statement in the case itself, never in $(…) or a pipeline, so the variable and the trap reach the
# case. Bash keeps one EXIT trap, so the call replaces any trap set before it. <cleanup> runs as
# written when the case exits, so it may read a global the case sets later; end each of its steps
# with `|| true`, so a failed step still leaves the tree removed.
create_case_tree() {
  # ${1-}, so shellcheck reads the argument as optional and passes a call without one
  local cleanup="${1-}"
  tree="$(mktemp -d)"
  # shellcheck disable=SC2064 # <cleanup> goes into the trap now; "$tree" expands at exit
  trap "${cleanup:+$cleanup; }rm -rf \"\$tree\" || true" EXIT
}
