# Renders a check's cases as the it_ functions scripts/test-lib/run-cases.sh runs: each case's
# script, run in a fresh directory of its own. A case is { title, script }; the title is the
# case's name with spaces for underscores, as run_cases prints it, so it must start with "it "
# and hold only letters, digits, spaces and , . / : -, and no two cases may share one.
# nixos/checks/test-utils-check.nix tests it.
{ lib }:
cases:
let
  titles = map (c: c.title) cases;
  invalid = lib.filter (title: builtins.match "it [A-Za-z0-9 ,./:-]+" title == null) titles;
  repeated = lib.filter (title: lib.count (other: other == title) titles > 1) (lib.unique titles);
in
if invalid != [ ] then
  throw "renderCases: titles must be \"it \" and letters, digits, spaces or , . / : -: ${lib.concatStringsSep "; " invalid}"
else if repeated != [ ] then
  throw "renderCases: titles must be unique: ${lib.concatStringsSep "; " repeated}"
else
  lib.concatMapStrings (c: ''
    ${lib.replaceStrings [ " " ] [ "_" ] c.title}() {
    cd "$(mktemp -d)"
    ${c.script}
    }
  '') cases
