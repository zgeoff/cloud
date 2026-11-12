#!/usr/bin/env bash
# Runs as root on geoffcloud. install-atc-git-clone-token.ts sends this file on ssh's stdin:
#
#   ssh root@geoffcloud bash -s -- <dir> <owner/repo>
#
# It asks GitHub whether <dir>/git-clone-token reads <owner/repo>: a GET of the repo's API URL
# must answer 200. The token goes from the file into a curl header file that bash builds from a
# process substitution, so it enters no argv and never returns to the caller.
#
# A path that is not a readable regular file exits 120: absent or unchecked. A token that is empty
# or holds a byte that is not printable, non-space ASCII exits 121: bad. GitHub answering 401, 403
# or 404 exits 122: bad. Any other answer exits 1 and leaves the token unchecked.
set -euo pipefail
export LC_ALL=C

check_git_clone_token() {
  local file="$1/git-clone-token" repo="$2" size value code
  { test -f "$file" && test -r "$file"; } || exit 120
  size="$(wc -c < "$file")" || exit 120
  value="$(cat "$file" && printf x)" || exit 120
  value="${value%x}"
  # command substitution drops a NUL byte, so a file that held one reads shorter than its size
  test "${#value}" = "$size" || exit 121
  value="${value%$'\n'}"
  [[ "$value" =~ ^[[:graph:]]+$ ]] || exit 121
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 30 \
    -H @<(printf 'Authorization: Bearer %s\n' "$value") \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo")" || code="curl-failed"
  case "$code" in
    200) exit 0 ;;
    401 | 403 | 404) exit 122 ;;
    *)
      echo "GitHub answered $code" >&2
      exit 1
      ;;
  esac
}

check_git_clone_token "$@"
