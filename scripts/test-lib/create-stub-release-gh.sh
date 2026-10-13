# shellcheck shell=bash
# create_stub_release_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI calls that the
# release check scripts make (find-release-bumps.sh, bump-release.sh, open-release-bump-pr.sh and
# merge-release-bump.sh). It logs each call's argv as a JSON line to STUB_TREE/calls, and the
# GH_TOKEN it ran with as a line to STUB_TREE/tokens ("unset" when missing). A test states the
# releases as files under STUB_TREE/releases/<repo>/, where a tag's directory is the tag with each
# "/" as "_" (@zgeoff/atc@1.2.3 is @zgeoff_atc@1.2.3):
#
# - `release list -R zgeoff/<repo> … --json tagName --jq .[].tagName` prints
#   releases/<repo>/tags, one tag per line, newest first as gh lists them, or nothing when the file
#   is missing, as gh prints for a repository without releases.
# - `release view <tag> -R zgeoff/<repo> --json body --jq .body` prints the tag's notes.md.
# - `release download <tag> -R zgeoff/<repo> -p <asset> -D <dir>` copies the tag's <asset> into
#   <dir>, creating it.
# - `api repos/zgeoff/<repo>/commits/<tag> --jq .sha` prints the tag's commit file.
# - `pr list … --state open …` prints STUB_TREE/open-prs, and `pr list … --state closed …`
#   STUB_TREE/closed-prs: the JSON array a test writes there, or `[]` when the file is missing,
#   filtered through `jq -r` with the call's --jq expression when it has one.
# - `pr view <n> …` prints STUB_TREE/pr-view, the JSON object a test writes there.
# - `pr merge … --disable-auto`, `pr merge … --squash …` and `label create …` print nothing.
# - `pr create …` prints https://github.com/zgeoff/cloud/pull/200, the URL of the new pull request.
# - `pr edit <n> …` prints https://github.com/zgeoff/cloud/pull/<n>.
# - `pr create` and `pr edit` with `--body-file <file>` also copy that file to STUB_TREE/body, so a
#   test reads a body whose file its caller has removed.
# - A release that the tree lacks answers as gh 2.102.0 does: `release view` and
#   `release download` print "release not found" on stderr and exit 1; `api …/commits/<tag>` prints
#   the API's 422 body on stdout and "gh: No commit found for SHA: <tag> (HTTP 422)" on stderr, and
#   exits 1. Both were checked against the real gh 2.102.0 on 2026-10-13.
# - Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# The pull request calls were checked against the GitHub CLI manual (gh_pr_list, gh_pr_view,
# gh_pr_create, gh_pr_edit, gh_pr_merge, gh_label_create) on 2026-10-13, not against real calls,
# because those would open, label and merge pull requests. The manual leaves unsettled what
# `pr merge` and `label create` print off a terminal; the scripts read nothing from either.
create_stub_release_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
echo "${GH_TOKEN-unset}" >> "$STUB_TREE/tokens"
# release_dir <repo> <tag>: the tag's directory in the tree
release_dir() { echo "$STUB_TREE/releases/$1/${2//\//_}"; }
# read_flag <flag> <args…>: prints the value after the flag
read_flag() {
  local flag="$1"
  shift
  while [ "$#" -gt 1 ]; do
    if [ "$1" = "$flag" ]; then echo "$2"; return; fi
    shift
  done
}
repo="$(read_flag -R "$@")"
repo="${repo#zgeoff/}"
case "$*" in
  "release list -R zgeoff/"*" --json tagName --jq .[].tagName")
    if [ -f "$STUB_TREE/releases/$repo/tags" ]; then cat "$STUB_TREE/releases/$repo/tags"; fi
    ;;
  "release view "*" -R zgeoff/"*" --json body --jq .body")
    dir="$(release_dir "$repo" "$3")"
    if [ ! -f "$dir/notes.md" ]; then echo "release not found" >&2; exit 1; fi
    cat "$dir/notes.md"
    ;;
  "release download "*" -R zgeoff/"*" -p "*" -D "*)
    dir="$(release_dir "$repo" "$3")"
    asset="$(read_flag -p "$@")"
    if [ ! -f "$dir/$asset" ]; then echo "release not found" >&2; exit 1; fi
    mkdir -p "$(read_flag -D "$@")"
    cp "$dir/$asset" "$(read_flag -D "$@")/$asset"
    ;;
  "api repos/zgeoff/"*"/commits/"*" --jq .sha")
    path="${2#repos/zgeoff/}"
    tag="${path#*/commits/}"
    dir="$(release_dir "${path%%/*}" "$tag")"
    if [ ! -f "$dir/commit" ]; then
      printf '{"message":"No commit found for SHA: %s","documentation_url":"https://docs.github.com/rest/commits/commits#get-a-commit","status":"422"}' "$tag"
      echo "gh: No commit found for SHA: $tag (HTTP 422)" >&2
      exit 1
    fi
    cat "$dir/commit"
    ;;
  "pr list "*)
    file="$STUB_TREE/$(read_flag --state "$@")-prs"
    if [ -f "$file" ]; then prs="$(cat "$file")"; else prs='[]'; fi
    filter="$(read_flag --jq "$@")"
    if [ -n "$filter" ]; then jq -r "$filter" <<< "$prs"; else echo "$prs"; fi
    ;;
  "pr view "*) cat "$STUB_TREE/pr-view" ;;
  "pr merge "*" --disable-auto" | "pr merge "*" --squash "* | "label create "*) ;;
  "pr create "* | "pr edit "*)
    body="$(read_flag --body-file "$@")"
    if [ -n "$body" ]; then cp "$body" "$STUB_TREE/body"; fi
    if [ "$2" = create ]; then number=200; else number="$3"; fi
    echo "https://github.com/zgeoff/cloud/pull/$number"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
