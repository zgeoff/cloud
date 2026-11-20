#!/usr/bin/env bats
# bats file_tags=suite:scripts
# Test for check-impd-image-dirs.sh: it passes when each impd image record has its build folder,
# for each of impd's three digest forms, and when impd holds no image, and fails naming each record
# whose folder holds no rootfs.ext4 or whose digest names no folder. The records take the shape of
# impd's ImageSchema, with invented ids and digests in the forms that zgeoff/impz's guest-build.ts
# (`imp-build-<hex>`) and template-service.ts (`imp-<uuid>`) write at v4.2.4 and v5.0.0. It stops with podman's exit code when imp-host is gone. ssh is
# the NixOS host stand-in from scripts/src/test-utils/shell, which answers the image listing and the folder
# listing from the case's STUB_IMPD_IMAGES and STUB_IMPD_IMAGE_DIRS. Each case runs the script
# under `env -i` and compares its stdout, stderr and ssh call log.
#
#   bash scripts/run-bats.sh

setup_file() {
  load 'src/test-utils/bats/setup'
}

setup() {
  load 'src/test-utils/bats/setup'
  load 'src/test-utils/shell/create-stub-nixos-ssh.sh'
  load 'src/test-utils/shell/create-stub-remote-tools.sh'
  load 'src/test-utils/shell/require-remote-tool-stubs.sh'
  # fixed, so the files the cases write do not depend on the caller's umask
  umask 022
  script="$BATS_TEST_DIRNAME/check-impd-image-dirs.sh"
  # the two remote commands the check runs, as the call log records them
  list_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host impz image ls --json"]'
  # shellcheck disable=SC2016 # $d is the remote shell's loop variable, as the call log records it
  dirs_call='["ssh","-o","BatchMode=yes","root@geoffcloud","podman exec imp-host sh -c '"'"'cd /var/lib/imp/images && for d in *; do if [ -f \"$d/rootfs.ext4\" ]; then echo \"$d\"; fi; done'"'"'"]'
  tree="$BATS_TEST_TMPDIR"
}

teardown() {
  stop_timeout_watchdog
}

# setup_test <tree>: the home and temp folders the cases run with, the ssh stand-in, fail-closed
# stand-ins for the other remote tools, and a guard that ends the case unless each resolves to a
# stand-in
setup_test() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/home" "$tree/tmp"
  : > "$tree/calls"
  create_stub_nixos_ssh "$tree/bin"
  create_stub_remote_tools "$tree/bin" "$tree/calls" scp sftp rsync tailscale
  require_remote_tool_stubs "$tree/bin"
}

@test "it passes when each image record has its build folder" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_1","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4","digest":"sha256:5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592","source":"oci","createdAt":"2026-10-20T08:00:00.000Z","sizeBytes":1048576,"pinned":true},{"id":"img_2","name":"base","ref":"ubuntu:24.04","digest":"sha256:7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7","source":"oci","createdAt":"2026-10-19T08:00:00.000Z","sizeBytes":2097152,"pinned":false}]' \
    STUB_IMPD_IMAGE_DIRS='7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7 5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592' \
    bash "$script" root@geoffcloud

  assert_output "== impd's images have their build folders: pv-base, base"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$dirs_call
EOF
}

@test "it passes a builder image whose folder holds its imp build digest" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_3","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4@sha256:2c624232cdd221771294dfbb310aca000a0df6ac8b66b696d90ef06fdefb64a3","digest":"imp-build-c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2","source":"oci","createdAt":"2026-10-21T08:00:00.000Z","sizeBytes":3145728,"pinned":true}]' \
    STUB_IMPD_IMAGE_DIRS='imp-build-c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2' \
    bash "$script" root@geoffcloud

  assert_output "== impd's images have their build folders: pv-base"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$dirs_call
EOF
}

@test "it passes a template whose folder holds its imp uuid digest" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_4","name":"warm-node","ref":"warm-node","digest":"imp-0199f3a2-7c41-7d8e-9b2a-4f6e1c0d3b5a","source":"imp","createdAt":"2026-10-22T08:00:00.000Z","sizeBytes":4194304,"pinned":false}]' \
    STUB_IMPD_IMAGE_DIRS='imp-0199f3a2-7c41-7d8e-9b2a-4f6e1c0d3b5a' \
    bash "$script" root@geoffcloud

  assert_output "== impd's images have their build folders: warm-node"
  refute_stderr

  run -0 diff - "$tree/calls" << EOF
$list_call
$dirs_call
EOF
}

@test "it fails naming a builder image whose imp build folder is gone" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_3","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4@sha256:2c624232cdd221771294dfbb310aca000a0df6ac8b66b696d90ef06fdefb64a3","digest":"imp-build-c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2","source":"oci","createdAt":"2026-10-21T08:00:00.000Z","sizeBytes":3145728,"pinned":true}]' \
    STUB_IMPD_IMAGE_DIRS='imp-build-8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
impd's image pv-base points at /var/lib/imp/images/imp-build-c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2, which holds no rootfs.ext4
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF
}

@test "it fails naming a template whose imp uuid folder is gone" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_4","name":"warm-node","ref":"warm-node","digest":"imp-0199f3a2-7c41-7d8e-9b2a-4f6e1c0d3b5a","source":"imp","createdAt":"2026-10-22T08:00:00.000Z","sizeBytes":4194304,"pinned":false}]' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
impd's image warm-node points at /var/lib/imp/images/imp-0199f3a2-7c41-7d8e-9b2a-4f6e1c0d3b5a, which holds no rootfs.ext4
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF
}

@test "it passes when impd holds no image" {
  setup_test "$tree"

  run -0 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[]' bash "$script" root@geoffcloud

  assert_output '== impd holds no image'
  refute_stderr

  run -0 diff - "$tree/calls" <<< "$list_call"
}

@test "it fails naming the record whose build folder is gone" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_1","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4","digest":"sha256:5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592","source":"oci","createdAt":"2026-10-20T08:00:00.000Z","sizeBytes":1048576,"pinned":true},{"id":"img_2","name":"base","ref":"ubuntu:24.04","digest":"sha256:7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7","source":"oci","createdAt":"2026-10-19T08:00:00.000Z","sizeBytes":2097152,"pinned":false}]' \
    STUB_IMPD_IMAGE_DIRS='7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7 9e107d9d372bb6826bd81d3542a419d69e107d9d372bb6826bd81d3542a419d6' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
impd's image pv-base points at /var/lib/imp/images/5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592, which holds no rootfs.ext4
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF

  run -0 diff - "$tree/calls" << EOF
$list_call
$dirs_call
EOF
}

@test "it names every record without a build folder" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_1","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4","digest":"sha256:5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592","source":"oci","createdAt":"2026-10-20T08:00:00.000Z","sizeBytes":1048576,"pinned":true},{"id":"img_2","name":"base","ref":"ubuntu:24.04","digest":"sha256:7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7","source":"oci","createdAt":"2026-10-19T08:00:00.000Z","sizeBytes":2097152,"pinned":false}]' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
impd's image pv-base points at /var/lib/imp/images/5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592, which holds no rootfs.ext4
impd's image base points at /var/lib/imp/images/7d793037a0760186574b0282f2f435e77d793037a0760186574b0282f2f435e7, which holds no rootfs.ext4
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF
}

@test "it fails naming a record whose digest names no folder" {
  setup_test "$tree"

  run -1 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMPD_IMAGES='[{"id":"img_1","name":"pv-base","ref":"ghcr.io/zgeoff/imp-base:4.2.4","digest":"../../etc","source":"oci","createdAt":"2026-10-20T08:00:00.000Z","sizeBytes":1048576,"pinned":true}]' \
    STUB_IMPD_IMAGE_DIRS='5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592' \
    bash "$script" root@geoffcloud

  refute_output
  assert_stderr - << 'EOF'
impd's image pv-base has the digest '../../etc', which names no image folder
re-add each image from its reference with `impz image add <ref> --name <name>` (docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)
EOF
}

@test "it stops with podman exit code when imp host is gone" {
  setup_test "$tree"

  run -125 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    STUB_IMP_HOST_GONE=1 bash "$script" root@geoffcloud

  refute_output
  assert_stderr 'Error: no container with name or ID "imp-host" found: no such container'

  run -0 diff - "$tree/calls" <<< "$list_call"
}

@test "it prints its usage without a host" {
  setup_test "$tree"

  run -2 --separate-stderr env -i PATH="$tree/bin:/usr/bin:/bin" HOME="$tree/home" TMPDIR="$tree/tmp" STUB_LOG="$tree/calls" \
    bash "$script"

  refute_output
  assert_stderr 'usage: check-impd-image-dirs.sh <host>'

  run -0 diff /dev/null "$tree/calls"
}
