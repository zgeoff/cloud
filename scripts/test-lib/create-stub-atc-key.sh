# shellcheck shell=bash
# create_stub_atc_key <bin>: writes <bin>/atc-key, a stand-in for atc-key. It logs each
# call's argv as a JSON line to STUB_TREE/calls; `atc-key zai` prints STUB_ZAI_KEY and a
# newline, and any other call ends with exit 97 and "unexpected: <argv>" on stderr.
create_stub_atc_key() {
  local bin="$1"
  cat > "$bin/atc-key" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' atc-key "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
case "$*" in
  zai) printf '%s\n' "$STUB_ZAI_KEY" ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/atc-key"
}
