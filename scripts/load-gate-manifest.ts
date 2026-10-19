import { readFile } from 'node:fs/promises';

// One path gate of .github/gates.yml: the check it names runs when a changed file matches one of
// its paths and none of its ignore globs.
export interface Gate {
  readonly name: string;
  readonly paths: readonly string[];
  readonly ignore: readonly string[];

  // the run summary's line when CI skips the check
  readonly skipped: string | undefined;
}

export type GateManifest = ReadonlyMap<string, Gate>;

// Reads and checks the manifest, and throws on any shape it does not know, such as a gate with no
// paths or a key it never reads, so a typo fails the caller instead of skipping a check.
export async function loadGateManifest(path: string): Promise<GateManifest> {
  const text = await readFile(path, 'utf8');

  const document: unknown = Bun.YAML.parse(text);

  if (!isRecord(document) || !isRecord(document['gates'])) {
    throw new Error(`${path} holds no gates`);
  }

  requireKnownKeys(path, document, ['gates']);

  return new Map(
    Object.entries(document['gates']).map((entry: readonly [string, unknown]) => [
      entry[0],
      parseGate(path, entry[0], entry[1]),
    ]),
  );
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function requireKnownKeys(
  where: string,
  record: Readonly<Record<string, unknown>>,
  known: readonly string[],
): void {
  const extra = Object.keys(record).filter((key: string) => !known.includes(key));

  if (extra.length > 0) {
    throw new Error(`${where}: unknown key ${extra.join(', ')}`);
  }
}

function parseGate(path: string, name: string, value: unknown): Gate {
  const where = `${path}: gate ${name}`;

  if (!isRecord(value)) {
    throw new Error(`${where} is not a mapping`);
  }

  requireKnownKeys(where, value, ['paths', 'ignore', 'skipped']);

  const skipped = value['skipped'];

  if (skipped !== undefined && (typeof skipped !== 'string' || skipped === '')) {
    throw new Error(`${where}: skipped is not a line of text`);
  }

  return {
    name,
    paths: parseGlobs(`${where}: paths`, value['paths'], true),
    ignore: parseGlobs(`${where}: ignore`, value['ignore'] ?? [], false),
    skipped,
  };
}

function parseGlobs(where: string, value: unknown, required: boolean): string[] {
  if (!Array.isArray(value) || (required && value.length === 0)) {
    throw new Error(`${where} is not a list of globs`);
  }

  return value.map((glob: unknown) => {
    if (typeof glob !== 'string' || glob === '') {
      throw new Error(`${where} holds ${JSON.stringify(glob)}, which is not a glob`);
    }

    return glob;
  });
}
