#!/usr/bin/env bash
# Test for run-shell-suites.sh: in a real git repository in the case tree, it runs every test-*.sh
# that git tracks or would track, at any depth, a suite added after the runner among them, in path
# order; it leaves out ignored files, .claude/ and the suites of other groups; it runs only the
# named group's suites when given one; it keeps going after a failed suite and names it; it passes
# CASE through; and it fails on an empty group and on a bad argument. Each case runs a copy of the
# runner, which runs from the copy's repo, under `env -i` with git's global and system config off,
# and compares the whole stdout and stderr.
#
#   bash scripts/test-run-shell-suites.sh
#   CASE='failed suite' bash scripts/test-run-shell-suites.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the modes the cases assert do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/assert-status.sh"

runner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-shell-suites.sh"

it_runs_every_suite_of_the_default_group_at_any_depth_in_path_order() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho a\n' > "$tree/repo/scripts/test-a.sh"
  mkdir -p "$tree/repo/deploy/new/area"
  printf '#!/usr/bin/env bash\necho b\n' > "$tree/repo/deploy/new/area/test-b.sh"
  printf '#!/usr/bin/env bash\necho root\n' > "$tree/repo/test-root.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add scripts/test-a.sh

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== deploy/new/area/test-b.sh
b
== scripts/test-a.sh
a
== test-root.sh
root
3 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_leaves_out_ignored_files_claude_files_other_groups_and_files_that_are_not_suites() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho a\n' > "$tree/repo/scripts/test-a.sh"
  mkdir -p "$tree/repo/ignored" "$tree/repo/.claude/skills/x/scripts" "$tree/repo/test-support/shell"
  echo '/ignored/' > "$tree/repo/.gitignore"
  printf '#!/usr/bin/env bash\necho ignored\nexit 1\n' > "$tree/repo/ignored/test-c.sh"
  printf '#!/usr/bin/env bash\necho claude\nexit 1\n' > "$tree/repo/.claude/skills/x/scripts/test-d.sh"
  printf '#!/usr/bin/env bash\n# A Docker suite.\n# shell-suite: docker-fixture\nset -e\necho docker\nexit 1\n' > "$tree/repo/scripts/test-docker.sh"
  printf '#!/usr/bin/env bash\necho helper\nexit 1\n' > "$tree/repo/test-support/shell/assert-equals.sh"
  printf '#!/usr/bin/env bash\necho tested\nexit 1\n' > "$tree/repo/scripts/test-a.sh.orig"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== scripts/test-a.sh
a
1 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_runs_only_the_suites_of_the_named_group() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho a\nexit 1\n' > "$tree/repo/scripts/test-a.sh"
  printf '#!/usr/bin/env bash\n# A Docker suite.\n#\n# shell-suite: docker-fixture\n# shellcheck source-path=SCRIPTDIR\necho docker\n' > "$tree/repo/scripts/test-docker.sh"
  printf '#!/usr/bin/env bash\n# shell-suite: other-fixture\necho other\nexit 1\n' > "$tree/repo/scripts/test-other.sh"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh docker-fixture) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== scripts/test-docker.sh
docker
1 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_reads_a_group_only_from_the_comment_block_at_the_top() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\nset -e\n# shell-suite: docker-fixture\necho late\n' > "$tree/repo/scripts/test-late.sh"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== scripts/test-late.sh
late
1 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_keeps_going_after_a_failed_suite_and_names_each_failed_suite() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho a\nexit 1\n' > "$tree/repo/scripts/test-a.sh"
  printf '#!/usr/bin/env bash\necho b\n' > "$tree/repo/scripts/test-b.sh"
  printf '#!/usr/bin/env bash\necho c >&2\nexit 3\n' > "$tree/repo/scripts/test-c.sh"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== scripts/test-a.sh
a
== scripts/test-b.sh
b
== scripts/test-c.sh
3 suites, 2 failed
EOF
  diff - "$tree/err" << 'EOF'
c
run-shell-suites: scripts/test-a.sh failed
run-shell-suites: scripts/test-c.sh failed
EOF
  assert_status 1 "$status"
}

it_passes_case_through_to_each_suite() {
  local status=0
  create_case_tree
  setup_test "$tree"
  # the suite expands CASE when it runs, so the text stays unexpanded here
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\necho "a: ${CASE-unset}"\n' > "$tree/repo/scripts/test-a.sh"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 CASE='some title' bash scripts/run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
== scripts/test-a.sh
a: some title
1 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_runs_from_the_repo_root_when_called_from_a_subdirectory() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\npwd\n' > "$tree/repo/scripts/test-a.sh"

  (cd "$tree/repo/scripts" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash run-shell-suites.sh) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << EOF
== scripts/test-a.sh
$tree/repo
1 suites, 0 failed
EOF
  diff /dev/null "$tree/err"
  assert_status 0 "$status"
}

it_fails_when_the_group_has_no_suite() {
  local status=0
  create_case_tree
  setup_test "$tree"
  printf '#!/usr/bin/env bash\necho a\n' > "$tree/repo/scripts/test-a.sh"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh docker-fixture) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'run-shell-suites: no suite in the docker-fixture group'
  assert_status 1 "$status"
}

it_rejects_a_group_that_is_not_a_plain_name_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh 'Docker fixture') > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-shell-suites.sh [group]'
  assert_status 2 "$status"
}

it_rejects_a_second_argument_with_its_usage() {
  local status=0
  create_case_tree
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/run-shell-suites.sh scripts extra) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: run-shell-suites.sh [group]'
  assert_status 2 "$status"
}

# a git repository whose scripts/ holds a copy of the runner, tracked, so the runner runs from the
# case's repo and never the real one
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo/scripts"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  cp "$runner" "$tree/repo/scripts/run-shell-suites.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add scripts/run-shell-suites.sh
}

run_cases
