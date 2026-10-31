# A derivation whose output lists, one per line and sorted, each store path that a file of the
# package names but the package's closure lacks, and is empty when the closure holds every one.
# Nix turns a path value, such as a module's ./file, into a string with no reference when the
# value reaches the text through toString instead of "${...}". The build machine has that path,
# so a check that runs there passes, and a host that receives only the closure does not have it.
#
#   buildStorePathGaps package
#
# nixos/checks/test-utils-check.nix tests it.
{ pkgs }:
package:
pkgs.runCommand "store-path-gaps"
  {
    closure = pkgs.closureInfo { rootPaths = [ package ]; };
  }
  ''
    # a store path's name never holds a slash, a space or a quote
    grep -rhoaE '${builtins.storeDir}/[0-9a-z]{32}-[^/[:space:]"'"'"'`;:)]+' ${package} | sort -u > named || true
    sort -u "$closure/store-paths" > closure
    comm -23 named closure > "$out"
  ''
