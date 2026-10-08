# shellcheck shell=bash
# create_stub_date <bin>: writes <bin>/date, a stand-in for date that wraps the real date
# and changes one thing: the instant it reads is STUB_NOW (any date -d string, such as
# 2026-10-08T12:34:56Z), never the clock. Formats, -u and every other argument go to the
# real date unchanged, run under the name date, so its output and errors are the real
# tool's. It logs each call's argv as a JSON line to STUB_TREE/calls. A call that names its
# own instant (-d, --date, -f, --file, -r, --reference, -s or --set), or a run without
# STUB_NOW, ends with exit 97 and "unexpected: <argv>" on stderr before the real date runs.
# The real date is the one on the fixed system path (/usr/local/bin, /usr/bin, /bin) when
# the stand-in is created.
create_stub_date() {
  local bin="$1" real_date
  real_date="$(PATH=/usr/local/bin:/usr/bin:/bin command -v date)"
  {
    printf '#!/usr/bin/env bash\nreal_date=%q\n' "$real_date"
    cat << 'STUB'
printf '%s\0' date "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ -z "${STUB_NOW:-}" ]; then echo "unexpected: $*" >&2; exit 97; fi
for arg in "$@"; do
  case "$arg" in
    -d* | --date* | -f* | --file* | -r* | --reference* | -s* | --set*) echo "unexpected: $*" >&2; exit 97 ;;
  esac
done
exec -a date "$real_date" -d "$STUB_NOW" "$@"
STUB
  } > "$bin/date"
  chmod +x "$bin/date"
}
