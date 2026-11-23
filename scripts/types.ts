export interface TargetImageFiles {
  // an atc config file: JSON with targets.<name>.image
  readonly atcConfigs: readonly string[];

  // a NixOS file that sets `image = "agent-..."` for the atc daemon's targets, and the clone that
  // holds it
  readonly nix: { readonly clone: string; readonly file: string };
}
