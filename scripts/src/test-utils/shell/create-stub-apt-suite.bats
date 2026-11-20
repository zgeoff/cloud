#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for create-stub-apt-suite.sh: a suite gets a Packages index per component, main with an
# entry for each package that names its .deb's path, size and SHA256, a Release that lists each
# index with its SHA256 and size, and no signature file; a package's .deb carries its name,
# version and dependency; and one package and version is the same .deb byte for byte in two
# archives. The agent image suite feeds these suites to the real apt.
#
# Every case builds a .deb with dpkg-deb. Without it on PATH each case skips, so a branch can push
# from a host that has none; CI sets CI and has dpkg-deb, so there a missing dpkg-deb fails each
# case instead of skipping it.
#
#   bash scripts/run-bats.sh

setup_file() {
  load '../bats/setup'
}

setup() {
  load '../bats/setup'
  load 'create-stub-apt-suite.sh'
  if ! command -v dpkg-deb > /dev/null; then
    if [ -n "${CI:-}" ]; then
      fail "dpkg-deb is not on PATH, and CI runs every case"
    fi
    skip "dpkg-deb is not on PATH; CI runs its cases"
  fi
  # fixed, so the files the cases compare do not depend on the caller's umask
  umask 022
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

@test "it writes a packages entry for each package with its deb s path size and sha256" {
  local stub lib

  create_stub_apt_suite "$tree/archive" noble-updates cloud-stub=1.0-1/cloud-stub-lib \
    cloud-stub-lib=2.0-1

  stub="$tree/archive/pool/main/cloud-stub_1.0-1_all.deb"
  lib="$tree/archive/pool/main/cloud-stub-lib_2.0-1_all.deb"
  diff - "$tree/archive/dists/noble-updates/main/binary-amd64/Packages" << EOF
Package: cloud-stub
Version: 1.0-1
Architecture: all
Maintainer: stub <stub@example.invalid>
Depends: cloud-stub-lib
Description: stub package
Filename: pool/main/cloud-stub_1.0-1_all.deb
Size: $(stat -c %s "$stub")
SHA256: $(sha256sum "$stub" | cut -d' ' -f1)

Package: cloud-stub-lib
Version: 2.0-1
Architecture: all
Maintainer: stub <stub@example.invalid>
Description: stub package
Filename: pool/main/cloud-stub-lib_2.0-1_all.deb
Size: $(stat -c %s "$lib")
SHA256: $(sha256sum "$lib" | cut -d' ' -f1)

EOF
}

@test "it writes an empty packages index for each other component" {
  create_stub_apt_suite "$tree/archive" noble cloud-stub=1.0-1

  (cd "$tree/archive/dists/noble" && find . -type f | sort) > "$tree/files"
  diff - "$tree/files" << 'EOF'
./Release
./main/binary-amd64/Packages
./multiverse/binary-amd64/Packages
./restricted/binary-amd64/Packages
./universe/binary-amd64/Packages
EOF
  diff /dev/null "$tree/archive/dists/noble/universe/binary-amd64/Packages"
  diff /dev/null "$tree/archive/dists/noble/restricted/binary-amd64/Packages"
  diff /dev/null "$tree/archive/dists/noble/multiverse/binary-amd64/Packages"
}

@test "it writes a release that lists each index with its sha256 and size" {
  local dists

  create_stub_apt_suite "$tree/archive" noble-security cloud-stub=1.0-1

  dists="$tree/archive/dists/noble-security"
  diff - "$dists/Release" << EOF
Origin: Ubuntu
Suite: noble-security
Codename: noble
Date: Thu, 01 Jan 2026 00:00:00 UTC
Architectures: amd64
Components: main universe restricted multiverse
SHA256:
 $(sha256sum "$dists/main/binary-amd64/Packages" | cut -d' ' -f1) $(stat -c %s "$dists/main/binary-amd64/Packages") main/binary-amd64/Packages
 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 universe/binary-amd64/Packages
 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 restricted/binary-amd64/Packages
 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 multiverse/binary-amd64/Packages
EOF
  refute [ -e "$dists/InRelease" ]
  refute [ -L "$dists/InRelease" ]
  refute [ -e "$dists/Release.gpg" ]
  refute [ -L "$dists/Release.gpg" ]
}

@test "it builds a deb with the package s name version and dependency" {
  create_stub_apt_suite "$tree/archive" noble cloud-stub=1.0-1/cloud-stub-lib

  dpkg-deb -f "$tree/archive/pool/main/cloud-stub_1.0-1_all.deb" Package Version Architecture \
    Depends > "$tree/fields"
  diff - "$tree/fields" << 'EOF'
Package: cloud-stub
Version: 1.0-1
Architecture: all
Depends: cloud-stub-lib
EOF
}

@test "it builds one package and version as the same deb in two archives" {
  create_stub_apt_suite "$tree/live" noble-updates cloud-stub=1.0-1
  # a scenario delay, not a wait: the second build lands in another second of the wall clock, so
  # a .deb that took a timestamp from it would differ
  sleep 1
  create_stub_apt_suite "$tree/snapshot" noble-updates cloud-stub=1.0-1

  cmp "$tree/live/pool/main/cloud-stub_1.0-1_all.deb" \
    "$tree/snapshot/pool/main/cloud-stub_1.0-1_all.deb"
}
