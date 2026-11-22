import { existsSync, readFileSync, readdirSync } from 'node:fs';

// imp-issuers holds one trust document per imp host, as `impz identity jwks` prints it, and
// forwarder-issuers one per telemetry forwarder, as its `install` prints it. With none, ingest
// refuses every request that the folder's senders make.
export type PepysTrustFolder = 'imp-issuers' | 'forwarder-issuers';

export function readPepysTrustDocuments(name: PepysTrustFolder): Record<string, string> {
  const folder = new URL(`../../deploy/pepys/${name}/`, import.meta.url);

  if (!existsSync(folder)) {
    return {};
  }

  return Object.fromEntries(
    readdirSync(folder)
      .filter((file) => file.endsWith('.json'))
      .map((file) => [file, readFileSync(new URL(file, folder), 'utf8')]),
  );
}
