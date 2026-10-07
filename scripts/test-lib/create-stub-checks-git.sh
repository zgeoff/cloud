# shellcheck shell=bash
# create_stub_checks_git <bin>: writes <bin>/git, a stand-in for the git that test-nixos.sh calls
# to find the repository and list its files. It logs each call's argv as a JSON line to STUB_LOG:
#
# - `rev-parse --show-toplevel`: STUB_TOPLEVEL and a newline, as git prints the toplevel;
# - `-C <STUB_TOPLEVEL> ls-files -z --cached --others --exclude-standard --deduplicate`: the
#   NUL-separated list in STUB_LS_FILES, unchanged;
# - any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_checks_git() {
  local bin="$1"
  cat > "$bin/git" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' git "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_LOG"
case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "$STUB_TOPLEVEL" ;;
  "-C $STUB_TOPLEVEL ls-files -z --cached --others --exclude-standard --deduplicate") cat "$STUB_LS_FILES" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/git"
}
