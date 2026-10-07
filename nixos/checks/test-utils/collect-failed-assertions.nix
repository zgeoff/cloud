# The messages of every assertion that fails in an evaluated NixOS system, in the order the
# system lists them. nixos/checks/test-utils-check.nix tests it.
system: map (a: a.message) (builtins.filter (a: !a.assertion) system.config.assertions)
