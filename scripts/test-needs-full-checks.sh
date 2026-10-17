#!/usr/bin/env bash
# Test for needs-full-checks.sh: against a real git repository in the case tree, it prints false
# for a change to Markdown files only, true for a change to any other file (a script, or a file
# under docs/ that is not Markdown), compares from the merge base, counts both paths of a rename,
# treats an all-zero base, a base that is not an ancestor (one with no history in common among
# them) and an empty change as needing the checks, and fails with git's error on a base git cannot
# resolve. Each case runs the script under `env -i` with git's global and system config off.
#
#   bash scripts/test-needs-full-checks.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../test-support/shell/run-cases.sh"

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needs-full-checks.sh"

it_prints_false_for_a_change_to_markdown_files_only() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/repo/docs/runbooks" "$tree/repo/.claude/skills/docs-writing"
  echo '# cloud' > "$tree/repo/README.md"
  echo '# a runbook' > "$tree/repo/docs/runbooks/notes.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the docs'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/README.md"
  echo changed >> "$tree/repo/docs/runbooks/notes.md"
  echo '# a skill' > "$tree/repo/.claude/skills/docs-writing/SKILL.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'change the docs'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_to_a_script_beside_markdown() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo '# cloud' > "$tree/repo/README.md"
  echo 'echo fixture' > "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the readme and a script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo changed >> "$tree/repo/README.md"
  echo '# changed' >> "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the readme and the script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_file_under_docs_that_is_not_markdown() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  mkdir "$tree/repo/docs"
  echo '<svg/>' > "$tree/repo/docs/overview.svg"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a diagram'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_file_whose_name_holds_md_before_its_extension() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  echo 'echo fixture' > "$tree/repo/notes.md.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_when_a_rename_turns_a_script_into_markdown() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo 'echo fixture' > "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" mv scripts/fixture.sh scripts/fixture.md
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'move the script to markdown'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_when_a_script_is_deleted() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo 'echo fixture' > "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rm -q scripts/fixture.sh
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'remove the script'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_merge_commit_whose_own_change_is_markdown_after_main_changed_a_script() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/repo/scripts"
  echo 'echo fixture' > "$tree/repo/scripts/fixture.sh"
  echo '# cloud' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a script and the readme'
  # as for a pull request: main changes the script after the fork, and the head under test is the
  # merge of the feature branch into main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -qc feature
  echo changed >> "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the readme on the feature branch'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -q main
  echo '# changed' >> "$tree/repo/scripts/fixture.sh"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the script on main'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" merge -q --no-edit feature

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" main~1 main) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_base_that_is_not_an_ancestor_of_the_head() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '# cloud' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the readme'
  # as for a push that rewrote main: the old tip changed only Markdown, and the new tip is its
  # parent
  echo changed >> "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qam 'change the readme'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/old-tip"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" reset -q --hard HEAD~1

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/old-tip")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_base_with_no_history_in_common_with_the_head() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  # as for a push that replaced main with an unrelated history: the old tip changed only Markdown
  echo '# cloud' > "$tree/repo/README.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add the readme'
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/old-tip"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" switch -q --orphan rewritten
  echo '# notes' > "$tree/repo/notes.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'start a new history'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/old-tip")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_a_change_with_no_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -q --allow-empty -m 'change nothing'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_false_for_a_change_to_a_markdown_file_whose_name_git_quotes() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" rev-parse HEAD > "$tree/base"
  mkdir "$tree/repo/docs"
  echo '# notes' > "$tree/repo/docs/é.md"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" add -A
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -qm 'add a file whose name git quotes'

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$(cat "$tree/base")" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< false
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_prints_true_for_an_all_zero_base_without_reading_git() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir "$tree/not-a-repo"

  (cd "$tree/not-a-repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" 0000000000000000000000000000000000000000 HEAD) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< true
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_with_gits_error_for_a_commit_id_the_clone_does_not_have() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" 1111111111111111111111111111111111111111 HEAD) \
    > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: Not a valid commit name 1111111111111111111111111111111111111111
ERR
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_fails_with_gits_error_for_a_base_git_cannot_resolve() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" no-such-ref HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'ERR'
fatal: Not a valid object name no-such-ref
ERR
  [ "$status" = 128 ] || {
    echo "exit $status, want 128" >&2
    exit 1
  }
}

it_rejects_an_empty_base_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" '' HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-full-checks.sh <base> <head>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_rejects_a_call_without_two_arguments_with_its_usage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/repo" && env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" HEAD) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: needs-full-checks.sh <base> <head>'
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

# Runtime every case needs: a git repository on main, with the identity the cases commit with in
# its own config. Each case commits the files its scenario starts from.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/home" "$tree/tmp" "$tree/repo"
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" init -q -b main
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.name fixture
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config user.email fixture@example.invalid
  # no auto maintenance: a commit's detached repack could still write into the repository while
  # the case's trap removes it
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" config maintenance.auto false
  # boot data: an empty root commit, so HEAD resolves before a case commits anything of its own
  env -i PATH=/usr/bin:/bin HOME="$tree/home" TMPDIR="$tree/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree/repo" commit -q --allow-empty -m 'start the history'
}

run_cases
