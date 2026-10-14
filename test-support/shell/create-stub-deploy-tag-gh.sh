# shellcheck shell=bash
# create_stub_deploy_tag_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI as
# move-deployed-prod.sh calls it, `gh api --method PATCH
# repos/<owner>/<repo>/git/refs/tags/deployed/prod -f sha=<sha> -F force=false`. It logs each
# call's argv as a JSON line to STUB_TREE/calls. It answers as GitHub's "Update a reference"
# endpoint does through gh api:
#
# - by default, a move GitHub takes: the updated reference's JSON on stdout, exit 0;
# - with STUB_TAG_MOVE=refused, a move that is not a fast forward: GitHub's 422 body on stdout,
#   `gh: Update is not a fast forward (HTTP 422)` on stderr, exit 1.
#
# Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Not checked against GitHub or a real gh (no test reaches GitHub). Checked on 2026-10-14
# against https://docs.github.com/en/rest/git/refs#update-a-reference (200 with the reference
# object, 422 "Validation failed, or the endpoint has been spammed") and
# https://cli.github.com/manual/gh_api (the response body goes to stdout; an HTTP error exits
# 1). The docs do not settle the 422 message for a move that is not a fast forward, nor gh's
# exact stderr line; the text here follows what GitHub's API answers in practice and needs a
# real sample.
create_stub_deploy_tag_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" = 8 ] && [ "$1 $2 $3" = "api --method PATCH" ] &&
  [[ "$4" =~ ^repos/[^/]+/[^/]+/git/refs/tags/deployed/prod$ ]] && [ "$5" = -f ] &&
  [ "$7 $8" = "-F force=false" ] && [[ "$6" =~ ^sha=([0-9a-f]{40})$ ]]; then
  sha="${BASH_REMATCH[1]}"
  repo="${4#repos/}"
  repo="${repo%/git/refs/tags/deployed/prod}"
  if [ "${STUB_TAG_MOVE:-}" = refused ]; then
    echo '{"message":"Update is not a fast forward","documentation_url":"https://docs.github.com/rest/git/refs#update-a-reference","status":"422"}'
    echo "gh: Update is not a fast forward (HTTP 422)" >&2
    exit 1
  fi
  jq -cn --arg repo "$repo" --arg sha "$sha" '{
    ref: "refs/tags/deployed/prod",
    url: "https://api.github.com/repos/\($repo)/git/refs/tags/deployed/prod",
    object: {sha: $sha, type: "commit", url: "https://api.github.com/repos/\($repo)/git/commits/\($sha)"}
  }'
  exit 0
fi
echo "unexpected: $*" >&2
exit 97
STUB
  chmod +x "$bin/gh"
}
