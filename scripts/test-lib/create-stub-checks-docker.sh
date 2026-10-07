# shellcheck shell=bash
# create_stub_checks_docker <bin>: writes <bin>/docker, a stand-in for the docker that
# test-nixos.sh runs nix in. It logs each call's argv as a JSON line to STUB_LOG:
#
# - a `run … eval --raw path:/src?dir=nixos#checks.x86_64-linux --apply …`: prints STUB_CHECKS
#   with no trailing newline, as `nix eval --raw` prints a string, or, when STUB_EVAL_ERROR is
#   set, prints it on stderr and exits 1, nix's exit for a failed evaluation;
# - a `run … build --no-link -L …`: copies the directory mounted at /src (its `<dir>:/src:ro`
#   argument) to STUB_BUILD_SAW, then, when STUB_BUILD_ERROR is set, prints it on stderr and
#   exits 1, nix's exit for a failed build;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_checks_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "run "*" eval --raw path:/src?dir=nixos#checks.x86_64-linux --apply "*)
    if [ -n "${STUB_EVAL_ERROR:-}" ]; then echo "$STUB_EVAL_ERROR" >&2; exit 1; fi
    printf '%s' "$STUB_CHECKS"
    ;;
  "run "*" build --no-link -L "*)
    src=""
    for arg in "$@"; do
      case "$arg" in *":/src:ro") src="${arg%:/src:ro}" ;; esac
    done
    cp -R "$src" "$STUB_BUILD_SAW"
    if [ -n "${STUB_BUILD_ERROR:-}" ]; then echo "$STUB_BUILD_ERROR" >&2; exit 1; fi
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/docker"
}
