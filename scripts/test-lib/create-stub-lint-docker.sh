# shellcheck shell=bash
# create_stub_lint_docker <bin>: writes <bin>/docker, a stand-in for the docker that lint.sh runs
# its tools in. It logs each call's argv as a JSON line to STUB_LOG, and answers:
#
# - a `run … nix … shell … -c <tool> <args…>`, where <tool> is shellcheck, shfmt, nixfmt,
#   deadnix, ruff or actionlint: exits 0 with no output, as each tool does on clean files, or,
#   when STUB_FAILING_TOOLS (a space-separated list) names the tool, prints "<tool>: findings" on
#   stdout and exits 1, as each of them does on findings;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Each tool's exit 1 on findings is its documented status, checked on 2026-10-14 against the
# versions that nixos/flake.lock's nixpkgs gives (shellcheck 0.11.0, shfmt 3.13.1 with -d, nixfmt
# 1.5.0 with --check, deadnix 1.3.2 with --fail, ruff 0.15.14 check and format --check,
# actionlint 1.7.12), with `docker run` passing the command's status through. The findings text
# is the stand-in's own; lint.sh passes each tool's output through unread.
create_stub_lint_docker() {
  local bin="$1"
  cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' docker "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
tool=""
if [ "${1:-}" = run ]; then
  seen_c=false
  for arg in "$@"; do
    if [ "$seen_c" = true ]; then
      tool="$arg"
      break
    fi
    [ "$arg" = -c ] && seen_c=true
  done
fi
case "$*:$tool" in
  "run "*" nix "*"shell "*:shellcheck | "run "*" nix "*"shell "*:shfmt | \
    "run "*" nix "*"shell "*:nixfmt | "run "*" nix "*"shell "*:deadnix | \
    "run "*" nix "*"shell "*:ruff | "run "*" nix "*"shell "*:actionlint)
    case " ${STUB_FAILING_TOOLS:-} " in
      *" $tool "*)
        echo "$tool: findings"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 97
    ;;
esac
STUB
  chmod +x "$bin/docker"
}
