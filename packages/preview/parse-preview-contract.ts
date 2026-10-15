// What preview/compose.yaml declares in its `x-preview` block, which Compose ignores: the guest
// port the app serves HTTP on, where impd's wake proxy sends requests, and the ready path
export interface PreviewContract {
  readonly port: number;
  readonly healthPath: string;
}

// Throws on a malformed file or block. A file without the block uses port 8080, impd's default
// HTTP port, and the path `/`.
export function parsePreviewContract(composeYAML: string): PreviewContract {
  const compose = requireMapping(Bun.YAML.parse(composeYAML), 'preview/compose.yaml');
  const block = requireMapping(compose['x-preview'] ?? {}, 'x-preview');
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

  return value as Readonly<Record<string, unknown>>;
}
