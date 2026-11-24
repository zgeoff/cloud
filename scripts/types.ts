export interface TargetImageFiles {
  // an atc config file: JSON with targets.<name>.image
  readonly atcConfigs: readonly string[];

  // a NixOS file that sets `image = "agent-..."` for the atc daemon's targets, and the clone that
  // holds it
  readonly nix: { readonly clone: string; readonly file: string };
}

// what an impz call answered, as text
export interface ImpAnswer {
  readonly exitCode: number;
  readonly timedOut: boolean;
  readonly stdout: string;
  readonly stderr: string;
}

// `ok` lets the move go on, or says it is done; `skip` leaves the alias where it was and passes the
// build; `fail` fails the build
export type AliasVerdict =
  | { readonly kind: 'ok' }
  | { readonly kind: 'skip'; readonly reason: string }
  | { readonly kind: 'fail'; readonly reason: string };
