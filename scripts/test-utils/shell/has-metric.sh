# shellcheck shell=bash
# has_metric <url> <pattern>: returns 0 when a line of the Prometheus metrics page at <url>/metrics
# matches the grep pattern, and 1 when none does or the page cannot be read, so wait_for can poll
# it while a server starts.
has_metric() {
  local page
  page="$(curl -q --noproxy '*' -fsS --max-time 5 "$1/metrics" 2> /dev/null)" || return 1
  grep -q -- "$2" <<< "$page"
}
