# shellcheck shell=sh
# Print, on one line, what an exec in imp-host sees of impd's root token: whether the file at $1
# (impz's token file, a link to impd's) exists, with its inode and modification time, and the
# start time of each impd process under the proc directory $2. It never prints the token.
# preview-image.sh runs it in imp-host on stdin after impd refuses an impz call with 401, so the
# unit's log shows whether impz read a token that impd did not load. The times are UTC, to the
# second.
token=$1
proc=$2

if [ -e "$token" ]; then
  modified=$(date -u -d "@$(stat -L -c %Y "$token")" +%Y-%m-%dT%H:%M:%SZ)
  facts="impz's token file: inode $(stat -L -c %i "$token"), modified $modified"
else
  facts="impz's token file: missing"
fi

# a process's start, in clock ticks after boot, is field 22 of its stat line; the fields after the
# command name, which may hold spaces, start at field 3
booted=$(awk '$1 == "btime" { print $2 }' "$proc/stat")
ticks=$(getconf CLK_TCK)
for dir in "$proc"/[0-9]*; do
  [ "$(cat "$dir/comm" 2> /dev/null)" = impd ] || continue
  # a process that exits between the reads leaves no stat line, or a short one, and is skipped
  line=$(cat "$dir/stat" 2> /dev/null) || continue
  # shellcheck disable=SC2086 # the fields split on purpose
  set -- ${line##*) }
  [ "$#" -ge 20 ] || continue
  shift 19
  started=$(date -u -d "@$((booted + $1 / ticks))" +%Y-%m-%dT%H:%M:%SZ)
  facts="$facts; impd ${dir##*/} started $started"
done
echo "$facts"
