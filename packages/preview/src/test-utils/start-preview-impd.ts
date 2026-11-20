import { onTestFinished } from 'bun:test';
import type { startTestImpd as StartTestImpd, TestImpd } from '@impz/testing';
import { http, passthrough } from 'msw';
import { z } from 'zod';
import { server as mockServer } from './server.ts';

interface PreviewImpSeed {
  readonly name: string;
  readonly state?: 'running' | 'sleeping';
  readonly image?: string;
  readonly httpPort?: number;

  // each one is a secret from seedSecret
  readonly grants?: readonly string[];
}

// the package's impd boots no VM, so it runs no command and has no wake proxy
export interface PreviewImpd {
  readonly url: string;
  readonly token: string;
  readonly client: TestImpd['client'];
  readonly fail: TestImpd['fail'];
  readonly freeze: TestImpd['freeze'];
  readonly thaw: TestImpd['thaw'];

  // each call the test made with the right token, as `<router>/<procedure> <name>`, or the
  // procedure alone for one that names no imp, in order: impd answers a wrong token with a 401
  // that the old hand-written fake did not log
  readonly calls: readonly string[];

  readonly seedImp: (options: PreviewImpSeed) => Promise<void>;

  // a custom secret that covers a host of its own, so no two secrets clash
  readonly seedSecret: (name: string) => Promise<void>;

  // the egress mode of each imp impd holds, by name; impd gives an imp created without a policy
  // its default, open
  readonly readEgressModes: () => Promise<Map<string, string>>;

  // the path filter that the last grant call of each filtered grant sent, as `<imp> <secret>`:
  // impd's answer to a grants.list names the secrets and no filter
  readonly readGrantPaths: () => Map<string, readonly string[]>;
}

// the impd of this test file: the first test starts it and the preload stops it once the file ends,
// so each file pays for one start; each test's cleanup empties it
const shared: { impd: Promise<TestImpd> | undefined } = { impd: undefined };

// the preload imports this file, so the package loads on the first call, and no other file pays
export async function startPreviewImpd(): Promise<PreviewImpd> {
  const testing = await import('@impz/testing');

  shared.impd ??= startSharedImpd(testing.startTestImpd);

  const impd = await shared.impd;

  // the preload resets MSW's handlers after each test, so each test allows loopback again
  allowLoopback(impd);

  const state = { first: impd.calls.length, arranged: new Set<number>() };

  onTestFinished(async () => {
    allowLoopback(impd);

    impd.clearFaults();
    impd.thaw();

    for (const imp of await impd.client.imps.list({})) {
      await impd.client.imps.destroy({ name: imp.name });
    }

    for (const secret of await impd.client.secrets.list({})) {
      await impd.client.secrets.delete({ name: secret.name });
    }
  });

  // a read or a write that arranges the test's start, not a call the unit made
  const arrange = async <T>(run: () => Promise<T>): Promise<T> => {
    const first = impd.calls.length;

    try {
      return await run();
    } finally {
      for (let index = first; index < impd.calls.length; index += 1) {
        state.arranged.add(index);
      }
    }
  };

  return {
    url: impd.url,
    token: testing.TEST_TOKEN,
    client: impd.client,
    fail: (...args) => impd.fail(...args),
    freeze: () => {
      impd.freeze();
    },
    thaw: () => {
      impd.thaw();
    },
    get calls() {
      return impd.calls
        .filter(
          (call, index) =>
            index >= state.first &&
            !state.arranged.has(index) &&
            call.authorization === `Bearer ${testing.TEST_TOKEN}`,
        )
        .map((call) => formatCall(call.procedure, call.input));
    },
    seedImp: (options) =>
      arrange(async () => {
        await impd.client.imps.create({
          name: options.name,
          image: options.image ?? 'base',
          memoryMib: 2048,
          httpPort: options.httpPort ?? 8080,
          backup: false,
        });

        for (const secret of options.grants ?? []) {
          await addSecret(impd, secret);

          await impd.client.grants.add({ name: options.name, secret });
        }

        if (options.state === 'sleeping') {
          await impd.client.imps.sleep({ name: options.name });
        }
      }),
    seedSecret: (name) => arrange(() => addSecret(impd, name)),
    readEgressModes: () =>
      arrange(async () => {
        const imps = await impd.client.imps.list({});

        const modes = await Promise.all(
          imps.map(async (imp) => {
            const policy = await impd.client.imps.policy({ name: imp.name });

            return [imp.name, policy.mode] as const;
          }),
        );

        return new Map(modes);
      }),
    readGrantPaths: () => {
      const paths = new Map<string, readonly string[]>();

      for (const call of impd.calls.slice(state.first)) {
        const filter = readGrantFilter(call.procedure, call.input);

        if (filter !== undefined) {
          paths.set(filter.key, filter.paths);
        }
      }

      return paths;
    },
  };
}

// stops the impd of the file that has just ended; the next file's first test starts another
export async function stopPreviewImpd(): Promise<void> {
  const started = shared.impd;

  shared.impd = undefined;

  const impd = await started;

  await impd?.stop();
}

const images = ['base', 'pv-base'];

async function startSharedImpd(startTestImpd: typeof StartTestImpd): Promise<TestImpd> {
  const impd = await startTestImpd({ features: { execRequire: true } });

  for (const image of images) {
    await impd.seedImage(image);
  }

  return impd;
}

// the service's fetch to impd is real loopback traffic, which MSW lets through
function allowLoopback(impd: TestImpd): void {
  mockServer.use(
    http.all(`${impd.url}/*`, () => passthrough()),
    http.all(`${impd.impdUrl}/*`, () => passthrough()),
  );
}

const namedInputSchema = z.object({ name: z.string() });

function formatCall(procedure: string, input: unknown): string {
  const named = namedInputSchema.safeParse(input);

  return named.success ? `${procedure} ${named.data.name}` : procedure;
}

async function addSecret(impd: TestImpd, name: string): Promise<void> {
  await impd.client.secrets.add({
    kind: 'custom',
    name,
    value: `${name}-value`,
    replace: true,
    rules: [{ host: `${name}.example.test`, header: 'authorization', scheme: 'bearer' }],
  });
}

const grantFilterSchema = z.object({ paths: z.array(z.string()).optional() });

const grantInputSchema = z.object({
  name: z.string(),
  secret: z.string(),
  filter: grantFilterSchema.optional(),
});

function readGrantFilter(
  procedure: string,
  input: unknown,
): { readonly key: string; readonly paths: readonly string[] } | undefined {
  const parsed = grantInputSchema.safeParse(input);

  if (procedure !== 'grants/add' || !parsed.success || parsed.data.filter?.paths === undefined) {
    return undefined;
  }

  return { key: `${parsed.data.name} ${parsed.data.secret}`, paths: parsed.data.filter.paths };
}
