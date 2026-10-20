# shellcheck shell=bash
# Write the CPU time of the host's cgroups, from cgroup v2's cpu.stat, as node-exporter textfile
# metrics, atomically, to $TEXTFILE_DIR/host_cgroup_cpu.prom. It reads the root cgroup and the two
# levels below it: the slices, such as system.slice, and the units in each, such as
# system.slice/k3s.service. The root's cpu.stat counts the whole host, so the root's time less its
# slices' is the work in the root cgroup itself: kernel threads, such as ZFS's, and interrupts.
# Inputs: TEXTFILE_DIR, and CGROUP_ROOT (default /sys/fs/cgroup), so
# nixos/checks/host-cgroup-cpu.nix can pass a tree of its own.
root="${CGROUP_ROOT:-/sys/fs/cgroup}"

tmp=$(mktemp -p "$TEXTFILE_DIR" .host_cgroup_cpu.XXXXXX)
trap 'rm -f "$tmp"' EXIT

shopt -s nullglob
stats=("$root/cpu.stat" "$root"/*/cpu.stat "$root"/*/*/cpu.stat)

# a cgroup can go between the glob and its read, so a file that no longer opens is skipped; only
# the root's must open, because its time is the host's
awk -v root="$root" '
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
    }
  }
' "${stats[@]}" > "$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$TEXTFILE_DIR/host_cgroup_cpu.prom"
