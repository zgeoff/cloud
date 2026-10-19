import type { Exposure } from '@zgeoff/cloud-topology';

export function getExposurePort(exposure: Exposure, name: string): number {
  const entry = exposure.entries.find((candidate) => candidate.name === name);

  // a reader of the registry must not fall back to its own value
  if (entry?.kind !== 'host-port' || entry.port === undefined) {
    throw new Error(`the exposure registry has no host-port entry ${name} with a port`);
  }

  return entry.port;
}
