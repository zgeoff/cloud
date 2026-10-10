# shellcheck shell=bash
# create_stub_pin_pr_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI calls that
# open-atc-pin-pr.sh makes. It logs each call's argv as a JSON line to STUB_TREE/calls.
#
# - `pr list …` prints STUB_TREE/open-prs, the JSON array a test writes there, or `[]` when the
#   file is missing, as `gh pr list --json number,autoMergeRequest` prints it.
# - `pr merge … --disable-auto` prints nothing and exits 0.
# - `pr create …` prints https://github.com/zgeoff/cloud/pull/200, the URL of the new pull request.
# - `pr edit <n> …` prints https://github.com/zgeoff/cloud/pull/<n>.
# - Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Checked against the GitHub CLI manual (https://cli.github.com/manual/gh_pr_create,
# gh_pr_edit, gh_pr_merge, gh_pr_list) and the JSON gh 2.99.0 prints for
# `gh pr view --json number,autoMergeRequest`, on 2026-10-10, not against real calls, because those
# would open pull requests. The manual leaves unsettled what `pr merge --disable-auto` prints off a
# terminal; open-atc-pin-pr.sh sends that output to stderr and reads nothing from it.
create_stub_pin_pr_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "pr list "*)
    if [ -f "$STUB_TREE/open-prs" ]; then cat "$STUB_TREE/open-prs"; else echo '[]'; fi
    ;;
  "pr merge "*" --disable-auto"*) ;;
  "pr create "*) echo "https://github.com/zgeoff/cloud/pull/200" ;;
  "pr edit "*) echo "https://github.com/zgeoff/cloud/pull/$3" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
