#!/usr/bin/env bash
# Tests the agent image's build step, sbin/install-ubuntu-packages, with the real apt in the image
# that `bun run test:agent-image` builds, against a stand-in for the Ubuntu archive hosts. What
# this proves: a pin installs as the snapshot holds it after the live archive replaced it, an
# unpinned dependency resolves as the snapshot holds it, apt fetches a file from the live archive
# first and from the snapshot when the live archive fails, a list or a file that the snapshot fails
# to serve at first is fetched again after a wait, a list it keeps failing fails the step with
# apt's error, and the step leaves the image's own apt sources. It refuses a call without a
# package.
#
# Each case runs one container of the image with no network, whose /etc/hosts points
# archive.ubuntu.com, security.ubuntu.com and snapshot.ubuntu.com at a stand-in on its own
# loopback port 80, and whose PATH starts with create_stub_clock's pause, so a wait is recorded
# and returns at once. The stand-in serves unsigned suites over HTTP, so the case allows an
# unsigned repository in apt's config, and removes apt's `is not signed` warning for each suite
# from stderr before it compares it. It drops Docker's source, which the container cannot reach.
# apt's stdout is its progress, whose order and timings change between runs, so no case compares
# it. The suites are built on the host, so the host needs dpkg-deb; without it the suite fails
# before any case. One case alone:
#
#   CASE='replaced' bash images/agent/test-install-ubuntu-packages.sh
# shell-suite: agent-image
# shellcheck source-path=SCRIPTDIR/../..
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
umask 022
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=test-support/shell/run-cases.sh
source "$repo/test-support/shell/run-cases.sh"
# shellcheck source=test-support/shell/create-case-tree.sh
source "$repo/test-support/shell/create-case-tree.sh"
# shellcheck source=test-support/shell/assert-status.sh
source "$repo/test-support/shell/assert-status.sh"
# shellcheck source=test-support/shell/create-stub-apt-suite.sh
source "$repo/test-support/shell/create-stub-apt-suite.sh"

if ! command -v dpkg-deb > /dev/null; then
  echo "test-install-ubuntu-packages: dpkg-deb is not on PATH, and every case needs it" >&2
  exit 1
fi

it_installs_a_pin_that_the_live_archive_replaced_as_the_snapshot_holds_it() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates cloud-stub=1.0-2
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" dpkg-query -W cloud-stub > "$tree/installed"
  diff - "$tree/installed" <<< $'cloud-stub\t1.0-1'
  docker exec "$container" grep ' /ubuntu/[^d]*pool/' /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
200 snapshot.ubuntu.com /ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_resolves_an_unpinned_dependency_as_the_snapshot_holds_it_when_the_live_archive_has_a_newer_one() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates \
    cloud-stub=1.0-1/cloud-stub-lib cloud-stub-lib=2.0-2
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates \
    cloud-stub=1.0-1/cloud-stub-lib cloud-stub-lib=2.0-1
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" dpkg-query -W cloud-stub cloud-stub-lib > "$tree/installed"
  diff - "$tree/installed" << 'EOF'
cloud-stub	1.0-1
cloud-stub-lib	2.0-1
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_fetches_a_file_from_the_live_archive_first() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates cloud-stub=1.0-1
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" grep ' /ubuntu/[^d]*pool/' /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
200 archive.ubuntu.com /ubuntu/pool/main/cloud-stub_1.0-1_all.deb
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_fetches_a_file_from_the_snapshot_when_the_live_archive_fails_to_serve_it() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates cloud-stub=1.0-1
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  echo '503 all /ubuntu/pool/main/cloud-stub_1.0-1_all.deb' > "$tree/faults"
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" dpkg-query -W cloud-stub > "$tree/installed"
  diff - "$tree/installed" <<< $'cloud-stub\t1.0-1'
  docker exec "$container" grep ' /ubuntu/[^d]*pool/' /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
503 archive.ubuntu.com /ubuntu/pool/main/cloud-stub_1.0-1_all.deb
200 snapshot.ubuntu.com /ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_fetches_a_list_again_after_a_wait_when_the_snapshot_fails_to_serve_it_at_first() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  echo '503 2 /ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages' \
    > "$tree/faults"
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" dpkg-query -W cloud-stub > "$tree/installed"
  diff - "$tree/installed" <<< $'cloud-stub\t1.0-1'
  docker exec "$container" grep ' /ubuntu/20260101T000000Z/dists/noble-updates/main/' \
    /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
503 snapshot.ubuntu.com /ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages
503 snapshot.ubuntu.com /ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages
200 snapshot.ubuntu.com /ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages
EOF
  docker exec "$container" cat /run/clock/pauses > "$tree/pauses"
  diff - "$tree/pauses" << 'EOF'
10
20
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 10s
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 20s
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_fetches_a_file_again_after_a_wait_when_the_snapshot_fails_to_serve_it_at_first() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates cloud-stub=1.0-2
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  echo '503 1 /ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb' > "$tree/faults"
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" dpkg-query -W cloud-stub > "$tree/installed"
  diff - "$tree/installed" <<< $'cloud-stub\t1.0-1'
  docker exec "$container" grep ' /ubuntu/[^d]*pool/' /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" << 'EOF'
503 snapshot.ubuntu.com /ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb
200 snapshot.ubuntu.com /ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb
EOF
  docker exec "$container" cat /run/clock/pauses > "$tree/pauses"
  diff - "$tree/pauses" <<< 10
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/pool/main/cloud-stub_1.0-1_all.deb  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some files failed to download
install-ubuntu-packages: apt-get install exited 100, again in 10s
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_fails_with_apt_s_error_when_the_snapshot_keeps_failing_a_list() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble-updates
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble-updates cloud-stub=1.0-1
  echo '503 all /ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages' \
    > "$tree/faults"
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" grep -c ' /ubuntu/20260101T000000Z/dists/noble-updates/main/' \
    /run/stub/requests > "$tree/requests"
  diff - "$tree/requests" <<< 5
  docker exec "$container" cat /run/clock/pauses > "$tree/pauses"
  diff - "$tree/pauses" << 'EOF'
10
20
40
80
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 10s
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 20s
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 40s
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
install-ubuntu-packages: apt-get update exited 100, again in 80s
E: Failed to fetch http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/dists/noble-updates/main/binary-amd64/Packages  503  Service Unavailable [IP: 127.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
EOF
  assert_status 100 "$status"
}

it_leaves_the_image_s_own_apt_sources_and_no_pin() {
  local image="$1" status=0 suite
  create_case_tree 'docker rm -f "$container" > /dev/null 2>&1 || true'
  setup_test "$image"
  for suite in noble-updates noble-backports noble-security; do
    create_stub_apt_suite "$tree/archive/ubuntu" "$suite"
    create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" "$suite"
  done
  create_stub_apt_suite "$tree/archive/ubuntu" noble
  create_stub_apt_suite "$tree/archive/ubuntu/20260101T000000Z" noble cloud-stub=1.0-1
  docker exec "$container" bash -c 'source /repo/test-support/shell/start-stub-apt-archive.sh &&
    start_stub_apt_archive /run/stub 80 > /dev/null 2>&1'

  docker exec -e PATH=/run/clock:/usr/sbin:/usr/bin:/sbin:/bin "$container" \
    /repo/images/agent/sbin/install-ubuntu-packages \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ cloud-stub=1.0-1 \
    > /dev/null 2> "$tree/err" || status=$?

  docker exec "$container" sh -c \
    'cd /etc/apt && find sources.list.d preferences.d | sort && ls -A /var/lib/apt/lists' \
    > "$tree/after"
  diff - "$tree/after" << 'EOF'
preferences.d
sources.list.d
sources.list.d/ubuntu.sources
EOF
  sed '/^W: The repository .* is not signed\.$/d' "$tree/err" > "$tree/err.normal"
  diff - "$tree/err.normal" << 'EOF'
debconf: delaying package configuration, since apt-utils is not installed
EOF
  assert_status 0 "$status"
}

it_refuses_a_call_without_a_package() {
  local status=0
  create_case_tree

  env -i PATH=/usr/bin:/bin HOME="$tree" TMPDIR="$tree" sh "$here/sbin/install-ubuntu-packages" \
    http://snapshot.ubuntu.com/ubuntu/20260101T000000Z/ > "$tree/out" 2> "$tree/err" || status=$?

  diff /dev/null "$tree/out"
  diff - "$tree/err" << 'EOF'
usage: install-ubuntu-packages <snapshot URI> <package>=<version>...
EOF
  assert_status 2 "$status"
}

# Starts the case's container of <image>, named for the case tree so a run never meets another
# run's container, with the repo and the case tree mounted read-only, and the pause of
# create_stub_clock in /run/clock. The stand-in serves $tree/archive, with the faults in
# $tree/faults, from /run/stub; each case writes both, then starts it. apt's config allows the
# stand-in's unsigned suites, and Docker's source, which the container cannot reach, is gone. The
# image's own sources.list.d holds ubuntu.sources besides.
setup_test() {
  local image="$1"
  container="install-ubuntu-packages-$(basename "$tree")"
  mkdir -p "$tree/archive"
  : > "$tree/faults"
  docker run -d --name "$container" --network none \
    --add-host archive.ubuntu.com:127.0.0.1 --add-host security.ubuntu.com:127.0.0.1 \
    --add-host snapshot.ubuntu.com:127.0.0.1 \
    -v "$repo:/repo:ro" -v "$tree:/case:ro" --entrypoint sleep "$image" infinity > /dev/null
  docker exec "$container" bash -c '
    set -e
    source /repo/test-support/shell/create-stub-clock.sh
    mkdir /run/clock && create_stub_clock /run/clock
    rm /etc/apt/sources.list.d/docker.list
    mkdir /run/stub && ln -s /case/archive /run/stub/root && ln -s /case/faults /run/stub/faults
    printf "%s\n" "Acquire::AllowInsecureRepositories \"true\";" \
      "APT::Get::AllowUnauthenticated \"true\";" > /etc/apt/apt.conf.d/99-stub-archive'
}

image="${AGENT_IMAGE:-cloud/agent-image}"
run_cases "$image"
