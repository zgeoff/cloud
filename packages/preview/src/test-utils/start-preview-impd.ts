import { onTestFinished } from 'bun:test';
import { createImpClient } from '@impz/client';
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

  // the path filter that impd stores for each filtered grant, by `<imp> <secret>`
  readonly readGrantPaths: () => Promise<Map<string, readonly string[]>>;
}

interface SharedImpd {
  readonly impd: TestImpd;

  // the secret of a token the test impd mints for the code under test, so a call that the test's
  // own setup makes with the root token stays out of the calls
  readonly token: string;
}

// the impd of this test file: the preload's beforeAll starts it and its afterAll stops it, so each
// file pays for one start outside its tests; each test's cleanup empties it
const shared: { impd: SharedImpd | undefined } = { impd: undefined };

// the preload starts the impd before each file's tests; the preload imports this file, so the
// package loads there
export async function startSharedPreviewImpd(): Promise<void> {
  const testing = await import('@impz/testing');

  shared.impd = await startSharedImpd(testing.startTestImpd);
}

export function startPreviewImpd(): PreviewImpd {
  const sharedImpd = shared.impd;

  if (sharedImpd === undefined) {
    throw new Error('the preload has not started the impd');
  }

  const impd = sharedImpd.impd;
  const token = sharedImpd.token;

  // the preload resets MSW's handlers after each test, so each test allows loopback again
  allowLoopback(impd);

  const first = impd.calls.length;

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

  // the test arranges its start with the root client, and the unit and the test's own reads use the
  // minted token's
  return {
    url: impd.url,
    token,
    client: createImpClient({ url: impd.url, token }),
    fail: (...args) => impd.fail(...args),
    freeze: () => {
      impd.freeze();
    },
    thaw: () => {
      impd.thaw();
    },
    get calls() {
      return impd.calls
        .filter((call, index) => index >= first && call.authorization === `Bearer ${token}`)
        .map((call) => formatCall(call.procedure, call.input));
    },
    seedImp: async (options) => {
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
    },
    seedSecret: (name) => addSecret(impd, name),
    readEgressModes: async () => {
      const imps = await impd.client.imps.list({});

      const modes = await Promise.all(
        imps.map(async (imp) => {
          const policy = await impd.client.imps.policy({ name: imp.name });

          return [imp.name, policy.mode] as const;
        }),
      );

      return new Map(modes);
    },
    readGrantPaths: async () => {
      const paths = new Map<string, readonly string[]>();

      const imps = await impd.client.imps.list({});

      for (const imp of imps) {
        const grants = await impd.client.grants.details({ name: imp.name });

        for (const grant of grants) {
          if (grant.filter?.paths !== undefined) {
            paths.set(`${imp.name} ${grant.secret}`, grant.filter.paths);
          }
        }
      }

      return paths;
    },
  };
}

// stops the impd of the file that has just ended; the preload starts another before the next file
export async function stopPreviewImpd(): Promise<void> {
  const started = shared.impd;

  shared.impd = undefined;

  await started?.impd.stop();
}

const images = ['base', 'pv-base'];

async function startSharedImpd(startTestImpd: typeof StartTestImpd): Promise<SharedImpd> {
  const impd = await startTestImpd({ features: { execRequire: true } });

  for (const image of images) {
    await impd.seedImage(image);
  }

  // the mint is real loopback traffic too
  allowLoopback(impd);

  const minted = await impd.client.tokens.create({ name: 'preview-test', scope: 'manage' });

  return { impd, token: minted.secret };
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
