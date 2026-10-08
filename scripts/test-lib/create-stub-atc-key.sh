# shellcheck shell=bash
# create_stub_atc_key <bin>: writes <bin>/atc-key, a stand-in for atc-key. It logs each
# call's argv as a JSON line to STUB_TREE/calls; `atc-key zai` prints STUB_ZAI_KEY and a
# newline, and any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# atc-key is an unversioned bash script installed on the developer machine
# (~/.local/bin/atc-key, sha256 60a36fed46938acb416c10ba2d7586e8066ca1f30901d74a2db0fe9531076603);
# its source repository was not located. Checked on 2026-10-08 by reading that script and
# running it against a temporary store holding ZAI_API_KEY=fixture-zai-key: `atc-key zai`
# printed the key and a newline (printf '%s\n') and exited 0. Not modelled, so they fail
# closed here: its other providers (kimi, meta), its exit 1 with no store or no key, and its
# usage error with exit 2.
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
