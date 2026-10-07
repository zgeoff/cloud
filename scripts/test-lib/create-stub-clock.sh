# shellcheck shell=bash
# create_stub_clock <dir>: a fake clock and pause for wait_for (wait-for.sh), as the two
# commands <dir>/clock and <dir>/sleep. The clock prints the whole second in <dir>/now,
# which starts at 0. The pause records its argument as a line of <dir>/pauses, then
# advances <dir>/now by one second, so a test reads how often wait_for paused and steps
# past a deadline without waiting. Pass them as WAIT_FOR_CLOCK=<dir>/clock and
# WAIT_FOR_SLEEP=<dir>/sleep.
create_stub_clock() {
  local dir="$1"
  echo 0 > "$dir/now"
  cat > "$dir/clock" << STUB
#!/usr/bin/env bash
cat "$dir/now"
STUB
  cat > "$dir/sleep" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$dir/pauses"
echo "\$((\$(cat "$dir/now") + 1))" > "$dir/now"
STUB
  chmod +x "$dir/clock" "$dir/sleep"
}
