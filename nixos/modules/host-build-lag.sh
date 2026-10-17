# shellcheck shell=bash
# Compare what geoffcloud runs with the latest green main build, and write how long each part has
# lagged behind it as node-exporter textfile metrics, atomically, to
# $TEXTFILE_DIR/host_build_lag.prom. The latest green build is the commit of the newest green
# scheduled or dispatched NixOS checks run on main, the runs that gate a host switch.
#
# - The system lags when the host's $CURRENT_SYSTEM resolves to a store path that no line of
#   $STATE_DIR/switches names, or when that line's commit is older than the green one and a file
#   the system is built from (nixos/ outside its checks, packages/topology/, packages/preview/)
#   changed between the two. scripts/switch-geoffcloud.sh appends "<commit> <store path>" to that
#   file before each activation.
# - imp lags when the version that `impz info` in the imp-host container prints is not the
#   imp-host image's tag in nixos/hosts/geoffcloud/configuration.nix at the green commit, or when
#   it prints none.
#
# A part that lags keeps "<what it runs> <since>" in $STATE_DIR/<part>-lag, so its lag counts from
# the first check that saw it run that, and a part that catches up drops the file. Inputs: REPO
# (owner/name), TEXTFILE_DIR, STATE_DIR, CURRENT_SYSTEM, GITHUB_API_URL and GITHUB_RAW_URL (GitHub's
# API and raw file hosts, read anonymously), and DOCKER, the docker that reaches imp-host. A failed
# GitHub read fails the run and leaves the metrics as they were, so their last check grows stale.
curl_args=(-fsS --max-time 30)
now=$(date +%s)

current=$(readlink -f "$CURRENT_SYSTEM")
running_commit=""
if [ -f "$STATE_DIR/switches" ]; then
  running_commit=$(while read -r commit path; do
    if [ "$path" = "$current" ]; then echo "$commit"; fi
  done < "$STATE_DIR/switches" | tail -n 1)
fi

runs=$(curl "${curl_args[@]}" \
  "$GITHUB_API_URL/repos/$REPO/actions/workflows/nixos-checks.yml/runs?branch=main&status=success&per_page=100")
green=$(jq -r '[.workflow_runs[] | select(.event == "schedule" or .event == "workflow_dispatch")][0].head_sha // empty' <<< "$runs")
if [ -z "$green" ]; then
  echo "host-build-lag: no green NixOS checks run on main" >&2
  exit 1
fi

if [ -z "$running_commit" ]; then
  system_lags=1
elif [ "$running_commit" = "$green" ]; then
  system_lags=0
else
  comparison=$(curl "${curl_args[@]}" "$GITHUB_API_URL/repos/$REPO/compare/$running_commit...$green")
  # GitHub lists at most 300 files, so a longer list may hide a system file
  system_lags=$(jq -r '
    if .status == "behind" or .status == "identical" then 0
    elif (.files | length) >= 300 then 1
    elif any(.files[] | .filename, (.previous_filename // empty);
      test("^(nixos/|packages/topology/|packages/preview/)") and (test("^nixos/checks/") | not)) then 1
    else 0 end' <<< "$comparison")
fi

config=$(curl "${curl_args[@]}" "$GITHUB_RAW_URL/$REPO/$green/nixos/hosts/geoffcloud/configuration.nix")
green_imp=$(sed -n 's|.*"ghcr\.io/zgeoff/imp-host:\([0-9][0-9.]*\)@sha256:.*|\1|p' <<< "$config")
if [ -z "$green_imp" ]; then
  echo "host-build-lag: no imp-host image in configuration.nix at $green" >&2
  exit 1
fi
running_imp=$("$DOCKER" exec imp-host impz info | sed -n 's/^version  *//p') || running_imp=""
if [ -n "$running_imp" ] && [ "$running_imp" = "$green_imp" ]; then
  imp_lags=0
else
  imp_lags=1
fi

# lag_seconds <part> <what it runs> <0 or 1>: prints the seconds since the first check that saw the
# part lag while it ran the same thing, 0 when it does not lag
lag_seconds() {
  local file="$STATE_DIR/$1-lag" running="$2" saved_running saved_since
  if [ "$3" = 0 ]; then
    rm -f "$file"
    echo 0
    return
  fi
  if [ -f "$file" ] && read -r saved_running saved_since < "$file" && [ "$saved_running" = "$running" ]; then
    echo $((now - saved_since))
    return
  fi
  printf '%s %s\n' "$running" "$now" > "$file"
  echo 0
}
system_lag=$(lag_seconds system "$current" "$system_lags")
imp_lag=$(lag_seconds imp "${running_imp:-none}" "$imp_lags")

tmp=$(mktemp -p "$TEXTFILE_DIR" .host_build_lag.XXXXXX)
cat > "$tmp" << EOF
# HELP host_build_lag_seconds How long the host has run an older part than the latest green main build, 0 when it runs that build's.
# TYPE host_build_lag_seconds gauge
host_build_lag_seconds{part="system"} $system_lag
host_build_lag_seconds{part="imp"} $imp_lag
# HELP host_build_lag_last_check_timestamp_seconds When the last check ran.
# TYPE host_build_lag_last_check_timestamp_seconds gauge
host_build_lag_last_check_timestamp_seconds $now
EOF
chmod 0644 "$tmp"
mv "$tmp" "$TEXTFILE_DIR/host_build_lag.prom"
