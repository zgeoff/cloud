#!/usr/bin/env bash
# Open or update the pull request that bumps one dependency to a release. Run it from the root of a
# zgeoff/cloud clone whose origin is zgeoff/cloud, with gh signed in to a token that may push to
# it, open pull requests and label them, and a git identity for the commit.
# scripts/bump-release.sh runs it:
#
#   bash scripts/open-release-bump-pr.sh <dependency> <version> <body file> <labels file> \
#     <pin command>...
#
# It builds the release-check/<dependency> branch from origin's main with the pin command, commits
# it as "chore(<dependency>): bump <dependency> to <version>", and force-pushes it with a lease on
# the branch it read. One pull request per dependency carries the newest release: a later release
# replaces the branch, the title, the body and the labels, and first turns off that pull request's
# auto-merge, so the new pin waits for its own checks. The labels file holds one label per line,
# from label-release-bump.sh; each label is created or updated in the repository before use.
#
# It stops, with no push and no pull request, when main already pins the release, which the pin
# command reports. It pushes nothing when the branch already changes the same files to the same
# contents as a fresh pin of main; it then opens the pull request if none is open, or brings the
# open one's labels up to date, so a run that failed after its push is repaired by running it
# again. A person holds a bump by labelling it needs-review, or rejects it by closing it. Both
# last while the bump targets the same release, which the branch's commit title names, even when
# main changes another pin in a file the bump changes: the script rebuilds the open pull request's
# branch and keeps its needs-review, with no auto-merge beside it, and leaves a closed pull
# request for the branch's head closed, with no push, until a later release or until the branch
# is deleted. Pull requests from forks never count. It keeps no newer pin on the branch: the
# release check runs one job at a time and always pins the newest release, so a newer branch means
# a withdrawn release.
set -euo pipefail
# comm needs the C collation that sort uses here
export LC_ALL=C

if [ "$#" -lt 5 ]; then
  echo "usage: open-release-bump-pr.sh <dependency> <version> <body file> <labels file> <pin command>..." >&2
  exit 2
fi
dependency="$1"
version="$2"
body="$3"
labels_file="$4"
shift 4
repo=zgeoff/cloud
branch="release-check/$dependency"
title="chore($dependency): bump $dependency to $version"
# every label this script manages, with its color and description
managed='update:major d73a4a a major release
update:minor fbca04 a minor release
update:patch 0e8a16 a patch release
migrations d73a4a the release adds database migrations
sandbox-images-changed fbca04 the release changes nixie'"'"'s sandbox images
auto-merge 0e8a16 merges on its own once its checks pass
needs-review d73a4a waits for a review before it merges'

mapfile -t labels < <(grep -v '^$' "$labels_file")
for label in "${labels[@]}"; do
  if ! grep -q "^$label " <<< "$managed"; then
    echo "not a release bump label: '$label'" >&2
    exit 2
  fi
done

# a change another pin left in the tree would ride along in this commit, under this title
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "the working tree has uncommitted changes; commit or discard them first" >&2
  exit 1
fi
git fetch -q origin main
git checkout -q -B "$branch" origin/main
"$@"
if git diff --quiet; then
  exit 0
fi
git commit -qam "$title"

# the branch's current commit, for the push's lease (empty when the branch does not exist)
lease=""
status=0
git ls-remote --exit-code --heads origin "refs/heads/$branch" > /dev/null || status=$?
case "$status" in
  0)
    git fetch -q origin "refs/heads/$branch"
    lease="$(git rev-parse FETCH_HEAD)"
    ;;
  2) ;;
  *) exit "$status" ;;
esac

# the branch needs no push when it changes the same files as this commit, to the same contents
same=false
# the branch already bumps to this release when its commit has this title, even when main has
# since changed another pin in a file the bump changes; a person's hold and rejection follow it
same_release=false
if [ -n "$lease" ]; then
  mapfile -t files < <(git diff --name-only origin/main HEAD)
  branch_files="$(git diff --name-only "$(git merge-base origin/main "$lease")" "$lease")"
  if [ "$(printf '%s\n' "${files[@]}")" = "$branch_files" ] &&
    git diff --quiet "$lease" HEAD -- "${files[@]}"; then
    same=true
    same_release=true
  elif [ "$(git log -1 --format=%s "$lease")" = "$title" ]; then
    same_release=true
  fi
fi

# ensure_labels: creates or updates each of the pull request's labels in the repository
ensure_labels() {
  local label line
  for label in "${labels[@]}"; do
    line="$(grep "^$label " <<< "$managed")"
    read -r _ color description <<< "$line"
    gh label create "$label" --repo "$repo" --force --color "$color" --description "$description" > /dev/null
  done
}

# this repository's own pull requests only: a fork's pull request can have the same branch name
prs="$(gh pr list --repo "$repo" --head "$branch" --state open \
  --json number,url,autoMergeRequest,labels,isCrossRepository |
  jq -c '[.[] | select(.isCrossRepository | not)]')"
number="$(jq -r '.[0].number // empty' <<< "$prs")"
joined="$(
  IFS=,
  echo "${labels[*]}"
)"

# sync_labels [keep-hold]: adds the missing labels to the open pull request and removes the
# managed labels it no longer carries. With keep-hold, a needs-review label stays, and auto-merge
# is not added beside it, so a person's hold on the pull request lasts.
sync_labels() {
  local current wanted add remove
  current="$(jq -r '.[0].labels[].name' <<< "$prs")"
  wanted="$(printf '%s\n' "${labels[@]}")"
  if [ "${1:-}" = keep-hold ] && grep -qx needs-review <<< "$current"; then
    wanted="$(
      grep -vx auto-merge <<< "$wanted"
      echo needs-review
    )"
  fi
  add="$(comm -13 <(sort <<< "$current") <(sort -u <<< "$wanted") | paste -sd,)"
  remove="$(comm -23 <(sort <<< "$current") <(sort -u <<< "$wanted") |
    grep -xF -f <(cut -d' ' -f1 <<< "$managed") | paste -sd, || true)"
  local args=()
  if [ -n "$add" ]; then args+=(--add-label "$add"); fi
  if [ -n "$remove" ]; then args+=(--remove-label "$remove"); fi
  if [ "${#args[@]}" -gt 0 ]; then
    gh pr edit "$number" --repo "$repo" "${args[@]}"
  fi
}

ensure_labels
# a person who closed the pull request for the branch's head rejected its release: keep it closed
# while the bump targets that release, with no push, so the branch keeps that head
if [ -z "$number" ] && [ "$same_release" = true ]; then
  closed="$(gh pr list --repo "$repo" --head "$branch" --state closed \
    --json number,headRefOid,isCrossRepository \
    --jq "[.[] | select((.isCrossRepository | not) and .headRefOid == \"$lease\")][0].number // empty")"
  if [ -n "$closed" ]; then
    echo "#$closed was closed with this bump; delete $branch to open it again"
    exit 0
  fi
fi
if [ "$same" = true ]; then
  if [ -n "$number" ]; then
    sync_labels keep-hold > /dev/null
    echo "$(jq -r '.[0].url' <<< "$prs") already bumps $dependency to $version"
    exit 0
  fi
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body" \
    --label "$joined"
  exit 0
fi

# the open pull request loses auto-merge before the push, so a new head never merges under the
# labels of the release it replaces, even when a later step fails
if [ -n "$number" ]; then
  if [ "$(jq -r '.[0].autoMergeRequest != null' <<< "$prs")" = true ]; then
    gh pr merge "$number" --repo "$repo" --disable-auto >&2
  fi
  if jq -e '.[0].labels | any(.name == "auto-merge")' <<< "$prs" > /dev/null; then
    gh pr edit "$number" --repo "$repo" --remove-label auto-merge > /dev/null
    prs="$(jq -c '.[0].labels |= map(select(.name != "auto-merge"))' <<< "$prs")"
  fi
fi

git push -q --force-with-lease="refs/heads/$branch:$lease" origin "HEAD:refs/heads/$branch"

if [ -n "$number" ]; then
  if [ "$same_release" = true ]; then
    sync_labels keep-hold > /dev/null
  else
    sync_labels > /dev/null
  fi
  gh pr edit "$number" --repo "$repo" --title "$title" --body-file "$body"
else
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body" \
    --label "$joined"
fi
