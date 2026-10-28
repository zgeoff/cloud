# shellcheck shell=bash
# create_stub_prod_apply_bun <bin>: writes <bin>/bun, a stand-in for the bun calls that the prod
# apply job's scripts make (check-out-deployed-revision.sh, preview-and-guard-prod.sh). It logs
# each call as one JSON line to STUB_LOG, {"cwd": <working directory>, "argv": ["bun", …]},
# because the directory a call runs in is part of what those scripts promise:
#
# - `install --frozen-lockfile`: prints nothing and exits STUB_INSTALL_EXIT (default 0). The real
#   install's progress lines are not modelled; no caller reads them;
# - `run sdk:build`: prints the script line on stderr, as bun does for a run without --silent;
#   with STUB_SDK_BUILD_EXIT set to a status other than 0, it also prints bun's
#   `error: script "sdk:build" exited with code <n>` on stderr and exits <n>;
# - `run --silent preview -- --refresh --json`: prints STUB_PLAN (nothing when unset or empty)
#   and exits STUB_PREVIEW_EXIT (default 0);
# - `run --silent ci:check-prod-plan <plan> <drift>`: prints STUB_GUARD (nothing when unset or
#   empty) and exits STUB_GUARD_EXIT (default 0);
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# What it assumes of bun, checked against bun 1.4.2 on 2026-10-14: `bun run <script>` echoes
# `$ <command>` on stderr, passes the script's output and exit status through, and on a failure
# adds `error: script "<name>" exited with code <n>` on stderr; --silent drops both lines.
create_stub_prod_apply_bun() {
  local bin="$1"
  cat > "$bin/bun" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' bun "$@" | jq -cRs --arg cwd "$PWD" '{cwd: $cwd, argv: split("\u0000")[:-1]}' >> "$STUB_LOG"
case "$#:$*" in
  "2:install --frozen-lockfile")
    exit "${STUB_INSTALL_EXIT:-0}"
    ;;
  "2:run sdk:build")
    echo '$ tsrs -p sdk/onidel/tsconfig.json && cp sdk/onidel/package.json sdk/onidel/bin/package.json' >&2
    status="${STUB_SDK_BUILD_EXIT:-0}"
    if [ "$status" != 0 ]; then echo "error: script \"sdk:build\" exited with code $status" >&2; fi
    exit "$status"
    ;;
  "6:run --silent preview -- --refresh --json")
    if [ -n "${STUB_PLAN:-}" ]; then printf '%s\n' "$STUB_PLAN"; fi
    exit "${STUB_PREVIEW_EXIT:-0}"
    ;;
  "5:run --silent ci:check-prod-plan "*)
    if [ -n "${STUB_GUARD:-}" ]; then printf '%s\n' "$STUB_GUARD"; fi
    exit "${STUB_GUARD_EXIT:-0}"
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 97
    ;;
esac
STUB
  chmod +x "$bin/bun"
}
