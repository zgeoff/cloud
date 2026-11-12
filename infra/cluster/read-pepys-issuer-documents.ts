import { existsSync, readFileSync, readdirSync } from 'node:fs';

const folder = new URL('../../deploy/pepys/imp-issuers/', import.meta.url);

// one trust document per imp host, as `impz identity jwks` prints it; with none, ingest refuses
// every telemetry export
export function readPepysIssuerDocuments(): Record<string, string> {
  if (!existsSync(folder)) {
    return {};
  }

  return Object.fromEntries(
    readdirSync(folder)
      .filter((name) => name.endsWith('.json'))
      .map((name) => [name, readFileSync(new URL(name, folder), 'utf8')]),
  );
}
