# shellcheck shell=bash
# normalize_restic_output: a filter from stdin to stdout that masks what restic prints
# that changes from run to run, so a suite can diff the rest exactly. A snapshot ID at the
# start of a table row or after "snapshot " becomes ID; a time from 2021 on (a new
# snapshot's wall clock) becomes NOW, while a seeded 2020 time keeps its value and loses
# only zero fractional seconds; a size in B, KiB or MiB becomes SIZE; a duration after
# " in " and a progress line's [m:ss] become T; a /tmp/tmp.* directory becomes /tmp/tmp.X.
normalize_restic_output() {
  sed -E \
    -e 's/^[0-9a-f]{8}  /ID  /' \
    -e 's/snapshot [0-9a-f]{8} /snapshot ID /' \
    -e 's/20(2[1-9]|[3-9][0-9])-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?/NOW/g' \
    -e 's/2020-([0-9]{2})-([0-9]{2}) ([0-9:]{8})\.0+ /2020-\1-\2 \3 /g' \
    -e 's/[0-9]+(\.[0-9]+)? (B|KiB|MiB)/SIZE/g' \
    -e 's/ in [0-9]+:[0-9]{2}/ in T/' \
    -e 's/^\[[0-9]+:[0-9]{2}\] /[T] /' \
    -e 's#/tmp/tmp\.[A-Za-z0-9]+#/tmp/tmp.X#'
}
