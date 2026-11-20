import { onTestFinished } from 'bun:test';
import type { TestImpd } from '@impz/testing';
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

// the impd of this test file: the first test starts it and the preload stops it once the file ends,
// so each file pays for one start; each test's cleanup empties it
const shared: { impd: Promise<TestImpd> | undefined } = { impd: undefined };

// the preload imports this file, so the package loads on the first call, and no other file pays
export async function startScriptsImpd(): Promise<ScriptsImpd> {
  const testing = await import('@impz/testing');

  shared.impd ??= testing.startTestImpd();

  const impd = await shared.impd;

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
    token: testing.TEST_TOKEN,
    fail: (...args) => impd.fail(...args),
    get calls() {
      return impd.calls
        .filter(
          (call, index) => index >= first && call.authorization === `Bearer ${testing.TEST_TOKEN}`,
        )
        .map((call) => formatCall(call.procedure, call.input));
    },
    seedImage: (name) => impd.seedImage(name),
  };
}

// stops the impd of the file that has just ended; the next file's first test starts another
export async function stopScriptsImpd(): Promise<void> {
  const started = shared.impd;

  shared.impd = undefined;

  const impd = await started;

  await impd?.stop();
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
