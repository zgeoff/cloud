// The impd secrets that the atc daemon's token atc-cloud may grant, in the mint's order: glm, which
// install-atc-gateway-credentials adds, then each secret that an auth profile of the daemon in
// nixos/hosts/geoffcloud/configuration.nix names. scripts/host/mint-atc-imp-token.sh mints with them.
export const atcCloudGrantable: readonly string[] = [
  'glm',
  'claude-setup-token',
  'github-imp-agents',
  'linear-imp-agents',
  'op-connect',
];
