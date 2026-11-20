import { onTestFinished } from 'bun:test';
import type { startTestImpd as StartTestImpd, TestImpd } from '@impz/testing';
import { http, passthrough } from 'msw';
import { z } from 'zod';
import { server } from './server.ts';

export interface ScriptsImpd {
  readonly url: string;
  readonly token: string;
  readonly fail: TestImpd['fail'];

  // each procedure the test called with the right token, in order, as `<router>/<procedure>` or
  // `images/add <name> <ref>`
  readonly calls: readonly string[];

  readonly seedImage: TestImpd['seedImage'];
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
export async function startSharedScriptsImpd(): Promise<void> {
  const testing = await import('@impz/testing');

  shared.impd = await startSharedImpd(testing.startTestImpd);
}

export function startScriptsImpd(): ScriptsImpd {
  const sharedImpd = shared.impd;

  if (sharedImpd === undefined) {
    throw new Error('the preload has not started the impd');
  }

  const impd = sharedImpd.impd;
  const token = sharedImpd.token;
  const first = impd.calls.length;

  // the preload resets MSW's handlers after each test, so each test allows loopback again
  allowLoopback(impd);

  onTestFinished(async () => {
    allowLoopback(impd);

    impd.clearFaults();

    for (const image of await impd.client.images.list()) {
      await impd.client.images.delete({ name: image.name });
    }
  });

  return {
    url: impd.url,
    token,
    fail: (...args) => impd.fail(...args),
    get calls() {
      return impd.calls
        .filter((call, index) => index >= first && call.authorization === `Bearer ${token}`)
        .map((call) => formatCall(call.procedure, call.input));
    },
    seedImage: (name) => impd.seedImage(name),
  };
}

// stops the impd of the file that has just ended; the preload starts another before the next file
export async function stopScriptsImpd(): Promise<void> {
  const started = shared.impd;

  shared.impd = undefined;

  await started?.impd.stop();
}

async function startSharedImpd(startTestImpd: typeof StartTestImpd): Promise<SharedImpd> {
  const impd = await startTestImpd();

  // the mint is real loopback traffic too
  allowLoopback(impd);

  const minted = await impd.client.tokens.create({ name: 'scripts-test', scope: 'manage' });

  return { impd, token: minted.secret };
}

// the script's fetch to impd is real loopback traffic, which MSW lets through
function allowLoopback(impd: TestImpd): void {
  server.use(
    http.all(`${impd.url}/*`, () => passthrough()),
    http.all(`${impd.impdUrl}/*`, () => passthrough()),
  );
}

const addInputSchema = z.object({ name: z.string(), ref: z.string() });

function formatCall(procedure: string, input: unknown): string {
  const add = addInputSchema.safeParse(input);

  return procedure === 'images/add' && add.success
    ? `${procedure} ${add.data.name} ${add.data.ref}`
    : procedure;
}
