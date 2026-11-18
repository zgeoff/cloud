# shellcheck shell=bash
# create_stub_scripted_command <bin> <name> [<log> <answers>]: writes <bin>/<name>, a command that
# answers each call from a script of answers, for a test of a wrapper that runs a command more
# than once. Call <n>, counting from 1, logs {"cwd": <working directory>, "argv": [<name>, …]} as one JSON line to
# STUB_LOG, prints the file <answers>/<n>.out on stdout and then <answers>/<n>.err on stderr, each
# only when it exists, and exits with the status in <answers>/<n>.status (default 0), where
# <answers> is STUB_ANSWERS. A call with neither an .out, an .err nor a .status file has no answer:
# it prints "unexpected: call <n>: <argv>" on stderr and exits 97. It keeps its count in
# <answers>/count. With STUB_LOG_ENV set to a space-separated list of variable names, each line
# also holds "env": {<name>: <value>} for each of those names that the call's environment sets,
# so a test reads which values reached the command. Given <log> and <answers>, the command logs to
# <log> and answers from <answers> in place of STUB_LOG and STUB_ANSWERS, so two scripted commands
# in one case keep their own logs and answers.
create_stub_scripted_command() {
  local bin="$1" name="$2" log="${3:-}" answers="${4:-}"
  {
    echo '#!/usr/bin/env bash'
    if [ -n "$log" ]; then printf 'STUB_LOG=%q\nSTUB_ANSWERS=%q\n' "$log" "$answers"; fi
    cat << 'STUB'
name="$(basename "$0")"
if [ -n "${STUB_LOG_ENV:-}" ]; then
  env_json="$(for variable in $STUB_LOG_ENV; do
    if [ -n "${!variable+set}" ]; then printf '%s\0%s\0' "$variable" "${!variable}"; fi
  done | jq -cRs 'split("\u0000")[:-1] | [range(0; length; 2) as $i | {(.[$i]): .[$i + 1]}] | add // {}')"
  printf '%s\0' "$name" "$@" | jq -cRs --arg cwd "$PWD" --argjson env "$env_json" '{cwd: $cwd, argv: split("\u0000")[:-1], env: $env}' >> "$STUB_LOG"
else
  printf '%s\0' "$name" "$@" | jq -cRs --arg cwd "$PWD" '{cwd: $cwd, argv: split("\u0000")[:-1]}' >> "$STUB_LOG"
fi
n=$(($(cat "$STUB_ANSWERS/count" 2> /dev/null || echo 0) + 1))
echo "$n" > "$STUB_ANSWERS/count"
answer="$STUB_ANSWERS/$n"
if [ ! -e "$answer.out" ] && [ ! -e "$answer.err" ] && [ ! -e "$answer.status" ]; then
  echo "unexpected: call $n: $*" >&2
  exit 97
fi
if [ -e "$answer.out" ]; then cat "$answer.out"; fi
if [ -e "$answer.err" ]; then cat "$answer.err" >&2; fi
exit "$(cat "$answer.status" 2> /dev/null || echo 0)"
STUB
  } > "$bin/$name"
  chmod +x "$bin/$name"
}
