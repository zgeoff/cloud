import type { Exposure } from '@zgeoff/cloud-topology';

// The port of the registry's host-port entry with this name. Throws when the registry has no such
// entry or the entry has no port, since a reader of the registry must not fall back to its own value.
export function getExposurePort(exposure: Exposure, name: string): number {
  const entry = exposure.entries.find((candidate) => candidate.name === name);

  if (entry?.kind !== 'host-port' || entry.port === undefined) {
    throw new Error(`the exposure registry has no host-port entry ${name} with a port`);
  }

  return entry.port;
}
