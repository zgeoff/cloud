import constants from './constants.json' with { type: 'json' };
import { topologySchema } from './topology-schema.ts';

// The shared constants, checked against their schema once, when the package loads
export const topology = topologySchema.parse(constants);
export { type Topology, topologySchema } from './topology-schema.ts';
