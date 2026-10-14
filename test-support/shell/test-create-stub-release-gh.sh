#!/usr/bin/env bash
# Test for create-stub-release-gh.sh: the gh stand-in logs each call and the GH_TOKEN it ran with,
# serves the releases a test writes under STUB_TREE/releases, answers a missing release as gh
# 2.102.0 does, lists, shows, merges, labels, creates and edits pull requests, and fails closed on
# any other call.
#
#   bash test-support/shell/test-create-stub-release-gh.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/create-stub-release-gh.sh"

# setup_test <tree>: the stand-in in <tree>/bin and the HOME and TMPDIR it runs with. It sets
# case_env, the environment every call in a case runs with.
setup_test() {
  local tree="$1"
  mkdir "$tree/bin" "$tree/home" "$tree/tmp"
  create_stub_release_gh "$tree/bin"
  case_env=(env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_TREE="$tree")
}

it_lists_the_release_tags_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/imp"
  printf '%s\n' v1.0.1 v1.0.0 > "$tree/releases/imp/tags"

  "${case_env[@]}" gh release list -R zgeoff/imp --exclude-drafts --exclude-pre-releases --limit 30 \
    --json tagName --jq '.[].tagName' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
v1.0.1
v1.0.0
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","release","list","-R","zgeoff/imp","--exclude-drafts","--exclude-pre-releases","--limit","30","--json","tagName","--jq",".[].tagName"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lists_no_release_when_the_test_wrote_no_tags() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh release list -R zgeoff/imp --exclude-drafts --exclude-pre-releases --limit 30 \
    --json tagName --jq '.[].tagName' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_shows_the_notes_of_a_tag_whose_slashes_become_underscores() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/atc/@zgeoff_atc@4.3.0"
  printf '%s\n' '## Features' '' '- one' > "$tree/releases/atc/@zgeoff_atc@4.3.0/notes.md"

  "${case_env[@]}" gh release view @zgeoff/atc@4.3.0 -R zgeoff/atc --json body --jq .body > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" << 'EOF'
## Features

- one
EOF
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","release","view","@zgeoff/atc@4.3.0","-R","zgeoff/atc","--json","body","--jq",".body"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_view_of_a_missing_release_as_gh_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh release view v9.9.9 -R zgeoff/nixie --json body --jq .body > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_downloads_a_release_asset_into_a_new_directory() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/atc/@zgeoff_atc@4.3.0"
  echo '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64' > "$tree/releases/atc/@zgeoff_atc@4.3.0/SHA256SUMS"

  "${case_env[@]}" gh release download @zgeoff/atc@4.3.0 -R zgeoff/atc -p SHA256SUMS -D "$tree/dl/new" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/dl/new/SHA256SUMS" <<< '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_download_of_a_missing_release_as_gh_does() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh release download @zgeoff/atc@9.9.9 -R zgeoff/atc -p SHA256SUMS -D "$tree/dl" > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'release not found'
  [ ! -e "$tree/dl" ] || {
    echo "the download made $tree/dl" >&2
    exit 1
  }
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_prints_the_commit_of_a_tag() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  mkdir -p "$tree/releases/imp/v1.0.1"
  echo c5bea94080fdde9e21e9720295c1ca727302662e > "$tree/releases/imp/v1.0.1/commit"

  "${case_env[@]}" gh api repos/zgeoff/imp/commits/v1.0.1 --jq .sha > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'c5bea94080fdde9e21e9720295c1ca727302662e'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","api","repos/zgeoff/imp/commits/v1.0.1","--jq",".sha"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_the_commit_of_a_missing_tag_with_the_apis_422() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh api repos/zgeoff/imp/commits/v9.9.9 --jq .sha > "$tree/out" 2> "$tree/err" || status=$?

  diff - <(
    cat "$tree/out"
    echo
  ) <<< '{"message":"No commit found for SHA: v9.9.9","documentation_url":"https://docs.github.com/rest/commits/commits#get-a-commit","status":"422"}'
  [ "$(tail -c 1 "$tree/out")" = '}' ] || {
    echo "stdout ends in a newline" >&2
    exit 1
  }
  diff - "$tree/err" <<< 'gh: No commit found for SHA: v9.9.9 (HTTP 422)'
  [ "$status" = 1 ] || {
    echo "exit $status, want 1" >&2
    exit 1
  }
}

it_lists_no_open_pull_request_when_the_test_wrote_none() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh pr list --repo zgeoff/cloud --head release-check/atc --state open --json number,url > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[]'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","list","--repo","zgeoff/cloud","--head","release-check/atc","--state","open","--json","number,url"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lists_the_open_pull_requests_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"number":12,"url":"https://github.com/zgeoff/cloud/pull/12"}]' > "$tree/open-prs"

  "${case_env[@]}" gh pr list --repo zgeoff/cloud --head release-check/atc --state open --json number,url > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[{"number":12,"url":"https://github.com/zgeoff/cloud/pull/12"}]'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_lists_the_closed_pull_requests_the_test_wrote_apart_from_the_open_ones() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"number":12}]' > "$tree/open-prs"
  echo '[{"number":15}]' > "$tree/closed-prs"

  "${case_env[@]}" gh pr list --repo zgeoff/cloud --head release-check/atc --state closed --json number > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '[{"number":15}]'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_filters_the_open_pull_requests_through_the_calls_jq() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '[{"number":12,"url":"https://github.com/zgeoff/cloud/pull/12"}]' > "$tree/open-prs"

  "${case_env[@]}" gh pr list --repo zgeoff/cloud --head release-check/atc --state open --json number --jq '.[0].number // empty' > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '12'
  diff /dev/null "$tree/err"
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_shows_the_pull_request_the_test_wrote() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo '{"headRefOid":"abc"}' > "$tree/pr-view"

  "${case_env[@]}" gh pr view 12 --repo zgeoff/cloud --json headRefOid > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< '{"headRefOid":"abc"}'
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","view","12","--repo","zgeoff/cloud","--json","headRefOid"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_turns_auto_merge_off_silently() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh pr merge 12 --repo zgeoff/cloud --disable-auto > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","merge","12","--repo","zgeoff/cloud","--disable-auto"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_squash_merges_silently_and_logs_the_token_it_ran_with() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" GH_TOKEN=app-token gh pr merge 12 --repo zgeoff/cloud --squash --match-head-commit abc > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","pr","merge","12","--repo","zgeoff/cloud","--squash","--match-head-commit","abc"]'
  diff - "$tree/tokens" <<< 'app-token'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_logs_unset_for_a_call_without_a_token() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh pr merge 12 --repo zgeoff/cloud --disable-auto > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/tokens" <<< 'unset'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_creates_a_label_silently() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh label create update:patch --repo zgeoff/cloud --force --color 0e8a16 --description 'a patch release' > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff /dev/null "$tree/err"
  diff - "$tree/calls" <<< '["gh","label","create","update:patch","--repo","zgeoff/cloud","--force","--color","0e8a16","--description","a patch release"]'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_a_create_with_the_new_pull_requests_url_and_keeps_its_body() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'Bumps atc to 4.3.0.' > "$tree/body.md"

  "${case_env[@]}" gh pr create --repo zgeoff/cloud --base main --head release-check/atc --title t --body-file "$tree/body.md" --label auto-merge > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/200'
  diff /dev/null "$tree/err"
  diff - "$tree/body" <<< 'Bumps atc to 4.3.0.'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_answers_an_edit_with_the_pull_requests_url_and_keeps_its_body() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"
  echo 'Bumps atc to 4.3.1.' > "$tree/body.md"

  "${case_env[@]}" gh pr edit 12 --repo zgeoff/cloud --title t --body-file "$tree/body.md" > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/12'
  diff /dev/null "$tree/err"
  diff - "$tree/body" <<< 'Bumps atc to 4.3.1.'
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_keeps_no_body_for_an_edit_without_a_body_file() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh pr edit 12 --repo zgeoff/cloud --add-label auto-merge > "$tree/out" 2> "$tree/err" || status=$?

  diff - "$tree/out" <<< 'https://github.com/zgeoff/cloud/pull/12'
  diff /dev/null "$tree/err"
  [ ! -e "$tree/body" ] || {
    echo "the edit kept a body: $(cat "$tree/body")" >&2
    exit 1
  }
  [ "$status" = 0 ] || {
    echo "exit $status, want 0" >&2
    exit 1
  }
}

it_fails_closed_on_an_unexpected_call() {
  local status=0
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  setup_test "$tree"

  "${case_env[@]}" gh repo delete zgeoff/cloud > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" <<< 'unexpected: repo delete zgeoff/cloud'
  diff - "$tree/calls" <<< '["gh","repo","delete","zgeoff/cloud"]'
  [ "$status" = 97 ] || {
    echo "exit $status, want 97" >&2
    exit 1
  }
}

run_cases
