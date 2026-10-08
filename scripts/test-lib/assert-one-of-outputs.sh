# shellcheck shell=bash
# assert_one_of_outputs <label> <stdout-file> <stderr-file> <status> <name> <stdout> <stderr> <status>...:
# passes silently when the actual stdout file, stderr file and exit status together match
# one of the supported outputs that follow, each given as a name (the tool version that
# prints it), its whole stdout file, its whole stderr file and its exit status. A stream
# expected empty is /dev/null. A stream that every supported version prints alike repeats
# the same file in each candidate, so a candidate binds both streams and the status, and
# one version's text never passes with another version's status.
#
# On no match it returns 1 and prints to stderr "<label>: matches none of the supported
# outputs", the actual stdout, stderr and status, then "not <name>: differs in <what>" per
# candidate, where <what> lists stdout, stderr and "exit <its status>" as they differ. Called without a whole number of candidates, it returns 2 with a usage line.
assert_one_of_outputs() {
  if [ "$#" -lt 8 ] || [ $((($# - 4) % 4)) != 0 ]; then
    echo "assert_one_of_outputs: want <label> <stdout> <stderr> <status>, then <name> <stdout> <stderr> <status> for each supported output" >&2
    return 2
  fi
  local label="$1" out="$2" err="$3" status="$4"
  shift 4
  local candidates=("$@")
  while [ "$#" -gt 0 ]; do
    if cmp -s "$2" "$out" && cmp -s "$3" "$err" && [ "$4" = "$status" ]; then
      return 0
    fi
    shift 4
  done
  {
    printf '%s: matches none of the supported outputs\n' "$label"
    printf -- '--- stdout\n'
    cat "$out" || true
    printf -- '--- stderr\n'
    cat "$err" || true
    printf -- '--- exit %s\n' "$status"
  } >&2
  set -- "${candidates[@]}"
  while [ "$#" -gt 0 ]; do
    local differs=""
    cmp -s "$2" "$out" || differs+=", stdout"
    cmp -s "$3" "$err" || differs+=", stderr"
    [ "$4" = "$status" ] || differs+=", exit $4"
    printf 'not %s: differs in %s\n' "$1" "${differs#, }" >&2
    shift 4
  done
  return 1
}
