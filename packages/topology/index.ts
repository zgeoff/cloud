import constants from './constants.json' with { type: 'json' };
import { exposureSchema } from './exposure-schema.ts';
import registry from './exposure.json' with { type: 'json' };
import { requireExposureMatchesTopology } from './require-exposure-matches-topology.ts';
import { topologySchema } from './topology-schema.ts';

// The shared constants and the exposure registry, each checked against its schema once, when the
// package loads, and the registry's ports against the constants
export const topology = topologySchema.parse(constants);
export const exposure = exposureSchema.parse(registry);
requireExposureMatchesTopology(exposure, topology);
export { type Exposure, type ExposureEntry } from './exposure-schema.ts';
export { type Topology, topologySchema } from './topology-schema.ts';
