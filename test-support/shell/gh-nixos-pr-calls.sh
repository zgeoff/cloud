# shellcheck shell=bash
# The gh calls find-nixos-check-run.sh makes for the merged pull request of a commit, as the JSON
# argv lines that create-stub-gh.sh records and matches.
#
# gh_pulls_call <commit>: the call that lists the merged pull requests of main that produced
# <commit>, printing "<number> <head sha>" per pull request.
gh_pulls_call() {
  jq -cn --arg commit "$1" '["gh", "api", "-X", "GET", "repos/{owner}/{repo}/commits/\($commit)/pulls",
    "--jq", ".[] | select(.merged_at != null and .base.ref == \"main\" and .merge_commit_sha == \"\($commit)\") | \"\\(.number) \\(.head.sha)\""]'
}

# gh_check_runs_call <head>: the call that prints the URLs of the successful `nixos` check runs on
# <head>.
gh_check_runs_call() {
  jq -cn --arg head "$1" '["gh", "api", "-X", "GET", "repos/{owner}/{repo}/commits/\($head)/check-runs",
    "-f", "check_name=nixos",
    "--jq", ".check_runs[] | select(.conclusion == \"success\") | .html_url"]'
}
