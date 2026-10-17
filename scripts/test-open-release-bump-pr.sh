#!/usr/bin/env bash
# Test for open-release-bump-pr.sh: from a clone of a real bare repository in the case tree, it
# runs the pin command on the release-check/<dependency> branch from origin's main, force-pushes
# that branch, and opens a labelled pull request, or updates the open one after it turns that
# one's auto-merge off. It pushes nothing when the branch already holds the same change, and stops
# with no push and no gh call when the pin changes nothing or fails. gh is the
# create-stub-release-gh.sh stand-in; git is real, under `env -i` with git's global and system
# config off. Each case's pin command writes a file, `pins`, as a pin script would.
#
#   bash scripts/test-open-release-bump-pr.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases commit do not depend on the caller's umask
umask 022
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts/../test-support/shell/run-cases.sh"
source "$scripts/../test-support/shell/create-stub-release-gh.sh"

script="$scripts/open-release-bump-pr.sh"

# setup_test <tree>: a bare repository at <tree>/origin.git, a working repository at <tree>/seed
# whose origin it is, the gh stand-in in <tree>/bin, and the home and temp folders the cases run
# with. It sets case_env, the environment every git and script call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp" "$tree/seed"
  create_stub_release_gh "$tree/bin"
  # no auto maintenance in any repository of the case: a commit's, a fetch's or a push's detached
  # repack could still write into it while the case's trap removes it. A push to a local origin
  # drops the GIT_CONFIG_* variables, so the origin carries the setting in its own config.
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp"
    STUB_TREE="$tree" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false)
  "${case_env[@]}" git init -q --bare -b main "$tree/origin.git"
  "${case_env[@]}" git -C "$tree/origin.git" config maintenance.auto false
  "${case_env[@]}" git -C "$tree/seed" init -q -b main
  "${case_env[@]}" git -C "$tree/seed" remote add origin "$tree/origin.git"
}

it_opens_a_labelled_pull_request_when_none_is_open() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'nixie 0.7.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "nixie 0.7.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/nixie:pins) <<< 'nixie 0.7.1'
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/nixie) <<< 'chore(nixie): bump nixie to 0.7.1'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/nixie","--title","chore(nixie): bump nixie to 0.7.1","--body-file","$tree/pr-body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_updates_the_open_pull_request_and_its_labels_after_it_turns_auto_merge_off() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'atc 4.2.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/atc
  echo 'atc 4.2.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(atc): bump atc to 4.2.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/atc
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":{"mergeMethod":"SQUASH"},"labels":[{"name":"auto-merge"},{"name":"keep me"},{"name":"update:patch"}],"number":12,"url":"https://github.com/zgeoff/cloud/pull/12"}]' > "$tree/open-prs"
  echo 'Bumps atc to 5.0.0.' > "$tree/pr-body"
  printf 'update:major\nneeds-review\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 5.0.0 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "atc 5.0.0" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/12'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/atc:pins) <<< 'atc 5.0.0'
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/atc) <<< 'chore(atc): bump atc to 5.0.0'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:major","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","a major release"]
["gh","label","create","needs-review","--repo","zgeoff/cloud","--force","--color","d73a4a","--description","waits for a review before it merges"]
["gh","pr","merge","12","--repo","zgeoff/cloud","--disable-auto"]
["gh","pr","edit","12","--repo","zgeoff/cloud","--remove-label","auto-merge"]
["gh","pr","edit","12","--repo","zgeoff/cloud","--add-label","needs-review,update:major","--remove-label","update:patch"]
["gh","pr","edit","12","--repo","zgeoff/cloud","--title","chore(atc): bump atc to 5.0.0","--body-file","$tree/pr-body"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_opens_the_missing_pull_request_when_the_branch_already_holds_the_change() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'imp 1.0.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  echo 'imp 1.0.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp > "$tree/before"
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "imp 1.0.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff "$tree/before" <("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp)
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","closed","--json","number,headRefOid,isCrossRepository","--jq","[.[] | select((.isCrossRepository | not) and .headRefOid == \\"$(cat "$tree/before")\\")][0].number // empty"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/imp","--title","chore(imp): bump imp to 1.0.1","--body-file","$tree/pr-body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_pushes_nothing_when_main_moved_only_in_other_files() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'imp 1.0.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  echo 'imp 1.0.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git -C "$tree/seed" switch -q main
  echo 'other work' > "$tree/seed/notes"
  "${case_env[@]}" git -C "$tree/seed" add notes
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add notes'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp > "$tree/before"
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"labels":[{"name":"auto-merge"},{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "imp 1.0.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1'
  diff /dev/null "$tree/err"
  diff "$tree/before" <("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp)
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_puts_back_the_auto_merge_label_with_no_push_after_a_run_that_failed_past_its_push() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'imp 1.0.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  echo 'imp 1.0.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git -C "$tree/seed" switch -q main
  "${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp > "$tree/before"
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  # the run before pushed this head, took auto-merge off and failed before it put it back
  echo '[{"autoMergeRequest":null,"labels":[{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "imp 1.0.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1'
  diff /dev/null "$tree/err"
  diff "$tree/before" <("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp)
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--add-label","auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_rebuilds_the_branch_when_main_changed_a_pinned_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf '# pins\nimp 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  printf '# pins\nimp 1.0.1\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git -C "$tree/seed" switch -q main
  printf '# the pins, by release\nimp 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'describe the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"labels":[{"name":"auto-merge"},{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^imp .*/imp 1.0.1/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/imp:pins) << 'EOF'
# the pins, by release
imp 1.0.1
EOF
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/imp) <<< 'chore(imp): bump imp to 1.0.1'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--remove-label","auto-merge"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--add-label","auto-merge"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--title","chore(imp): bump imp to 1.0.1","--body-file","$tree/pr-body"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_stops_when_main_already_pins_the_release() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'nixie 0.7.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "nixie 0.7.1 is already pinned"; echo "nixie 0.7.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'nixie 0.7.1 is already pinned'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" for-each-ref --format='%(refname)') <<< 'refs/heads/main'
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_without_a_push_when_the_pin_fails() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'nixie 0.7.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "the notes list 0 nixie digests" >&2; exit 1') > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the notes list 0 nixie digests'
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" for-each-ref --format='%(refname)') <<< 'refs/heads/main'
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_refuses_a_label_it_does_not_manage() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nship-it\n' > "$tree/labels"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" true) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< "not a release bump label: 'ship-it'"
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_prints_its_usage_without_a_pin_command() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  (cd "$tree/seed" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels") > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'usage: open-release-bump-pr.sh <dependency> <version> <body file> <labels file> <pin command>...'
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 2 ] || {
    echo "exit $status, want 2" >&2
    exit 1
  }
}

it_keeps_a_persons_needs_review_hold_on_an_unchanged_branch() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'imp 1.0.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  echo 'imp 1.0.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"isCrossRepository":false,"labels":[{"name":"needs-review"},{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "imp 1.0.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << 'EOF'
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_a_bump_closed_that_a_person_closed_at_the_same_head() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'imp 1.0.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/imp
  echo 'imp 1.0.1' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/imp
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  head="$("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/imp)"
  echo "[{\"headRefOid\":\"$head\",\"isCrossRepository\":false,\"number\":15}]" > "$tree/closed-prs"
  echo 'Bumps imp to 1.0.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" imp 1.0.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "imp 1.0.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#15 was closed with this bump; delete release-check/imp to open it again'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/imp","--state","closed","--json","number,headRefOid,isCrossRepository","--jq","[.[] | select((.isCrossRepository | not) and .headRefOid == \\"$head\\")][0].number // empty"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_opens_its_own_pull_request_past_a_forks_with_the_same_branch_name() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'nixie 0.7.0' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"isCrossRepository":true,"labels":[],"number":31,"url":"https://github.com/zgeoff/cloud/pull/31"}]' > "$tree/open-prs"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" \
    sh -c 'echo "nixie 0.7.1" > pins') > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/nixie","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/nixie","--title","chore(nixie): bump nixie to 0.7.1","--body-file","$tree/pr-body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_refuses_a_working_tree_that_another_pin_left_changed() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'nixie 0.7.0\nimp 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  printf 'nixie 0.7.0\nimp 1.0.1\n' > "$tree/clone/pins"
  echo 'Bumps nixie to 0.7.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" nixie 0.7.1 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^nixie .*/nixie 0.7.1/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'the working tree has uncommitted changes; commit or discard them first'
  diff - "$tree/clone/pins" << 'EOF'
nixie 0.7.0
imp 1.0.1
EOF
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" for-each-ref --format='%(refname)') <<< 'refs/heads/main'
  [ ! -e "$tree/calls" ] || {
    echo "gh ran: $(cat "$tree/calls")" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_keeps_a_persons_needs_review_hold_when_main_changed_another_pin_in_the_same_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'atc 4.2.0\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/atc
  printf 'atc 4.2.1\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(atc): bump atc to 4.2.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/atc
  "${case_env[@]}" git -C "$tree/seed" switch -q main
  printf 'atc 4.2.0\nimp-base 1.0.1\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"isCrossRepository":false,"labels":[{"name":"needs-review"},{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps atc to 4.2.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 4.2.1 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^atc .*/atc 4.2.1/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" show release-check/atc:pins) << 'EOF'
atc 4.2.1
imp-base 1.0.1
EOF
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/atc) <<< 'chore(atc): bump atc to 4.2.1'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--title","chore(atc): bump atc to 4.2.1","--body-file","$tree/pr-body"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_drops_a_persons_needs_review_hold_when_a_later_release_replaces_the_bump() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'atc 4.2.0\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/atc
  printf 'atc 4.2.1\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(atc): bump atc to 4.2.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/atc
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  echo '[{"autoMergeRequest":null,"isCrossRepository":false,"labels":[{"name":"needs-review"},{"name":"update:patch"}],"number":14,"url":"https://github.com/zgeoff/cloud/pull/14"}]' > "$tree/open-prs"
  echo 'Bumps atc to 4.2.2.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 4.2.2 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^atc .*/atc 4.2.2/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/14'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/atc) <<< 'chore(atc): bump atc to 4.2.2'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--add-label","auto-merge","--remove-label","needs-review"]
["gh","pr","edit","14","--repo","zgeoff/cloud","--title","chore(atc): bump atc to 4.2.2","--body-file","$tree/pr-body"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_a_rejected_release_closed_when_main_changed_another_pin_in_the_same_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'atc 4.2.0\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/atc
  printf 'atc 4.2.1\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(atc): bump atc to 4.2.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/atc
  "${case_env[@]}" git -C "$tree/seed" switch -q main
  printf 'atc 4.2.0\nimp-base 1.0.1\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(imp): bump imp to 1.0.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  head="$("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/atc)"
  echo "[{\"headRefOid\":\"$head\",\"isCrossRepository\":false,\"number\":15}]" > "$tree/closed-prs"
  echo 'Bumps atc to 4.2.1.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 4.2.1 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^atc .*/atc 4.2.1/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '#15 was closed with this bump; delete release-check/atc to open it again'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/atc) <<< "$head"
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","closed","--json","number,headRefOid,isCrossRepository","--jq","[.[] | select((.isCrossRepository | not) and .headRefOid == \\"$head\\")][0].number // empty"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_opens_a_later_release_after_a_person_rejected_the_one_before() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  printf 'atc 4.2.0\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" add -A
  "${case_env[@]}" git -C "$tree/seed" commit -qm 'add the pins'
  "${case_env[@]}" git -C "$tree/seed" push -q origin main
  "${case_env[@]}" git -C "$tree/seed" switch -qc release-check/atc
  printf 'atc 4.2.1\nimp-base 1.0.0\n' > "$tree/seed/pins"
  "${case_env[@]}" git -C "$tree/seed" commit -qam 'chore(atc): bump atc to 4.2.1'
  "${case_env[@]}" git -C "$tree/seed" push -q origin release-check/atc
  "${case_env[@]}" git clone -q "$tree/origin.git" "$tree/clone"
  head="$("${case_env[@]}" git --git-dir="$tree/origin.git" rev-parse release-check/atc)"
  echo "[{\"headRefOid\":\"$head\",\"isCrossRepository\":false,\"number\":15}]" > "$tree/closed-prs"
  echo 'Bumps atc to 4.2.2.' > "$tree/pr-body"
  printf 'update:patch\nauto-merge\n' > "$tree/labels"

  (cd "$tree/clone" && "${case_env[@]}" bash "$script" atc 4.2.2 "$tree/pr-body" "$tree/labels" \
    sed -i 's/^atc .*/atc 4.2.2/' pins) > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff - <("${case_env[@]}" git --git-dir="$tree/origin.git" log --format=%s main..release-check/atc) <<< 'chore(atc): bump atc to 4.2.2'
  diff - "$tree/calls" << EOF
["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url,autoMergeRequest,labels,isCrossRepository"]
["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]
["gh","label","create","auto-merge","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","merges on its own once its checks pass"]
["gh","pr","create","--repo","zgeoff/cloud","--base","main","--head","release-check/atc","--title","chore(atc): bump atc to 4.2.2","--body-file","$tree/pr-body","--label","update:patch,auto-merge"]
EOF
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

run_cases
