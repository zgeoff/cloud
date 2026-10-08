# Renders a check's cases as the it_ functions scripts/test-lib/run-cases.sh runs: each case's
# script, run in a fresh directory of its own. A case is { title, script }; the title is the
# case's name with spaces for underscores, as run_cases prints it, so it must start with "it "
# and hold only letters, digits, spaces and , . / : -, and no two cases may share one. It throws
# the first message collect-case-rejections.nix lists for the cases.
# nixos/checks/test-utils-check.nix tests it.
{ lib }:
cases:
let
  rejections = import ./collect-case-rejections.nix { inherit lib; } cases;
in
if rejections != [ ] then
  throw (builtins.head rejections)
else
  lib.concatMapStrings (c: ''
    ${lib.replaceStrings [ " " ] [ "_" ] c.title}() {
    cd "$(mktemp -d)"
    ${c.script}
    }
  '') cases
