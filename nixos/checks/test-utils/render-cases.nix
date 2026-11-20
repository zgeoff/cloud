# Renders a check's cases as one .bats file that a bats call in the check runs. The file starts
# with bats_require_minimum_version 1.5.0 and a setup that loads bats-support and bats-assert, which
# the check gets from pkgs.bats.withLibraries, then moves into $BATS_TEST_TMPDIR, the fresh
# directory bats makes for each case. The setup then sources each file of `sources`, such as
# wait-for.sh, so the functions they define reach every case. The file defines assert_within, which
# a case calls for a value that must be a whole number from a low to a high bound.
#
# Each case becomes a @test whose script runs in a subshell of its own, with errexit, nounset and
# pipefail, as the old run_cases ran it. The subshell lets a case set an EXIT trap, which would
# replace the trap bats uses to record the case's result, and closes bats' output descriptor 3, so a
# background process the case starts does not keep bats waiting after the case ends.
#
# A case is { title, script }; the title is the case's name and must start with "it " and hold only
# letters, digits, spaces and , . / : -, and no two cases may share one. It throws the first
# message collect-case-rejections.nix lists for the cases.
# nixos/checks/test-utils-check.nix tests it.
{
  lib,
  sources ? [ ],
}:
cases:
let
  rejections = import ./collect-case-rejections.nix { inherit lib; } cases;
in
if rejections != [ ] then
  throw (builtins.head rejections)
else
  ''
    bats_require_minimum_version 1.5.0

    setup() {
      bats_load_library bats-support
      bats_load_library bats-assert
      cd "$BATS_TEST_TMPDIR"
    ${
      lib.concatMapStrings (file: ''
        source ${file}
      '') sources
    }}

    # assert_within <low> <value> <high>: fails unless the value is a whole number from low to high
    assert_within() {
      assert_regex "$2" '^[0-9]+$'
      assert [ "$2" -ge "$1" ]
      assert [ "$2" -le "$3" ]
    }

  ''
  + lib.concatMapStrings (c: ''
    @test "${c.title}" {
    (
    exec 3>&-
    set -euo pipefail
    ${c.script}
    )
    }

  '') cases
