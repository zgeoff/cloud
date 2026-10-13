#!/usr/bin/env bash
# Merge a release check pull request once it may merge on its own. The release bump merge workflow
# runs it each time a check workflow finishes on a release-check/<dependency> branch:
#
#   APP_LOGIN=app/<slug> MERGE_TOKEN=<token> bash scripts/merge-release-bump.sh <branch>
#
# gh reads the pull request with the token in GH_TOKEN; the merge uses MERGE_TOKEN, the release
# check app's token, so the push to main starts its workflows, which a GITHUB_TOKEN merge would
# not. It squash-merges the branch's open pull request, pinned to the head it checked, only when:
#
# - APP_LOGIN, the release check app, opened it from this repository, and the app's bot user
#   authored every commit on it, so a commit someone else pushed waits for a person;
# - it carries `auto-merge` and not `needs-review` (label-release-bump.sh's decision);
# - it changes only the files that its dependency's pin script writes;
# - every GitHub Actions check run on its head has passed or was skipped, `ci` among them, and
#   `nixos` among them when it changes `nixos/`, since a person's pull request skips the NixOS
#   checks and the ruleset requires only `ci`. Commit statuses from other apps, such as a review
#   bot's, do not count.
#
# Any other pull request, or one still waiting for a check, stays open: it prints why and exits 0.
# A branch that is not a release check branch, or that has no open pull request, prints why and
# exits 0 too.
set -euo pipefail
# comm needs the C collation that sort uses here
export LC_ALL=C

if [ "$#" -ne 1 ]; then
  echo "usage: merge-release-bump.sh <branch>" >&2
  exit 2
fi
branch="$1"
if [ -z "${APP_LOGIN:-}" ]; then
  echo "APP_LOGIN must name the release check app, as app/<slug>" >&2
  exit 2
fi
if [ -z "${MERGE_TOKEN:-}" ]; then
  echo "MERGE_TOKEN must hold the release check app's token" >&2
  exit 2
fi
repo=zgeoff/cloud

case "$branch" in
  release-check/atc)
    allowed='deploy/atc-gateway/versions.env
images/agent/Dockerfile
nixos/packages/atc.nix'
    ;;
  release-check/imp)
    allowed='images/agent/Dockerfile
nixos/flake.lock
nixos/flake.nix
nixos/hosts/geoffcloud/configuration.nix'
    ;;
  release-check/nixie)
    allowed='infra/Pulumi.prod.yaml'
    ;;
  *)
    echo "$branch is not a release check branch"
    exit 0
    ;;
esac

# this repository's own pull request: a fork's pull request can have the same branch name
number="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)][0].number // empty')"
if [ -z "$number" ]; then
  echo "$branch has no open pull request"
  exit 0
fi
pr="$(gh pr view "$number" --repo "$repo" \
  --json author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup)"

# hold <reason>: leaves the pull request open, saying why
hold() {
  echo "#$number stays open: $1"
  exit 0
}

author="$(jq -r .author.login <<< "$pr")"
if [ "$author" != "$APP_LOGIN" ] || [ "$(jq -r .isCrossRepository <<< "$pr")" != false ]; then
  hold "$APP_LOGIN did not open it from $repo"
fi
# a commit anyone else pushed to the branch is not a pin, whatever files it touches
bot="${APP_LOGIN#app/}[bot]"
others="$(jq -r --arg bot "$bot" '[.commits[] | select(any(.authors[]; .login != $bot)) | .oid[0:7]] | join(", ")' <<< "$pr")"
if [ -n "$others" ] || [ "$(jq '.commits | length' <<< "$pr")" = 0 ]; then
  hold "commits ${others:-none} are not all by $bot"
fi
labels="$(jq -r '.labels[].name' <<< "$pr")"
if ! grep -qx auto-merge <<< "$labels" || grep -qx needs-review <<< "$labels"; then
  hold "it is not labelled auto-merge without needs-review"
fi
other="$(jq -r '.files[].path' <<< "$pr" | sort | comm -23 - <(echo "$allowed") | paste -sd' ')"
if [ -n "$other" ]; then
  hold "it changes $other, which no pin of its dependency writes"
fi

runs="$(jq -c '[.statusCheckRollup[] | select(.__typename == "CheckRun")]' <<< "$pr")"
pending="$(jq -r '[.[] | select(.status != "COMPLETED") | .name] | join(", ")' <<< "$runs")"
if [ -n "$pending" ]; then
  hold "waiting for $pending"
fi
failed="$(jq -r '[.[] | select(.conclusion | IN("SUCCESS", "SKIPPED", "NEUTRAL") | not) | "\(.name) (\(.conclusion))"] | join(", ")' <<< "$runs")"
if [ -n "$failed" ]; then
  hold "$failed did not pass"
fi
required=(ci)
if jq -e 'any(.files[].path; startswith("nixos/"))' <<< "$pr" > /dev/null; then
  required+=(nixos)
fi
for name in "${required[@]}"; do
  if ! jq -e --arg name "$name" 'any(.[]; .name == $name and .conclusion == "SUCCESS")' <<< "$runs" > /dev/null; then
    hold "waiting for $name"
  fi
done

head="$(jq -r .headRefOid <<< "$pr")"
GH_TOKEN="$MERGE_TOKEN" gh pr merge "$number" --repo "$repo" --squash --match-head-commit "$head"
echo "merged #$number at $head"
