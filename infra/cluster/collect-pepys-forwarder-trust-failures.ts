import { createHash } from 'node:crypto';
import { z } from 'zod';

// Ingest exits at start on a document its loader refuses, and on an issuer name or key that both
// folders hold, so each failure here would stop the new ingest pod. Each document of the forwarders
// is named after its issuer, so the folder never names one issuer twice.
export function collectPepysForwarderTrustFailures(
  forwarders: Readonly<Record<string, string>>,
  imps: Readonly<Record<string, string>>,
): string[] {
  const failures: string[] = [];

  const impDocuments = Object.values(imps).flatMap((text) => {
    const parsed = parseDocument(text);

    return parsed === undefined ? [] : [parsed];
  });

  const impIssuers = new Set(impDocuments.map((document) => document.issuer));
  const impThumbprints = new Set(impDocuments.flatMap((document) => collectThumbprints(document)));

  for (const [file, text] of Object.entries(forwarders)) {
    const document = parseDocument(text);
    const where = `deploy/pepys/forwarder-issuers/${file}`;

    if (document === undefined) {
      failures.push(`${where} is not a trust document that ingest loads`);
      continue;
    }

    if (file !== `${document.issuer}.json`) {
      failures.push(`${where} must be named ${document.issuer}.json, after its issuer`);
    }

    if (impIssuers.has(document.issuer)) {
      failures.push(`${where} names the issuer ${document.issuer}, which an imp host has`);
    }

    if (collectThumbprints(document).some((thumbprint) => impThumbprints.has(thumbprint))) {
      failures.push(`${where} holds a key that an imp host's trust document holds`);
    }
  }

  return failures;
}

// The fields that @impz/client's loadIdentityIssuers takes, which ingest runs at start
const keySchema = z.object({
  kty: z.literal('EC'),
  crv: z.literal('P-256'),
  x: z.string().regex(/^[\w-]+$/u),
  y: z.string().regex(/^[\w-]+$/u),
  kid: z.string().min(1).max(128),
  alg: z.literal('ES256'),
  use: z.literal('sig'),
});

const retireSchema = z.object({ kid: z.string().min(1).max(128), at: z.int().nonnegative() });

const documentSchema = z.object({
  issuer: z.string().regex(/^[\w.-]{1,128}$/u),
  keys: z.array(keySchema).min(1).max(2),
  retire: z.array(retireSchema).max(1),
});

type TrustDocument = z.output<typeof documentSchema>;

function parseDocument(text: string): TrustDocument | undefined {
  try {
    const result = documentSchema.safeParse(JSON.parse(text));

    return result.success ? result.data : undefined;
  } catch {
    return undefined;
  }
}

// RFC 7638: the SHA-256 of the key's required members, in lexical order with no whitespace. Ingest
// compares keys by it, whatever their kid.
function collectThumbprints(document: TrustDocument): string[] {
  return document.keys.map((key) => {
    const members = JSON.stringify({ crv: key.crv, kty: key.kty, x: key.x, y: key.y });

    return createHash('sha256').update(members).digest('base64url');
  });
}
