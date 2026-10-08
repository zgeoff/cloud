# The messages renderCases rejects a check's cases with, in the order it checks them: a title
# that is not "it " and letters, digits, spaces or , . / : -, then a title two cases share. An
# empty list means renderCases renders the cases. render-cases.nix throws the first message;
# nixos/checks/test-utils-check.nix tests it.
{ lib }:
cases:
let
  titles = map (c: c.title) cases;
  invalid = lib.filter (title: builtins.match "it [A-Za-z0-9 ,./:-]+" title == null) titles;
  repeated = lib.filter (title: lib.count (other: other == title) titles > 1) (lib.unique titles);
in
lib.optional (invalid != [ ])
  "renderCases: titles must be \"it \" and letters, digits, spaces or , . / : -: ${lib.concatStringsSep "; " invalid}"
++ lib.optional (repeated != [ ])
  "renderCases: titles must be unique: ${lib.concatStringsSep "; " repeated}"
