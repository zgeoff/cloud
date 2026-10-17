# shellcheck shell=bash
# create_stub_scripted_command <bin> <name>: writes <bin>/<name>, a command that answers each call
# from a script of answers, for a test of a wrapper that runs a command more than once. Call <n>,
# counting from 1, logs {"cwd": <working directory>, "argv": [<name>, …]} as one JSON line to
# STUB_LOG, prints the file <answers>/<n>.out on stdout and then <answers>/<n>.err on stderr, each
# only when it exists, and exits with the status in <answers>/<n>.status (default 0), where
# <answers> is STUB_ANSWERS. A call with neither an .out, an .err nor a .status file has no answer:
# it prints "unexpected: call <n>: <argv>" on stderr and exits 97. It keeps its count in
# <answers>/count.
create_stub_scripted_command() {
  local bin="$1" name="$2"
  cat > "$bin/$name" << 'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s\0' "$name" "$@" | jq -cRs --arg cwd "$PWD" '{cwd: $cwd, argv: split("\u0000")[:-1]}' >> "$STUB_LOG"
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
  chmod +x "$bin/$name"
}
