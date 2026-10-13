#!/usr/bin/env bash
# Open or update the pull request that bumps one dependency to a release, the way
# open-atc-pin-pr.sh does for the agent image's atc pin. Run it from the root of a zgeoff/cloud
# clone whose origin is zgeoff/cloud, with gh signed in to a token that may push to it, open pull
# requests and label them, and a git identity for the commit. scripts/bump-release.sh runs it:
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
# again. Unlike open-atc-pin-pr.sh it keeps no newer pin on the branch: the release check runs one
# job at a time and always pins the newest release, so a newer branch means a withdrawn release.
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
if [ -n "$lease" ]; then
  mapfile -t files < <(git diff --name-only origin/main HEAD)
  branch_files="$(git diff --name-only "$(git merge-base origin/main "$lease")" "$lease")"
  if [ "$(printf '%s\n' "${files[@]}")" = "$branch_files" ] &&
    git diff --quiet "$lease" HEAD -- "${files[@]}"; then
    same=true
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

prs="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,url,autoMergeRequest,labels)"
number="$(jq -r '.[0].number // empty' <<< "$prs")"
joined="$(IFS=,; echo "${labels[*]}")"

# sync_labels: adds the missing labels to the open pull request and removes the managed labels
# it no longer carries
sync_labels() {
  local current add remove
  current="$(jq -r '.[0].labels[].name' <<< "$prs")"
  add="$(comm -13 <(sort <<< "$current") <(printf '%s\n' "${labels[@]}" | sort) | paste -sd,)"
  remove="$(comm -23 <(sort <<< "$current") <(printf '%s\n' "${labels[@]}" | sort) |
    grep -xF -f <(cut -d' ' -f1 <<< "$managed") | paste -sd, || true)"
  local args=()
  if [ -n "$add" ]; then args+=(--add-label "$add"); fi
  if [ -n "$remove" ]; then args+=(--remove-label "$remove"); fi
  if [ "${#args[@]}" -gt 0 ]; then
    gh pr edit "$number" --repo "$repo" "${args[@]}"
  fi
}

ensure_labels
if [ "$same" = true ]; then
  if [ -n "$number" ]; then
    sync_labels > /dev/null
    echo "$(jq -r '.[0].url' <<< "$prs") already bumps $dependency to $version"
  else
    gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body" \
      --label "$joined"
  fi
  exit 0
fi

if [ -n "$number" ] && [ "$(jq -r '.[0].autoMergeRequest != null' <<< "$prs")" = true ]; then
  gh pr merge "$number" --repo "$repo" --disable-auto >&2
fi

git push -q --force-with-lease="refs/heads/$branch:$lease" origin "HEAD:refs/heads/$branch"

if [ -n "$number" ]; then
  sync_labels > /dev/null
  gh pr edit "$number" --repo "$repo" --title "$title" --body-file "$body"
else
  gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body" \
    --label "$joined"
fi
