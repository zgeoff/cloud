# shellcheck shell=bash
# create_stub_gh <bin> <log> <responses>: writes <bin>/gh, a stand-in for the GitHub CLI that
# answers each call from recorded responses. The absolute paths of <log> and <responses> go into
# the script when it is written, so a suite that shares one call log between several stand-ins
# passes that log here and keeps the calls in the order they ran.
#
# Each call appends its argv, "gh" first, as one JSON line to <log>. It then reads <responses>, a
# JSON Lines file, at call time, so a case may write or replace it after this setup. Each line
# records one response:
#
#   {"argv": [...], "stdout": "...", "stderr": "...", "exit": N, "env": {...},
#    "downloads": {...}, "stdout_file": "..."}
#
# - argv, the only required field, matches the call's argv, "gh" first, element for element and in
#   length. A null element matches any one argument, such as a temp path the caller makes;
# - env names variables that must hold exactly the given values in the call's environment, or the
#   line does not match;
# - downloads maps an asset name to a source file, which the stand-in copies into the directory
#   that follows -D in the argv, as `gh release download -D` does;
# - stdout and stderr print as given, then stdout_file's bytes print on stdout, and the call exits
#   with exit, 0 by default.
#
# The first line that matches answers. A call that no line matches, or a missing <responses>,
# ends with "unexpected: <argv>" on stderr and exit 97.
create_stub_gh() {
  local bin="$1" log responses
  log="$(realpath -m "$2")"
  responses="$(realpath -m "$3")"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'log=%q\nresponses=%q\n' "$log" "$responses"
    cat << 'STUB'
argv="$(printf '%s\0' gh "$@" | jq -cRs 'split("\u0000")[:-1]')"
printf '%s\n' "$argv" >> "$log"
response=
if [ -f "$responses" ]; then
  response="$(jq -cn --argjson argv "$argv" 'first(inputs | select(. as $r
    | ($r.argv | length) == ($argv | length)
    and all(range($argv | length); $r.argv[.] == null or $r.argv[.] == $argv[.])
    and all(($r.env // {}) | to_entries[]; $ENV[.key] == .value)))' "$responses")"
fi
if [ -z "$response" ]; then
  echo "unexpected: $*" >&2
  exit 97
fi
if jq -e 'has("downloads")' <<< "$response" > /dev/null; then
  dir=
  while [ "$#" -gt 1 ]; do
    if [ "$1" = -D ]; then dir="$2"; fi
    shift
  done
  if [ -z "$dir" ]; then
    echo "gh stand-in: the response has downloads but the call has no -D" >&2
    exit 97
  fi
  jq -j '.downloads | to_entries[] | "\(.key)\u0000\(.value)\u0000"' <<< "$response" |
    while IFS= read -r -d '' name && IFS= read -r -d '' source; do
      cp "$source" "$dir/$name"
    done
fi
jq -j '.stdout // ""' <<< "$response"
jq -j '.stderr // ""' <<< "$response" >&2
file="$(jq -r '.stdout_file // ""' <<< "$response")"
if [ -n "$file" ]; then cat "$file"; fi
exit "$(jq -r '.exit // 0' <<< "$response")"
STUB
  } > "$bin/gh"
  chmod +x "$bin/gh"
}
