# shellcheck shell=bash
# create_stub_bot_user_gh <bin>: writes <bin>/gh, a stand-in for the GitHub CLI call that
# set-release-bot-identity.sh makes to read a GitHub App bot user's id. It logs each call's argv as
# a JSON line to STUB_TREE/calls. A test states the users as files: STUB_TREE/users/<login> holds
# the user's id.
#
# - `api users/<login, with [ and ] as %5B and %5D> --jq .id` prints the id;
# - for a login the tree lacks it answers as gh 2.99.0 did on 2026-10-14 for a user GitHub does
#   not know: the API's 404 body on stdout, "gh: Not Found (HTTP 404)" on stderr, and exit 1;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_bot_user_gh() {
  local bin="$1"
  cat > "$bin/gh" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  "api users/"*" --jq .id")
    if [ "$#" != 4 ]; then echo "unexpected: $*" >&2; exit 97; fi
    login="${2#users/}"
    login="${login//%5B/[}"
    login="${login//%5D/]}"
    if [ ! -f "$STUB_TREE/users/$login" ]; then
      printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    cat "$STUB_TREE/users/$login"
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/gh"
}
