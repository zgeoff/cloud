export interface PreviewContract {
  readonly port: number;
  readonly healthPath: string;
}

export function parsePreviewContract(composeYAML: string): PreviewContract {
  const compose = requireMapping(Bun.YAML.parse(composeYAML), 'preview/compose.yaml');
  const block = requireMapping(compose['x-preview'] ?? {}, 'x-preview');

  // impd's default HTTP port
  const port = block['port'] ?? 8080;
  const healthPath = block['health'] ?? '/';

  if (typeof port !== 'number' || !Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new TypeError('x-preview.port is not a TCP port');
  }

  if (typeof healthPath !== 'string' || !healthPath.startsWith('/')) {
    throw new TypeError('x-preview.health is not a path that starts with /');
  }

  return { port, healthPath };
}

function requireMapping(value: unknown, what: string): Readonly<Record<string, unknown>> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError(`${what} is not a mapping`);
  }

  // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- checked as an object above
  return value as Readonly<Record<string, unknown>>;
}
