import { parseArgs } from 'node:util';
import { match } from 'ts-pattern';

// A stand-in for `kubectl proxy --port=0`, run as its own program with --mode serve, refuse (with
// --error <text>) or quiet. Its serving line is kubectl's, from pkg/cmd/proxy/proxy.go at v0.34.1,
// with the listener's address.
type StubMode =
  | { readonly mode: 'serve' }
  | { readonly mode: 'refuse'; readonly error: string }
  | { readonly mode: 'quiet' };

const stubMode = parseStubArgs(process.argv.slice(2));

if (stubMode === undefined) {
  process.stderr.write(`unexpected: ${JSON.stringify(process.argv.slice(2))}\n`);
  process.exit(97);
}

match(stubMode)
  .with({ mode: 'serve' }, () => {
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      routes: { '/*': new Response('stub kubectl proxy') },
    });

    process.stdout.write(`Starting to serve on 127.0.0.1:${String(server.port)}\n`);
  })
  .with({ mode: 'refuse' }, (refusal) => {
    process.stderr.write(`${refusal.error}\n`);
    process.exit(1);
  })
  .with({ mode: 'quiet' }, () => {
    setInterval(() => {}, 60_000);
  })
  .exhaustive();

// util.parseArgs throws on an option it does not know
function parseStubArgs(args: readonly string[]): StubMode | undefined {
  const parsed = tryParseArgs(args);
  const mode = parsed?.values.mode;
  const error = parsed?.values.error;

  if (mode === 'serve' && error === undefined) {
    return { mode };
  }

  if (mode === 'refuse' && error !== undefined) {
    return { mode, error };
  }

  if (mode === 'quiet' && error === undefined) {
    return { mode };
  }

  return undefined;
}

function tryParseArgs(args: readonly string[]) {
  try {
    return parseArgs({
      args: [...args],
      options: { mode: { type: 'string' }, error: { type: 'string' } },
      strict: true,
    });
  } catch {
    return null;
  }
}
