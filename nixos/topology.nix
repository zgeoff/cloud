# The constants that the host shares with infra, the scripts and the images, from their one
# written source. It reads ../packages/topology, so the flake builds with the repo root as its
# source (path:.?dir=nixos), as scripts/switch-geoffcloud.sh and scripts/run-nixos-checks.sh do.
builtins.fromJSON (builtins.readFile ../packages/topology/constants.json)
