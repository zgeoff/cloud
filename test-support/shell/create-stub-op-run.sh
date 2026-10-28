# shellcheck shell=bash
# create_stub_op_run <bin> <log>: writes <bin>/op, a stand-in for the 1Password CLI's
# `op run --env-file=<file> -- <command…>`. It logs each call's argv and working directory as
# {"cwd": <working directory>, "argv": ["op", …]}, one JSON line to <log>. When <file> exists,
# relative to the working directory, it runs <command…> with the caller's environment, its
# stdin, stdout and stderr, and exits with the command's status. It does not read <file>, so no
# reference in it resolves and none of its variables reach the command. Any other call, or a
# <file> that does not exist, ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Checked on 2026-10-20 against https://www.1password.dev/cli/reference/commands/run/ for op
# 2.40.0, the version deploy-prod.yml installs: the usage `op run -- <command>… [flags]`, the
# flag `--env-file=.env`, and the example `op run --env-file="./.env" -- printenv DB_PASSWORD`.
# The page does not say that op passes the command's exit status through, or which error op
# prints for a missing env file; the stand-in passes the status through and models no such error.
create_stub_op_run() {
  local bin="$1" log="$2"
  {
    echo '#!/usr/bin/env bash'
    printf 'log=%q\n' "$log"
    cat << 'STUB'
printf '%s\0' op "$@" | jq -cRs --arg cwd "$PWD" '{cwd: $cwd, argv: split("\u0000")[:-1]}' >> "$log"
if [ "$#" -ge 4 ] && [ "$1" = run ] && [[ "$2" == --env-file=?* ]] && [ "$3" = -- ] &&
  [ -f "${2#--env-file=}" ]; then
  shift 3
  exec "$@"
fi
echo "unexpected: $*" >&2
exit 97
STUB
  } > "$bin/op"
  chmod +x "$bin/op"
}
