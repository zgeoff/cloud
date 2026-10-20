import { join } from 'node:path';
import { buildNetworkPolicyManifests } from './build-network-policy-manifests.ts';

// the NixOS check reads nothing outside nixos/ and packages/topology, so it applies this copy of
// the policies; a test fails while the copy differs from the builders
await Bun.write(
  join(import.meta.dir, '..', '..', 'nixos', 'checks', 'network-policies.json'),
  `${JSON.stringify(buildNetworkPolicyManifests(), null, 2)}\n`,
);
