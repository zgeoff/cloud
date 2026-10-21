# shellcheck shell=bash
# Write the CPU time of the host's cgroups, from cgroup v2's cpu.stat, and the host's kernel time
# as node-exporter textfile metrics, atomically, to $TEXTFILE_DIR/host_cgroup_cpu.prom. It reads
# the root cgroup and the two levels below it: the slices, such as system.slice, and the units in
# each, such as system.slice/k3s.service.
# The kernel time is the CPU time that was neither idle, iowait nor stolen, less the top-level
# cgroups' usage: kernel threads in the root cgroup, such as ZFS's, and interrupts. It never comes
# from the root's cpu.stat, because the kernel samples the root's time at each tick, while a child's
# usage is the scheduler's exact runtime, so the root less its children can read below zero.
# Inputs: TEXTFILE_DIR, and CGROUP_ROOT (default /sys/fs/cgroup) and PROC_ROOT (default /proc), so
# nixos/checks/host-cgroup-cpu.nix can pass trees of its own.
root="${CGROUP_ROOT:-/sys/fs/cgroup}"
proc="${PROC_ROOT:-/proc}"
out="$TEXTFILE_DIR/host_cgroup_cpu.prom"
last_written=$(stat -c %Y "$out" 2> /dev/null || echo 0)

tmp=$(mktemp -p "$TEXTFILE_DIR" .host_cgroup_cpu.XXXXXX)
trap 'rm -f "$tmp"' EXIT

shopt -s nullglob
stats=("$root/cpu.stat" "$root"/*/cpu.stat "$root"/*/*/cpu.stat)
top_level=("$root"/*/)
top_level_ids=""
if ((${#top_level[@]} > 0)); then
  top_level_ids=$(stat -c '%i %n' "${top_level[@]}" 2> /dev/null || true)
fi

# a cgroup can go between the glob and its read, so a file that no longer opens is skipped; only
# the root's must open, because its time is the host's
TOP_LEVEL_IDS="$top_level_ids" awk -v root="$root" -v proc="$proc" -v ticks_per_second="$(getconf CLK_TCK)" \
  -v last="$out" -v last_written="$last_written" '
  BEGIN {
    print "# HELP host_cgroup_cpu_seconds_total CPU time of the tasks in a cgroup and its descendants, from cpu.stat. The root cgroup, /, counts the whole host."
    print "# TYPE host_cgroup_cpu_seconds_total counter"
    for (i = 1; i < ARGC; i++) {
      path = ARGV[i]
      user = ""
      sys = ""
      while ((getline line < path) > 0) {
        split(line, field, " ")
        if (field[1] == "user_usec") user = field[2]
        if (field[1] == "system_usec") sys = field[2]
      }
      close(path)
      if (user == "" || sys == "") {
        if (i == 1) {
          print "host-cgroup-cpu: no user_usec and system_usec in " path > "/dev/stderr"
          exit 1
        }
        continue
      }
      cgroup = substr(path, length(root) + 1)
      sub(/\/cpu\.stat$/, "", cgroup)
      if (cgroup == "") cgroup = "/"
      # systemd escapes a unit name with backslashes, such as system-serial\x2dgetty.slice
      gsub(/\\/, "\\\\", cgroup)
      gsub(/"/, "\\\"", cgroup)
      printf "host_cgroup_cpu_seconds_total{cgroup=\"%s\",mode=\"user\"} %.6f\n", cgroup, user / 1000000
      printf "host_cgroup_cpu_seconds_total{cgroup=\"%s\",mode=\"system\"} %.6f\n", cgroup, sys / 1000000
      if (cgroup ~ /^\/[^\/]+$/) {
        usage[cgroup] = sprintf("%.6f", user / 1000000) + sprintf("%.6f", sys / 1000000)
        top_level_order[++top_level_count] = cgroup
        top_level_usage += usage[cgroup]
      }
    }

    if ((getline line < (proc "/uptime")) > 0) {
      split(line, field, " ")
      uptime = field[1]
    }
    while ((getline line < (proc "/stat")) > 0) {
      split(line, field, " ")
      if (field[1] ~ /^cpu[0-9]+$/) cpus++
      # idle, iowait and steal, which the kernel measures rather than samples
      if (field[1] == "cpu") not_running = field[5] + field[6] + field[9]
      if (field[1] == "btime") booted = field[2]
    }
    if (uptime == "" || cpus == 0 || not_running == "" || booted == "") {
      print "host-cgroup-cpu: no uptime, CPUs and btime in " proc > "/dev/stderr"
      exit 1
    }

    # cgroup v2 gives each cgroup an inode that the kernel never reuses within a boot, so a cgroup
    # made again under the same name reads as another cgroup
    count = split(ENVIRON["TOP_LEVEL_IDS"], entry, "\n")
    for (j = 1; j <= count; j++) {
      space = index(entry[j], " ")
      if (space == 0) continue
      cgroup = substr(entry[j], space + 1 + length(root))
      sub(/\/$/, "", cgroup)
      gsub(/\\/, "\\\\", cgroup)
      gsub(/"/, "\\\"", cgroup)
      id[cgroup] = substr(entry[j], 1, space - 1)
    }

    removed = 0
    last_kernel = 0
    if (last_written >= booted) {
      while ((getline line < last) > 0) {
        split(line, field, " ")
        if (field[1] == "host_kernel_cpu_seconds_total") last_kernel = field[2] + 0
        if (field[1] == "#" && field[2] == "host_cgroup_cpu_removed_seconds") removed = field[3] + 0
        if (field[1] == "#" && field[2] == "host_cgroup_cpu_id") last_id[field[3]] = field[4]
        if (index(field[1], "host_cgroup_cpu_seconds_total{cgroup=\"") == 1) {
          cgroup = substr(field[1], length("host_cgroup_cpu_seconds_total{cgroup=\"") + 1)
          cgroup = substr(cgroup, 1, index(cgroup, "\",mode=\"") - 1)
          if (cgroup ~ /^\/[^\/]+$/) last_usage[cgroup] += field[2]
        }
      }
    }
    # a top-level cgroup can go, such as user.slice after its last session, and its time goes with
    # it, so the last time of each one gone or made again since the last write stays subtracted
    for (cgroup in last_usage) {
      if (!(cgroup in usage)) gone = 1
      else if ((cgroup in last_id) && (cgroup in id)) gone = last_id[cgroup] != id[cgroup]
      else gone = usage[cgroup] < last_usage[cgroup]
      if (gone) removed += last_usage[cgroup]
    }
    kernel = cpus * uptime - not_running / ticks_per_second - top_level_usage - removed

    # iowait can read lower than at the last read, and each column rounds to a tick, so the
    # difference can dip; a counter that drops reads as a reset, so the last count from this boot
    # holds until the reading passes it
    if (last_kernel > kernel) kernel = last_kernel

    print "# HELP host_kernel_cpu_seconds_total CPU time that was neither idle, iowait nor stolen, less the usage of the top-level cgroups: kernel threads in the root cgroup and interrupts."
    print "# TYPE host_kernel_cpu_seconds_total counter"
    printf "host_kernel_cpu_seconds_total %.6f\n", kernel
    printf "# host_cgroup_cpu_removed_seconds %.6f\n", removed
    for (j = 1; j <= top_level_count; j++) {
      cgroup = top_level_order[j]
      if (cgroup in id) printf "# host_cgroup_cpu_id %s %s\n", cgroup, id[cgroup]
    }
  }
' "${stats[@]}" > "$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$out"
