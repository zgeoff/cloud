# The exposure registry: every public route and port, and each port the host keeps to the tailnet
# or to itself, from its one written source. The host config builds its firewall's public ports
# and its cloud_host admissions from it, and checks/exposure.nix compares it with the evaluated
# firewall. It reads ../packages/topology, so the flake builds with the repo root as its source
# (path:.?dir=nixos), as nixos/topology.nix does.
builtins.fromJSON (builtins.readFile ../packages/topology/exposure.json)
